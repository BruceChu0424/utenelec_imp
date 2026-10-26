package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageResourceUnavailableException;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.AttachmentPreviewProperties;
import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PostConstruct;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.DirectoryStream;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.FileTime;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.stream.Stream;

/**
 * 办公文档在线预览：把已授权的 CLEAN 原件用 LibreOffice 转成 PDF 并缓存在附件存储根目录的
 * {@code preview/} 私有目录（文件名 {@code <附件id>-<原件sha256>.pdf}，原件不可变故缓存可复用）。
 *
 * <p>授权与审计委托 {@link AttachmentService#openPreviewSource}（attachment:download + owner 策略），
 * 本类只负责转换、缓存与并发边界：有限槽位、每槽独立 LibreOffice 用户配置目录、超时强杀、
 * 临时工作目录用后即删。soffice 缺失/超时/失败一律返回业务错误，客户端回落为下载原件。
 * 附件物理删除完成后由删除 Outbox 调用 {@link #evict} 清掉缓存。</p>
 */
@Slf4j
@Service
public class AttachmentPreviewService implements AttachmentPreviewEvictor {

    /** 转换进程执行抽象：单元测试注入假实现，不真的启动 soffice。 */
    @FunctionalInterface
    interface ProcessRunner {
        /** 返回退出码；超过 {@code timeout} 必须结束进程并抛 {@link TimeoutException}。 */
        int run(List<String> command, Path workingDirectory, Duration timeout)
                throws IOException, InterruptedException, TimeoutException;
    }

    /** 已可读的缓存 PDF；{@code fileName} 是给浏览器的展示名（原名改 .pdf 后缀）。 */
    public record RenderedPreview(Path file, long sizeBytes, String fileName) {
    }

    /** Already-open cache content: eviction cannot race the controller's later file open. */
    public record PreviewDownload(InputStream stream, long sizeBytes, String fileName) { }

    /**
     * 交给 LibreOffice 转 PDF 的类型（2026-09-11 从 6 种扩到 11 种）。
     *
     * <p>入选标准只有一条：LibreOffice 打得开且版式还原得住 —— Writer/Calc/Impress 覆盖
     * MS 与 OpenDocument 两套办公格式，Draw 覆盖 svg。客户端自己能渲染的（图片/PDF/文本/CSV/zip）
     * 不进来白占转换槽位；渲染不了也转不动的（tiff/heic/7z/rar）根本不承诺预览。
     * 改这份集合要同步 {@code StorageProperties.allowedContentTypes}、
     * {@link AttachmentContentInspector} 的扩展名表与客户端的能力矩阵，
     * 并确认服务器装了对应的 LibreOffice 组件（见 deploy/simple/RUNBOOK.zh-CN.md 第 1b 步）。</p>
     */
    static final Set<String> CONVERTIBLE_EXTENSIONS = Set.of(
            "doc", "docx", "rtf", "odt",
            "xls", "xlsx", "ods",
            "ppt", "pptx", "odp",
            "svg");
    private static final Set<String> CONVERTIBLE_CONTENT_TYPES = Set.of(
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/rtf",
            "application/vnd.oasis.opendocument.text",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.oasis.opendocument.spreadsheet",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.oasis.opendocument.presentation",
            "image/svg+xml");
    private static final String CACHE_DIRECTORY = "preview";
    private static final String SCRATCH_DIRECTORY = "scratch";
    private static final String WORK_PREFIX = "preview-";
    private static final long SLOT_WAIT_SECONDS = 5;
    private static final Set<String> CONVERTER_ENVIRONMENT = Set.of(
            "PATH", "LANG", "LANGUAGE", "TZ", "LC_ALL", "LC_CTYPE", "LC_COLLATE", "LC_MESSAGES",
            "LC_MONETARY", "LC_NUMERIC", "LC_TIME", "LC_ADDRESS", "LC_IDENTIFICATION",
            "LC_MEASUREMENT", "LC_NAME", "LC_PAPER", "LC_TELEPHONE", "SYSTEMROOT", "WINDIR");

    private final AttachmentService attachments;
    private final AttachmentPreviewProperties properties;
    private final StorageProperties storage;
    private final ProcessRunner runner;
    private final Semaphore slots;
    private final Object cacheLock = new Object();

    @Autowired
    public AttachmentPreviewService(AttachmentService attachments,
                                    AttachmentPreviewProperties properties,
                                    StorageProperties storage) {
        this(attachments, properties, storage,
                (command, directory, timeout) -> runSoffice(command, directory, timeout, properties.getMaxOutputBytes()));
    }

    AttachmentPreviewService(AttachmentService attachments,
                             AttachmentPreviewProperties properties,
                             StorageProperties storage,
                             ProcessRunner runner) {
        this.attachments = attachments;
        this.properties = properties;
        this.storage = storage;
        this.runner = runner;
        int maximum = properties.getMaxConcurrent();
        if (maximum < 1 || maximum > 8) {
            throw new IllegalStateException("Attachment preview concurrency must be between 1 and 8");
        }
        if (properties.getTimeout() == null || properties.getTimeout().isZero()
                || properties.getTimeout().isNegative() || properties.getTimeout().compareTo(Duration.ofMinutes(10)) > 0) {
            throw new IllegalStateException("Attachment preview timeout must be positive and at most ten minutes");
        }
        if (properties.getMaxOutputBytes() <= 0 || properties.getMaxExpandedBytes() <= 0
                || properties.getMaxExpandedBytes() > Integer.MAX_VALUE || properties.getMaxArchiveEntries() <= 0) {
            throw new IllegalStateException("Attachment preview resource limits must be positive and bounded");
        }
        this.slots = new Semaphore(maximum, true);
    }

    @PostConstruct
    void init() {
        Path root = storageRoot();
        if (root == null) {
            if (properties.isEnabled()) {
                log.warn("Attachment preview is enabled but the active storage provider has no private root; previews are unavailable");
            }
            return;
        }
        try {
            Files.createDirectories(root.resolve(CACHE_DIRECTORY));
            Files.createDirectories(root.resolve(SCRATCH_DIRECTORY));
            cleanupAbandonedWork(root.resolve(SCRATCH_DIRECTORY));
        } catch (IOException error) {
            log.warn("Attachment preview cache directory is not writable: {}", error.getMessage());
        }
        if (properties.isEnabled() && !sofficeResolvable()) {
            log.warn("Attachment preview is enabled but soffice is not executable at '{}'; previews are unavailable",
                    properties.getSofficePath());
        }
    }

    /** 转换能力是否就绪（配置打开 + 存储根目录可用 + soffice 可执行）。 */
    public boolean isAvailable() {
        return properties.isEnabled() && storageRoot() != null && sofficeResolvable();
    }

    /** 授权 → 缓存命中直接返回 → 否则还原原件到私有工作目录、转换、原子入缓存。 */
    public RenderedPreview render(UUID attachmentId) {
        AttachmentService.PreviewSource source = attachments.openPreviewSource(attachmentId);
        if (!convertible(source)) {
            throw unsupported("该文件类型不支持在线预览");
        }
        if (source.sizeBytes() <= 0 || source.sizeBytes() > storage.getMaxBytes()) {
            throw unsupported("文件过大");
        }
        if (source.sha256() == null || !source.sha256().matches("[a-f0-9]{64}")) {
            throw unsupported("原件校验信息不完整");
        }
        Path root = storageRoot();
        if (!properties.isEnabled() || root == null) {
            throw unsupported("服务器未开启文档转换");
        }
        Path cacheDirectory = root.resolve(CACHE_DIRECTORY);
        Path cached = cacheDirectory.resolve(cacheFileName(source.id(), source.sha256()));
        RenderedPreview hit = cacheHit(cached, source);
        if (hit != null) {
            return hit;
        }
        if (!sofficeResolvable()) {
            throw unsupported("服务器未安装文档转换组件");
        }
        acquireSlot();
        try {
            hit = cacheHit(cached, source);
            if (hit != null) {
                attachments.openPreviewSource(attachmentId);
                return hit;
            }
            RenderedPreview rendered = convert(root, cached, source);
            // Native conversion can take a minute; recheck live ACL/session/password after waiting.
            attachments.openPreviewSource(attachmentId);
            return rendered;
        } finally {
            slots.release();
        }
    }

    public PreviewDownload open(UUID attachmentId) throws IOException {
        for (int attempt = 0; attempt < 2; attempt++) {
            RenderedPreview rendered = render(attachmentId);
            synchronized (cacheLock) {
                try {
                    long size = Files.size(rendered.file());
                    return new PreviewDownload(Files.newInputStream(rendered.file(),
                            StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS),
                            size, rendered.fileName());
                } catch (java.nio.file.NoSuchFileException evicted) {
                    // A different conversion trimmed this entry between render and open; rebuild once.
                }
            }
        }
        throw new StorageResourceUnavailableException("预览缓存正在更新，请重试");
    }

    /** 附件物理删除完成后清掉其全部缓存版本（按附件 id 前缀）。 */
    @Override
    public void evict(UUID attachmentId) {
        if (attachmentId == null) {
            return;
        }
        Path root = storageRoot();
        if (root == null) {
            return;
        }
        Path cacheDirectory = root.resolve(CACHE_DIRECTORY);
        if (!Files.isDirectory(cacheDirectory)) {
            return;
        }
        String prefix = attachmentId + "-";
        synchronized (cacheLock) {
            try (DirectoryStream<Path> files = Files.newDirectoryStream(cacheDirectory, prefix + "*.pdf")) {
                for (Path file : files) {
                    Files.deleteIfExists(file);
                }
            } catch (IOException error) {
                log.warn("Attachment preview cache eviction failed for {}: {}", attachmentId, error.getMessage());
            }
        }
    }

    static String cacheFileName(UUID attachmentId, String sha256) {
        return attachmentId + "-" + sha256 + "-v2.pdf";
    }

    static boolean convertible(AttachmentService.PreviewSource source) {
        String contentType = source.contentType() == null ? "" : source.contentType().toLowerCase(Locale.ROOT);
        return CONVERTIBLE_CONTENT_TYPES.contains(contentType)
                || CONVERTIBLE_EXTENSIONS.contains(extension(source.originalName()));
    }

    private static String extension(String name) {
        if (name == null) {
            return "";
        }
        int dot = name.lastIndexOf('.');
        if (dot < 0 || dot == name.length() - 1) {
            return "";
        }
        return name.substring(dot + 1).toLowerCase(Locale.ROOT);
    }

    /** Legacy records may have no suffix; keep the worker's fixed format contract without .bin auto-detection. */
    private static String conversionExtension(AttachmentService.PreviewSource source) {
        String extension = extension(source.originalName());
        if (CONVERTIBLE_EXTENSIONS.contains(extension)) return extension;
        return switch (source.contentType() == null ? "" : source.contentType().toLowerCase(Locale.ROOT)) {
            case "application/msword" -> "doc";
            case "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx";
            case "application/rtf" -> "rtf";
            case "application/vnd.oasis.opendocument.text" -> "odt";
            case "application/vnd.ms-excel" -> "xls";
            case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "xlsx";
            case "application/vnd.oasis.opendocument.spreadsheet" -> "ods";
            case "application/vnd.ms-powerpoint" -> "ppt";
            case "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx";
            case "application/vnd.oasis.opendocument.presentation" -> "odp";
            case "image/svg+xml" -> "svg";
            default -> throw unsupported("该文件类型不支持在线预览");
        };
    }

    private static String pdfDisplayName(String originalName) {
        String base = originalName == null || originalName.isBlank() ? "preview" : originalName;
        int dot = base.lastIndexOf('.');
        return (dot > 0 ? base.substring(0, dot) : base) + ".pdf";
    }

    private RenderedPreview cacheHit(Path cached, AttachmentService.PreviewSource source) {
        try {
            if (!Files.isRegularFile(cached, LinkOption.NOFOLLOW_LINKS)) {
                return null;
            }
            long size = Files.size(cached);
            if (size <= 0 || size > properties.getMaxOutputBytes() || !hasPdfSignature(cached)) {
                Files.deleteIfExists(cached);
                return null;
            }
            // 最近使用时间驱动容量淘汰；失败不影响读取。
            try {
                Files.setLastModifiedTime(cached, FileTime.from(Instant.now()));
            } catch (IOException ignored) {
                // 只影响淘汰顺序
            }
            return new RenderedPreview(cached, size, pdfDisplayName(source.originalName()));
        } catch (IOException error) {
            return null;
        }
    }

    private void acquireSlot() {
        boolean acquired;
        try {
            acquired = slots.tryAcquire(SLOT_WAIT_SECONDS, TimeUnit.SECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new StorageResourceUnavailableException("预览转换被中断，请重试");
        }
        if (!acquired) {
            throw new StorageResourceUnavailableException("预览转换繁忙，请稍后重试");
        }
    }

    private RenderedPreview convert(Path root, Path cached, AttachmentService.PreviewSource source) {
        Path scratch = root.resolve(SCRATCH_DIRECTORY);
        Path work = null;
        try {
            Files.createDirectories(scratch);
            Files.createDirectories(cached.getParent());
            work = Files.createTempDirectory(scratch, WORK_PREFIX);
            String extension = conversionExtension(source);
            Path input = work.resolve("source." + extension);
            try (InputStream in = source.open(); OutputStream out = Files.newOutputStream(input)) {
                long copied = 0;
                byte[] buffer = new byte[65536];
                int count;
                while ((count = in.read(buffer, 0, (int) Math.min(buffer.length, source.sizeBytes() - copied + 1))) != -1) {
                    copied += count;
                    if (copied > source.sizeBytes()) throw unsupported("原件大小与记录不一致");
                    out.write(buffer, 0, count);
                }
                if (copied != source.sizeBytes()) throw unsupported("原件大小与记录不一致");
            }
            try {
                com.uten.imp.common.files.document.ZipSafety.inspectOfficePreview(input, properties.getMaxExpandedBytes(),
                        properties.getMaxArchiveEntries(), properties.getTimeout());
                if ("svg".equals(extension) || "image/svg+xml".equals(source.contentType())) {
                    try (InputStream svg = Files.newInputStream(input)) {
                        com.uten.imp.common.files.document.OfficePreviewXmlSafety.inspect(svg,
                                com.uten.imp.common.files.document.OfficePreviewXmlSafety.Kind.SVG);
                    }
                }
            } catch (ApiException invalidArchive) {
                throw unsupported("文档格式或内容未通过预览安全检查");
            }
            // Never reuse document-modifiable profiles or trust stores between conversions.
            Path profile = work.resolve("profile");
            writeSafeProfile(profile);
            List<String> command = List.of(
                    properties.getSofficePath(),
                    "--headless", "--norestore", "--nologo", "--nolockcheck",
                    "-env:UserInstallation=" + profile.toUri(),
                    "--convert-to", "pdf",
                    "--outdir", work.toString(),
                    input.toString());
            int exit = runner.run(command, work, properties.getTimeout());
            Path output = work.resolve("source.pdf");
            if (exit != 0 || !Files.isRegularFile(output, LinkOption.NOFOLLOW_LINKS)
                    || Files.size(output) <= 0 || Files.size(output) > properties.getMaxOutputBytes()
                    || !hasPdfSignature(output)) {
                throw unsupported("文档转换失败");
            }
            synchronized (cacheLock) {
                publish(output, cached);
                trimCache(cached.getParent(), cached);
                long size = Files.size(cached);
                return new RenderedPreview(cached, size, pdfDisplayName(source.originalName()));
            }
        } catch (TimeoutException timeout) {
            log.warn("Attachment preview conversion timed out id={}", source.id());
            throw unsupported("文档转换超时");
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw unsupported("文档转换被中断");
        } catch (ApiException | StorageResourceUnavailableException error) {
            throw error;
        } catch (IOException | RuntimeException error) {
            log.warn("Attachment preview conversion failed id={} type={}", source.id(), error.getClass().getSimpleName());
            throw unsupported("文档转换失败");
        } finally {
            deleteRecursively(work);
        }
    }

    private static boolean hasPdfSignature(Path path) throws IOException {
        try (InputStream input = Files.newInputStream(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            return java.util.Arrays.equals(input.readNBytes(5), "%PDF-".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
        }
    }

    /** Defense in depth, not an OS sandbox. Settings follow LibreOffice's own registry schemas. */
    private static void writeSafeProfile(Path profile) throws IOException {
        Path user = Files.createDirectories(profile.resolve("user"));
        try (InputStream settings = AttachmentPreviewService.class.getResourceAsStream("/attachment-preview-safe-profile.xcu")) {
            if (settings == null) throw new IOException("The shared preview safety profile is unavailable");
            Files.copy(settings, user.resolve("registrymodifications.xcu"));
        }
    }

    /** 先移到同目录临时名再原子改名；并发生成同一缓存时保留先落地者。 */
    private static void publish(Path output, Path cached) throws IOException {
        Path staged = cached.resolveSibling(cached.getFileName() + "." + UUID.randomUUID() + ".part");
        Files.move(output, staged, StandardCopyOption.REPLACE_EXISTING);
        try {
            Files.move(staged, cached, StandardCopyOption.ATOMIC_MOVE);
        } catch (FileAlreadyExistsException raced) {
            Files.deleteIfExists(staged);
        } finally {
            Files.deleteIfExists(staged);
        }
    }

    private void trimCache(Path cacheDirectory, Path retained) {
        long limit = properties.getCacheMaxBytes();
        if (limit <= 0 || cacheDirectory == null || !Files.isDirectory(cacheDirectory)) {
            return;
        }
        try (Stream<Path> listing = Files.list(cacheDirectory)) {
            List<Path> files = new ArrayList<>();
            long total = 0;
            for (Path file : (Iterable<Path>) listing::iterator) {
                if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)
                        || !file.getFileName().toString().endsWith(".pdf")) {
                    continue;
                }
                total += Files.size(file);
                files.add(file);
            }
            if (total <= limit) {
                return;
            }
            files.sort(Comparator.comparing(file -> {
                try {
                    return Files.getLastModifiedTime(file);
                } catch (IOException error) {
                    return FileTime.fromMillis(0);
                }
            }));
            for (Path file : files) {
                if (total <= limit) {
                    break;
                }
                // Keep the response being returned even when one PDF is larger than the cache budget.
                if (file.equals(retained)) continue;
                long size = Files.size(file);
                if (Files.deleteIfExists(file)) {
                    total -= size;
                }
            }
        } catch (IOException error) {
            log.warn("Attachment preview cache trim skipped: {}", error.getMessage());
        }
    }

    private static void cleanupAbandonedWork(Path scratch) {
        if (!Files.isDirectory(scratch)) {
            return;
        }
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(scratch, WORK_PREFIX + "*")) {
            for (Path entry : entries) {
                if (Files.isDirectory(entry, LinkOption.NOFOLLOW_LINKS)) {
                    deleteRecursively(entry);
                }
            }
        } catch (IOException error) {
            log.warn("Abandoned preview work directories were not cleaned: {}", error.getMessage());
        }
    }

    private static void deleteRecursively(Path directory) {
        if (directory == null || !Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) {
            return;
        }
        try (Stream<Path> walk = Files.walk(directory)) {
            walk.sorted(Comparator.reverseOrder()).forEach(path -> {
                try {
                    Files.deleteIfExists(path);
                } catch (IOException ignored) {
                    // 留给下次启动的清扫
                }
            });
        } catch (IOException ignored) {
            // 留给下次启动的清扫
        }
    }

    /** internal → 内部根目录；local（开发）→ 本地目录；oss/disabled 没有私有根目录，不提供预览。 */
    Path storageRoot() {
        String provider = storage.getProvider() == null ? "" : storage.getProvider().trim().toLowerCase(Locale.ROOT);
        String configured = switch (provider) {
            case "internal" -> storage.getInternal() == null ? null : storage.getInternal().getRoot();
            case "local" -> storage.getLocalDir();
            default -> null;
        };
        if (configured == null || configured.isBlank()) {
            return null;
        }
        Path root = Path.of(configured).toAbsolutePath().normalize();
        return Files.isDirectory(root) ? root : null;
    }

    boolean sofficeResolvable() {
        String configured = properties.getSofficePath();
        if (configured == null || configured.isBlank()) {
            return false;
        }
        Path direct = Path.of(configured);
        if (direct.isAbsolute() || configured.contains("/") || configured.contains("\\")) {
            return Files.isExecutable(direct);
        }
        String pathVariable = System.getenv("PATH");
        if (pathVariable == null) {
            return false;
        }
        for (String entry : pathVariable.split(java.io.File.pathSeparator)) {
            if (entry.isBlank()) {
                continue;
            }
            Path candidate = Path.of(entry).resolve(configured);
            if (Files.isExecutable(candidate) || Files.isExecutable(Path.of(candidate + ".exe"))) {
                return true;
            }
        }
        return false;
    }

    private static ApiException unsupported(String reason) {
        return new ApiException(ErrorCode.BUSINESS, "暂不支持预览：" + reason + "，请下载原件查看");
    }

    /**
     * 真实进程：不继承应用凭据, 只保留平台运行/区域设置, HOME 与临时文件落本次私有目录。
     * 输出丢弃, 超时强杀。环境最小化不改变 OS 用户: 文件与进程隔离仍需独立的转换 worker。
     */
    static int runSoffice(List<String> command, Path workingDirectory, Duration timeout)
            throws IOException, InterruptedException, TimeoutException {
        return runSoffice(command, workingDirectory, timeout, 67108864L);
    }

    private static int runSoffice(List<String> command, Path workingDirectory, Duration timeout, long maxOutputBytes)
            throws IOException, InterruptedException, TimeoutException {
        ProcessBuilder builder = new ProcessBuilder(command)
                .directory(workingDirectory.toFile())
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD);
        var environment = builder.environment();
        var runtimeEnvironment = new HashMap<String, String>();
        environment.forEach((name, value) -> {
            if (CONVERTER_ENVIRONMENT.contains(name.toUpperCase(Locale.ROOT))) {
                runtimeEnvironment.put(name, value);
            }
        });
        environment.clear();
        environment.putAll(runtimeEnvironment);
        String privateDirectory = workingDirectory.toAbsolutePath().normalize().toString();
        for (String name : List.of("HOME", "TMPDIR", "TMP", "TEMP")) {
            environment.put(name, privateDirectory);
        }
        Process process = builder.start();
        long deadline = System.nanoTime() + timeout.toNanos();
        var children = new java.util.LinkedHashMap<Long, ProcessHandle>();
        try {
            while (true) {
                process.descendants().forEach(child -> children.put(child.pid(), child));
                if (process.waitFor(100, TimeUnit.MILLISECONDS)) return process.exitValue();
                Path output = workingDirectory.resolve("source.pdf");
                if (Files.isRegularFile(output, LinkOption.NOFOLLOW_LINKS) && Files.size(output) > maxOutputBytes) {
                    throw new IOException("Converted PDF exceeded output limit");
                }
                if (System.nanoTime() - deadline >= 0) {
                    throw new TimeoutException("soffice conversion exceeded " + timeout);
                }
            }
        } finally {
            process.descendants().forEach(child -> children.put(child.pid(), child));
            destroyProcessTree(process, new ArrayList<>(children.values()));
        }
    }

    private static void destroyProcessTree(Process process, List<ProcessHandle> descendants) {
        // soffice may be a launcher with a separate soffice.bin child. Kill descendants first,
        // then reap the launcher before allowing its private directory to be removed.
        for (int index = descendants.size() - 1; index >= 0; index--) {
            ProcessHandle child = descendants.get(index);
            if (child.isAlive()) child.destroyForcibly();
        }
        if (process.isAlive()) process.destroyForcibly();
        boolean interrupted = Thread.interrupted();
        try { process.waitFor(2, TimeUnit.SECONDS); }
        catch (InterruptedException ignored) { interrupted = true; }
        finally { if (interrupted) Thread.currentThread().interrupt(); }
    }
}

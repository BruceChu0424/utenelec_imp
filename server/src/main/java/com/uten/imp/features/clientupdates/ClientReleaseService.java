package com.uten.imp.features.clientupdates;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeMap;
import java.util.UUID;
import java.util.concurrent.Semaphore;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;

@Service
@RequiredArgsConstructor
public class ClientReleaseService {
    public static final String PUBLISH_PERMISSION = "client_release:publish";
    public static final String PUBLISH_EXPRESSION = "hasAuthority('" + PUBLISH_PERMISSION + "') "
            + "and !principal.visitor and !principal.mustChangePassword and principal.impersonatedBy == null";
    public static final String DOWNLOADS_EXPRESSION = "isAuthenticated() and !principal.visitor "
            + "and !principal.mustChangePassword and (principal.superAdmin or principal.employeeId != null)";
    private static final Set<String> PLATFORMS = Set.of("windows", "android", "ios", "macos", "linux");
    private static final Set<String> ARCHITECTURES = Set.of("x86", "x64", "arm64", "armeabi-v7a", "universal");
    private final ClientReleaseCatalog catalog;
    private final ClientPackageInspector inspector;
    private final ClientUpdateProperties properties;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;
    private final Semaphore uploadSlots = new Semaphore(2);

    @PreAuthorize(PUBLISH_EXPRESSION)
    public List<ClientReleaseDto.Release> list() {
        publisher();
        return catalog.locked(root -> catalog.list(root).stream()
                .sorted(Comparator.comparing(ClientReleaseDto.Release::createdAt).reversed()).toList());
    }

    @PreAuthorize(PUBLISH_EXPRESSION)
    public ClientReleaseDto.Release create(ClientReleaseDto.Create request) {
        AuthUser actor = publisher();
        ClientReleaseDto.Release draft = normalize(request);
        ClientReleaseDto.Release result = catalog.locked(root -> {
            Path directory = catalog.directory(root, draft.id());
            if (Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) {
                ClientReleaseDto.Release existing = catalog.require(root, draft.id());
                if (!sameDraft(existing, draft)) throw new ApiException(ErrorCode.CONFLICT, "本次发布编号已用于不同的版本信息");
                return existing;
            }
            if (catalog.list(root).size() >= properties.getMaxReleases())
                throw new ApiException(ErrorCode.CONFLICT, "客户端版本数量已达到上限，请先联系管理员归档");
            catalog.write(root, draft);
            return draft;
        });
        record(actor, "client_release_create", result.id());
        return result;
    }

    @PreAuthorize(PUBLISH_EXPRESSION)
    public ClientReleaseDto.Release upload(UUID id, InputStream input, long contentLength) {
        AuthUser actor = publisher();
        if (contentLength > properties.getMaxPackageBytes()) throw tooLarge();
        if (contentLength == 0) throw invalid("更新包不能为空");
        if (!uploadSlots.tryAcquire()) throw new ApiException(ErrorCode.RATE_LIMITED, "当前已有客户端更新包正在上传，请稍后再试");
        ClientReleaseDto.Release result;
        try {
            result = uploadPackage(id, input, contentLength);
        } finally {
            uploadSlots.release();
        }
        record(actor, "client_release_upload", id);
        return result;
    }

    private ClientReleaseDto.Release uploadPackage(UUID id, InputStream input, long contentLength) {
        UploadTarget target = catalog.locked(root -> {
            ClientReleaseDto.Release release = catalog.require(root, id);
            requireDraft(release);
            if ("store".equals(release.installMode())) throw invalid("应用商店版本不需要上传软件包");
            return new UploadTarget(root, release);
        });
        Path temporary = catalog.directory(target.root(), id).resolve(".upload-" + UUID.randomUUID() + ".tmp");
        ClientReleaseDto.Release result;
        try {
            requireSpace(temporary.getParent(), contentLength >= 0 ? contentLength : 65536);
            long total = 0;
            long lastSpaceCheck = 0;
            var digest = ClientPackageInspector.digest();
            try {
                try (FileChannel output = FileChannel.open(temporary, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
                    byte[] bytes = new byte[65536];
                    for (int read; (read = input.read(bytes)) != -1;) {
                        if (read > properties.getMaxPackageBytes() - total) throw tooLarge();
                        if (total - lastSpaceCheck >= 8388608) {
                            requireSpace(temporary.getParent(), read);
                            lastSpaceCheck = total;
                        }
                        total += read;
                        digest.update(bytes, 0, read);
                        ByteBuffer buffer = ByteBuffer.wrap(bytes, 0, read);
                        while (buffer.hasRemaining()) output.write(buffer);
                    }
                    output.force(true);
                }
                if (total == 0 || (contentLength >= 0 && contentLength != total)) throw invalid("更新包未完整上传，请重新上传");
                String sha256 = HexFormat.of().formatHex(digest.digest());
                if (!sha256.equals(target.release().expectedSha256())) throw invalid("更新包 SHA-256 校验失败，请重新选择完整的软件包");
                inspector.inspect(temporary, target.release());
                long uploadedBytes = total;
                result = catalog.locked(root -> {
                    ClientReleaseDto.Release release = catalog.require(root, id);
                    requireDraft(release);
                    if (!sameDraft(release, target.release())) throw new ApiException(ErrorCode.CONFLICT, "客户端版本草稿已经变化，请刷新后重新上传");
                    ClientReleaseCatalog.replace(temporary, packagePath(root, id));
                    ClientReleaseDto.Release uploaded = copy(release, sha256, uploadedBytes, "DRAFT", null);
                    catalog.write(root, uploaded);
                    return uploaded;
                });
            } finally {
                Files.deleteIfExists(temporary);
            }
        } catch (IOException failure) {
            throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "客户端更新包暂存失败，请联系管理员检查磁盘空间和持久化目录");
        }
        return result;
    }

    @PreAuthorize(PUBLISH_EXPRESSION)
    public ClientReleaseDto.Release publish(UUID id) {
        AuthUser actor = publisher();
        ClientReleaseDto.Release result = catalog.locked(root -> {
            ClientReleaseDto.Release release = catalog.require(root, id);
            if ("PUBLISHED".equals(release.state())) {
                retireSupersededWindowsPackages(root, release);
                return release;
            }
            requireDraft(release);
            long previousBuild = catalog.list(root).stream().filter(other -> other.publishedAt() != null
                            && other.platform().equals(release.platform()) && overlaps(other.architecture(), release.architecture())
                            && other.runtimeFamily().equals(release.runtimeFamily())
                            && other.packageKind().equals(release.packageKind()))
                    .mapToLong(ClientReleaseDto.Release::buildNumber).max().orElse(0);
            if (release.buildNumber() <= previousBuild)
                throw new ApiException(ErrorCode.CONFLICT, "构建号必须大于同平台、架构、运行时及包类型已经发布过的版本");
            if (!"store".equals(release.installMode())) validatePublishedPackage(root, release);
            ClientReleaseDto.Release published = copy(release, release.sha256(), release.sizeBytes(), "PUBLISHED", Instant.now());
            catalog.write(root, published);
            retireSupersededWindowsPackages(root, published);
            return published;
        });
        record(actor, "client_release_publish", id);
        return result;
    }

    /** The installer and update ZIP become the retained generation only after both are usable. */
    private void retireSupersededWindowsPackages(Path root, ClientReleaseDto.Release published) throws IOException {
        if (!"windows".equals(published.platform())) return;
        List<ClientReleaseDto.Release> releases = catalog.list(root);
        var targets = releases.stream().filter(release -> "PUBLISHED".equals(release.state())
                && "windows".equals(release.platform()) && published.architecture().equals(release.architecture())
                && published.runtimeFamily().equals(release.runtimeFamily())).toList();
        var order = Comparator.comparingLong(ClientReleaseDto.Release::buildNumber);
        var installer = targets.stream().filter(release -> "installer".equals(release.packageKind())).max(order).orElse(null);
        var update = targets.stream().filter(release -> "update".equals(release.packageKind())).max(order).orElse(null);
        if (installer == null || update == null || !ClientRuntimeFamily.setupMode(published.runtimeFamily()).equals(installer.installMode())
                || !ClientRuntimeFamily.archiveMode(published.runtimeFamily()).equals(update.installMode()) || installer.buildNumber() != update.buildNumber()
                || !installer.version().equals(update.version()) || published.buildNumber() != installer.buildNumber()
                || !published.version().equals(installer.version())) return;

        // Recheck both committed files before touching any old metadata or bytes.
        validatePublishedPackage(root, installer);
        validatePublishedPackage(root, update);
        var obsolete = releases.stream().filter(release -> "windows".equals(release.platform())
                && published.architecture().equals(release.architecture()) && release.publishedAt() != null
                && published.runtimeFamily().equals(release.runtimeFamily())
                && Set.of("PUBLISHED", "WITHDRAWN").contains(release.state())
                && release.buildNumber() < installer.buildNumber() && !"store".equals(release.installMode())).toList();
        for (var release : obsolete) {
            if (!release.equals(catalog.require(root, release.id())))
                throw new IOException("Obsolete client release identity mismatch");
            Path binary = packagePath(root, release.id());
            if (Files.exists(binary, LinkOption.NOFOLLOW_LINKS) && !Files.isRegularFile(binary, LinkOption.NOFOLLOW_LINKS))
                throw new IOException("Invalid obsolete client package");
        }
        for (var release : obsolete) {
            // Keep the request identity, expected digest and publication history for retries and build ordering.
            // Metadata goes first: interruption can leave only an unbound old binary, never a broken published pair.
            if (!"WITHDRAWN".equals(release.state()) || release.sha256() != null || release.sizeBytes() != 0)
                catalog.write(root, copy(release, null, 0, "WITHDRAWN", release.publishedAt()));
            Files.deleteIfExists(packagePath(root, release.id()));
        }
    }

    private void validatePublishedPackage(Path root, ClientReleaseDto.Release release) throws IOException {
        Path binary = packagePath(root, release.id());
        if (release.sha256() == null || !Files.isRegularFile(binary, LinkOption.NOFOLLOW_LINKS)
                || Files.size(binary) != release.sizeBytes()) throw invalid("请先完整上传并校验更新包");
        var digest = ClientPackageInspector.digest();
        try (InputStream input = Files.newInputStream(binary, LinkOption.NOFOLLOW_LINKS)) {
            byte[] bytes = new byte[65536];
            for (int read; (read = input.read(bytes)) != -1;) digest.update(bytes, 0, read);
        }
        if (!release.sha256().equals(HexFormat.of().formatHex(digest.digest())))
            throw invalid("已上传的更新包发生变化，请重新上传");
        inspector.inspect(binary, release);
    }

    @PreAuthorize(PUBLISH_EXPRESSION)
    public ClientReleaseDto.Release withdraw(UUID id) {
        AuthUser actor = publisher();
        ClientReleaseDto.Release result = catalog.locked(root -> {
            ClientReleaseDto.Release release = catalog.require(root, id);
            if ("WITHDRAWN".equals(release.state())) return release;
            ClientReleaseDto.Release withdrawn = copy(release, release.sha256(), release.sizeBytes(), "WITHDRAWN", release.publishedAt());
            catalog.write(root, withdrawn);
            return withdrawn;
        });
        record(actor, "client_release_withdraw", id);
        return result;
    }

    public ClientReleaseDto.Check check(String platform, String architecture, long currentBuildNumber) {
        return check(platform, architecture, currentBuildNumber, ClientRuntimeFamily.FLUTTER);
    }

    public ClientReleaseDto.Check check(String platform, String architecture, long currentBuildNumber, String runtimeFamily) {
        authenticated();
        requireTarget(platform, architecture);
        String family = ClientRuntimeFamily.requireKnown(runtimeFamily);
        ClientRuntimeFamily.requireTarget(family, platform, architecture);
        if (currentBuildNumber < 0 || currentBuildNumber > Integer.MAX_VALUE) throw invalid("当前客户端构建号无效");
        ClientReleaseDto.Release latest = catalog.locked(root -> catalog.list(root).stream()
                .filter(release -> "PUBLISHED".equals(release.state()) && release.platform().equals(platform)
                        && release.runtimeFamily().equals(family)
                        && "update".equals(release.packageKind())
                        && (release.architecture().equals(architecture) || "universal".equals(release.architecture()))
                        && release.buildNumber() > currentBuildNumber)
                .max(Comparator.comparingLong(ClientReleaseDto.Release::buildNumber)
                        .thenComparing(release -> release.architecture().equals(architecture))).orElse(null));
        return new ClientReleaseDto.Check(latest != null, latest,
                Math.max(60, Math.min(properties.getPollIntervalSeconds(), 86400)));
    }

    @PreAuthorize(DOWNLOADS_EXPRESSION)
    public List<ClientReleaseDto.Release> downloads() {
        return downloads(ClientRuntimeFamily.FLUTTER, false);
    }

    @PreAuthorize(DOWNLOADS_EXPRESSION)
    public List<ClientReleaseDto.Release> downloads(String runtimeFamily, boolean allRuntimeFamilies) {
        employeeDownloader();
        String family = ClientRuntimeFamily.requireKnown(runtimeFamily);
        return catalog.locked(root -> {
            var latest = new TreeMap<String, ClientReleaseDto.Release>();
            for (var release : catalog.list(root)) {
                if (!"PUBLISHED".equals(release.state()) || !"windows".equals(release.platform())
                        || !"installer".equals(release.packageKind())
                        || !ClientRuntimeFamily.setupMode(release.runtimeFamily()).equals(release.installMode())
                        || !allRuntimeFamilies && !family.equals(release.runtimeFamily())) continue;
                Path binary = packagePath(root, release.id());
                if (release.sha256() == null || release.sizeBytes() <= 0
                        || !Files.isRegularFile(binary, LinkOption.NOFOLLOW_LINKS) || Files.size(binary) != release.sizeBytes()) continue;
                latest.merge(release.runtimeFamily() + ":" + release.architecture(), release,
                        (previous, candidate) -> candidate.buildNumber() > previous.buildNumber() ? candidate : previous);
            }
            return List.copyOf(latest.values());
        });
    }

    public Download download(UUID id) {
        return download(id, ClientRuntimeFamily.FLUTTER);
    }

    public Download download(UUID id, String runtimeFamily) {
        authenticated();
        String family = ClientRuntimeFamily.requireKnown(runtimeFamily);
        return catalog.locked(root -> {
            ClientReleaseDto.Release release = catalog.require(root, id);
            if (!family.equals(release.runtimeFamily())) throw new ApiException(ErrorCode.NOT_FOUND, "此运行时下不存在该客户端包");
            if ("installer".equals(release.packageKind())) employeeDownloader();
            if (!"PUBLISHED".equals(release.state()) || "store".equals(release.installMode()))
                throw new ApiException(ErrorCode.NOT_FOUND, "此客户端更新包当前不可下载");
            Path binary = packagePath(root, id);
            if (!Files.isRegularFile(binary, LinkOption.NOFOLLOW_LINKS) || Files.size(binary) != release.sizeBytes())
                throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "客户端更新包暂不可用，请稍后重试");
            return new Download(release, Files.newInputStream(binary, LinkOption.NOFOLLOW_LINKS));
        });
    }

    private ClientReleaseDto.Release normalize(ClientReleaseDto.Create request) {
        if (request == null || request.requestId() == null) throw invalid("请提供本次发布编号");
        requireTarget(request.platform(), request.architecture());
        String family = ClientRuntimeFamily.requireKnown(request.runtimeFamily());
        ClientRuntimeFamily.requireTarget(family, request.platform(), request.architecture());
        if (!Set.of("update", "installer").contains(request.packageKind())) throw invalid("客户端包类型无效");
        if ("installer".equals(request.packageKind()) && !"windows".equals(request.platform()))
            throw invalid("当前仅支持 Windows 完整客户端发布");
        if ("linux".equals(request.platform())) throw invalid("Linux 客户端暂不支持在线更新发布");
        if (request.version() == null || request.version().length() > 64
                || !request.version().matches("[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?")) throw invalid("请填写有效的客户端版本号，例如 2.5.28");
        if (request.buildNumber() < 1 || request.buildNumber() > Integer.MAX_VALUE) throw invalid("构建号必须为有效正整数");
        if ("windows".equals(request.platform()) && request.buildNumber() > 65535)
            throw invalid("Windows 构建号不能超过 65535，请按程序版本信息填写");
        String notes = request.releaseNotes() == null ? "" : request.releaseNotes().strip();
        if (notes.length() > 10000) throw invalid("更新说明不能超过 10000 字符");
        String fileName = request.fileName();
        String expectedSha = request.expectedSha256();
        String storeUrl = request.storeUrl() == null || request.storeUrl().isBlank() ? null : request.storeUrl().strip();
        String mode;
        if (storeUrl != null) {
            if ("installer".equals(request.packageKind())) throw invalid("Windows 完整客户端必须上传专用安装文件，不能使用商店链接");
            validateStoreUrl(storeUrl, request.platform());
            if (fileName != null && !fileName.isBlank() || expectedSha != null && !expectedSha.isBlank())
                throw invalid("应用商店版本不能同时上传更新包");
            fileName = null;
            expectedSha = null;
            mode = "store";
        } else {
            if (!Set.of("windows", "android").contains(request.platform())) throw invalid("iOS 和 macOS 请填写官方应用商店更新链接");
            boolean windowsSetup = "windows".equals(request.platform()) && "installer".equals(request.packageKind())
                    && fileName != null && fileName.toLowerCase(Locale.ROOT).endsWith(".exe");
            if (ClientRuntimeFamily.WPF_LEGACY.equals(family) && "installer".equals(request.packageKind()) && !windowsSetup)
                throw invalid("WPF 兼容客户端首装必须使用专用 Setup.exe");
            String extension = windowsSetup ? ".exe" : "windows".equals(request.platform()) ? ".zip" : ".apk";
            if (fileName == null || !fileName.matches("[A-Za-z0-9][A-Za-z0-9._ -]{0,180}")
                    || !fileName.toLowerCase(Locale.ROOT).endsWith(extension)) throw invalid("请选择对应平台和用途的 EXE、ZIP 或 APK 文件，文件名请使用字母和数字");
            if (expectedSha == null || !expectedSha.matches("[0-9a-fA-F]{64}")) throw invalid("请提供更新包的 SHA-256 校验值");
            expectedSha = expectedSha.toLowerCase(Locale.ROOT);
            mode = "windows".equals(request.platform())
                    ? "installer".equals(request.packageKind()) ? windowsSetup ? ClientRuntimeFamily.setupMode(family) : "windows_bundle" : ClientRuntimeFamily.archiveMode(family)
                    : "android_package";
        }
        return new ClientReleaseDto.Release(request.requestId(), request.platform(), request.architecture(), request.version(),
                request.buildNumber(), notes, request.mandatory(), fileName, expectedSha, null, 0, mode, storeUrl,
                "store".equals(mode) ? null : "/api/client-updates/" + request.requestId() + "/download"
                        + (ClientRuntimeFamily.WPF_LEGACY.equals(family) ? "?runtimeFamily=wpf_legacy" : ""), "DRAFT", Instant.now(), null,
                request.packageKind(), family);
    }

    private static void requireTarget(String platform, String architecture) {
        if (platform == null || !PLATFORMS.contains(platform) || architecture == null || !ARCHITECTURES.contains(architecture))
            throw invalid("客户端平台或架构无效");
        boolean valid = switch (platform) {
            case "windows" -> Set.of("x86", "x64", "arm64").contains(architecture);
            case "android" -> Set.of("arm64", "armeabi-v7a", "x64", "universal").contains(architecture);
            case "ios" -> Set.of("arm64", "universal").contains(architecture);
            default -> Set.of("arm64", "x64", "universal").contains(architecture);
        };
        if (!valid) throw invalid("此平台不支持所选客户端架构");
    }

    private static void validateStoreUrl(String url, String platform) {
        try {
            URI uri = URI.create(url);
            String host = uri.getHost();
            if (url.length() > 2048 || !"https".equalsIgnoreCase(uri.getScheme()) || uri.getUserInfo() != null
                    || (uri.getPort() != -1 && uri.getPort() != 443) || uri.getFragment() != null
                    || !(Set.of("ios", "macos").contains(platform) && "apps.apple.com".equalsIgnoreCase(host)
                    || "android".equals(platform) && "play.google.com".equalsIgnoreCase(host) && uri.getPath().startsWith("/store/apps/")))
                throw invalid("请填写对应平台的官方 HTTPS 应用商店链接");
        } catch (IllegalArgumentException malformed) {
            throw invalid("应用商店链接格式无效");
        }
    }

    private static boolean overlaps(String left, String right) { return left.equals(right) || "universal".equals(left) || "universal".equals(right); }
    private static Path packagePath(Path root, UUID id) { return root.resolve(id.toString()).resolve("package.bin"); }
    private void requireSpace(Path directory, long nextBytes) throws IOException {
        if (Files.getFileStore(directory).getUsableSpace() - Math.max(0, properties.getMinFreeBytes()) < nextBytes)
            throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "客户端更新目录的可用空间不足，请先清理或扩容后再上传");
    }
    private static void requireDraft(ClientReleaseDto.Release release) {
        if (!"DRAFT".equals(release.state())) throw new ApiException(ErrorCode.CONFLICT, "只能上传或发布草稿版本，已发布的更新包不能被替换");
    }
    private static ClientReleaseDto.Release copy(ClientReleaseDto.Release release, String sha, long size, String state, Instant published) {
        return new ClientReleaseDto.Release(release.id(), release.platform(), release.architecture(), release.version(), release.buildNumber(),
                release.releaseNotes(), release.mandatory(), release.fileName(), release.expectedSha256(), sha, size,
                release.installMode(), release.storeUrl(), release.downloadUrl(), state, release.createdAt(), published, release.packageKind(), release.runtimeFamily());
    }
    private static boolean sameDraft(ClientReleaseDto.Release left, ClientReleaseDto.Release right) {
        return left.platform().equals(right.platform()) && left.architecture().equals(right.architecture()) && left.version().equals(right.version())
                && left.buildNumber() == right.buildNumber() && left.releaseNotes().equals(right.releaseNotes()) && left.mandatory() == right.mandatory()
                && left.packageKind().equals(right.packageKind())
                && left.runtimeFamily().equals(right.runtimeFamily())
                && java.util.Objects.equals(left.fileName(), right.fileName()) && java.util.Objects.equals(left.expectedSha256(), right.expectedSha256())
                && java.util.Objects.equals(left.storeUrl(), right.storeUrl());
    }
    private AuthUser authenticated() { return currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED)); }
    private AuthUser employeeDownloader() {
        AuthUser actor = authenticated();
        if (actor.isVisitor() || actor.isMustChangePassword() || !actor.isSuperAdmin() && actor.getEmployeeId() == null)
            throw new ApiException(ErrorCode.FORBIDDEN);
        return actor;
    }
    private AuthUser publisher() {
        AuthUser actor = authenticated();
        if (actor.isVisitor() || actor.isMustChangePassword() || actor.getImpersonatedBy() != null
                || !actor.getPermissions().contains(PUBLISH_PERMISSION)) throw new ApiException(ErrorCode.FORBIDDEN);
        return actor;
    }
    private void record(AuthUser actor, String action, UUID id) {
        audit.logExplicit(actor.getId(), actor.getLoginAccount(), action, "client_release", id.toString(), "success");
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
    private static ApiException tooLarge() { return new ApiException(ErrorCode.PAYLOAD_TOO_LARGE, "客户端更新包超过允许的大小"); }
    public record Download(ClientReleaseDto.Release release, InputStream stream) {}
    private record UploadTarget(Path root, ClientReleaseDto.Release release) {}
}

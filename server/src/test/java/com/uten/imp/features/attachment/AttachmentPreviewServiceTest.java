package com.uten.imp.features.attachment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.AttachmentPreviewProperties;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AttachmentPreviewServiceTest {
    private static final String SHA = "a".repeat(64);
    private static final byte[] PDF = "%PDF-1.4 rendered".getBytes(StandardCharsets.US_ASCII);

    @TempDir Path root;

    @Test void missingSofficeOrDisabledPreviewIsABusinessErrorAndNeverSpawnsAProcess() {
        var attachments = source("合同.docx", "application/msword");
        var runs = new AtomicInteger();
        var properties = properties(true, root.resolve("definitely-missing-soffice").toString());
        var service = new AttachmentPreviewService(attachments, properties, storage(), (command, dir, timeout) -> {
            runs.incrementAndGet(); return 0;
        });
        var error = assertThrows(ApiException.class, () -> service.render(UUID.randomUUID()));
        assertEquals(ErrorCode.BUSINESS, error.getCode());
        assertTrue(error.getMessage().contains("暂不支持预览"));
        assertEquals(0, runs.get());

        properties.setEnabled(false);
        assertEquals(ErrorCode.BUSINESS, assertThrows(ApiException.class,
                () -> service.render(UUID.randomUUID())).getCode());
        assertEquals(0, runs.get());
        assertFalse(service.isAvailable());
    }

    @Test void nonOfficeAndOversizedOriginalsAreRefusedBeforeAnyConversion() {
        var runs = new AtomicInteger();
        var service = new AttachmentPreviewService(source("图片.png", "image/png"),
                properties(true, executableSoffice()), storage(), (command, dir, timeout) -> { runs.incrementAndGet(); return 0; });
        assertEquals(ErrorCode.BUSINESS, assertThrows(ApiException.class, () -> service.render(UUID.randomUUID())).getCode());

        var storage = storage(); storage.setMaxBytes(3);
        var large = new AttachmentPreviewService(source("大.xlsx", "application/vnd.ms-excel"),
                properties(true, executableSoffice()), storage, (command, dir, timeout) -> { runs.incrementAndGet(); return 0; });
        assertEquals(ErrorCode.BUSINESS, assertThrows(ApiException.class, () -> large.render(UUID.randomUUID())).getCode());
        assertEquals(0, runs.get());
    }

    /**
     * 可转换集合 = LibreOffice 打得开的办公文档（MS + OpenDocument + rtf + svg）。
     * 客户端自己能渲染的（png/txt/csv/zip）与谁都渲染不了的（tiff/heic）都不得进转换通道：
     * 前者白占槽位，后者会给用户一个必然失败的预览。
     */
    @Test void theConvertibleSetIsExactlyTheLibreOfficeFamily() throws Exception {
        for (String name : List.of("合同.doc", "合同.docx", "说明.rtf", "说明.odt",
                "台账.xls", "台账.xlsx", "台账.ods",
                "方案.ppt", "方案.pptx", "方案.odp", "图标.svg")) {
            UUID id = UUID.randomUUID();
            var commands = new ArrayList<List<String>>();
            var service = new AttachmentPreviewService(source(id, name, "application/octet-stream"),
                    properties(true, executableSoffice()), storage(), (command, dir, timeout) -> {
                        commands.add(command);
                        Files.write(Path.of(command.get(command.indexOf("--outdir") + 1)).resolve("source.pdf"), PDF);
                        return 0;
                    });
            var rendered = service.render(id);
            assertEquals(PDF.length, rendered.sizeBytes(), name);
            assertEquals(1, commands.size(), name + " 必须触发一次转换");
        }

        for (String name : List.of("导出.csv", "归档.zip", "扫描件.tiff", "照片.heic",
                "资料.7z", "说明.txt", "照片.png", "合同.pdf", "未知.bin")) {
            var runs = new AtomicInteger();
            var service = new AttachmentPreviewService(source(name, "application/octet-stream"),
                    properties(true, executableSoffice()), storage(), (command, dir, timeout) -> {
                        runs.incrementAndGet();
                        return 0;
                    });
            var error = assertThrows(ApiException.class, () -> service.render(UUID.randomUUID()), name);
            assertEquals(ErrorCode.BUSINESS, error.getCode(), name);
            assertEquals(0, runs.get(), name + " 不该启动任何转换进程");
        }
    }

    @Test void contentTypeAloneCanSelectTheConversionChannelForLegacyRowsWithoutAnExtension() throws Exception {
        UUID id = UUID.randomUUID();
        var commands = new ArrayList<List<String>>();
        var service = new AttachmentPreviewService(
                source(id, "无扩展名", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
                properties(true, executableSoffice()), storage(), (command, dir, timeout) -> {
                    commands.add(command);
                    Files.write(Path.of(command.get(command.indexOf("--outdir") + 1)).resolve("source.pdf"), PDF);
                    return 0;
                });
        assertEquals("无扩展名.pdf", service.render(id).fileName());
        assertEquals(1, commands.size());
        assertTrue(commands.get(0).getLast().endsWith("source.pptx"), "worker input must use the known MIME's fixed suffix");
    }

    @Test void conversionWritesAnAtomicCacheEntryAndTheSecondCallIsAPureCacheHit() throws Exception {
        UUID id = UUID.randomUUID();
        var attachments = source(id, "报价 单.docx", "application/msword");
        var commands = new ArrayList<List<String>>();
        var service = new AttachmentPreviewService(attachments, properties(true, executableSoffice()), storage(),
                (command, dir, timeout) -> {
                    commands.add(command);
                    // 假 soffice：把 source.<ext> 转成 source.pdf 落在 --outdir。
                    Path outdir = Path.of(command.get(command.indexOf("--outdir") + 1));
                    assertTrue(Files.isRegularFile(Path.of(command.get(command.size() - 1))));
                    Files.write(outdir.resolve("source.pdf"), PDF);
                    return 0;
                });
        service.init();

        var first = service.render(id);
        assertEquals("报价 单.pdf", first.fileName());
        assertEquals(PDF.length, first.sizeBytes());
        assertArrayEquals(PDF, Files.readAllBytes(first.file()));
        assertEquals(root.resolve("preview").resolve(AttachmentPreviewService.cacheFileName(id, SHA)), first.file());
        assertEquals(1, commands.size());
        assertTrue(commands.get(0).contains("--headless"));
        assertTrue(commands.get(0).stream().anyMatch(part -> part.startsWith("-env:UserInstallation=file:")));
        try (var leftovers = Files.list(root.resolve("scratch"))) {
            assertTrue(leftovers.noneMatch(path -> path.getFileName().toString().startsWith("preview-")),
                    "work directory must be removed after conversion");
        }

        var second = service.render(id);
        assertEquals(first.file(), second.file());
        assertEquals(1, commands.size(), "cache hit must not spawn another conversion");

        service.evict(id);
        assertFalse(Files.exists(first.file()));
    }

    @Test void timeoutAndNonZeroExitBecomeBusinessErrorsAndLeaveNoPartialCache() throws Exception {
        UUID id = UUID.randomUUID();
        var timingOut = new AttachmentPreviewService(source(id, "慢.pptx", "application/vnd.ms-powerpoint"),
                properties(true, executableSoffice()), storage(), (command, dir, timeout) -> { throw new TimeoutException("slow"); });
        assertEquals(ErrorCode.BUSINESS, assertThrows(ApiException.class, () -> timingOut.render(id)).getCode());
        var failing = new AttachmentPreviewService(source(id, "坏.doc", "application/msword"),
                properties(true, executableSoffice()), storage(), (command, dir, timeout) -> 1);
        assertEquals(ErrorCode.BUSINESS, assertThrows(ApiException.class, () -> failing.render(id)).getCode());
        assertFalse(Files.exists(root.resolve("preview").resolve(AttachmentPreviewService.cacheFileName(id, SHA))));
    }

    @Test void everyConversionGetsAFreshProfileWithMacrosActiveContentAndLinkUpdatesDisabled() throws Exception {
        var profiles = new ArrayList<Path>();
        var service = new AttachmentPreviewService(source("制度.docx", "application/msword"),
                properties(true, executableSoffice()), storage(), (command, work, timeout) -> {
                    Path profile = Path.of(java.net.URI.create(command.stream()
                            .filter(part -> part.startsWith("-env:UserInstallation="))
                            .findFirst().orElseThrow().substring("-env:UserInstallation=".length())));
                    profiles.add(profile);
                    assertTrue(profile.startsWith(work), "profile must be private to this conversion");
                    String settings = Files.readString(profile.resolve("user/registrymodifications.xcu"));
                    assertTrue(settings.contains("DisableMacrosExecution\" oor:op=\"fuse\"><value>true"));
                    assertTrue(settings.contains("DisableActiveContent\" oor:op=\"fuse\"><value>true"));
                    assertTrue(settings.contains("BlockUntrustedRefererLinks\" oor:op=\"fuse\"><value>true"));
                    Files.write(work.resolve("source.pdf"), PDF);
                    return 0;
                });
        UUID id = UUID.randomUUID();
        service.render(id);
        // source() creates a stable metadata id; evict that actual cached attachment before re-rendering.
        try (var files = Files.list(root.resolve("preview"))) {
            for (Path file : files.toList()) Files.delete(file);
        }
        service.render(id);
        assertEquals(2, profiles.size());
        assertFalse(profiles.get(0).equals(profiles.get(1)));
        assertTrue(profiles.stream().noneMatch(Files::exists));
    }

    @Test void invalidOrOversizedPdfIsNeverPublishedAndInvalidCacheIsRebuilt() throws Exception {
        UUID id = UUID.randomUUID();
        var properties = properties(true, executableSoffice());
        var runs = new AtomicInteger();
        var service = new AttachmentPreviewService(source(id, "制度.docx", "application/msword"),
                properties, storage(), (command, work, timeout) -> {
                    runs.incrementAndGet();
                    Files.write(work.resolve("source.pdf"), runs.get() == 1 ? "not a pdf".getBytes(StandardCharsets.UTF_8) : PDF);
                    return 0;
                });
        assertThrows(ApiException.class, () -> service.render(id));
        Path cached = root.resolve("preview").resolve(AttachmentPreviewService.cacheFileName(id, SHA));
        assertFalse(Files.exists(cached));
        Files.writeString(cached, "damaged cache");
        assertArrayEquals(PDF, Files.readAllBytes(service.render(id).file()));
        assertEquals(2, runs.get());
        service.evict(id);
        properties.setMaxOutputBytes(PDF.length - 1);
        assertThrows(ApiException.class, () -> service.render(id));
        assertFalse(Files.exists(cached));
    }

    @Test void responseSurvivesATinyCacheBudgetAndConcurrentEviction() throws Exception {
        UUID id = UUID.randomUUID();
        var properties = properties(true, executableSoffice());
        properties.setCacheMaxBytes(1);
        var service = new AttachmentPreviewService(source(id, "制度.docx", "application/msword"),
                properties, storage(), (command, work, timeout) -> {
                    Files.write(work.resolve("source.pdf"), PDF); return 0;
                });
        var download = service.open(id);
        try (var input = download.stream()) {
            assertEquals(PDF.length, download.sizeBytes());
            service.evict(id);
            assertArrayEquals(PDF, input.readAllBytes());
        }
        service.evict(id);
    }

    @Test void timeoutTerminatesTheConverterAndItsDescendantProcess() throws Exception {
        Path work = Files.createDirectory(root.resolve("process-tree"));
        Path report = root.resolve("descendant-pid.txt");
        assertThrows(TimeoutException.class, () -> AttachmentPreviewService.runSoffice(
                EnvironmentProbe.command("fork", work, report), work, Duration.ofSeconds(2)));
        assertTrue(Files.isRegularFile(report), "launcher must create a real child before timing out");
        long pid = Long.parseLong(Files.readString(report));
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false) && System.nanoTime() < deadline) {
            Thread.sleep(20);
        }
        assertFalse(ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false), "descendant must not outlive timeout");
    }

    @Test void permissionRevokedDuringConversionPreventsTheResultFromBeingReturned() throws Exception {
        UUID id = UUID.randomUUID();
        var attachments = source(id, "制度.docx", "application/msword");
        var service = new AttachmentPreviewService(attachments, properties(true, executableSoffice()), storage(),
                (command, work, timeout) -> {
                    Files.write(work.resolve("source.pdf"), PDF);
                    when(attachments.openPreviewSource(id)).thenThrow(new ApiException(ErrorCode.FORBIDDEN));
                    return 0;
                });
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.open(id)).getCode());
    }

    @Test void authorizationFailureFromTheAttachmentServicePropagatesUnchanged() {
        var attachments = mock(AttachmentService.class);
        when(attachments.openPreviewSource(org.mockito.ArgumentMatchers.any()))
                .thenThrow(new ApiException(ErrorCode.NOT_FOUND, "Attachment not found"));
        var runs = new AtomicInteger();
        var service = new AttachmentPreviewService(attachments, properties(true, executableSoffice()), storage(),
                (command, dir, timeout) -> { runs.incrementAndGet(); return 0; });
        assertEquals(ErrorCode.NOT_FOUND, assertThrows(ApiException.class, () -> service.render(UUID.randomUUID())).getCode());
        assertEquals(0, runs.get());
        verify(attachments, never()).delete(org.mockito.ArgumentMatchers.any());
    }

    @Test void realConversionChildReceivesNoServerCredentialsAndUsesItsPrivateWorkDirectory() throws Exception {
        Path work = Files.createDirectory(root.resolve("private conversion work"));
        Path report = root.resolve("child-environment-names.txt");
        List<String> credentials = List.of("UTEN_DB_PASSWORD", "UTEN_MIGRATOR_DB_PASSWORD",
                "UTEN_PGP_MASTER_KEY", "UTEN_JWT_SECRET", "UTEN_HMAC_KEY", "UTEN_SECRET_CIPHER_KEY",
                "BOOTSTRAP_ADMIN_PASSWORD", "UTEN_AI_API_KEY",
                "AWS_SECRET_ACCESS_KEY", "SSH_AUTH_SOCK", "FUTURE_PROVIDER_SECRET");
        ProcessBuilder parent = new ProcessBuilder(EnvironmentProbe.command("convert", work, report))
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD);
        credentials.forEach(name -> parent.environment().put(name, "synthetic-regression-sentinel"));
        parent.environment().put("HOME", root.resolve("inherited-home").toString());
        parent.environment().put("TMPDIR", root.resolve("inherited-tmp").toString());
        parent.environment().put("LANG", "zh_CN.UTF-8");
        Process process = parent.start();
        try {
            assertTrue(process.waitFor(30, TimeUnit.SECONDS), "conversion probe must finish");
            assertTrue(Files.isRegularFile(report), "real conversion child must write its environment names");
            List<String> names = Files.readAllLines(report, StandardCharsets.UTF_8);
            for (String credential : credentials) {
                assertFalse(names.contains(credential), credential + " must never reach the conversion child");
            }
            assertEquals(0, process.exitValue(), "private HOME/TMP and locale must be available to the child");
        } finally {
            if (process.isAlive()) process.destroyForcibly();
        }
    }

    /** Separate JVMs exercise the production launcher; only environment names are written, never values. */
    public static class EnvironmentProbe {
        public static void main(String[] args) throws Exception {
            Path work = Path.of(args[1]).toAbsolutePath().normalize();
            Path report = Path.of(args[2]);
            if ("fork".equals(args[0])) {
                Process child = new ProcessBuilder(command("sleep", work, report)).start();
                Files.writeString(report, Long.toString(child.pid()));
                Thread.sleep(30000);
                return;
            }
            if ("sleep".equals(args[0])) { Thread.sleep(30000); return; }
            if ("convert".equals(args[0])) {
                System.exit(AttachmentPreviewService.runSoffice(
                        command("inspect", work, report), work, Duration.ofSeconds(15)));
            }
            Files.write(report, System.getenv().keySet().stream().sorted().toList(), StandardCharsets.UTF_8);
            for (String name : List.of("HOME", "TMPDIR", "TMP", "TEMP")) {
                if (!work.toString().equals(System.getenv(name))) System.exit(91);
            }
            if (!"zh_CN.UTF-8".equals(System.getenv("LANG"))) System.exit(92);
        }

        static List<String> command(String mode, Path work, Path report) {
            String executable = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")
                    ? "java.exe" : "java";
            return List.of(Path.of(System.getProperty("java.home"), "bin", executable).toString(),
                    "-cp", System.getProperty("java.class.path"), EnvironmentProbe.class.getName(),
                    mode, work.toString(), report.toString());
        }
    }

    private AttachmentService source(String name, String contentType) {
        return source(UUID.randomUUID(), name, contentType);
    }

    private AttachmentService source(UUID id, String name, String contentType) {
        var attachments = mock(AttachmentService.class);
        byte[] bytes = (name.endsWith(".svg") ? "<svg xmlns=\"http://www.w3.org/2000/svg\"/>" : "original office bytes")
                .getBytes(StandardCharsets.UTF_8);
        when(attachments.openPreviewSource(org.mockito.ArgumentMatchers.any())).thenAnswer(ignored ->
                new AttachmentService.PreviewSource(id, name, contentType, bytes.length, SHA,
                        () -> new ByteArrayInputStream(bytes)));
        return attachments;
    }

    private StorageProperties storage() {
        var storage = new StorageProperties();
        storage.setProvider("local");
        storage.setLocalDir(root.toString());
        return storage;
    }

    private static AttachmentPreviewProperties properties(boolean enabled, String soffice) {
        var properties = new AttachmentPreviewProperties();
        properties.setEnabled(enabled);
        properties.setSofficePath(soffice);
        properties.setTimeout(Duration.ofSeconds(5));
        properties.setMaxConcurrent(1);
        return properties;
    }

    /** 任何可执行文件都能充当“已安装的 soffice”，真实进程由假 ProcessRunner 顶替。 */
    private String executableSoffice() {
        try {
            Path fake = root.resolve(System.getProperty("os.name", "").toLowerCase().contains("win") ? "soffice.exe" : "soffice");
            if (!Files.exists(fake)) {
                Files.write(fake, new byte[]{0});
                var file = fake.toFile();
                assertTrue(file.setExecutable(true, false) || file.canExecute());
            }
            return fake.toString();
        } catch (java.io.IOException error) {
            throw new IllegalStateException(error);
        }
    }
}

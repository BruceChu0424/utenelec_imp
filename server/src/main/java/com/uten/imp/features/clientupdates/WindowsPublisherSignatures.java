package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.Map;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;
import org.apache.commons.compress.archivers.zip.ZipFile;
import org.springframework.stereotype.Component;
import org.springframework.beans.factory.annotation.Autowired;

/** Independent verification of the uploaded bytes; package assertions are never a trust decision. */
@Component
public class WindowsPublisherSignatures {
    private static final Set<String> COMPANY_FILES = Set.of("uten_imp.exe", "flutter_windows.dll",
            "client_updater.ps1", "uten.legacy.desktop.exe", "uten.legacy.core.dll", "uten.legacy.updater.exe");
    private static final int MAX_EXECUTABLES = 128;
    private static final int MAX_OUTPUT_BYTES = 65536;
    private static final long MAX_FILE_BYTES = 536870912L;
    private static final long PACKAGE_NANOS = Duration.ofMinutes(2).toNanos();
    private final Semaphore slots = new Semaphore(2);
    private final ClientUpdateProperties properties;
    private final VerificationProcess process;

    @Autowired
    public WindowsPublisherSignatures(ClientUpdateProperties properties) { this(properties, WindowsPublisherSignatures::execute); }
    WindowsPublisherSignatures(ClientUpdateProperties properties, VerificationProcess process) {
        this.properties = properties;
        this.process = process;
    }

    void inspect(Path file, ClientReleaseDto.Release release) throws IOException {
        if (!"windows".equals(release.platform()) || "store".equals(release.installMode())) return;
        Settings settings = settings();
        if (!slots.tryAcquire()) throw new ApiException(ErrorCode.CONFLICT, "Windows 软件签名正在校验，请稍后重试");
        long deadline = System.nanoTime() + PACKAGE_NANOS;
        try {
            verifyVersion(settings);
            if ("installer".equals(release.packageKind())) {
                verify(file, true, settings, deadline);
                return;
            }
            inspectArchive(file, release, settings, deadline);
        } finally { slots.release(); }
    }

    private void inspectArchive(Path file, ClientReleaseDto.Release release, Settings settings, long deadline) throws IOException {
        ClientZipDirectory.inspect(file, 20001, 16777216L);
        Path scratch = Files.createTempDirectory(file.toAbsolutePath().getParent(), ".windows-signature-");
        List<Path> extracted = new ArrayList<>();
        Map<String, WindowsPayloadBinding.FileProof> proofs = new HashMap<>();
        Path main = null;
        String executable = "wpf_legacy".equals(release.runtimeFamily()) ? "Uten.Legacy.Desktop.exe" : "uten_imp.exe";
        try (ZipFile zip = ZipFile.builder().setPath(file).get()) {
            var entries = zip.getEntries();
            int inspected = 0;
            long expanded = 0;
            while (entries.hasMoreElements()) {
                requireDeadline(deadline);
                var entry = entries.nextElement();
                if (entry.isDirectory()) continue;
                String name = entry.getName().toLowerCase(Locale.ROOT);
                String leaf = name.substring(name.lastIndexOf('/') + 1);
                boolean namedExecutable = name.endsWith(".exe") || name.endsWith(".dll") || name.endsWith(".ps1");
                try (InputStream input = zip.getInputStream(entry)) {
                    byte[] prefix = input.readNBytes(2);
                    boolean pe = prefix.length == 2 && prefix[0] == 'M' && prefix[1] == 'Z';
                    boolean executableFile = namedExecutable || pe;
                    if (entry.getSize() < 0 || entry.getSize() > MAX_FILE_BYTES || entry.getSize() > 2147483648L - expanded)
                        throw invalid("Windows 运行文件大小超出签名校验上限");
                    expanded += entry.getSize();
                    if (executableFile && (++inspected > MAX_EXECUTABLES || entry.getSize() < 1))
                        throw invalid("Windows 软件包的可执行文件数量或大小超出签名校验上限");
                    String suffix = name.endsWith(".ps1") ? ".ps1" : pe ? ".exe" : ".bin";
                    Path target = executableFile ? scratch.resolve(inspected + suffix) : null;
                    if (target != null) extracted.add(target);
                    long total = prefix.length;
                    var digest = ClientPackageInspector.digest();
                    digest.update(prefix);
                    try (var output = target == null ? java.io.OutputStream.nullOutputStream()
                            : Files.newOutputStream(target, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
                        output.write(prefix);
                        byte[] buffer = new byte[65536];
                        for (int read; (read = input.read(buffer)) != -1;) {
                            requireDeadline(deadline);
                            if (read > entry.getSize() - total || read > MAX_FILE_BYTES - total) throw invalid("Windows 可执行文件实际大小不匹配");
                            total += read;
                            digest.update(buffer, 0, read);
                            output.write(buffer, 0, read);
                        }
                    }
                    if (total != entry.getSize()) throw invalid("Windows 可执行文件未完整上传");
                    if (proofs.putIfAbsent(entry.getName(), new WindowsPayloadBinding.FileProof(total, HexFormat.of().formatHex(digest.digest()))) != null)
                        throw invalid("Windows 运行文件路径重复");
                    if (target != null) {
                        verify(target, COMPANY_FILES.contains(leaf), settings, deadline);
                        if ("flutter".equals(release.runtimeFamily()) && "flutter_windows.dll".equals(name))
                            WindowsEngineSafety.requireApproved(target, release.architecture());
                        if (executable.equals(entry.getName())) main = target;
                    }
                }
            }
            if (inspected == 0) throw invalid("Windows 软件包缺少可验证的签名程序");
            if (main == null) throw invalid("Windows 软件包缺少签名主程序");
            WindowsPayloadBinding.inspect(main, proofs, release);
            requireDeadline(deadline);
        } finally {
            for (Path target : extracted) Files.deleteIfExists(target);
            Files.deleteIfExists(scratch);
        }
    }

    private static void requireDeadline(long deadline) {
        if (System.nanoTime() >= deadline) throw invalid("Windows 软件包签名校验超时，请稍后重试");
    }

    private void verify(Path file, boolean company, Settings settings, long deadline) throws IOException {
        List<String> pins = company ? settings.pins() : List.of("");
        for (String pin : pins) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) throw invalid("Windows 软件包签名校验超时，请稍后重试");
            var command = new ArrayList<>(List.of(settings.executable().toString(), "verify", "-index", "0",
                    "-CAfile", settings.ca().toString(), "-TSA-CAfile", settings.tsaCa().toString(),
                    "-CRLfile", settings.crl().toString(), "-TSA-CRLfile", settings.tsaCrl().toString(), "-ignore-cdp"));
            if (company) command.addAll(List.of("-require-leaf-hash", "sha256:" + pin));
            command.addAll(List.of("-in", file.toAbsolutePath().toString()));
            Result result;
            try { result = process.verify(List.copyOf(command), Duration.ofNanos(Math.min(remaining, Duration.ofSeconds(30).toNanos()))); }
            catch (IOException unavailable) { throw invalid("Windows 签名验证器不可用，请管理员检查正式签名验证配置"); }
            if (result.exitCode() == 0 && !result.outputExceeded()
                    && !result.output().contains("Timestamp Server Signature verification: failed")
                    && (!company || timestampVerified(result.output()))) return;
        }
        throw invalid("Windows 软件签名、可信发布者、时间戳或撤销状态校验失败，请使用公司签名后的完整正式包");
    }

    private void verifyVersion(Settings settings) throws IOException {
        Result result;
        try { result = process.verify(List.of(settings.executable().toString(), "--version"), Duration.ofSeconds(5)); }
        catch (IOException unavailable) { throw invalid("Windows 签名验证器不可用，请管理员检查正式签名验证配置"); }
        var version = Pattern.compile("(?m)^osslsigncode (\\d+)\\.(\\d+)[^\\r\\n]*$").matcher(result.output());
        if (result.exitCode() != 0 || result.outputExceeded() || !version.find())
            throw invalid("Windows 签名验证器版本无法确认，请安装受控的 osslsigncode 2.14 或更新修复版本");
        try {
            int major = Integer.parseInt(version.group(1)), minor = Integer.parseInt(version.group(2));
            if (major < 2 || major == 2 && minor < 14)
                throw invalid("Windows 签名验证器版本过旧，请安装受控的 osslsigncode 2.14 或更新修复版本");
        } catch (NumberFormatException malformed) { throw invalid("Windows 签名验证器版本无法确认"); }
    }

    static boolean timestampVerified(String output) {
        // With -index 0 these fixed tool diagnostics refer to the same primary signature.
        // Reject the mandatory missing-timestamp diagnostic too: certificate/description text cannot forge success.
        return output.contains("Timestamp Server Signature verification: ok")
                && !output.contains("Timestamp is not available")
                && !output.contains("Timestamp Server Signature verification: failed");
    }

    private Settings settings() {
        List<String> pins = Arrays.stream(properties.getWindowsPublisherSha256().split(",", -1))
                .map(String::strip).map(value -> value.toLowerCase(Locale.ROOT)).toList();
        if (pins.isEmpty() || pins.size() > 4 || pins.stream().anyMatch(pin -> !pin.matches("[0-9a-f]{64}")))
            throw invalid("尚未配置公司 Windows 正式签名证书，请管理员配置 UTEN_WINDOWS_PUBLISHER_SHA256 后再发布");
        Path executable = configuredFile(properties.getWindowsSignatureVerifier());
        if (!Files.isExecutable(executable)) throw invalid("Windows 签名验证器不可执行");
        return new Settings(pins, executable, configuredFile(properties.getWindowsSignatureCaFile()),
                configuredFile(properties.getWindowsSignatureTsaCaFile()), configuredFile(properties.getWindowsSignatureCrlFile()),
                configuredFile(properties.getWindowsSignatureTsaCrlFile()));
    }

    private static Path configuredFile(String value) {
        try {
            Path path = Path.of(value);
            if (!path.isAbsolute() || !Files.isRegularFile(path) || !Files.isReadable(path)
                    || Files.size(path) == 0 || Files.size(path) > 67108864L) throw new IOException();
            return path.toRealPath();
        } catch (IOException | RuntimeException invalid) {
            throw invalid("Windows 正式签名验证器、公共信任根或撤销列表未配置完整，请联系管理员");
        }
    }

    static Result execute(List<String> command, Duration timeout) throws IOException {
        Process process = new ProcessBuilder(command).redirectErrorStream(true).start();
        process.getOutputStream().close();
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        boolean[] exceeded = { false };
        Thread reader = Thread.ofVirtual().start(() -> {
            try (var input = process.getInputStream()) {
                byte[] buffer = new byte[4096];
                for (int read; (read = input.read(buffer)) != -1;) {
                    if (read > MAX_OUTPUT_BYTES - output.size()) { exceeded[0] = true; process.destroyForcibly(); break; }
                    output.write(buffer, 0, read);
                }
            } catch (IOException failure) { exceeded[0] = true; }
        });
        try {
            if (!process.waitFor(timeout.toMillis(), TimeUnit.MILLISECONDS)) throw new IOException("Signature verification timeout");
            reader.join(2000);
            if (reader.isAlive()) throw new IOException("Signature verifier output did not close");
            return new Result(process.exitValue(), output.toString(StandardCharsets.UTF_8), exceeded[0]);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IOException("Signature verification interrupted", interrupted);
        } finally {
            process.descendants().forEach(ProcessHandle::destroyForcibly);
            process.destroyForcibly();
            try { process.getInputStream().close(); } catch (IOException ignored) { /* closes bounded reader */ }
        }
    }

    @FunctionalInterface interface VerificationProcess { Result verify(List<String> command, Duration timeout) throws IOException; }
    record Result(int exitCode, String output, boolean outputExceeded) { }
    private record Settings(List<String> pins, Path executable, Path ca, Path tsaCa, Path crl, Path tsaCrl) { }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}

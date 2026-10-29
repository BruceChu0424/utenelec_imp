package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Path;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipException;
import org.apache.commons.compress.archivers.zip.ZipArchiveEntry;
import org.apache.commons.compress.archivers.zip.ZipFile;
import org.springframework.stereotype.Component;

/** Validates the bytes being published, including the Windows installer's authoritative manifest. */
@Component
public class ClientPackageInspector {
    private static final long MAX_EXPANDED_BYTES = 2147483648L;
    private static final int MAX_FILES = 20001;
    private static final String MANIFEST = "uten-client-manifest.json";
    private static final String UPDATER = "client_updater/client_updater.ps1";
    private final ObjectMapper mapper;

    public ClientPackageInspector(ObjectMapper mapper) { this.mapper = mapper; }

    void inspect(Path file, ClientReleaseDto.Release release) throws IOException {
        ClientRuntimeFamily.requireMode(release);
        ClientDeliveryContract.require(release);
        if (ClientRuntimeFamily.setupMode(release.runtimeFamily()).equals(release.installMode())) {
            WindowsSetupInspector.inspect(file, release);
            return;
        }
        boolean wpf = ClientRuntimeFamily.WPF_LEGACY.equals(release.runtimeFamily());
        if (wpf && (Files.size(file) < 1 || Files.size(file) > WpfPackageContract.MAXIMUM_PACKAGE_BYTES))
            throw invalid("WPF 更新 ZIP 超出共享包合同上限");
        if (wpf) WindowsWpfPackageInspector.requireDirectory(file);
        long maximumExpanded = wpf ? WpfPackageContract.MAXIMUM_EXPANDED_BYTES_EXCLUSIVE - 1L : MAX_EXPANDED_BYTES;
        try (ZipFile zip = ZipFile.builder().setPath(file).get()) {
            Map<String, ZipArchiveEntry> files = new HashMap<>();
            Set<String> folded = new HashSet<>();
            long expanded = 0;
            var entries = zip.getEntries();
            int count = 0;
            while (entries.hasMoreElements()) {
                ZipArchiveEntry entry = entries.nextElement();
                if (++count > MAX_FILES) throw invalid("更新包包含的文件过多");
                String name = safePath(entry.getName());
                if (entry.isUnixSymlink() || (entry.getExternalAttributes() & 1024) != 0)
                    throw invalid("更新包不能包含符号链接或重解析点");
                if (!folded.add(name.toLowerCase(Locale.ROOT))) throw invalid("更新包包含重名或大小写冲突的路径");
                if (entry.isDirectory()) {
                    if (isWindowsPackage(release)) throw invalid("Windows 软件包不能包含显式目录，请使用客户端打包工具生成");
                    continue;
                }
                if (entry.getSize() > (wpf ? WpfPackageContract.MAXIMUM_FILE_BYTES : 536870912L)) throw invalid("更新包中的单个文件超过上限");
                if (entry.getSize() < (wpf ? 1 : 0) || entry.getSize() > maximumExpanded - expanded)
                    throw invalid("更新包解压后的大小超过上限");
                expanded += entry.getSize();
                files.put(name, entry);
            }
            Set<String> fileNames = new HashSet<>();
            files.keySet().forEach(name -> fileNames.add(name.toLowerCase(Locale.ROOT)));
            for (String name : fileNames) {
                for (int slash = name.indexOf('/'); slash >= 0; slash = name.indexOf('/', slash + 1)) {
                    if (fileNames.contains(name.substring(0, slash))) throw invalid("更新包中的文件与目录路径冲突");
                }
            }
            if (isWindowsPackage(release)) inspectWindows(zip, files, release);
            else if (!files.containsKey("AndroidManifest.xml") || !files.containsKey("classes.dex"))
                throw invalid("请选择完整的 Android APK 更新包");
            else if (ClientDeliveryContract.auditedAndroid(release)) AndroidPackageInspector.inspect(zip, files, release);
        } catch (ZipException malformed) {
            throw invalid("更新包不是有效的 ZIP 或 APK 文件");
        }
    }

    private void inspectWindows(ZipFile zip, Map<String, ZipArchiveEntry> files, ClientReleaseDto.Release release)
            throws IOException {
        boolean installer = "installer".equals(release.packageKind());
        boolean wpf = ClientRuntimeFamily.WPF_LEGACY.equals(release.runtimeFamily());
        if (wpf && (!files.keySet().containsAll(WindowsWpfPackageInspector.REQUIRED) || !files.containsKey(MANIFEST)))
            throw invalid("WPF 更新包缺少原生程序、托管库、许可、正式连接配置或版本清单");
        if (wpf && files.size() != WindowsWpfPackageInspector.REQUIRED.size() + 1)
            throw invalid("WPF 更新 ZIP 必须仅含六个运行文件及根清单");
        if (!wpf && (!files.keySet().containsAll(Set.of("uten_imp.exe", "flutter_windows.dll", "data/app.so",
                "data/icudtl.dat", MANIFEST)) || files.keySet().stream().noneMatch(name -> name.startsWith("data/flutter_assets/")))
            ) throw invalid("Windows 更新包缺少程序、Flutter 运行库、资源或版本清单");
        if (!wpf && installer && (!files.containsKey(UPDATER) || files.get(UPDATER).getSize() <= 0))
            throw invalid("Windows 完整客户端缺少首装更新器，请选择专用完整客户端 ZIP");
        ZipArchiveEntry manifestEntry = files.get(MANIFEST);
        int manifestLimit = wpf ? WpfPackageContract.MAXIMUM_MANIFEST_BYTES : 8388608;
        if (manifestEntry.getSize() > manifestLimit) throw invalid("Windows 更新清单过大");
        JsonNode manifest;
        try (InputStream input = zip.getInputStream(manifestEntry)) {
            byte[] bytes = input.readNBytes(manifestLimit + 1);
            if (wpf && (bytes.length != manifestEntry.getSize() || bytes.length > manifestLimit)) throw invalid("Windows 更新清单大小不匹配");
            manifest = wpf ? WindowsWpfPackageInspector.strictJson(bytes, mapper) : mapper.readTree(bytes);
        } catch (JsonProcessingException malformed) {
            throw invalid("Windows 更新清单不是有效的 JSON 文件");
        }
        if (wpf) WindowsWpfPackageInspector.manifestFields(manifest);
        if (manifest == null || !manifest.isObject() || manifest.path("schemaVersion").asInt(-1) != 1
                || wpf && (!manifest.path("schemaVersion").isIntegralNumber() || !manifest.path("schemaVersion").canConvertToInt()
                    || !manifest.path("buildNumber").isIntegralNumber() || !manifest.path("buildNumber").canConvertToLong()
                    || manifest.path("buildNumber").asLong() < 1 || manifest.path("buildNumber").asLong() > 65535
                    || !manifest.path("version").isTextual() || !manifest.path("runtimeFamily").isTextual()
                    || !manifest.path("packageKind").isTextual())
                || !"windows".equals(manifest.path("platform").asText())
                || !release.architecture().equals(manifest.path("architecture").asText())
                || manifest.path("buildNumber").asLong(-1) != release.buildNumber()
                || !release.packageKind().equals(manifest.path("packageKind").asText("update"))
                || !release.runtimeFamily().equals(manifest.path("runtimeFamily").asText("flutter"))
                || (wpf || ClientDeliveryContract.paired(release)) && !release.version().equals(manifest.path("version").asText())
                || !(wpf ? WindowsWpfPackageInspector.EXECUTABLE : "uten_imp.exe").equals(manifest.path("executable").asText())
                || !manifest.path("files").isArray())
            throw invalid("Windows 软件清单的平台、架构、包类型或构建号与发布信息不一致");
        Set<String> recorded = new HashSet<>();
        for (JsonNode item : manifest.path("files")) {
            if (wpf) WindowsWpfPackageInspector.fileFields(item);
            String name = safePath(item.path("path").asText());
            if (name.length() > 230 || !(wpf ? WindowsWpfPackageInspector.allowedFile(name)
                    : "uten_imp.exe".equals(name) || name.startsWith("data/") || name.matches("[^/]+\\.dll") || installer && UPDATER.equals(name)))
                throw invalid("Windows 软件包包含程序运行目录以外的文件");
            ZipArchiveEntry entry = files.get(name);
            if (MANIFEST.equals(name) || !recorded.add(name) || entry == null
                    || wpf && (!item.path("path").isTextual() || !item.path("size").isIntegralNumber()
                        || !item.path("size").canConvertToLong() || !item.path("sha256").isTextual())
                    || item.path("size").asLong(-1) != entry.getSize()
                    || !item.path("sha256").asText().matches("[0-9a-f]{64}"))
                throw invalid("Windows 更新包的文件清单不完整或格式不正确");
            MessageDigest digest = digest();
            long total = 0;
            try (InputStream input = zip.getInputStream(entry)) {
                byte[] buffer = new byte[65536];
                for (int read; (read = input.read(buffer)) != -1;) {
                    total += read;
                    if (total > entry.getSize()) throw invalid("更新包中文件的实际大小与清单不一致");
                    digest.update(buffer, 0, read);
                }
            }
            if (total != entry.getSize() || !HexFormat.of().formatHex(digest.digest()).equals(item.path("sha256").asText()))
                throw invalid("Windows 更新包中文件的校验值与清单不一致");
        }
        if (recorded.size() != files.size() - 1) throw invalid("Windows 更新包包含未登记在清单内的文件");
        if (wpf) WindowsWpfPackageInspector.inspect(zip, files, release, mapper);
        else if (ClientDeliveryContract.paired(release)) WindowsFlutterPackageInspector.inspect(zip, files, release);
    }

    private static boolean isWindowsPackage(ClientReleaseDto.Release release) {
        return "windows_archive".equals(release.installMode()) || "windows_bundle".equals(release.installMode())
                || "windows_wpf_archive".equals(release.installMode());
    }

    private static String safePath(String name) {
        if (name == null || name.isEmpty() || name.length() > 1024 || name.startsWith("/")
                || name.contains("\\") || name.contains(":")) throw invalid("更新包包含无效路径");
        String normalized = name.endsWith("/") ? name.substring(0, name.length() - 1) : name;
        for (String part : normalized.split("/", -1)) {
            String stem = part.split("\\.", 2)[0].toUpperCase(Locale.ROOT);
            if (part.isBlank() || ".".equals(part) || "..".equals(part) || part.endsWith(".") || part.endsWith(" ")
                    || part.chars().anyMatch(character -> character < 32 || "<>\"|?*".indexOf(character) >= 0)
                    || Set.of("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
                    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9").contains(stem))
                throw invalid("更新包包含不安全的文件路径");
        }
        return normalized;
    }

    static MessageDigest digest() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }

    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}

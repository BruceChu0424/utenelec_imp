package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;

/** Byte-level package fixtures: no uploaded executable is loaded or run. */
final class WindowsRuntimeProfileFixture {
    private WindowsRuntimeProfileFixture() { }
    static Map<String, Object> formal() {
        return Map.of("schemaVersion", 1, "buildProfile", "formal", "applicationId", "com.uten.uten_imp",
                "nativeProductName", "优腾综合管理平台", "runtimeFamily", "flutter");
    }
    static byte[] archive(ObjectMapper mapper, String version, long build, Map<String, String> pe,
            byte[] profile, String installerHash) throws Exception {
        var files = new LinkedHashMap<String, byte[]>();
        files.put("uten_imp.exe", WindowsFlutterFixture.main(build, "x64", version, pe));
        files.put("flutter_windows.dll", WindowsFlutterFixture.engine(build, "x64", version));
        byte[] elf = WindowsFlutterFixture.elf("x64");
        byte[] urls = "https://192.168.1.13/api https://justplayit.cn/api".getBytes(StandardCharsets.UTF_8);
        byte[] snapshot = java.util.Arrays.copyOf(elf, elf.length + urls.length);
        System.arraycopy(urls, 0, snapshot, elf.length, urls.length);
        files.put("data/app.so", snapshot);
        files.put("data/icudtl.dat", "icu".getBytes(StandardCharsets.UTF_8));
        files.put("data/flutter_assets/AssetManifest.bin", "assets".getBytes(StandardCharsets.UTF_8));
        if (profile != null) files.put(WindowsRuntimeProfileContract.FILE, profile);
        var entries = new ArrayList<Map<String, Object>>();
        files.forEach((name, bytes) -> entries.add(Map.of("path", name, "size", bytes.length, "sha256", ClientReleaseFixtures.sha(bytes))));
        var manifest = new LinkedHashMap<String, Object>();
        manifest.put("schemaVersion", 1); manifest.put("platform", "windows"); manifest.put("runtimeFamily", "flutter");
        manifest.put("architecture", "x64"); manifest.put("version", version); manifest.put("buildNumber", build);
        manifest.put("packageKind", "update"); manifest.put("executable", "uten_imp.exe"); manifest.put("files", entries);
        if (installerHash != null) manifest.put("installerSha256", installerHash);
        files.put("uten-client-manifest.json", mapper.writeValueAsBytes(manifest));
        return ClientReleaseFixtures.zip(files);
    }
}

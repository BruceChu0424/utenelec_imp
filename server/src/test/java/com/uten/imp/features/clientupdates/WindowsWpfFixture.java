package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import java.nio.file.Files;
import java.nio.file.Path;

/** Synthetic metadata fixtures, containing no executable CLR code or ERP release artifact. */
final class WindowsWpfFixture {
    static final String COMPANY_RELEASE_PROVENANCE = WpfPackageContract.COMPANY_RELEASE_MARKER;
    private WindowsWpfFixture() { }
    static byte[] setup(long build, String architecture, String version) {
        return WindowsSetupFixture.bytes(build, architecture, version, Map.of(
                "ProductName", "Uten IMP Native WPF Compatibility Validation",
                "OriginalFileName", "UtenWin7WpfSetup.exe",
                "FileDescription", "Uten IMP Native WPF Compatibility Validation"));
    }
    static byte[] image(long build, String architecture, String version, boolean library) {
        return image(build, architecture, version, library, COMPANY_RELEASE_PROVENANCE);
    }
    static byte[] image(long build, String architecture, String version, boolean library, String provenance) {
        byte[] bytes = WindowsSetupFixture.bytes(build, architecture, version, Map.of("Comments", provenance));
        Arrays.fill(bytes, 152, 512, (byte) 0);
        var data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        boolean x64 = !library && "x64".equals(architecture);
        int optionalSize = x64 ? 240 : 224, directories = x64 ? 112 : 96, section = 152 + optionalSize;
        data.putShort(132, (short) (x64 ? 0x8664 : 0x14c)).putShort(148, (short) optionalSize)
                .putShort(150, (short) (0x102 | (library ? 0x2000 : 0)));
        data.putShort(152, (short) (x64 ? 0x20b : 0x10b)).putInt(152 + directories - 4, 16);
        data.putInt(152 + directories + 16, 4096).putInt(152 + directories + 20, 4096);
        data.putInt(section + 8, 4096).putInt(section + 12, 4096).putInt(section + 16, 4096).putInt(section + 20, 512);
        data.putInt(152 + directories + 14 * 8, 4096 + 2800).putInt(152 + directories + 14 * 8 + 4, 72);
        int clr = 512 + 2800, metadata = 512 + 3000;
        data.putInt(clr, 72).putShort(clr + 4, (short) 2).putShort(clr + 6, (short) 5)
                .putInt(clr + 8, 4096 + 3000).putInt(clr + 12, 64)
                .putInt(clr + 16, !library && !x64 ? 3 : 1).putInt(clr + 20, library ? 0 : 0x06000001);
        data.putInt(metadata, 0x424a5342).putShort(metadata + 4, (short) 1).putShort(metadata + 6, (short) 1)
                .putInt(metadata + 12, 12);
        byte[] runtime = "v4.0.30319\0".getBytes(StandardCharsets.US_ASCII);
        System.arraycopy(runtime, 0, bytes, metadata + 16, runtime.length);
        data.putInt(684, library ? 2 : 1);
        return bytes;
    }
    static Map<String, byte[]> files(long build, String architecture, String version) {
        var files = new LinkedHashMap<String, byte[]>();
        files.put("Uten.Legacy.Desktop.exe", image(build, architecture, version, false));
        files.put("Uten.Legacy.Core.dll", image(build, architecture, version, true));
        files.put("BouncyCastle.Cryptography.dll", dependencyFixture("lib/net461/BouncyCastle.Cryptography.dll", WpfPackageContract.DEPENDENCY_DLL_SHA256));
        files.put("BouncyCastle-LICENSE.md", dependencyFixture("LICENSE.md", WpfPackageContract.DEPENDENCY_LICENSE_SHA256));
        files.put("Uten.Legacy.Desktop.exe.config", "<configuration><startup><supportedRuntime version=\"v4.0\" sku=\".NETFramework,Version=v4.8\"/></startup></configuration>".getBytes(StandardCharsets.UTF_8));
        files.put("uten.client.json", "{\"endpoints\":[{\"id\":\"company\",\"name\":\"公司\",\"apiBaseUrl\":\"https://imp.utenelec/api\"}],\"selectedEndpointId\":\"company\"}".getBytes(StandardCharsets.UTF_8));
        return files;
    }
    private static byte[] dependencyFixture(String name, String expected) {
        // The already restored private vendor bytes are read only, never loaded/executed.
        // CI must explicitly provide this audited dependency fixture or report a skip.
        Path root = Path.of(System.getProperty("uten.wpf.dependencyFixtureRoot",
                "../build/windows-wpf/dependencies/BouncyCastle.Cryptography.2.7.0"));
        Path file = root.resolve(name);
        org.junit.jupiter.api.Assumptions.assumeTrue(Files.isRegularFile(file), "Pinned private WPF dependency fixture is unavailable: " + file);
        try {
            byte[] bytes = Files.readAllBytes(file);
            if (!sha(bytes).equals(expected)) throw new IllegalStateException("Pinned WPF fixture bytes differ from the authoritative lock");
            return bytes;
        } catch (java.io.IOException error) { throw new IllegalStateException("Cannot read pinned WPF fixture", error); }
    }
    static byte[] update(long build, String architecture, String version) throws Exception {
        return zip(files(build, architecture, version), build, architecture, version, "wpf_legacy");
    }
    static byte[] flutterUpdate(long build, String architecture) throws Exception {
        var files = new LinkedHashMap<String, byte[]>();
        for (String name : java.util.List.of("uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin"))
            files.put(name, name.getBytes(StandardCharsets.UTF_8));
        var manifest = new LinkedHashMap<String, Object>();
        manifest.put("schemaVersion", 1); manifest.put("platform", "windows"); manifest.put("architecture", architecture);
        manifest.put("buildNumber", build); manifest.put("executable", "uten_imp.exe");
        var records = new ArrayList<Map<String, Object>>();
        files.forEach((name, bytes) -> records.add(Map.of("path", name, "size", bytes.length, "sha256", sha(bytes))));
        manifest.put("files", records);
        return archive(files, manifest);
    }
    static byte[] zip(Map<String, byte[]> files, long build, String architecture, String version, String family) throws Exception {
        var manifest = new LinkedHashMap<String, Object>();
        manifest.put("schemaVersion", 1); manifest.put("platform", "windows"); manifest.put("architecture", architecture);
        manifest.put("version", version); manifest.put("buildNumber", build); manifest.put("packageKind", "update");
        manifest.put("executable", "Uten.Legacy.Desktop.exe");
        if (family != null) manifest.put("runtimeFamily", family);
        var records = new ArrayList<Map<String, Object>>();
        for (var entry : files.entrySet()) records.add(Map.of("path", entry.getKey(), "size", entry.getValue().length, "sha256", sha(entry.getValue())));
        manifest.put("files", records);
        return archive(files, manifest);
    }
    private static byte[] archive(Map<String, byte[]> files, Map<String, Object> manifest) throws Exception {
        var bytes = new ByteArrayOutputStream();
        try (var zip = new ZipOutputStream(bytes)) {
            for (var entry : files.entrySet()) { zip.putNextEntry(new ZipEntry(entry.getKey())); zip.write(entry.getValue()); zip.closeEntry(); }
            zip.putNextEntry(new ZipEntry("uten-client-manifest.json")); zip.write(new ObjectMapper().writeValueAsBytes(manifest)); zip.closeEntry();
        }
        return bytes.toByteArray();
    }
    static String sha(byte[] bytes) { return HexFormat.of().formatHex(ClientPackageInspector.digest().digest(bytes)); }
}

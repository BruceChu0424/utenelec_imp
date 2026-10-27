package com.uten.imp.features.clientupdates;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Synthetic PE resource tree only; never an executable ERP installer or a verified Inno payload. */
final class WindowsSetupFixture {
    private WindowsSetupFixture() { }
    static byte[] bytes(long build, String architecture, String version) {
        return bytes(build, architecture, version, Map.of());
    }
    static byte[] bytes(long build, String architecture, String version, Map<String, String> overrides) {
        String base = version.split("-", 2)[0], text = base + "." + build;
        String[] parts = base.split("\\.");
        final int ms;
        final int ls;
        try {
            ms = Integer.parseInt(parts[0]) << 16 | Integer.parseInt(parts[1]);
            ls = Integer.parseInt(parts[2]) << 16 | (int) build;
        } catch (NumberFormatException invalidVersion) {
            throw new IllegalArgumentException("Fixture version must contain numeric components", invalidVersion);
        }
        var strings = new LinkedHashMap<String, String>();
        strings.put("ProductName", "Uten IMP Windows Setup");
        strings.put("OriginalFileName", "UtenIMPSetup.exe");
        strings.put("FileDescription", "Uten IMP Windows Setup (" + architecture + ")");
        strings.put("FileVersion", text);
        strings.put("ProductVersion", text);
        strings.putAll(overrides);
        var entries = new ArrayList<byte[]>();
        strings.forEach((key, value) -> entries.add(block(key, 1, utf16(value), List.of())));
        byte[] table = block("040904e4", 1, new byte[0], entries);
        byte[] stringInfo = block("StringFileInfo", 1, new byte[0], List.of(table));
        ByteBuffer fixed = ByteBuffer.allocate(52).order(ByteOrder.LITTLE_ENDIAN);
        for (int value : new int[] {0xfeef04bd, 0x10000, ms, ls, ms, ls, 63, 0, 0x40004, 1, 0, 0, 0}) fixed.putInt(value);
        byte[] versionInfo = block("VS_VERSION_INFO", 0, fixed.array(), List.of(stringInfo));
        byte[] bytes = new byte[4608];
        ByteBuffer pe = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        pe.putShort(0, (short) 0x5a4d).putInt(60, 128).putInt(128, 0x4550);
        pe.putShort(132, (short) 0x14c).putShort(134, (short) 1).putShort(148, (short) 224).putShort(150, (short) 0x102);
        pe.putShort(152, (short) 0x10b).putInt(244, 16).putInt(264, 4096).putInt(268, 4096);
        pe.putInt(384, 4096).putInt(388, 4096).putInt(392, 4096).putInt(396, 512);
        for (int directory : new int[] {512, 536, 560}) pe.putShort(directory + 14, (short) 1);
        pe.putInt(528, 16).putInt(532, 0x80000018);
        pe.putInt(552, 1).putInt(556, 0x80000030);
        pe.putInt(576, 1033).putInt(580, 72);
        pe.putInt(584, 4096 + 96).putInt(588, versionInfo.length);
        System.arraycopy(versionInfo, 0, bytes, 608, versionInfo.length);
        return bytes;
    }
    private static byte[] utf16(String value) { return (value + '\0').getBytes(StandardCharsets.UTF_16LE); }
    private static byte[] block(String key, int type, byte[] value, List<byte[]> children) {
        var out = new ByteArrayOutputStream();
        out.writeBytes(new byte[6]);
        out.writeBytes(utf16(key));
        pad(out);
        out.writeBytes(value);
        for (byte[] child : children) { pad(out); out.writeBytes(child); }
        byte[] result = out.toByteArray();
        ByteBuffer.wrap(result).order(ByteOrder.LITTLE_ENDIAN).putShort((short) result.length)
                .putShort((short) (type == 1 ? value.length / 2 : value.length)).putShort((short) type);
        return result;
    }
    private static void pad(ByteArrayOutputStream out) { while ((out.size() & 3) != 0) out.write(0); }
}

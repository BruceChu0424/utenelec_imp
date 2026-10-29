package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** Bounded PE/version-resource validation, not Authenticode or compressed Inno payload verification. */
final class WindowsSetupInspector {
    private static final int MAX_RESOURCE_BYTES = 16 * 1024 * 1024;
    private WindowsSetupInspector() { }

    static void inspect(Path file, ClientReleaseDto.Release release) throws IOException {
        ClientRuntimeFamily.requireMode(release);
        if (!"windows".equals(release.platform()) || !"installer".equals(release.packageKind())) throw invalid();
        try (var channel = FileChannel.open(file, StandardOpenOption.READ)) {
            Reader reader = new Reader(channel);
            Data dos = reader.read(0, 64);
            if (dos.word(0) != 0x5a4d) throw invalid();
            long pe = dos.dword(60);
            Data header = reader.read(pe, 24);
            int sections = header.word(6), optionalSize = header.word(20);
            // Inno's configured outer SetupLdr is x86, independent of the installed application architecture.
            if (header.dword(0) != 0x4550 || header.word(4) != 0x14c || (header.word(22) & 2) == 0
                    || sections < 1 || sections > 96 || optionalSize < 120) throw invalid();
            Data optional = reader.read(pe + 24, optionalSize);
            if (optional.word(0) != 0x10b || optional.dword(92) < 3) throw invalid();
            long resourceRva = optional.dword(112), resourceSize = optional.dword(116);
            if (resourceSize < 16 || resourceSize > MAX_RESOURCE_BYTES) throw invalid();
            Data table = reader.read(pe + 24 + optionalSize, sections * 40);
            var ranges = new ArrayList<Section>();
            for (int i = 0; i < sections; i++) {
                int entry = i * 40;
                ranges.add(new Section(table.dword(entry + 12), Math.min(table.dword(entry + 8), table.dword(entry + 16)),
                        table.dword(entry + 20)));
            }
            ResourceTree resources = new ResourceTree(reader.read(offset(ranges, resourceRva, resourceSize), (int) resourceSize));
            int versions = 0;
            for (Entry type : resources.entries(0)) {
                if (type.name() != 16) continue;
                if (!type.directory()) throw invalid();
                for (Entry name : resources.entries(type.offset())) {
                    if (!name.directory()) throw invalid();
                    for (Entry language : resources.entries(name.offset())) {
                        if (language.directory() || ++versions > 128) throw invalid();
                        long valueRva = resources.data.dword(language.offset());
                        long valueSize = resources.data.dword(language.offset() + 4);
                        if (valueSize < 92 || valueSize > 65535) throw invalid();
                        inspectVersion(reader.read(offset(ranges, valueRva, valueSize), (int) valueSize), release);
                    }
                }
            }
            if (versions == 0) throw invalid();
        }
    }

    static long offset(List<Section> sections, long rva, long length) {
        Long result = null;
        for (Section section : sections) {
            long delta = rva - section.rva();
            if (delta < 0 || delta > section.length() || length > section.length() - delta) continue;
            if (result != null) throw invalid();
            result = section.raw() + delta;
        }
        if (result == null) throw invalid();
        return result;
    }

    private static void inspectVersion(Data data, ClientReleaseDto.Release release) {
        Block root = new Blocks(data).read(0, data.length(), 0);
        if (!"VS_VERSION_INFO".equals(root.key()) || root.type() != 0 || root.valueSize() != 52) throw invalid();
        int fixed = root.value();
        if (data.dword(fixed) != 0xfeef04bdL || data.dword(fixed + 4) != 0x10000 || data.dword(fixed + 36) != 1) throw invalid();
        int[] version = numericVersion(release.version());
        long ms = ((long) version[0] << 16) | version[1], ls = ((long) version[2] << 16) | release.buildNumber();
        if (data.dword(fixed + 8) != ms || data.dword(fixed + 12) != ls
                || data.dword(fixed + 16) != ms || data.dword(fixed + 20) != ls) throw invalid();
        String textVersion = version[0] + "." + version[1] + "." + version[2] + "." + release.buildNumber();
        int tables = 0;
        for (Block info : root.children()) {
            if (!"StringFileInfo".equals(info.key())) continue;
            if (info.type() != 1 || info.valueSize() != 0) throw invalid();
            for (Block table : info.children()) {
                if (!table.key().matches("[0-9a-fA-F]{8}") || table.type() != 1 || table.valueSize() != 0) throw invalid();
                Map<String, String> values = new HashMap<>();
                for (Block item : table.children()) {
                    if (item.type() != 1 || !item.children().isEmpty() || item.valueSize() < 2) throw invalid();
                    String value = versionText(data.text(item.value(), item.valueSize()));
                    if (values.putIfAbsent(item.key().toLowerCase(Locale.ROOT), value) != null) throw invalid();
                }
                boolean wpf = ClientRuntimeFamily.WPF_LEGACY.equals(release.runtimeFamily());
                String product = wpf ? "Uten IMP Native WPF Compatibility Validation" : "Uten IMP Windows Setup";
                if (!product.equals(values.get("productname"))
                        || !(wpf ? "UtenWin7WpfSetup.exe" : "UtenIMPSetup.exe").equals(values.get("originalfilename"))
                        || !(wpf ? product : "Uten IMP Windows Setup (" + release.architecture() + ")").equals(values.get("filedescription"))
                        || !textVersion.equals(values.get("fileversion")) || !textVersion.equals(values.get("productversion"))) throw invalid();
                tables++;
            }
        }
        if (tables == 0) throw invalid();
    }

    private static String versionText(String value) {
        // Inno pads the reserved text slots with ASCII spaces and NULs. Preserve every other character.
        if (value.indexOf('\0') < 0) throw invalid();
        int end = value.length();
        while (end > 0 && (value.charAt(end - 1) == ' ' || value.charAt(end - 1) == '\0')) end--;
        String normalized = value.substring(0, end);
        if (normalized.indexOf('\0') >= 0) throw invalid();
        return normalized;
    }

    static int[] numericVersion(String version) {
        try {
            String[] parts = version.split("-", 2)[0].split("\\.", -1);
            if (parts.length != 3) throw invalid();
            int[] result = new int[3];
            for (int i = 0; i < 3; i++) {
                result[i] = Integer.parseInt(parts[i]);
                if (result[i] < 0 || result[i] > 65535) throw invalid();
            }
            return result;
        } catch (NumberFormatException malformed) { throw invalid(); }
    }

    record Section(long rva, long length, long raw) { }
    record Entry(long name, boolean directory, int offset) { }
    record Block(String key, int type, int value, int valueSize, List<Block> children) { }

    static final class ResourceTree {
        private final Data data;
        private int visited;
        ResourceTree(Data data) { this.data = data; }
        List<Entry> entries(int start) {
            int count = data.word(start + 12) + data.word(start + 14);
            if ((visited += count) > 4096) throw invalid();
            data.range(start + 16, count * 8);
            var entries = new ArrayList<Entry>();
            for (int i = 0; i < count; i++) {
                int entry = start + 16 + i * 8;
                long target = data.dword(entry + 4);
                entries.add(new Entry(data.dword(entry), (target & 0x80000000L) != 0, (int) (target & 0x7fffffff)));
            }
            return entries;
        }
    }

    static final class Blocks {
        private final Data data;
        private int visited;
        Blocks(Data data) { this.data = data; }
        Block read(int start, int limit, int depth) {
            if (depth > 4 || ++visited > 4096) throw invalid();
            int length = data.word(start), valueLength = data.word(start + 2), type = data.word(start + 4);
            if (length < 8 || length > limit - start || type > 1) throw invalid();
            int end = start + length, cursor = start + 6, keyEnd = cursor;
            while (keyEnd + 2 <= end && data.word(keyEnd) != 0) {
                keyEnd += 2;
                if (keyEnd - cursor > 512) throw invalid();
            }
            if (keyEnd + 2 > end) throw invalid();
            String key = data.text(cursor, keyEnd - cursor);
            int value = align(keyEnd + 2), valueSize = type == 1 ? valueLength * 2 : valueLength;
            if (value > end || valueSize > end - value) throw invalid();
            var children = new ArrayList<Block>();
            for (cursor = align(value + valueSize); cursor < end; ) {
                if (end - cursor < 6) {
                    for (int i = cursor; i < end; i++) if (data.bytes[i] != 0) throw invalid();
                    break;
                }
                children.add(read(cursor, end, depth + 1));
                cursor = align(cursor + data.word(cursor));
            }
            return new Block(key, type, value, valueSize, List.copyOf(children));
        }
    }

    private static int align(int value) { return (value + 3) & ~3; }
    private record Reader(FileChannel channel) {
        Data read(long offset, int length) throws IOException {
            if (offset < 0 || length < 0 || length > MAX_RESOURCE_BYTES || offset > channel.size() - length) throw invalid();
            byte[] bytes = new byte[length];
            ByteBuffer buffer = ByteBuffer.wrap(bytes);
            while (buffer.hasRemaining()) if (channel.read(buffer, offset + buffer.position()) <= 0) throw invalid();
            return new Data(bytes);
        }
    }
    static final class Data {
        private final byte[] bytes;
        private final ByteBuffer buffer;
        Data(byte[] bytes) { this.bytes = bytes; this.buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN); }
        int length() { return bytes.length; }
        void range(int offset, int length) { if (offset < 0 || length < 0 || offset > bytes.length - length) throw invalid(); }
        int word(int offset) { range(offset, 2); return Short.toUnsignedInt(buffer.getShort(offset)); }
        long dword(int offset) { range(offset, 4); return Integer.toUnsignedLong(buffer.getInt(offset)); }
        byte[] bytes(int offset, int length) { range(offset, length); return java.util.Arrays.copyOfRange(bytes, offset, offset + length); }
        String text(int offset, int length) {
            range(offset, length);
            if ((length & 1) != 0) throw invalid();
            return new String(bytes, offset, length, StandardCharsets.UTF_16LE);
        }
    }
    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "请选择本项目生成且平台、版本、构建号匹配的 Windows Setup.exe 安装包");
    }
}

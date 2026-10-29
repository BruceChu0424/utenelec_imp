package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.apache.commons.compress.archivers.zip.ZipArchiveEntry;
import org.apache.commons.compress.archivers.zip.ZipFile;

/** Bounded Android binary XML/native-header inspection. No aapt/process or uploaded code runs.
 * Format source: AOSP androidfw ResourceTypes.h (ResStringPool/ResXMLTree_attrExt/attribute).
 * Resource-indirected versionName is deliberately unsupported rather than guessed. */
final class AndroidPackageInspector {
    private static final int MAX_MANIFEST = 4 * 1024 * 1024;
    private static final String ANDROID = "http://schemas.android.com/apk/res/android";
    private static final String PACKAGE = "com.uten.uten_imp";
    private static final Map<String,String> ABIS = Map.of("arm64-v8a", "arm64", "armeabi-v7a", "armeabi-v7a", "x86_64", "x64");
    private AndroidPackageInspector() { }
    static void inspect(ZipFile zip, Map<String, ZipArchiveEntry> files, ClientReleaseDto.Release release) throws IOException {
        byte[] xml = read(zip, files.get("AndroidManifest.xml"), MAX_MANIFEST, false);
        verifyEntry(zip, files.get("AndroidManifest.xml"));
        Manifest manifest = new BinaryXml(xml).read();
        if (!PACKAGE.equals(manifest.packageName()) || !release.version().equals(manifest.version())
                || release.buildNumber() != manifest.build()) throw invalid();
        ZipArchiveEntry dex = files.get("classes.dex"); byte[] header = read(zip, dex, 112, true);
        if (header.length < 112 || header[0] != 'd' || header[1] != 'e' || header[2] != 'x' || header[3] != '\n' || header[7] != 0
                || !Set.of("035", "037", "038", "039", "040").contains(new String(header,4,3,StandardCharsets.US_ASCII))) throw invalid();
        var data = new WindowsSetupInspector.Data(header);
        if (data.dword(32) != dex.getSize() || data.dword(36) != 112 || data.dword(40) != 0x12345678L) throw invalid();
        verifyEntry(zip, dex);
        var found = new HashSet<String>();
        for (var entry : files.entrySet()) {
            if (!entry.getKey().startsWith("lib/") || !entry.getKey().endsWith(".so")) continue;
            String[] parts = entry.getKey().split("/", -1);
            if (parts.length != 3 || !ABIS.containsKey(parts[1])) throw invalid();
            NativeBinaryArchitecture.elf(read(zip, entry.getValue(), 64, true), ABIS.get(parts[1]));
            verifyEntry(zip, entry.getValue());
            found.add(parts[1]);
        }
        Set<String> expected = "universal".equals(release.architecture()) ? ABIS.keySet()
                : Set.of(switch (release.architecture()) { case "arm64" -> "arm64-v8a"; case "x64" -> "x86_64"; case "armeabi-v7a" -> "armeabi-v7a"; default -> "invalid"; });
        if (!found.equals(expected)) throw invalid();
        for (String abi : expected) if (!files.containsKey("lib/" + abi + "/libflutter.so") || !files.containsKey("lib/" + abi + "/libapp.so")) throw invalid();
    }
    private static void verifyEntry(ZipFile zip, ZipArchiveEntry entry) throws IOException {
        var crc = new java.util.zip.CRC32(); long total = 0;
        try (var input = zip.getInputStream(entry)) {
            byte[] buffer = new byte[65536];
            for (int read; (read = input.read(buffer)) != -1;) { total += read; if (total > entry.getSize()) throw invalid(); crc.update(buffer, 0, read); }
        }
        if (total != entry.getSize() || entry.getCrc() < 0 || crc.getValue() != entry.getCrc()) throw invalid();
    }
    private static byte[] read(ZipFile zip, ZipArchiveEntry entry, int maximum, boolean prefix) throws IOException {
        if (entry == null || entry.getSize() < 1 || !prefix && entry.getSize() > maximum) throw invalid();
        try (var input = zip.getInputStream(entry)) {
            byte[] bytes = input.readNBytes(maximum + (prefix ? 0 : 1));
            if (!prefix && (bytes.length != entry.getSize() || bytes.length > maximum)) throw invalid();
            return bytes;
        }
    }
    private record Manifest(String packageName, String version, long build) { }
    private record Attribute(String namespace, String name, long resource, int type, long data, String text) { }
    private static final class BinaryXml {
        private final WindowsSetupInspector.Data bytes;
        private final int length;
        private List<String> strings;
        private long[] resources;
        BinaryXml(byte[] bytes) { this.bytes = new WindowsSetupInspector.Data(bytes); length = bytes.length; }
        Manifest read() {
            if (length < 8 || bytes.word(0) != 3 || bytes.word(2) != 8 || bytes.dword(4) != length) throw invalid();
            var stack = new ArrayDeque<String>(); String packageName = null, version = null; Long build = null;
            boolean rootSeen = false, rootClosed = false, applicationSeen = false; int nodes = 0;
            for (int at = 8; at < length;) {
                if (++nodes > 100000) throw invalid();
                int type = bytes.word(at), header = bytes.word(at + 2), size = integer(bytes.dword(at + 4));
                if (header < 8 || size < header || size > length - at || (size & 3) != 0) throw invalid();
                if (type == 1) {
                    if (strings != null || rootSeen) throw invalid(); strings = pool(at, header, size);
                } else if (type == 0x180) {
                    if (strings == null || resources != null || rootSeen || header != 8 || (size - 8) / 4 > strings.size()) throw invalid();
                    resources = new long[(size - 8) / 4]; for (int i = 0; i < resources.length; i++) resources[i] = bytes.dword(at + 8 + 4 * i);
                } else {
                    if (strings == null || header != 16 || size < 24) throw invalid();
                    int extension = at + header;
                    if (type == 0x102) {
                        if (rootClosed || size < 36) throw invalid();
                        String name = text(bytes.dword(extension + 4)); String ns = nullable(bytes.dword(extension));
                        int count = bytes.word(extension + 12), start = bytes.word(extension + 8), stride = bytes.word(extension + 10);
                        if (start < 20 || stride != 20 || count > 1024 || (long)header + start + (long)count * stride > size || stack.size() > 64) throw invalid();
                        var attributes = new LinkedHashMap<String, Attribute>(); var resourceIds = new HashSet<Long>();
                        for (int i = 0; i < count; i++) {
                            int value = extension + start + stride * i;
                            long nameId = bytes.dword(value + 4), rawId = bytes.dword(value + 8);
                            String attributeName = text(nameId), attributeNs = nullable(bytes.dword(value));
                            long resource = resources != null && nameId < resources.length ? resources[(int)nameId] : 0;
                            if (bytes.word(value + 12) != 8 || bytes.bytes(value + 14, 1)[0] != 0) throw invalid();
                            int valueType = bytes.bytes(value + 15, 1)[0] & 255; long datum = bytes.dword(value + 16);
                            String content = valueType == 3 ? text(datum) : null;
                            if (valueType == 3 && rawId != 0xffffffffL && !content.equals(text(rawId))) throw invalid();
                            var attr = new Attribute(attributeNs, attributeName, resource, valueType, datum, content);
                            if (attributes.putIfAbsent((attributeNs == null ? "" : attributeNs) + ":" + attributeName, attr) != null
                                    || resource != 0 && !resourceIds.add(resource)) throw invalid();
                        }
                        if (stack.isEmpty()) {
                            if (rootSeen || !"manifest".equals(name) || ns != null) throw invalid(); rootSeen = true;
                            Attribute pkg = attributes.get(":package"); if (pkg == null || pkg.type() != 3) throw invalid(); packageName = pkg.text();
                            if (attributes.containsKey(":split")) throw invalid();
                            for (var value : attributes.values()) {
                                if (android(value, "versionCode", 0x0101021bL)) { build = number(value); if (build < 1 || build > Integer.MAX_VALUE) throw invalid(); }
                                if (android(value, "versionName", 0x0101021cL)) { if (value.type() != 3 || value.text().isBlank() || value.text().length() > 64) throw invalid(); version = value.text(); }
                                if (android(value, "versionCodeMajor", 0x01010576L) && number(value) != 0) throw invalid();
                                if ("isFeatureSplit".equals(value.name()) && value.data() != 0) throw invalid();
                            }
                        } else if (stack.size() == 1 && "application".equals(name)) {
                            if (applicationSeen || ns != null) throw invalid(); applicationSeen = true;
                            for (var value : attributes.values()) if (android(value, "debuggable", 0x0101000fL) || android(value, "testOnly", 0x01010272L)) {
                                if (value.type() != 0x12 || value.data() != 0) throw invalid();
                            }
                        }
                        stack.push((ns == null ? "" : ns) + ":" + name);
                    } else if (type == 0x103) {
                        String name = (nullable(bytes.dword(extension)) == null ? "" : nullable(bytes.dword(extension))) + ":" + text(bytes.dword(extension + 4));
                        if (stack.isEmpty() || !stack.pop().equals(name)) throw invalid(); if (stack.isEmpty()) rootClosed = true;
                    } else if (type != 0x100 && type != 0x101 && type != 0x104) throw invalid();
                }
                at += size;
            }
            if (!rootSeen || !rootClosed || !applicationSeen || !stack.isEmpty() || packageName == null || version == null || build == null) throw invalid();
            return new Manifest(packageName, version, build);
        }
        private boolean android(Attribute attr, String name, long resource) {
            if (!name.equals(attr.name()) && attr.resource() != resource) return false;
            if (!name.equals(attr.name()) || !ANDROID.equals(attr.namespace()) || attr.resource() != resource) throw invalid();
            return true;
        }
        private long number(Attribute value) { if (value.type() != 0x10 && value.type() != 0x11) throw invalid(); return value.data(); }
        private List<String> pool(int at, int header, int size) {
            if (header < 28) throw invalid(); int count = integer(bytes.dword(at + 8)), styles = integer(bytes.dword(at + 12));
            long flags = bytes.dword(at + 16); int start = integer(bytes.dword(at + 20));
            if (count > 16384 || styles != 0 || start < (long)header + count * 4L || start >= size || (flags & ~0x101L) != 0) throw invalid();
            var result = new ArrayList<String>(count);
            for (int i = 0; i < count; i++) {
                int offset = integer(bytes.dword(at + header + 4 * i)); if (offset >= size - start) throw invalid();
                int[] cursor = {at + start + offset}; String value;
                if ((flags & 0x100) != 0) {
                    int characters = length8(cursor, at + size), encoded = length8(cursor, at + size);
                    if (encoded > at + size - cursor[0] - 1 || bytes.bytes(cursor[0] + encoded,1)[0] != 0) throw invalid();
                    value = decode(bytes.bytes(cursor[0],encoded), true); if (value.length() != characters) throw invalid();
                } else {
                    int characters = bytes.word(cursor[0]); cursor[0] += 2;
                    if ((characters & 0x8000) != 0) { characters = (characters & 0x7fff) << 16 | bytes.word(cursor[0]); cursor[0] += 2; }
                    if (characters < 0 || characters > (at + size - cursor[0] - 2) / 2 || bytes.word(cursor[0] + characters * 2) != 0) throw invalid();
                    value = decode(bytes.bytes(cursor[0], characters * 2), false);
                }
                if (value.indexOf(0) >= 0) throw invalid(); result.add(value);
            }
            return List.copyOf(result);
        }
        private int length8(int[] at, int end) { if (at[0] >= end) throw invalid(); int first = bytes.bytes(at[0]++,1)[0] & 255; if ((first & 128) == 0) return first;
            if (at[0] >= end) throw invalid(); return (first & 127) << 8 | bytes.bytes(at[0]++,1)[0] & 255; }
        private String text(long index) { if (index < 0 || index >= strings.size()) throw invalid(); return strings.get((int)index); }
        private String nullable(long index) { return index == 0xffffffffL ? null : text(index); }
        private String decode(byte[] value, boolean utf8) {
            try { return (utf8 ? StandardCharsets.UTF_8 : StandardCharsets.UTF_16LE).newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(value)).toString(); }
            catch (CharacterCodingException malformed) { throw invalid(); }
        }
    }
    private static int integer(long value) { if (value < 0 || value > Integer.MAX_VALUE) throw invalid(); return (int)value; }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "APK 实际应用标识、直接版本、完整 ABI 或正式运行文件无法验证，请选择对应目标的完整 Release APK"); }
}

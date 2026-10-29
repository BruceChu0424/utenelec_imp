package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Bounded PE/CLR metadata checks; never loads an uploaded assembly or executes its code. */
final class WindowsManagedImageInspector {
    static final String COMPANY_RELEASE_PROVENANCE = "UTEN WPF candidate; Configuration=Release; Distribution=Company";
    private WindowsManagedImageInspector() { }
    static void inspect(byte[] bytes, ClientReleaseDto.Release release, boolean library, boolean applicationVersion) {
        if (bytes.length > 32 * 1024 * 1024) throw invalid();
        var image = new WindowsSetupInspector.Data(bytes);
        if (image.word(0) != 0x5a4d) throw invalid();
        int pe = integer(image.dword(60));
        if (image.dword(pe) != 0x4550) throw invalid();
        int machine = image.word(pe + 4), count = image.word(pe + 6), optionalSize = image.word(pe + 20);
        int characteristics = image.word(pe + 22), optional = pe + 24;
        if (count < 1 || count > 96 || (characteristics & 2) == 0 || ((characteristics & 0x2000) != 0) != library) throw invalid();
        int magic = image.word(optional), directories = magic == 0x10b ? 96 : magic == 0x20b ? 112 : -1;
        if (directories < 0 || optionalSize < directories + 15 * 8
                || image.dword(optional + directories - 4) < 15
                || !(machine == 0x14c && magic == 0x10b || machine == 0x8664 && magic == 0x20b)) throw invalid();
        var sections = new ArrayList<WindowsSetupInspector.Section>();
        int sectionTable = optional + optionalSize;
        image.range(sectionTable, count * 40);
        for (int i = 0; i < count; i++) {
            int position = sectionTable + i * 40;
            sections.add(new WindowsSetupInspector.Section(image.dword(position + 12),
                    Math.min(image.dword(position + 8), image.dword(position + 16)), image.dword(position + 20)));
        }
        long clrRva = image.dword(optional + directories + 14 * 8), clrSize = image.dword(optional + directories + 14 * 8 + 4);
        if (clrRva == 0 || clrSize < 72 || clrSize > 4096) throw invalid();
        int clr = integer(WindowsSetupInspector.offset(sections, clrRva, clrSize));
        image.range(clr, integer(clrSize));
        long flags = image.dword(clr + 16);
        if (image.dword(clr) != 72 || (flags & 1) == 0 || (flags & 0x10) != 0 || (flags & 0x20000) != 0) throw invalid();
        boolean required32 = (flags & 2) != 0;
        if (machine == 0x8664 && required32 || !library && !(("x86".equals(release.architecture()) && machine == 0x14c && required32)
                || ("x64".equals(release.architecture()) && machine == 0x8664 && !required32))) throw invalid();
        if (library && ("x86".equals(release.architecture()) && machine == 0x8664
                || "x64".equals(release.architecture()) && required32)) throw invalid();
        long metadataRva = image.dword(clr + 8), metadataSize = image.dword(clr + 12);
        if (metadataSize < 20 || metadataSize > 32 * 1024 * 1024) throw invalid();
        int metadata = integer(WindowsSetupInspector.offset(sections, metadataRva, metadataSize));
        image.range(metadata, integer(metadataSize));
        int versionBytes = integer(image.dword(metadata + 12));
        if (image.dword(metadata) != 0x424a5342 || versionBytes < 1 || versionBytes > 1024 || versionBytes > metadataSize - 16
                || !new String(Arrays.copyOfRange(bytes, metadata + 16, metadata + 16 + versionBytes), StandardCharsets.US_ASCII).startsWith("v4.0.")) throw invalid();
        if (applicationVersion) inspectVersions(image, sections, optional + directories, release, library);
    }
    private static void inspectVersions(WindowsSetupInspector.Data image, List<WindowsSetupInspector.Section> sections,
            int directory, ClientReleaseDto.Release release, boolean library) {
        long rva = image.dword(directory + 16), length = image.dword(directory + 20);
        if (length < 16 || length > 16 * 1024 * 1024) throw invalid();
        int start = integer(WindowsSetupInspector.offset(sections, rva, length));
        image.range(start, integer(length));
        // Shared bounded VERSIONINFO parser is also used for the native Flutter Setup loader.
        var resource = new WindowsSetupInspector.Data(imageBytes(image, start, integer(length)));
        var tree = new WindowsSetupInspector.ResourceTree(resource);
        int count = 0;
        for (var type : tree.entries(0)) {
            if (type.name() != 16) continue;
            if (!type.directory()) throw invalid();
            for (var name : tree.entries(type.offset())) {
                if (!name.directory()) throw invalid();
                for (var language : tree.entries(name.offset())) {
                    if (language.directory() || ++count > 128) throw invalid();
                    long valueRva = resource.dword(language.offset()), size = resource.dword(language.offset() + 4);
                    if (size < 92 || size > 65535) throw invalid();
                    int offset = integer(WindowsSetupInspector.offset(sections, valueRva, size));
                    var value = new WindowsSetupInspector.Data(imageBytes(image, offset, integer(size)));
                    var block = new WindowsSetupInspector.Blocks(value).read(0, value.length(), 0);
                    if (!"VS_VERSION_INFO".equals(block.key()) || block.type() != 0 || block.valueSize() != 52) throw invalid();
                    int fixed = block.value();
                    int[] version = WindowsSetupInspector.numericVersion(release.version());
                    if (value.dword(fixed) != 0xfeef04bdL || value.dword(fixed + 4) != 0x10000
                            || value.dword(fixed + 8) != ((long) version[0] << 16 | version[1])
                            || value.dword(fixed + 12) != ((long) version[2] << 16 | release.buildNumber())
                            || value.dword(fixed + 36) != (library ? 2 : 1)) throw invalid();
                    int strings = 0;
                    for (var info : block.children()) {
                        if (!"StringFileInfo".equals(info.key())) continue;
                        if (info.type() != 1 || info.valueSize() != 0) throw invalid();
                        for (var table : info.children()) {
                            if (table.type() != 1 || table.valueSize() != 0 || !table.key().matches("[0-9a-fA-F]{8}")) throw invalid();
                            var fields = new java.util.HashMap<String, String>();
                            for (var item : table.children()) {
                                if (item.type() != 1 || !item.children().isEmpty() || item.valueSize() < 2) throw invalid();
                                String text = value.text(item.value(), item.valueSize());
                                int end = text.length();
                                if (end == 0 || text.charAt(end - 1) != '\0') throw invalid();
                                while (end > 0 && text.charAt(end - 1) == '\0') end--;
                                text = text.substring(0, end);
                                if (text.indexOf('\0') >= 0 || fields.putIfAbsent(item.key().toLowerCase(java.util.Locale.ROOT), text) != null) throw invalid();
                            }
                            if (!COMPANY_RELEASE_PROVENANCE.equals(fields.get("comments"))) throw invalid();
                            strings++;
                        }
                    }
                    if (strings == 0) throw invalid();
                }
            }
        }
        if (count == 0) throw invalid();
    }
    private static byte[] imageBytes(WindowsSetupInspector.Data image, int start, int size) {
        image.range(start, size);
        return image.bytes(start, size);
    }
    private static int integer(long value) { if (value < 0 || value > Integer.MAX_VALUE) throw invalid(); return (int) value; }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "WPF 软件包的 PE、CLR、架构、文件版本或 Release/Company 来源不匹配"); }
}

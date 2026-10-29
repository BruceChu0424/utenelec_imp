package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import org.apache.commons.compress.archivers.zip.ZipArchiveEntry;
import org.apache.commons.compress.archivers.zip.ZipFile;

/** Audited Windows Flutter bytes: main PE version/identity, engine PE and AOT ELF architecture. */
final class WindowsFlutterPackageInspector {
    private static final int MAX_MAIN_BYTES = 32 * 1024 * 1024;
    private WindowsFlutterPackageInspector() { }
    static void inspect(ZipFile zip, Map<String, ZipArchiveEntry> files, ClientReleaseDto.Release release) throws IOException {
        byte[] main = bounded(zip, files.get("uten_imp.exe"), MAX_MAIN_BYTES, false);
        var pe = pe(main, release.architecture(), false);
        version(main, pe, release);
        pe(bounded(zip, files.get("flutter_windows.dll"), 1048576, true), release.architecture(), true);
        NativeBinaryArchitecture.elf(bounded(zip, files.get("data/app.so"), 64, true), release.architecture());
    }
    private static byte[] bounded(ZipFile zip, ZipArchiveEntry entry, int maximum, boolean prefix) throws IOException {
        if (entry == null || entry.getSize() < 64 || !prefix && entry.getSize() > maximum) throw invalid();
        try (var input = zip.getInputStream(entry)) {
            byte[] bytes = input.readNBytes(maximum + (prefix ? 0 : 1));
            if (!prefix && (bytes.length != entry.getSize() || bytes.length > maximum)) throw invalid();
            return bytes;
        }
    }
    private record Pe(java.util.List<WindowsSetupInspector.Section> sections, long resourceRva, long resourceSize) { }
    private static Pe pe(byte[] bytes, String architecture, boolean library) {
        var image = new WindowsSetupInspector.Data(bytes);
        if (image.word(0) != 0x5a4d) throw invalid();
        int pe = integer(image.dword(60));
        if (image.dword(pe) != 0x4550 || image.word(pe + 4) != NativeBinaryArchitecture.peMachine(architecture)
                || (image.word(pe + 22) & 2) == 0 || ((image.word(pe + 22) & 0x2000) != 0) != library) throw invalid();
        int count = image.word(pe + 6), optionalSize = image.word(pe + 20), optional = pe + 24;
        int magic = image.word(optional), directories = magic == 0x10b ? 96 : magic == 0x20b ? 112 : -1;
        if (count < 1 || count > 96 || directories < 0 || optionalSize < directories + 15 * 8
                || ("x86".equals(architecture) ? magic != 0x10b : magic != 0x20b)
                || image.dword(optional + directories - 4) < 15 || image.dword(optional + directories + 14 * 8) != 0) throw invalid();
        var sections = new ArrayList<WindowsSetupInspector.Section>();
        for (int i = 0; i < count; i++) {
            int section = optional + optionalSize + i * 40;
            sections.add(new WindowsSetupInspector.Section(image.dword(section + 12), Math.min(image.dword(section + 8), image.dword(section + 16)), image.dword(section + 20)));
        }
        return new Pe(sections, image.dword(optional + directories + 16), image.dword(optional + directories + 20));
    }
    private static void version(byte[] bytes, Pe pe, ClientReleaseDto.Release release) {
        if (pe.resourceSize() < 16 || pe.resourceSize() > 16 * 1024 * 1024) throw invalid();
        var data = new WindowsSetupInspector.Data(bytes);
        int rootOffset = integer(WindowsSetupInspector.offset(pe.sections(), pe.resourceRva(), pe.resourceSize()));
        var resource = new WindowsSetupInspector.Data(data.bytes(rootOffset, integer(pe.resourceSize())));
        var tree = new WindowsSetupInspector.ResourceTree(resource);
        int count = 0;
        for (var type : tree.entries(0)) {
            if (type.name() != 16) continue;
            if (!type.directory()) throw invalid();
            for (var name : tree.entries(type.offset())) {
                if (!name.directory()) throw invalid();
                for (var language : tree.entries(name.offset())) {
                    if (language.directory() || ++count > 128) throw invalid();
                    long rva = resource.dword(language.offset()), length = resource.dword(language.offset() + 4);
                    if (length < 92 || length > 65535) throw invalid();
                    var info = new WindowsSetupInspector.Data(data.bytes(integer(WindowsSetupInspector.offset(pe.sections(), rva, length)), integer(length)));
                    var block = new WindowsSetupInspector.Blocks(info).read(0, info.length(), 0);
                    if (!"VS_VERSION_INFO".equals(block.key()) || block.type() != 0 || block.valueSize() != 52) throw invalid();
                    int fixed = block.value(); int[] version = WindowsSetupInspector.numericVersion(release.version());
                    long ms = (long)version[0] << 16 | version[1], ls = (long)version[2] << 16 | release.buildNumber();
                    if (info.dword(fixed) != 0xfeef04bdL || info.dword(fixed + 4) != 0x10000
                            || info.dword(fixed + 8) != ms || info.dword(fixed + 12) != ls || info.dword(fixed + 16) != ms || info.dword(fixed + 20) != ls
                            || (info.dword(fixed + 24) & info.dword(fixed + 28) & 1) != 0 || info.dword(fixed + 36) != 1) throw invalid();
                    int strings = 0;
                    for (var entry : block.children()) if ("StringFileInfo".equals(entry.key())) for (var table : entry.children()) {
                        Map<String, String> values = new HashMap<>();
                        for (var text : table.children()) {
                            if (text.type() != 1 || text.valueSize() < 2 || !text.children().isEmpty()) throw invalid();
                            String raw = info.text(text.value(), text.valueSize());
                            if (raw.charAt(raw.length() - 1) != 0) throw invalid();
                            int end = raw.length(); while (end > 0 && raw.charAt(end - 1) == 0) end--;
                            String value = raw.substring(0, end);
                            if (value.indexOf(0) >= 0 || values.putIfAbsent(text.key().toLowerCase(Locale.ROOT), value) != null) throw invalid();
                        }
                        if (!"uten_imp.exe".equals(values.get("originalfilename")) || !"uten_imp".equals(values.get("internalname"))
                                || !"Uten".equals(values.get("companyname")) || !"优腾综合管理平台".equals(values.get("productname"))) throw invalid();
                        strings++;
                    }
                    if (strings == 0) throw invalid();
                }
            }
        }
        if (count == 0) throw invalid();
    }
    private static int integer(long value) { if (value < 0 || value > Integer.MAX_VALUE) throw invalid(); return (int)value; }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "Windows Flutter 包的实际程序身份、版本或架构与发布信息不符"); }
}

package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HexFormat;

/** Engine identity survives signing. This mapped-image digest is not an Authenticode trust check. */
final class WindowsEngineSafety {
    private WindowsEngineSafety() { }

    static void requireApproved(Path file, String architecture) throws IOException {
        String image = imageSha256(file);
        JsonNode contract;
        try (var input = WindowsEngineSafety.class.getResourceAsStream("/contracts/windows-engine-safety/v1.json")) {
            if (input == null) throw invalid("Windows 引擎安全合同未打包，请重新构建服务端");
            contract = new ObjectMapper().readTree(input);
        }
        if (contract.path("schemaVersion").asInt() != 1
                || !"mapped-pe-image-sha256-v1".equals(contract.path("algorithm").asText()))
            throw invalid("Windows 引擎安全合同版本不匹配");
        for (var unsafe : contract.path("engines")) if (image.equals(unsafe.path("peImageSha256").asText()))
            throw invalid("软件包包含已确认不安全的 Windows 引擎，重新签名不能替代闪退修复");
        for (var reviewed : contract.path("reviewedEngines")) {
            if (image.equals(reviewed.path("peImageSha256").asText())
                    && architecture.equals(reviewed.path("architecture").asText())
                    && "release".equals(reviewed.path("runtimeMode").asText())) return;
        }
        throw invalid("Windows 正式引擎尚未通过同源修复审核，请使用审核通过的 Release 引擎");
    }

    static String imageSha256(Path file) throws IOException {
        try (var channel = FileChannel.open(file, StandardOpenOption.READ)) {
            Layout layout = layout(channel);
            var digest = ClientPackageInspector.digest();
            hash(channel, digest, 0, layout.checksum());
            hash(channel, digest, layout.checksum() + 4, layout.certificateDirectory() - layout.checksum() - 4);
            hash(channel, digest, layout.certificateDirectory() + 8, layout.headers() - layout.certificateDirectory() - 8);
            for (Range range : layout.sections()) hash(channel, digest, range.start(), range.length());
            return HexFormat.of().formatHex(digest.digest());
        }
    }

    static Layout layout(FileChannel channel) throws IOException {
            long size = channel.size();
            ByteBuffer dos = read(channel, 0, 64);
            if (u16(dos, 0) != 0x5a4d) throw malformed();
            long peOffset = u32(dos, 60);
            ByteBuffer pe = read(channel, peOffset, 24);
            int count = u16(pe, 6), optionalSize = u16(pe, 20);
            if (u32(pe, 0) != 0x4550 || count < 1 || count > 96 || optionalSize < 96 || optionalSize > 4096) throw malformed();
            long optionalOffset = peOffset + 24;
            ByteBuffer optional = read(channel, optionalOffset, optionalSize);
            int magic = u16(optional, 0), directories = magic == 0x10b ? 96 : magic == 0x20b ? 112 : -1;
            if (directories < 0 || optionalSize < directories + 40 || u32(optional, directories - 4) < 5) throw malformed();
            long headers = u32(optional, 60), checksum = optionalOffset + 64, certificateDirectory = optionalOffset + directories + 32;
            long sectionStart = optionalOffset + optionalSize;
            if (headers < sectionStart + count * 40L || headers > size || certificateDirectory + 8 > headers) throw malformed();
            long certificate = u32(optional, directories + 32), certificateSize = u32(optional, directories + 36);
            if ((certificate == 0) != (certificateSize == 0)
                    || certificate != 0 && (certificate % 8 != 0 || certificateSize < 8 || certificate < headers || certificate > size - certificateSize)) throw malformed();
            var sections = new ArrayList<Range>();
            for (int index = 0; index < count; index++) {
                ByteBuffer section = read(channel, sectionStart + index * 40L, 40);
                long length = u32(section, 16), start = u32(section, 20);
                if (length == 0) continue;
                if (start < headers || length > size || start > size - length
                        || certificate != 0 && start + length > certificate) throw malformed();
                sections.add(new Range(start, length));
            }
            sections.sort(Comparator.comparingLong(Range::start));
            long previous = headers;
            for (Range range : sections) {
                if (range.start() < previous) throw malformed();
                previous = range.start() + range.length();
            }
            return new Layout(headers, checksum, certificateDirectory, certificate, certificateSize, previous, java.util.List.copyOf(sections));
    }

    static ByteBuffer read(FileChannel channel, long offset, int count) throws IOException {
        if (offset < 0 || offset > channel.size() - count) throw malformed();
        ByteBuffer result = ByteBuffer.allocate(count).order(ByteOrder.LITTLE_ENDIAN);
        while (result.hasRemaining()) if (channel.read(result, offset + result.position()) < 1) throw malformed();
        return result.flip();
    }

    private static void hash(FileChannel channel, java.security.MessageDigest digest, long start, long length) throws IOException {
        if (length < 0) throw malformed();
        ByteBuffer buffer = ByteBuffer.allocate(65536);
        long position = start;
        while (length > 0) {
            buffer.clear().limit((int)Math.min(buffer.capacity(), length));
            int count = channel.read(buffer, position);
            if (count < 1) throw malformed();
            digest.update(buffer.array(), 0, count);
            position += count;
            length -= count;
        }
    }

    private static int u16(ByteBuffer bytes, int offset) { return Short.toUnsignedInt(bytes.getShort(offset)); }
    private static long u32(ByteBuffer bytes, int offset) { return Integer.toUnsignedLong(bytes.getInt(offset)); }
    private record Range(long start, long length) { }
    record Layout(long headers, long checksum, long certificateDirectory, long certificate, long certificateSize,
                  long mappedEnd, java.util.List<Range> sections) { }
    private static ApiException malformed() { return invalid("Windows 引擎的 PE 映像范围无效"); }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}

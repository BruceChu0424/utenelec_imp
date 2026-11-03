package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;

/** Pre-allocation guard for ordinary Windows producer ZIPs; never decompresses payloads or establishes trust. */
final class ClientZipDirectory {
    private ClientZipDirectory() { }

    record Directory(int entries, long centralBytes, long centralOffset) { }
    private record Range(long start, long end) { }

    /** Shared contract/vectors: contracts/windows-zip-directory/vectors-v1.json. Call before opening any ZIP library. */
    static Directory inspect(Path file, int maxEntries, long maxCentralBytes) throws IOException {
        if (maxEntries < 1 || maxEntries >= 65535 || maxCentralBytes < 1)
            throw new IllegalArgumentException("Windows ZIP directory limits must be positive and non-ZIP64");
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.READ)) {
            long size = channel.size();
            int tailSize = (int)Math.min(size, 65557L);
            ByteBuffer tail = read(channel, size - tailSize, tailSize, size);
            int position = -1;
            for (int index = tailSize - 4; index >= 0; index--) {
                if (u32(tail, index) == 0x06054b50L) { position = index; break; }
            }
            if (position < 0 || position + 22 > tailSize) throw invalid();
            int disk = u16(tail, position + 4), startDisk = u16(tail, position + 6);
            int diskCount = u16(tail, position + 8), count = u16(tail, position + 10);
            long length = u32(tail, position + 12), offset = u32(tail, position + 16);
            int comment = u16(tail, position + 20);
            long eocd = size - tailSize + position;
            if (disk != 0 || startDisk != 0 || diskCount != count || count == 65535 || count > maxEntries
                    || length == 0xffffffffL || offset == 0xffffffffL || length > maxCentralBytes
                    || length < count * 46L || offset > eocd || length != eocd - offset
                    || position + 22 + comment != tailSize) throw invalid();
            for (int index = position + 22; index + 4 <= tailSize; index++) {
                long signature = u32(tail, index);
                if (signature == 0x06064b50L || signature == 0x07064b50L) throw invalid();
            }

            var ranges = new ArrayList<Range>(count);
            long cursor = offset;
            for (int index = 0; index < count; index++) {
                ByteBuffer header = read(channel, cursor, 46, eocd);
                if (u32(header, 0) != 0x02014b50L) throw invalid();
                int flags = u16(header, 8), method = u16(header, 10);
                long crc = u32(header, 16), compressed = u32(header, 20), expanded = u32(header, 24);
                int nameLength = u16(header, 28), extraLength = u16(header, 30), commentLength = u16(header, 32);
                int entryDisk = u16(header, 34);
                long local = u32(header, 42);
                int recordLength = 46 + nameLength + extraLength + commentLength;
                if (entryDisk != 0 || compressed == 0xffffffffL || expanded == 0xffffffffL || local == 0xffffffffL
                        || nameLength == 0 || recordLength > eocd - cursor) throw invalid();
                byte[] name = read(channel, cursor + 46, nameLength, eocd).array();
                extraFields(read(channel, cursor + 46 + nameLength, extraLength, eocd));
                ByteBuffer localHeader = read(channel, local, 30, offset);
                if (u32(localHeader, 0) != 0x04034b50L) throw invalid();
                int localFlags = u16(localHeader, 6), localMethod = u16(localHeader, 8);
                long localCrc = u32(localHeader, 14), localCompressed = u32(localHeader, 18), localExpanded = u32(localHeader, 22);
                int localNameLength = u16(localHeader, 26), localExtraLength = u16(localHeader, 28);
                if (localFlags != flags || localMethod != method || localNameLength != nameLength
                        || localCompressed == 0xffffffffL || localExpanded == 0xffffffffL
                        || !Arrays.equals(name, read(channel, local + 30, localNameLength, offset).array())) throw invalid();
                extraFields(read(channel, local + 30 + localNameLength, localExtraLength, offset));
                long dataEnd = local + 30 + localNameLength + localExtraLength + compressed;
                if (dataEnd > offset) throw invalid();
                if ((flags & 8) != 0) {
                    boolean signature = u32(read(channel, dataEnd, 4, offset), 0) == 0x08074b50L;
                    int descriptorSize = signature ? 16 : 12;
                    ByteBuffer descriptor = read(channel, dataEnd, descriptorSize, offset);
                    int skip = signature ? 4 : 0;
                    if (u32(descriptor, skip) != crc || u32(descriptor, skip + 4) != compressed
                            || u32(descriptor, skip + 8) != expanded) throw invalid();
                    dataEnd += descriptorSize;
                } else if (localCrc != crc || localCompressed != compressed || localExpanded != expanded) throw invalid();
                ranges.add(new Range(local, dataEnd));
                cursor += recordLength;
            }
            if (cursor != eocd) throw invalid();
            ranges.sort(Comparator.comparingLong(Range::start));
            long previous = 0;
            for (Range range : ranges) {
                if (range.start() != previous || range.end() < range.start()) throw invalid();
                previous = range.end();
            }
            if (previous != offset) throw invalid();
            return new Directory(count, length, offset);
        }
    }

    private static void extraFields(ByteBuffer bytes) {
        int index = 0;
        while (index < bytes.limit()) {
            if (index + 4 > bytes.limit()) throw invalid();
            int tag = u16(bytes, index), length = u16(bytes, index + 2);
            index += 4;
            if (tag == 1 || length > bytes.limit() - index) throw invalid();
            index += length;
        }
    }

    private static ByteBuffer read(FileChannel channel, long offset, int count, long end) throws IOException {
        if (offset < 0 || count < 0 || count > 65557 || offset > end - count) throw invalid();
        ByteBuffer result = ByteBuffer.allocate(count).order(ByteOrder.LITTLE_ENDIAN);
        while (result.hasRemaining()) if (channel.read(result, offset + result.position()) < 1) throw invalid();
        return result.flip();
    }

    private static int u16(ByteBuffer bytes, int offset) { return Short.toUnsignedInt(bytes.getShort(offset)); }
    private static long u32(ByteBuffer bytes, int offset) { return Integer.toUnsignedLong(bytes.getInt(offset)); }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED,
            "Windows ZIP 目录不完整、存在歧义、使用 ZIP64 或超出有界合同"); }
}

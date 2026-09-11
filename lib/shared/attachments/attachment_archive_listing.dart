// 压缩包预览 = 读清单，不解压。
//
// 只解析 ZIP 的「中央目录」（文件尾部的索引区），拿到条目名、原始大小与层级即可；
// 压缩数据一个字节都不碰，因此没有解压炸弹风险，也不需要引入解压依赖。
// 7z / rar 的目录区本身是压缩的，纯 Dart 读不了，故这两种只允许上传、不承诺预览
// （见 attachment_file_rules.dart 的能力矩阵）。

import 'dart:convert';
import 'dart:typed_data';

import 'attachment_text_decoder.dart';

/// 压缩包中的一个条目。
class ArchiveEntry {
  const ArchiveEntry({
    required this.path,
    required this.sizeBytes,
    required this.compressedBytes,
    required this.isDirectory,
  });

  /// 包内完整路径，如 `发票/2026/03.pdf`。
  final String path;

  /// 解压后大小；ZIP64 之外的包最大 4GB。
  final int sizeBytes;

  final int compressedBytes;
  final bool isDirectory;

  /// 目录层级：顶层条目为 0，每多一层父目录 +1（目录条目不把自己算进去）。
  int get depth {
    final trimmed = isDirectory && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return '/'.allMatches(trimmed).length;
  }

  /// 末级名称（目录条目去掉结尾斜杠）。
  String get name {
    final segments = path.split('/').where((segment) => segment.isNotEmpty);
    return segments.isEmpty ? path : segments.last;
  }
}

/// 清单解析结果；`truncated` 为真表示条目过多只列了前一部分。
class ArchiveListing {
  const ArchiveListing({
    required this.entries,
    required this.totalEntries,
    required this.truncated,
  });

  final List<ArchiveEntry> entries;
  final int totalEntries;
  final bool truncated;
}

/// 清单读不出来时抛出：损坏、加密目录、或根本不是 ZIP。
class ArchiveListingException implements Exception {
  const ArchiveListingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 单次预览最多列出的条目数，超出只展示前 [kArchiveEntryLimit] 条。
const int kArchiveEntryLimit = 2000;

/// 读 ZIP 中央目录得到条目清单。失败抛 [ArchiveListingException]。
ArchiveListing readZipListing(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final endOffset = _findEndOfCentralDirectory(bytes);
  if (endOffset < 0) {
    throw const ArchiveListingException('这不是一个完整的 ZIP 文件，或文件已损坏');
  }
  var totalEntries = view.getUint16(endOffset + 10, Endian.little);
  var directoryOffset = view.getUint32(endOffset + 16, Endian.little);
  if (totalEntries == 0xFFFF || directoryOffset == 0xFFFFFFFF) {
    final zip64 = _readZip64(view, bytes, endOffset);
    if (zip64 == null) {
      throw const ArchiveListingException('ZIP64 索引缺失，无法列出条目');
    }
    totalEntries = zip64.$1;
    directoryOffset = zip64.$2;
  }
  if (directoryOffset < 0 || directoryOffset >= bytes.length) {
    throw const ArchiveListingException('ZIP 索引位置越界，文件可能已损坏');
  }

  final entries = <ArchiveEntry>[];
  var cursor = directoryOffset;
  var seen = 0;
  while (seen < totalEntries && cursor + 46 <= bytes.length) {
    if (view.getUint32(cursor, Endian.little) != 0x02014b50) break;
    final flags = view.getUint16(cursor + 8, Endian.little);
    final compressed = view.getUint32(cursor + 20, Endian.little);
    final uncompressed = view.getUint32(cursor + 24, Endian.little);
    final nameLength = view.getUint16(cursor + 28, Endian.little);
    final extraLength = view.getUint16(cursor + 30, Endian.little);
    final commentLength = view.getUint16(cursor + 32, Endian.little);
    final nameStart = cursor + 46;
    final nameEnd = nameStart + nameLength;
    if (nameEnd > bytes.length) break;
    final rawName = Uint8List.sublistView(bytes, nameStart, nameEnd);
    // 位 11 = 条目名是 UTF-8；老 WinRAR/资源管理器打的包多半是 GBK，走同一套编码识别。
    final path = (flags & 0x800) != 0
        ? utf8.decode(rawName, allowMalformed: true)
        : decodeAttachmentText(rawName).text;
    final normalized = path.replaceAll('\\', '/');
    if (seen < kArchiveEntryLimit) {
      entries.add(
        ArchiveEntry(
          path: normalized,
          sizeBytes: uncompressed,
          compressedBytes: compressed,
          isDirectory: normalized.endsWith('/'),
        ),
      );
    }
    cursor = nameEnd + extraLength + commentLength;
    seen++;
  }
  if (entries.isEmpty && totalEntries > 0) {
    throw const ArchiveListingException('ZIP 索引读取失败，文件可能已损坏');
  }
  return ArchiveListing(
    entries: entries,
    totalEntries: seen,
    truncated: seen > entries.length,
  );
}

/// 从尾部回扫 EOCD 签名；ZIP 注释最长 65535 字节，因此回扫窗口取 64KB + 22。
int _findEndOfCentralDirectory(Uint8List bytes) {
  if (bytes.length < 22) return -1;
  final view = ByteData.sublistView(bytes);
  final lowest = bytes.length - 22 - 65535 < 0 ? 0 : bytes.length - 22 - 65535;
  for (var offset = bytes.length - 22; offset >= lowest; offset--) {
    if (view.getUint32(offset, Endian.little) == 0x06054b50) return offset;
  }
  return -1;
}

/// 返回 (条目总数, 中央目录偏移)；定位器或 ZIP64 EOCD 缺失时返回 null。
(int, int)? _readZip64(ByteData view, Uint8List bytes, int endOffset) {
  final locator = endOffset - 20;
  if (locator < 0 || view.getUint32(locator, Endian.little) != 0x07064b50) {
    return null;
  }
  final directoryEnd = view.getUint64(locator + 8, Endian.little);
  if (directoryEnd < 0 || directoryEnd + 56 > bytes.length) return null;
  if (view.getUint32(directoryEnd, Endian.little) != 0x06064b50) return null;
  final total = view.getUint64(directoryEnd + 32, Endian.little);
  final offset = view.getUint64(directoryEnd + 48, Endian.little);
  if (total > kArchiveEntryLimit * 100 || offset > bytes.length) return null;
  return (total, offset);
}

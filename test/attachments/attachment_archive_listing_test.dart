import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/attachments/attachment_archive_listing.dart';

/// 一条待打包的条目；[nameBytes] 直接给字节，便于构造 GBK 条目名的老包。
class _Entry {
  _Entry(this.nameBytes, this.size, {this.utf8Flag = true});

  _Entry.named(String name, this.size)
    : nameBytes = utf8.encode(name),
      utf8Flag = true;

  final List<int> nameBytes;
  final int size;
  final bool utf8Flag;
}

/// 手搓一个 stored（不压缩）ZIP：本地头 + 数据 + 中央目录 + EOCD。
/// 预览只读中央目录，数据段填零即可。
Uint8List _zip(List<_Entry> entries, {int? comment}) {
  final out = BytesBuilder();
  final offsets = <int>[];

  void u16(BytesBuilder sink, int value) =>
      sink.add([value & 0xFF, (value >> 8) & 0xFF]);
  void u32(BytesBuilder sink, int value) => sink.add([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);

  for (final entry in entries) {
    offsets.add(out.length);
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, entry.utf8Flag ? 0x800 : 0);
    u16(out, 0); // stored
    u16(out, 0);
    u16(out, 0);
    u32(out, 0); // crc
    u32(out, entry.size);
    u32(out, entry.size);
    u16(out, entry.nameBytes.length);
    u16(out, 0);
    out.add(entry.nameBytes);
    out.add(List<int>.filled(entry.size, 0x41));
  }

  final directoryOffset = out.length;
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    u32(out, 0x02014b50);
    u16(out, 20);
    u16(out, 20);
    u16(out, entry.utf8Flag ? 0x800 : 0);
    u16(out, 0);
    u16(out, 0);
    u16(out, 0);
    u32(out, 0);
    u32(out, entry.size);
    u32(out, entry.size);
    u16(out, entry.nameBytes.length);
    u16(out, 0);
    u16(out, 0);
    u16(out, 0);
    u16(out, 0);
    u32(out, 0);
    u32(out, offsets[index]);
    out.add(entry.nameBytes);
  }
  final directorySize = out.length - directoryOffset;

  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, directorySize);
  u32(out, directoryOffset);
  u16(out, comment ?? 0);
  if (comment != null) out.add(List<int>.filled(comment, 0x20));
  return out.toBytes();
}

void main() {
  test('列出条目：名称、大小、目录标记与层级', () {
    final listing = readZipListing(
      _zip([
        _Entry.named('说明.txt', 12),
        _Entry.named('发票/', 0),
        _Entry.named('发票/2026/03.pdf', 2048),
      ]),
    );
    expect(listing.totalEntries, 3);
    expect(listing.truncated, isFalse);
    expect(listing.entries.map((e) => e.name), ['说明.txt', '发票', '03.pdf']);
    expect(listing.entries[0].depth, 0);
    expect(listing.entries[1].isDirectory, isTrue);
    expect(listing.entries[1].depth, 0);
    expect(listing.entries[2].depth, 2);
    expect(listing.entries[2].sizeBytes, 2048);
  });

  test('老包的 GBK 条目名也能显示成中文', () {
    // 「合同.pdf」的 GBK 字节；位 11 未置位表示不是 UTF-8。
    final listing = readZipListing(
      _zip([
        _Entry(
          const [0xBA, 0xCF, 0xCD, 0xAC, 0x2E, 0x70, 0x64, 0x66],
          16,
          utf8Flag: false,
        ),
      ]),
    );
    expect(listing.entries.single.name, '合同.pdf');
  });

  test('反斜杠路径归一成正斜杠，层级照样算得对', () {
    final listing = readZipListing(
      _zip([_Entry.named(r'单据\2026\出库单.xlsx', 10)]),
    );
    expect(listing.entries.single.path, '单据/2026/出库单.xlsx');
    expect(listing.entries.single.depth, 2);
  });

  test('带注释的包仍能找到 EOCD', () {
    final listing = readZipListing(
      _zip([_Entry.named('a.txt', 1)], comment: 300),
    );
    expect(listing.entries.single.name, 'a.txt');
  });

  test('不是 ZIP / 已损坏时抛出可展示的原因', () {
    expect(
      () => readZipListing(Uint8List.fromList(List.filled(64, 0x41))),
      throwsA(isA<ArchiveListingException>()),
    );
    expect(
      () => readZipListing(Uint8List(0)),
      throwsA(isA<ArchiveListingException>()),
    );
  });
}

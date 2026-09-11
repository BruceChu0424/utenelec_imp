// 附件文本解码：txt / csv / md / log / json / xml 的字节 → 字符串。
//
// 为什么不只 utf8.decode(allowMalformed: true)：这是中文市场的 ERP，从老系统、
// Excel「另存为 CSV」、Windows 记事本导出的文本大量是 GBK/GB18030 或带 BOM 的
// UTF-16，按 UTF-8 硬解就是整屏乱码。识别顺序（先确定性、后启发式）：
//   1. BOM：UTF-8 / UTF-16LE / UTF-16BE 直接认定；
//   2. 严格 UTF-8 解码成功 → UTF-8（ASCII 文本走这条）；
//   3. 字节结构完全符合 GB18030（且确实出现多字节序列）→ GB18030；
//   4. 都不符合 → UTF-8 容错解码，并如实标注「编码未知」，不伪装成解对了。
// 解码表由 JDK 的 GB18030 字符集机器生成，见 gb18030_table.dart。

import 'dart:convert';
import 'dart:typed_data';

import 'gb18030_table.dart';

/// 识别出的文本编码；`label` 直接显示在预览弹窗的编码角标上。
enum AttachmentTextEncoding {
  utf8('UTF-8'),
  utf8Bom('UTF-8 BOM'),
  utf16le('UTF-16 LE'),
  utf16be('UTF-16 BE'),
  gb18030('GB18030'),
  unknown('编码未知');

  const AttachmentTextEncoding(this.label);

  final String label;
}

/// 解码结果：文本 + 用了哪种编码。`lossy` 为真时界面要如实提示可能有乱码。
class DecodedAttachmentText {
  const DecodedAttachmentText(this.text, this.encoding);

  final String text;
  final AttachmentTextEncoding encoding;

  bool get lossy => encoding == AttachmentTextEncoding.unknown;
}

/// 解码附件文本字节。永不抛异常：最差也会返回容错解码的结果。
DecodedAttachmentText decodeAttachmentText(Uint8List bytes) {
  if (bytes.isEmpty) {
    return const DecodedAttachmentText('', AttachmentTextEncoding.utf8);
  }
  if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) {
    final body = Uint8List.sublistView(bytes, 3);
    return DecodedAttachmentText(
      utf8.decode(body, allowMalformed: true),
      AttachmentTextEncoding.utf8Bom,
    );
  }
  if (_startsWith(bytes, const [0xFF, 0xFE])) {
    return DecodedAttachmentText(
      _decodeUtf16(bytes, 2, littleEndian: true),
      AttachmentTextEncoding.utf16le,
    );
  }
  if (_startsWith(bytes, const [0xFE, 0xFF])) {
    return DecodedAttachmentText(
      _decodeUtf16(bytes, 2, littleEndian: false),
      AttachmentTextEncoding.utf16be,
    );
  }
  try {
    return DecodedAttachmentText(
      const Utf8Decoder().convert(bytes),
      AttachmentTextEncoding.utf8,
    );
  } on FormatException {
    // 不是 UTF-8，继续往下判。
  }
  if (isStructurallyGb18030(bytes)) {
    return DecodedAttachmentText(
      decodeGb18030(bytes),
      AttachmentTextEncoding.gb18030,
    );
  }
  return DecodedAttachmentText(
    utf8.decode(bytes, allowMalformed: true),
    AttachmentTextEncoding.unknown,
  );
}

/// 字节流是否符合 GB18030 的结构规则，且至少出现一个多字节序列
/// （纯 ASCII 已经在上一步被 UTF-8 接走，这里再判就成了假阳性）。
bool isStructurallyGb18030(Uint8List bytes) {
  var index = 0;
  var multiByte = false;
  while (index < bytes.length) {
    final lead = bytes[index];
    if (lead <= 0x7F) {
      index++;
      continue;
    }
    if (lead == 0x80 || lead == 0xFF || index + 1 >= bytes.length) return false;
    final second = bytes[index + 1];
    if (second >= 0x30 && second <= 0x39) {
      if (index + 3 >= bytes.length) return false;
      final third = bytes[index + 2];
      final fourth = bytes[index + 3];
      if (third < 0x81 || third > 0xFE || fourth < 0x30 || fourth > 0x39) {
        return false;
      }
      index += 4;
    } else if (second >= 0x40 && second <= 0xFE && second != 0x7F) {
      index += 2;
    } else {
      return false;
    }
    multiByte = true;
  }
  return multiByte;
}

/// GB18030 解码：单字节 ASCII、双字节查表、四字节（BMP 段表 + 增补区线性映射）。
/// 表外码位一律输出 U+FFFD，不猜。
String decodeGb18030(Uint8List bytes) {
  final table = _twoByteTable();
  final buffer = StringBuffer();
  var index = 0;
  while (index < bytes.length) {
    final lead = bytes[index];
    if (lead <= 0x7F) {
      buffer.writeCharCode(lead);
      index++;
      continue;
    }
    if (lead == 0x80 || lead == 0xFF || index + 1 >= bytes.length) {
      buffer.writeCharCode(0xFFFD);
      index++;
      continue;
    }
    final second = bytes[index + 1];
    if (second >= 0x30 && second <= 0x39) {
      if (index + 3 >= bytes.length) {
        buffer.writeCharCode(0xFFFD);
        index++;
        continue;
      }
      buffer.writeCharCode(
        _fourByteCodePoint(lead, second, bytes[index + 2], bytes[index + 3]),
      );
      index += 4;
      continue;
    }
    if (second >= 0x40 && second <= 0xFE && second != 0x7F) {
      final slot =
          (lead - 0x81) * 190 + (second < 0x7F ? second - 0x40 : second - 0x41);
      final value = (table[slot * 2] << 8) | table[slot * 2 + 1];
      buffer.writeCharCode(value == 0 ? 0xFFFD : value);
      index += 2;
      continue;
    }
    buffer.writeCharCode(0xFFFD);
    index++;
  }
  return buffer.toString();
}

int _fourByteCodePoint(int b1, int b2, int b3, int b4) {
  if (b3 < 0x81 || b3 > 0xFE || b4 < 0x30 || b4 > 0x39) return 0xFFFD;
  final linear =
      (b1 - 0x81) * 12600 + (b2 - 0x30) * 1260 + (b3 - 0x81) * 10 + (b4 - 0x30);
  if (b1 <= 0x84) {
    return _bmpRunLookup(linear);
  }
  // 0x90 起是增补平面：线性序号与 U+10000 之后的码位一一对应。
  const supplementaryBase = (0x90 - 0x81) * 12600;
  if (linear < supplementaryBase) return 0xFFFD;
  final codePoint = 0x10000 + linear - supplementaryBase;
  return codePoint > 0x10FFFF ? 0xFFFD : codePoint;
}

int _bmpRunLookup(int linear) {
  final runs = _fourByteRuns();
  var low = 0;
  var high = runs.length ~/ 3 - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final start = runs[middle * 3];
    if (linear < start) {
      high = middle - 1;
    } else if (linear >= start + runs[middle * 3 + 2]) {
      low = middle + 1;
    } else {
      return runs[middle * 3 + 1] + (linear - start);
    }
  }
  return 0xFFFD;
}

Uint8List? _twoByteCache;
Int32List? _fourByteCache;

/// 双字节表按 UTF-16 大端逐槽位存放（每槽 2 字节），首次解码时才从 Base64 展开。
Uint8List _twoByteTable() =>
    _twoByteCache ??= base64Decode(kGb18030TwoByteTableBase64);

Int32List _fourByteRuns() => _fourByteCache ??= Int32List.fromList(
  kGb18030FourByteBmpRuns.split(',').map(int.parse).toList(growable: false),
);

String _decodeUtf16(Uint8List bytes, int offset, {required bool littleEndian}) {
  final units = <int>[];
  for (var index = offset; index + 1 < bytes.length; index += 2) {
    units.add(
      littleEndian
          ? bytes[index] | (bytes[index + 1] << 8)
          : (bytes[index] << 8) | bytes[index + 1],
    );
  }
  return String.fromCharCodes(units);
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

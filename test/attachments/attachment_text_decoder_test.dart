import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/attachments/attachment_text_decoder.dart';

/// 参考字节由 JDK 21 的 GB18030 字符集生成，不是手搓的。
Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('编码识别', () {
    test('UTF-8 中文原样解出，且不会被误判成 GB18030', () {
      final bytes = Uint8List.fromList(utf8.encode('送货单：第 3 批已到，请核对。'));
      final decoded = decodeAttachmentText(bytes);
      expect(decoded.text, '送货单：第 3 批已到，请核对。');
      expect(decoded.encoding, AttachmentTextEncoding.utf8);
      expect(decoded.lossy, isFalse);
    });

    test('纯 ASCII 走 UTF-8，不进 GB18030 分支', () {
      final decoded = decodeAttachmentText(
        Uint8List.fromList(utf8.encode('order,qty\nA-1,20\n')),
      );
      expect(decoded.encoding, AttachmentTextEncoding.utf8);
      expect(
        isStructurallyGb18030(Uint8List.fromList(utf8.encode('order,qty'))),
        isFalse,
        reason: '没有多字节序列就不算 GB18030',
      );
    });

    test('UTF-8 BOM 被剥掉并标注出来', () {
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('客户确认'),
      ]);
      final decoded = decodeAttachmentText(bytes);
      expect(decoded.text, '客户确认');
      expect(decoded.encoding, AttachmentTextEncoding.utf8Bom);
    });

    test('UTF-16 LE / BE 带 BOM 都能解', () {
      // 记事本「Unicode」另存为的典型形态。
      expect(
        decodeAttachmentText(_bytes([0xFF, 0xFE, 0x2D, 0x4E, 0x87, 0x65])).text,
        '中文',
      );
      expect(
        decodeAttachmentText(_bytes([0xFE, 0xFF, 0x4E, 0x2D, 0x65, 0x87])).text,
        '中文',
      );
    });
  });

  group('GB18030 解码', () {
    test('双字节区：老系统导出的 GBK 中文解得对', () {
      expect(decodeAttachmentText(_bytes([0xD6, 0xD0, 0xCE, 0xC4])).text, '中文');
      final delivery = decodeAttachmentText(
        _bytes([
          0xCB, 0xCD, 0xBB, 0xF5, 0xB5, 0xA5, 0xA3, 0xBA, 0xB5, 0xDA, //
          0x20, 0x33, 0x20, 0xC5, 0xFA, 0xD2, 0xD1, 0xB5, 0xBD,
        ]),
      );
      expect(delivery.text, '送货单：第 3 批已到');
      expect(delivery.encoding, AttachmentTextEncoding.gb18030);
      expect(delivery.lossy, isFalse);
    });

    test('GBK 的 CSV 一行行解得对（分隔符与换行是 ASCII，中文是双字节）', () {
      final decoded = decodeAttachmentText(
        _bytes([
          0xD0, 0xD5, 0xC3, 0xFB, 0x2C, 0xB2, 0xBF, 0xC3, 0xC5, 0x2C, //
          0xBD, 0xF0, 0xB6, 0xEE, 0x0A, 0xD5, 0xC5, 0xC8, 0xFD, 0x2C,
          0xC9, 0xFA, 0xB2, 0xFA, 0xB2, 0xBF, 0x2C, 0x31, 0x32, 0x30,
          0x30, 0x2E, 0x35, 0x30, 0x0A,
        ]),
      );
      expect(decoded.encoding, AttachmentTextEncoding.gb18030);
      expect(decoded.text, '姓名,部门,金额\n张三,生产部,1200.50\n');
    });

    test('四字节区：BMP 扩展字与增补平面字都能解', () {
      // 㐀 = U+3400（CJK 扩展 A，四字节 BMP 段）
      expect(decodeGb18030(_bytes([0x81, 0x39, 0xEE, 0x39])), '㐀');
      // 𠀀 = U+20000（增补平面，线性映射）
      expect(decodeGb18030(_bytes([0x95, 0x32, 0x82, 0x36])), '𠀀');
    });

    test('结构判定：合法序列为真，越界字节为假', () {
      expect(isStructurallyGb18030(_bytes([0xD6, 0xD0])), isTrue);
      expect(isStructurallyGb18030(_bytes([0x81, 0x39, 0xEE, 0x39])), isTrue);
      expect(isStructurallyGb18030(_bytes([0xD6])), isFalse, reason: '首字节后断尾');
      expect(
        isStructurallyGb18030(_bytes([0xD6, 0x20])),
        isFalse,
        reason: '第二字节落在 0x40 以下且不是 0x30-0x39',
      );
      expect(isStructurallyGb18030(_bytes([0xFF, 0x41])), isFalse);
    });
  });

  test('既不是 UTF-8 也不是 GB18030：容错解码并如实标注编码未知', () {
    final decoded = decodeAttachmentText(
      _bytes([0xE9, 0x80, 0x41, 0xFF, 0x42]),
    );
    expect(decoded.encoding, AttachmentTextEncoding.unknown);
    expect(decoded.lossy, isTrue);
    expect(decoded.text, contains('A'));
    expect(decoded.text, contains('B'));
    expect(decoded.text, contains('\u{FFFD}'));
  });

  test('空文件不炸', () {
    final decoded = decodeAttachmentText(Uint8List(0));
    expect(decoded.text, isEmpty);
    expect(decoded.lossy, isFalse);
  });
}

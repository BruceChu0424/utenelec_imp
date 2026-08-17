// 附件图片压缩工具测试：构造超限大图（>300KB、长边 >1920），
// 验证压缩生效、输出为合法 JPEG、长边收敛到上限内、文件名/类型同步变更。

import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:uten_imp/shared/attachments/attachment_image_compressor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('大图压缩为长边受限的 JPEG 并重命名扩展', () async {
    // 平滑底 + 小幅噪声（真实照片特征）：PNG 滤波压不动（确保 >300KB 触发压缩），
    // JPEG 量化后体积骤降（验证"压缩有收益"路径）
    final random = Random(42);
    final source = img.Image(width: 3000, height: 2200);
    for (final pixel in source) {
      final n = random.nextInt(0x10000);
      pixel
        ..r = 128 + ((n & 0x1f) - 16)
        ..g = 128 + (((n >> 5) & 0x1f) - 16)
        ..b = 128 + (((n >> 10) & 0x1f) - 16);
    }
    final original = Uint8List.fromList(img.encodePng(source));
    expect(original.length, greaterThan(300 * 1024));

    final result = await AttachmentImageCompressor.process(
      bytes: original,
      fileName: 'contract_scan.png',
      contentType: 'image/png',
    );

    expect(result.compressed, isTrue);
    expect(result.contentType, 'image/jpeg');
    expect(result.fileName, 'contract_scan.jpg');
    expect(result.bytes.length, lessThan(original.length));

    final decoded = img.decodeJpg(result.bytes);
    expect(decoded, isNotNull);
    final longEdge = decoded == null
        ? 0
        : decoded.width > decoded.height
        ? decoded.width
        : decoded.height;
    expect(longEdge, lessThanOrEqualTo(AttachmentImageCompressor.maxEdge));
  });

  test('小图与 GIF 原样保留', () async {
    final tiny = Uint8List.fromList(
      img.encodePng(img.Image(width: 8, height: 8)),
    );
    final kept = await AttachmentImageCompressor.process(
      bytes: tiny,
      fileName: 'dot.png',
      contentType: 'image/png',
    );
    expect(kept.compressed, isFalse);
    expect(kept.bytes, same(tiny));

    // GIF 头 + 极小逻辑屏
    final gif = Uint8List.fromList([
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x10, 0x00, 0x10, 0x00,
    ]);
    final keptGif = await AttachmentImageCompressor.process(
      bytes: gif,
      fileName: 'anim.gif',
      contentType: 'image/gif',
    );
    expect(keptGif.compressed, isFalse);
  });

  test('无法解码的损坏数据退回原文件', () async {
    final junk = Uint8List.fromList(List.filled(400 * 1024, 0x61));
    final result = await AttachmentImageCompressor.process(
      bytes: junk,
      fileName: 'broken.png',
      contentType: 'image/png',
    );
    expect(result.compressed, isFalse);
    expect(result.bytes, same(junk));
  });
}

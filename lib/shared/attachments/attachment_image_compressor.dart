// 附件上传客户端图片压缩（对齐主流 IM/审批应用——微信/钉钉/飞书的通行做法）：
//
// - 解码走 dart:ui 原生解码器：自动应用 EXIF 方向（手机拍照的旋转元数据），
//   且支持"目标尺寸解码"，从不按原尺寸解压超大图（与后端 40MP 校验双保险）。
// - 重编码为标准 JPEG（q85、长边 ≤1920）：下载后任何看图工具可打开，应用内预览不受影响。
//   JPEG 无透明通道，先合成到白底（证件扫描/合同照片不含透明，无视觉影响）。
// - 保留原文件的情形：GIF（动画会丢）、非图片、原图已足够小、压缩后反而变大。
// - 压缩在 isolate 中执行（JPEG 编码为纯 Dart CPU 密集操作），不卡 UI。
//
// 失败策略：任何异常都退回原图上传——服务端仍有尺寸/魔数/病毒扫描校验兜底。

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class AttachmentImageCompressor {
  AttachmentImageCompressor._();

  /// 长边上限：覆盖 A4@200dpi 扫描（≈1650px）与主流手机照片，超过则等比缩小。
  static const int maxEdge = 1920;

  /// JPEG 质量：85 是"肉眼无损与体积"的业界常用平衡点。
  static const int jpegQuality = 85;

  /// 原图小于该值直接跳过（已足够小，重编码只会徒增画质损失）。
  static const int skipThresholdBytes = 300 * 1024;

  static bool isCompressible(String? contentType) {
    return contentType == 'image/jpeg' ||
        contentType == 'image/png' ||
        contentType == 'image/webp' ||
        contentType == 'image/bmp';
  }

  /// 返回应上传的字节与文件名；[CompressedResult.compressed] 为 true 时表示发生了压缩。
  static Future<CompressedResult> process({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    final original = CompressedResult(
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
    );
    if (!isCompressible(contentType) || bytes.length <= skipThresholdBytes) {
      return original;
    }
    try {
      // ① 原生解码（主 isolate；引擎线程执行，自动 EXIF 转向 + 目标尺寸解码）
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (int width, int height) {
          final longEdge = math.max(width, height);
          if (longEdge <= maxEdge) {
            return ui.TargetImageSize(width: width, height: height);
          }
          final scale = maxEdge / longEdge;
          return ui.TargetImageSize(
            width: math.max(1, (width * scale).round()),
            height: math.max(1, (height * scale).round()),
          );
        },
      );
      final frame = await codec.getNextFrame();
      final width = frame.image.width;
      final height = frame.image.height;
      final rgba = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (rgba == null) return original;

      // ② 白底合成 + JPEG 编码（compute：后台 isolate）
      final encoded = await compute(
        _encodeJpegOverWhite,
        _EncodeInput(rgba.buffer.asUint8List(), width, height),
      );
      if (encoded == null || encoded.length >= bytes.length) {
        return original; // 压缩无收益（原图已优化过），保留原文件
      }
      return CompressedResult(
        bytes: encoded,
        fileName: _withJpegExtension(fileName),
        contentType: 'image/jpeg',
        compressed: true,
        originalSize: bytes.length,
      );
    } catch (_) {
      return original;
    }
  }

  /// `合同扫描.png` → `合同扫描.jpg`（已是 jpg/jpeg 时保持原名）。
  static String _withJpegExtension(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return fileName;
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    return '$base.jpg';
  }

  /// RGBA 合成到白底后编码 JPEG；返回 null 表示编码失败。
  static Uint8List? _encodeJpegOverWhite(_EncodeInput input) {
    try {
      final rgba = input.rgba;
      final rgb = Uint8List(input.width * input.height * 3);
      for (int i = 0, o = 0; i < input.width * input.height; i++) {
        final a = rgba[i * 4 + 3];
        if (a == 255) {
          rgb[o++] = rgba[i * 4];
          rgb[o++] = rgba[i * 4 + 1];
          rgb[o++] = rgba[i * 4 + 2];
        } else {
          // alpha 混合到白底：c' = c·a + 255·(1-a)
          final inv = 255 - a;
          rgb[o++] = (rgba[i * 4] * a + 255 * inv) ~/ 255;
          rgb[o++] = (rgba[i * 4 + 1] * a + 255 * inv) ~/ 255;
          rgb[o++] = (rgba[i * 4 + 2] * a + 255 * inv) ~/ 255;
        }
      }
      final image = img.Image.fromBytes(
        width: input.width,
        height: input.height,
        bytes: rgb.buffer,
        numChannels: 3,
      );
      return Uint8List.fromList(img.encodeJpg(image, quality: jpegQuality));
    } catch (_) {
      return null;
    }
  }
}

class _EncodeInput {
  const _EncodeInput(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

class CompressedResult {
  const CompressedResult({
    required this.bytes,
    required this.fileName,
    required this.contentType,
    this.compressed = false,
    this.originalSize,
  });

  final Uint8List bytes;
  final String fileName;
  final String contentType;
  final bool compressed;
  final int? originalSize;
}

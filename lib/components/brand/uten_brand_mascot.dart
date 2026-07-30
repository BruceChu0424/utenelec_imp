// UtenBrandMascot - 品牌 IP / 吉祥物（戴黄色安全帽的"德国工程师"）
// 文档：docs/02-组件库/UtenBrandMascot.md（待写）
//
// 原图 747×778（≈1:1）。可用作启动屏、登录页侧图、About 头部、空状态装饰等大画幅。
// width/height 都是 nullable：都不传时按图片原尺寸（747×778）渲染。
//
// 用法：
//   UtenBrandMascot()                                      // 原尺寸
//   UtenBrandMascot(width: 280, height: 280)              // 固定 280×280
//   UtenBrandMascot.size(200)                             // 正方形 200×200
//   const UtenBrandMascot.background(expand: true)        // 全屏铺底（用作启动屏）

import 'package:flutter/material.dart';

import '../../core/constants/assets.dart';

class UtenBrandMascot extends StatelessWidget {
  const UtenBrandMascot({
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.semanticLabel = 'Uten 优腾 德国工程师',
  });

  /// 正方形快捷构造：边长 [size]，避免同时算 width/height。
  const UtenBrandMascot.size(double size, {super.key})
    : width = size,
      height = size,
      fit = BoxFit.contain,
      semanticLabel = 'Uten 优腾 德国工程师';

  /// 启动屏 / 全屏铺底快捷构造：用 [SizedBox.expand] 占满父空间。
  const UtenBrandMascot.background({super.key})
    : width = double.infinity,
      height = double.infinity,
      fit = BoxFit.contain,
      semanticLabel = 'Uten 优腾 德国工程师';

  final double? width;
  final double? height;
  final BoxFit fit;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      UtenAssets.logoIp,
      fit: fit,
      semanticLabel: semanticLabel,
      gaplessPlayback: true,
    );

    // 完全不约束 → 原尺寸
    if (width == null && height == null) return image;

    // 同时约束 → 最常见用法
    if (width != null && height != null) {
      return SizedBox(width: width, height: height, child: image);
    }

    // 单边约束 → 让另一边由图片本身比例决定
    if (width != null) {
      return SizedBox(width: width, child: image);
    }
    return SizedBox(height: height, child: image);
  }
}

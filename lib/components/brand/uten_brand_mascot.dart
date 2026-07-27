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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final image = Image.asset(
      UtenAssets.logoIp,
      fit: fit,
      semanticLabel: semanticLabel,
      gaplessPlayback: true,
    );

    // 全屏铺底（启动屏）：不加背景容器
    final isFullscreen = width == double.infinity && height == double.infinity;
    if (isFullscreen) return image;

    // 尺寸约束包装
    Widget sized;
    if (width != null && height != null) {
      sized = SizedBox(width: width, height: height, child: image);
    } else if (width != null) {
      sized = SizedBox(width: width, child: image);
    } else if (height != null) {
      sized = SizedBox(height: height, child: image);
    } else {
      sized = image;
    }

    // 背景容器：浅色模式白底、深色模式 surfaceContainerHigh（随深色模式变化），圆角 + 裁剪。
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? scheme.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: isDark
            ? Border.all(color: scheme.outlineVariant, width: 0.5)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: sized,
    );
  }
}

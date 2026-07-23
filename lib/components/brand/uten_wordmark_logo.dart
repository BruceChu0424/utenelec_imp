// UtenWordmarkLogo - 横向品牌名锁版（图 UTEN + ELEC）
// 文档：docs/02-组件库/UtenWordmarkLogo.md（待写）
//
// 原图比例 405×74（≈5.47:1），组件默认按 240×44 渲染以适配中等卡片头部。
// 调用方可在 width/height 自定义尺寸（保持宽高比用 BoxFit.contain，组件内已设）。
//
// 用法：
//   UtenWordmarkLogo()                              // 默认 240×44
//   UtenWordmarkLogo(width: 360, height: 66)        // 大屏 hero banner
//   const UtenWordmarkLogo.splash()                // 启动屏用 320×~58

import 'package:flutter/material.dart';

import '../../core/constants/assets.dart';

class UtenWordmarkLogo extends StatelessWidget {
  const UtenWordmarkLogo({
    super.key,
    this.width = 240,
    this.height = 44,
  });

  /// 启动屏常用尺寸（略大，居中感更强）
  const UtenWordmarkLogo.splash({super.key})
      : width = 320,
        height = 320 / (405 / 74);

  /// 紧凑尺寸（卡片内、行内、Avatar 旁的小标识）
  const UtenWordmarkLogo.compact({super.key})
      : width = 120,
        height = 120 / (405 / 74);

  /// 渲染宽度（默认 240）。null 时让图片按原始尺寸渲染。
  final double width;

  /// 渲染高度（默认 44）。null 时让图片按原始尺寸渲染。
  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      UtenAssets.logoName,
      width: width,
      height: height,
      fit: BoxFit.contain,
      // 图像未加载完成前不闪烁；包一层语义标签便于屏幕阅读器
      semanticLabel: 'Uten ELEC',
      gaplessPlayback: true,
    );
  }
}

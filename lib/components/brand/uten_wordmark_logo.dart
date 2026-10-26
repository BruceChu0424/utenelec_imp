// UtenWordmarkLogo - 软件品牌：现有动漫 IP + UTEN。
// 文档：docs/02-组件库/UtenWordmarkLogo.md（待写）
//
// 默认按 240×44 渲染以适配中等卡片头部；公司文件 logo 仍由 PlatformBrandLogo 负责。
// 调用方可在 width/height 自定义尺寸（保持宽高比用 BoxFit.contain，组件内已设）。
//
// 用法：
//   UtenWordmarkLogo()                              // 默认 240×44
//   UtenWordmarkLogo(width: 360, height: 66)        // 大屏 hero banner
//   const UtenWordmarkLogo.splash()                // 启动屏用 320×~58

import 'package:flutter/material.dart';

import '../../core/constants/app_info.dart';
import '../../core/theme/uten_tokens.dart';
import 'uten_brand_mascot.dart';

class UtenWordmarkLogo extends StatelessWidget {
  const UtenWordmarkLogo({super.key, this.width = 240, this.height = 44});

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
    return SizedBox(
      width: width,
      height: height,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenBrandMascot.size(height),
            const SizedBox(width: UtenSpacing.s8),
            Text(
              AppInfo.displayName,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: height * .5,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 通用通知红色数字徽章（导航/工作台模块角标）。
// 纯展示组件：count<=0 时不渲染；>99 显示 99+。
//
// 高度恒等于 [size]、宽度随数字自适应（minWidth=size 保证单数字是正圆，
// 多位数横向变宽呈胶囊）。不可让徽章随父级拉伸——带 alignment 的 Container
// 在有界约束（如 SegmentedButton 的 label 槽）下会撑满，变成行高大小。

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

class UtenNotificationBadge extends StatelessWidget {
  const UtenNotificationBadge({
    super.key,
    required this.count,
    this.size = 16,
    this.showLabel = false,
  });

  final int count;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();

    final label = count > 99 ? '99+' : count.toString();

    return SizedBox(
      height: size,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: showLabel ? 8 : (size / 4)),
        constraints: BoxConstraints(minWidth: size),
        decoration: BoxDecoration(
          // 徽章有自己的实底色, 不吃 colorScheme.error(2026-09-22 用户口径
          // 「红变得更红」)。那是全站语义红, 400 多处引用, 为角标改深它是过度波及;
          // 与黄徽章的 UtenColors.warningStrong 同一个路子。
          color: UtenColors.dangerStrong,
          borderRadius: BorderRadius.circular(size / 2),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          style: TextStyle(
            // 实底是固定的深红, 字就得是固定的白 —— 跟着 colorScheme.onError 走的话
            // 深色模式下可能换成深色, 压在这块固定红底上会读不清。
            color: Colors.white,
            fontSize: showLabel ? 11 : 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

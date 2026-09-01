// 通用通知红色数字徽章（导航/工作台模块角标）。
// 纯展示组件：count<=0 时不渲染；>99 显示 99+。
//
// 高度恒等于 [size]、宽度随数字自适应（minWidth=size 保证单数字是正圆，
// 多位数横向变宽呈胶囊）。不可让徽章随父级拉伸——带 alignment 的 Container
// 在有界约束（如 SegmentedButton 的 label 槽）下会撑满，变成行高大小。

import 'package:flutter/material.dart';

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

    final theme = Theme.of(context);
    final label = count > 99 ? '99+' : count.toString();

    return SizedBox(
      height: size,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: showLabel ? 8 : (size / 4)),
        constraints: BoxConstraints(minWidth: size),
        decoration: BoxDecoration(
          color: theme.colorScheme.error,
          borderRadius: BorderRadius.circular(size / 2),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          style: TextStyle(
            color: theme.colorScheme.onError,
            fontSize: showLabel ? 11 : 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

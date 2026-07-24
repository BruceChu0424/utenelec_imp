// 通用通知红色数字徽章（导航/工作台模块角标）。
// 纯展示组件：count<=0 时不渲染；>99 显示 99+。

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

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: showLabel ? 8 : (size / 4),
        vertical: showLabel ? 2 : 0,
      ),
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      decoration: BoxDecoration(
        color: theme.colorScheme.error,
        borderRadius: BorderRadius.circular(size),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: theme.colorScheme.onError,
          fontSize: showLabel ? 11 : 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

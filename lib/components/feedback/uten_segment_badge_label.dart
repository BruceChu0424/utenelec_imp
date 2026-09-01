// UtenSegmentBadgeLabel - 分段按钮标签 + 计数徽章。
//
// 给 SegmentedButton/Tab 等按钮的 label 槽位用：文字 + 右侧红色圆数字徽章
//（UtenNotificationBadge，工作台角标同款）。计数语义由调用方定义——通常是
// 「该分段下的全量任务数」（非当前页推算）。
//
// 计数口径约定（与工作台合并角标一致）：
// - count == null：仍在加载/未知 → 徽章不显示，不把「未知」伪装成 0；
// - count <= 0：真实零 → 徽章隐藏（UtenNotificationBadge 行为）；
// - count > 99 显示 99+。
//
// 2026-09-01 抽出：待检处置合并 IQC+FQC 时引入，原为页面内私有 _segmentLabel；
// 任何「分类分段 + 待办数」的工具条都应复用本组件，不再手写 Row+Badge。

import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import 'uten_notification_badge.dart';

class UtenSegmentBadgeLabel extends StatelessWidget {
  const UtenSegmentBadgeLabel({
    super.key,
    required this.label,
    this.count,
    this.badgeSize = 16,
  });

  /// 分段文字（如「采购收货」「自制产成品」）。
  final String label;

  /// 该分段的计数；null = 加载中/未知（不显示徽章）。
  final int? count;

  /// 徽章直径，默认 16（与分段导航条内边距协调）。
  final double badgeSize;

  @override
  Widget build(BuildContext context) {
    final count = this.count;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (count != null && count > 0) ...[
          const SizedBox(width: UtenSpacing.s4),
          UtenNotificationBadge(count: count, size: badgeSize),
        ],
      ],
    );
  }
}

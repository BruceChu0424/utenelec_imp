// UtenSegmentBadgeLabel - 分段按钮标签 + 计数（两种形态，由调用方挑）。
//
// 给 SegmentedButton/Tab 等按钮的 label 槽位用：文字 + 右侧计数。
// 计数只有两种呈现，选错就是 bug（docs/00-项目准则/14-徽章与计数口径.md）：
//
// - [UtenSegmentCountForm.browsing]（**默认**）中性括号数字 `(N)`：
//   「这一段有多少条、供我掂量」——阶段/状态监控、草稿、历史、来源细分。
//   0 也显示 `(0)` 保持整行队形；null（加载中/未知）不渲染。**永不进上层累加。**
// - [UtenSegmentCountForm.actionable] 红色通知徽章：该分段本身就是「等我动手、
//   不动会出事」的队列（待审 / 待确认 / 待收货 / 待出库 / 待检 / 被驳回 /
//   超期 / 异常）。0 与 null 一律不渲染（不留红色的 0，也不把未知伪装成 0）；
//   >99 显示 99+。
//
// 逐段怎么选（同一条工具条里一段一段回答）：
//   ① 这个数字变大时，是「有人在等我干活」吗？不是 → 括号。
//   ② 是 → 同一条工具条里是否已有一段红徽章覆盖了这批活的**总量**？
//      是 → 细分切片用括号（同一批活不在一行里红两遍），只有总量段挂红。
// 默认是括号：新调用方忘了传 [countForm] 也不会凭空造出一个假警报。
//
// 计数语义由调用方定义——通常是「该分段下的全量任务数」（非当前页推算）。
//
// 分段计数**不进** `lib/shared/badges/todo_badge_registry.dart`：累加只认注册表
// 里的入口，分段是页面内的切片。
//
// 2026-09-01 抽出：待检处置合并 IQC+FQC 时引入，原为页面内私有 _segmentLabel。
// 2026-09-11 加 [UtenSegmentCountForm]：此前一律红徽章，浏览型分段（阶段监控、
// 草稿、来源细分）全是假警报，本次按口径逐页收敛。

import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import 'uten_count_suffix.dart';
import 'uten_notification_badge.dart';

/// 分段计数的两种呈现形态（默认 [browsing]，见本文件头部选择法）。
enum UtenSegmentCountForm {
  /// 中性括号数字 `(N)`：浏览型分段，0 显示为 `(0)` 保持队形。
  browsing,

  /// 红色通知徽章：该分段是「等我动手」的待办队列，0/null 不渲染。
  actionable,
}

class UtenSegmentBadgeLabel extends StatelessWidget {
  const UtenSegmentBadgeLabel({
    super.key,
    required this.label,
    this.count,
    this.countForm = UtenSegmentCountForm.browsing,
    this.badgeSize = 16,
  });

  /// 分段文字（如「采购收货」「自制产成品」）。
  final String label;

  /// 该分段的计数；null = 加载中/未知（两种形态都不渲染数字）。
  final int? count;

  /// 计数呈现形态；默认中性括号数字（见本文件头部）。
  final UtenSegmentCountForm countForm;

  /// 徽章直径，默认 16（与分段导航条内边距协调）。仅 [UtenSegmentCountForm.actionable] 用。
  final double badgeSize;

  @override
  Widget build(BuildContext context) {
    final count = this.count;
    if (countForm == UtenSegmentCountForm.actionable) {
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
    // 中性括号：与标签共用基线（字号不同也不会一高一低）。
    // 颜色取**分段自身的前景色**再压半透明——选中段背景是 M3 secondaryContainer，
    // 固定 onSurfaceVariant 在上面对比度不够；跟随前景色则选中/未选/置灰三态
    // 都自动成立（禁止写死颜色）。
    final inherited = DefaultTextStyle.of(context).style.color;
    final base = inherited ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label),
        if (count != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: UtenSpacing.s4),
            child: UtenCountSuffix(
              count: count,
              // 分段标签保留 `(0)`：整行分段的数字位置不能忽有忽无。
              hideWhenZero: false,
              color: base.withValues(alpha: base.a * 0.72),
              semanticsLabel: '共 $count 条',
            ),
          ),
      ],
    );
  }
}

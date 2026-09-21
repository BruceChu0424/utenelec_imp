// UtenSegmentBadgeLabel - 分段按钮标签 + 计数(三种形态，由调用方挑)。
//
// 给 SegmentedButton/Tab 等按钮的 label 槽位用：文字 + 右侧计数。
// 计数只有三种呈现，选错就是 bug(docs/00-项目准则/14-徽章与计数口径.md)：
//
// - [UtenSegmentCountForm.browsing]（**默认**）中性括号数字 `(N)`：
//   「这一段已经结束了、供我掂量」——已完成 / 已审 / 已出库 / 红冲 / 历史 / 全部。
//   0 也显示 `(0)` 保持整行队形；null（加载中/未知）不渲染。**永不进上层累加。**
// - [UtenSegmentCountForm.actionable] 红色通知徽章：该分段本身就是「等我动手、
//   不动会出事」的队列（待审 / 待确认 / 待收货 / 待出库 / 待检 / 被驳回 /
//   超期 / 异常 / 等待物料 / 本人草稿)。0 与 null 一律不渲染(不留红色的 0，
//   也不把未知伪装成 0)；>99 显示 99+。
// - [UtenSegmentCountForm.inProgress] 黄色进行中徽章(2026-09-21 新增)：该分段
//   「已经在办、球还在流程里滚着，但还没完，现在不用我动手」——生产中 / 加工中 /
//   执行中 / 在途 / 等待财务审核 / 财务已通过待执行 / 等待检查结果。
//   0 与 null 同样不渲染(没有在跑的活就不该有黄色)。
//
// 逐段怎么选（同一条工具条里一段一段回答）：
//   ① 这个数字变大时，是「有人在等我干活」吗？是 → 红徽章。
//      同一条工具条里已有一段红徽章覆盖了这批活的**总量**时，细分切片退回括号
//      (同一批活不在一行里红两遍)，只有总量段挂红。
//   ② 不是 → 这一段的东西还在流程里没结束吗？是 → 黄徽章。
//   ③ 都不是(已完成 / 已审 / 红冲 / 历史 / 全部)→ 中性括号。
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
import 'uten_in_progress_badge.dart';
import 'uten_notification_badge.dart';

/// 分段计数的三种呈现形态(默认 [browsing]，见本文件头部选择法)。
enum UtenSegmentCountForm {
  /// 中性括号数字 `(N)`：已结束/历史/全部的浏览型分段，0 显示为 `(0)` 保持队形。
  browsing,

  /// 红色通知徽章：该分段是「等我动手」的待办队列，0/null 不渲染。
  actionable,

  /// 黄色进行中徽章：该分段是「已在办、还没完、现在不用我动手」，0/null 不渲染。
  inProgress,
}

class UtenSegmentBadgeLabel extends StatelessWidget {
  const UtenSegmentBadgeLabel({
    super.key,
    required this.label,
    this.count,
    this.countForm = UtenSegmentCountForm.browsing,
    this.inProgressCount,
    this.badgeSize = 16,
  });

  /// 分段文字（如「采购收货」「自制产成品」）。
  final String label;

  /// 该分段的计数；null = 加载中/未知（三种形态都不渲染数字）。
  final int? count;

  /// 大类分段专用的**第二枚**计数：黄色在办数，画在 [count] 那枚的**左边**
  /// （与 hub 卡右上角「黄左红右」同序）。
  ///
  /// 只在一个大类里**同时**装着「等我动手」和「在办中」两批活时才传，此时
  /// [count]/[countForm] 放红色那半、本参数放黄色那半——否则大类只显红数，
  /// 点进去的小类行却有黄数，「大类 = 各小类之和」就对不上了。
  /// 同色只有一档时照常用 [count] + [countForm] 一个参数搞定，别传这个。
  final int? inProgressCount;

  /// 计数呈现形态；默认中性括号数字（见本文件头部）。
  final UtenSegmentCountForm countForm;

  /// 徽章直径，默认 16(与分段导航条内边距协调)。
  /// 仅 [UtenSegmentCountForm.actionable] / [UtenSegmentCountForm.inProgress] 用。
  final double badgeSize;

  @override
  Widget build(BuildContext context) {
    final count = this.count;
    final inProgress = inProgressCount;
    final hasInProgress = inProgress != null && inProgress > 0;
    if (countForm != UtenSegmentCountForm.browsing || hasInProgress) {
      // 红/黄两种徽章形态同构：同高、同 0 不渲染规则，只有颜色与语义不同。
      // 两枚并存时黄在左、红在右(与 hub 卡右上角同序)。
      final actionable = countForm == UtenSegmentCountForm.actionable;
      final hasPrimary =
          count != null &&
          count > 0 &&
          countForm != UtenSegmentCountForm.browsing;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (hasInProgress) ...[
            const SizedBox(width: UtenSpacing.s4),
            UtenInProgressBadge(count: inProgress, size: badgeSize),
          ],
          if (hasPrimary) ...[
            const SizedBox(width: UtenSpacing.s4),
            if (actionable)
              UtenNotificationBadge(count: count, size: badgeSize)
            else
              UtenInProgressBadge(count: count, size: badgeSize),
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

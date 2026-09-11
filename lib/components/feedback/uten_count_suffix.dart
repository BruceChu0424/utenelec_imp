// 括号数字（中性计数）—— 全站两种计数呈现形态里的「浏览型」那一种。
//
// 口径（docs/00-项目准则/14-徽章与计数口径.md）：
//   · UtenNotificationBadge（红色圆数字）= 「需要我处理、不处理会出事」的待办数：
//     待审 / 待确认 / 待收货 / 待出库 / 待检 / 被驳回 / 超期 / 异常。醒目，且会被
//     上层容器（hub 卡 → 工作台模块卡 → 导航 Tab）逐级累加。
//   · UtenCountSuffix（本组件，中性 `(N)`）= 「有多少条、供我掂量」：草稿、我的某某、
//     历史/记录、分段标签、一切浏览型集合。不抢眼，**永不进上层累加**。
//
// 用法：挂在 UtenHubCard 的 [UtenHubCard.labelSuffix] 槽位（紧跟标题文字），
// 或任何「标签 + 条数」的行内位置。卡片上 0 不渲染（不留「(0)」噪声）；
// 分段标签需要用 (0) 保持队形时传 hideWhenZero: false。

import 'package:flutter/material.dart';

class UtenCountSuffix extends StatelessWidget {
  const UtenCountSuffix({
    super.key,
    required this.count,
    this.hideWhenZero = true,
    this.semanticsLabel,
    this.color,
  });

  /// 条数；null = 加载中/未知 → 不渲染（不把「未知」伪装成 0）。
  final int? count;

  /// 0 是否隐藏。卡片入口用默认 true；分段标签传 false 以保持「(0)」队形。
  final bool hideWhenZero;

  /// 无障碍读法（如「草稿 3 张」）；null 时读 `(3)` 本身。
  final String? semanticsLabel;

  /// 文字颜色覆盖；null = 主题 `onSurfaceVariant`（卡片/常规行内位置）。
  /// 背景会变色的宿主（如 SegmentedButton 选中段）传宿主前景色的半透明值，
  /// 否则固定的中性灰在选中背景上对比度不足。**不要传写死的颜色常量。**
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final value = count;
    if (value == null) return const SizedBox.shrink();
    if (value <= 0 && hideWhenZero) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Text(
      '(${value > 999 ? '999+' : value})',
      maxLines: 1,
      semanticsLabel: semanticsLabel,
      style: theme.textTheme.bodySmall?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

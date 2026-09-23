// UtenHubCard - 二级模块页（销售/采购/委外/生产/钱流/仓库/基础资料 hub）通用入口卡片。
//
// 收口原本散落在各 hub 页里 7~8 份 copy 的 _EntryTile / _ResourceTile /
// _WarehouseTaskCenterTile，统一：40×40 图标盒、卡片描边/圆角/内边距，
// 以及图标行最右边的计数徽章（UtenNotificationBadge 系, 2026-09-23 起不再浮在右上角）。
//
// 三个计数槽位(docs/00-项目准则/14-徽章与计数口径.md)：
//   · [badge](图标行最右边，**靠右那枚**)= 红色通知徽章，给「轮到我
//     动手」的待办数(**2026-09-11 起草稿也算**，见该文档 §草稿)，恒在图标行最右边、
//     不随标题文字漂移——这正是各 hub 之前不一致的根因；并且会被上层容器
//     （工作台模块卡 / 导航 Tab）逐级累加。
//   · [progressBadge](图标行最右边，**红徽章左边那枚**)= 黄色进行中徽章，给「已经在办、
//     还没完、现在不用我动手」的数(生产中 / 加工中 / 在途 / 等待财务审核 …)。
//     2026-09-21 用户口径：黄色在红色左边; 2026-09-23 起两枚一起挪到图标行最右边并放大 1.4 倍。
//     同样逐级累加，但走另一张注册表(in_progress_badge_registry)，与红色互不相干。
//   · [labelSuffix]（标题文字右侧行内）= 次要计数位。一张卡同时有「别人给我的待办」
//     和「我自己的草稿」时，待办占 [badge]，草稿退到这里（仍是红色 UtenDraftBadge）
//     ——一个 badge 槽塞两个红圆点读不懂。浏览型计数（历史/记录）也走这里，
//     用中性 [UtenCountSuffix]。
//
// 未启用单据(enabled=false)：图标与标题置灰，图标行右边显「未启用」chip(占用徽章位，
// 此时两枚计数徽章都不渲染——没启用的单据谈不上待办或在办)。

import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_notification_badge.dart' show UtenBadgeScale;

class UtenHubCard extends StatelessWidget {
  const UtenHubCard({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.description,
    this.color,
    this.badge,
    this.progressBadge,
    this.labelSuffix,
    this.enabled = true,
    this.onDisabledTap,
    this.labelStyle,
  });

  final IconData icon;
  final String label;

  /// 副标题；为 null 则只显图标 + 标题（仓库出入库/库存/报表 tile 无描述）。
  final String? description;

  final VoidCallback onTap;

  /// 图标底色与图标色；默认 theme.colorScheme.primary（基础资料按条目传绿/青）。
  final Color? color;

  /// 图标行最右边的「待办」徽章(如 PurchaseTaskBadge / UtenNotificationBadge)，
  /// 并排两枚时在**右**。
  ///
  /// 只放「轮到我动手」的数字(含本人草稿)；「在办中」的数字请用 [progressBadge]，
  /// 其余次要计数请用 [labelSuffix]。
  final Widget? badge;

  /// 图标行最右边的「进行中」黄色徽章([UtenInProgressBadge] 系)，并排两枚时在**左**。
  ///
  /// 放「已经在办、还没完、现在不用我动手」的数字。两枚都有时的顺序是
  /// 「黄 红」——2026-09-21 用户口径，黄色在红色左边。
  final Widget? progressBadge;

  /// 标题右侧的次要计数位：卡片已用 [badge] 放待办时，草稿徽章
  /// （`UtenDraftBadge`）退到这里；浏览型计数用 `UtenCountSuffix`。
  ///
  /// 与标题同一行；标题过长时先压标题（Flexible 换行），后缀始终完整可见。
  /// 2026-09-11 起全部 hub 的草稿都占得到 [badge]（那几张卡本就没有别的待办徽章），
  /// 所以本槽位当前无调用点——保留是给「同时有待办与草稿」的卡用的。
  final Widget? labelSuffix;

  /// false → 图标/标题置灰 + 图标行右边「未启用」chip；点击走 [onDisabledTap]。
  final bool enabled;
  final VoidCallback? onDisabledTap;

  /// 标题文字样式；默认 titleSmall·w600（基础资料传 titleMedium 保留原观感）。
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.primary;
    final iconColor = enabled ? tint : theme.colorScheme.outline;
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : onDisabledTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            vertical: UtenSpacing.s20,
            horizontal: UtenSpacing.s16,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 图标与计数徽章同一行: 图标在左, 黄(进行中)/红(待办) 徽章在这一行
              // 最右边与图标垂直居中(2026-09-23 用户口径: 不再浮在卡片右上角)。
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.1),
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Icon(icon, color: iconColor, size: 22),
                  ),
                  const Spacer(),
                  _badges(theme),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              // 标题与括号数字同一行：标题仍是独立的 Text（不换成 Text.rich——
              // 那会让 data 变 null，`find.text('仓库调拨')` 之类的既有断言与
              // 读屏的整段朗读一起失效），Flexible 保证字号放大/窄屏时照常换行。
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      style: (labelStyle ?? theme.textTheme.titleSmall)
                          ?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: enabled
                                ? null
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  if (labelSuffix != null) ...[
                    const SizedBox(width: UtenSpacing.s4),
                    labelSuffix!,
                  ],
                ],
              ),
              if (description != null) ...[
                const SizedBox(height: 2),
                Text(
                  description!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 黄(进行中) 在左、红(待办) 在右; 两枚都是 count<=0 自己返回 SizedBox.shrink,
  /// 只有一枚有数时另一枚不占宽。hub 卡上的徽章统一放大 1.4 倍, 比工作台小卡更醒目。
  Widget _badges(ThemeData theme) {
    if (!enabled) return _DisabledChip(theme: theme);
    return UtenBadgeScale(
      scale: 1.4,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?progressBadge,
          if (progressBadge != null && badge != null)
            const SizedBox(width: UtenSpacing.s6),
          ?badge,
        ],
      ),
    );
  }
}

class _DisabledChip extends StatelessWidget {
  const _DisabledChip({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        AppLocalizations.of(context).hubDisabledChip,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

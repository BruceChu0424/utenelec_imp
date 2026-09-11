// UtenHubCard - 二级模块页（销售/采购/委外/生产/钱流/仓库/基础资料 hub）通用入口卡片。
//
// 收口原本散落在各 hub 页里 7~8 份 copy 的 _EntryTile / _ResourceTile /
// _WarehouseTaskCenterTile，统一：40×40 图标盒、卡片描边/圆角/内边距，
// 以及右上角徽章浮层（UtenNotificationBadge 系）。
//
// 两个计数槽位（docs/00-项目准则/14-徽章与计数口径.md）：
//   · [badge]（右上角 Stack Positioned）= 红色通知徽章，给「需要我处理」的待办数
//     （**2026-09-11 起草稿也算**，见该文档 §草稿），恒在卡片右上角、不随标题文字
//     或图标行漂移——这正是各 hub 之前不一致的根因；并且会被上层容器
//     （工作台模块卡 / 导航 Tab）逐级累加。
//   · [labelSuffix]（标题文字右侧行内）= 次要计数位。一张卡同时有「别人给我的待办」
//     和「我自己的草稿」时，待办占 [badge]，草稿退到这里（仍是红色 UtenDraftBadge）
//     ——一个 badge 槽塞两个红圆点读不懂。浏览型计数（历史/记录）也走这里，
//     用中性 [UtenCountSuffix]。
//
// 未启用单据（enabled=false）：图标与标题置灰，右上角显「未启用」chip（占用徽章位）。

import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';

class UtenHubCard extends StatelessWidget {
  const UtenHubCard({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.description,
    this.color,
    this.badge,
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

  /// 右上角浮层「待办」徽章（如 PurchaseTaskBadge / UtenNotificationBadge）。
  ///
  /// 只放「需要我处理」的数字（含本人草稿）；次要计数请用 [labelSuffix]。
  final Widget? badge;

  /// 标题右侧的次要计数位：卡片已用 [badge] 放待办时，草稿徽章
  /// （`UtenDraftBadge`）退到这里；浏览型计数用 `UtenCountSuffix`。
  ///
  /// 与标题同一行；标题过长时先压标题（Flexible 换行），后缀始终完整可见。
  /// 2026-09-11 起全部 hub 的草稿都占得到 [badge]（那几张卡本就没有别的待办徽章），
  /// 所以本槽位当前无调用点——保留是给「同时有待办与草稿」的卡用的。
  final Widget? labelSuffix;

  /// false → 图标/标题置灰 + 右上角「未启用」chip；点击走 [onDisabledTap]。
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
        child: Stack(
          children: [
            Container(
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
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.1),
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Icon(icon, color: iconColor, size: 22),
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
            Positioned(
              top: UtenSpacing.s8,
              right: UtenSpacing.s8,
              child:
                  badge ??
                  (enabled
                      ? const SizedBox.shrink()
                      : _DisabledChip(theme: theme)),
            ),
          ],
        ),
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

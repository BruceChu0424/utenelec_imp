// UtenHubCard - 二级模块页（销售/采购/委外/生产/钱流/仓库/基础资料 hub）通用入口卡片。
//
// 收口原本散落在各 hub 页里 7~8 份 copy 的 _EntryTile / _ResourceTile /
// _WarehouseTaskCenterTile，统一：40×40 图标盒、卡片描边/圆角/内边距，
// 以及右上角徽章浮层（UtenNotificationBadge 系）。
//
// 徽章通过 [badge] 槽位以 Stack Positioned(top/right) 渲染，恒在卡片右上角，
// 不再随标题文字或图标行漂移——这正是各 hub 之前不一致的根因。
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

  /// 右上角浮层徽章（如 PurchaseTaskBadge / UtenNotificationBadge）。
  final Widget? badge;

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
                  Text(
                    label,
                    style: (labelStyle ?? theme.textTheme.titleSmall)?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? null
                          : theme.colorScheme.onSurfaceVariant,
                    ),
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

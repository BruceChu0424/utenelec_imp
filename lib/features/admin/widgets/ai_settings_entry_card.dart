// 系统设置页顶部的「AI 服务」入口卡(ADR-133): 点击进入 /admin/ai-settings。
//
// 外观与系统设置页自己的分组卡片一致(细边框 + 控件圆角), 不依赖性能档等全局偏好。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/ai/ai_progress_dialog.dart';

class AiSettingsEntryCard extends StatelessWidget {
  const AiSettingsEntryCard({super.key, this.margin});

  /// 作网格瓦片时传 EdgeInsets.zero（间距由网格管），默认整宽独占一行留底部间距。
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    void open() => context.push(RouteName.adminAiSettings);
    return Semantics(
      button: true,
      label: '${l10n.aiSettingsTitle}, ${l10n.aiSettingsEntrySubtitle}',
      onTap: open,
      excludeSemantics: true,
      child: Card(
        key: const ValueKey('system-settings-ai-entry'),
        margin: margin ?? const EdgeInsets.only(bottom: UtenSpacing.s12),
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: UtenRadius.controlAll,
          side: BorderSide(color: theme.dividerColor),
        ),
        child: InkWell(
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                const AiSparkleBadge(size: 40, animate: false),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.aiSettingsTitle,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s2),
                      Text(
                        l10n.aiSettingsEntrySubtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

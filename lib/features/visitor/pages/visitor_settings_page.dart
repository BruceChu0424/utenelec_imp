// VisitorSettingsPage - 访客端设置页
// 文档：docs/03-页面/访客预约系统.md
//
// 设计原则（与员工 SettingsPage 一致）：
// - 直接调用平台已有的 4 个 switcher 组件（UtenThemeSwitcher / UtenLocaleSwitcher
//   / UtenFontScaler / UtenPerformanceTierSwitcher），逻辑零重复
// - 用 SettingsSection 统一"标题 + 卡片 + 行 + 分隔线"布局
// - 关于/退出登录用访客自己的 session
// - 不显示"修改密码"——访客是验证码登录，没有密码
//
// 响应式：访客流程不经主外壳，全断点自套 UtenContentContainer.narrow
//（设置页宜窄，宽屏居中不拉宽）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/settings/uten_font_scaler.dart';
import '../../../components/settings/uten_locale_switcher.dart';
import '../../../components/settings/uten_performance_switcher.dart';
import '../../../components/settings/uten_theme_switcher.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../settings/widgets/settings_section.dart';
import '../providers/visitor_session_provider.dart';

class VisitorSettingsPage extends ConsumerWidget {
  const VisitorSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.visitorSettingsTitle,
        showBackButton: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: UtenContentContainer.narrow(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 外观区
              SettingsSection(
                title: l10n.settingsSectionAppearance,
                children: [
                  SettingsItem(
                    title: l10n.settingsThemeMode,
                    child: const UtenThemeSwitcher(),
                  ),
                  SettingsItem(
                    title: l10n.settingsLanguage,
                    child: const UtenLocaleSwitcher(),
                  ),
                  SettingsItem(
                    title: l10n.settingsFontSize,
                    child: const UtenFontScaler(),
                  ),
                ],
              ),

              const SizedBox(height: UtenSpacing.s24),

              // 性能区
              SettingsSection(
                title: l10n.settingsSectionPerformance,
                children: [
                  SettingsItem(
                    title: l10n.settingsPerformanceTier,
                    subtitle: l10n.settingsPerformanceHint,
                    child: const UtenPerformanceTierSwitcher(),
                  ),
                ],
              ),

              const SizedBox(height: UtenSpacing.s24),

              // 关于
              SettingsSection(
                title: l10n.settingsSectionAbout,
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline, size: 20),
                    title: Text(l10n.settingsVersion),
                    trailing: const Text('0.1.0 (Phase 0)'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),

              const SizedBox(height: UtenSpacing.s24),

              // 退出访客
              UtenCard(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                child: Material(
                  color: Colors.transparent,
                  child: ListTile(
                    leading: const Icon(Icons.logout,
                        color: UtenColors.error, size: 20),
                    title: Text(
                      l10n.visitorLogout,
                      style: const TextStyle(color: UtenColors.error),
                    ),
                    onTap: () => _confirmLogout(context, ref),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),

              const SizedBox(height: UtenSpacing.s32),

              Center(
                child: Text(
                  'Uten IMP · 访客端',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.visitorLogout),
        content: Text(l10n.settingsLogoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: UtenColors.error),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(visitorSessionProvider.notifier).logout();
      if (context.mounted) {
        context.go(RouteName.entry);
      }
    }
  }
}

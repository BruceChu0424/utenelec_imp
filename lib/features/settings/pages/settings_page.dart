// SettingsPage - 设置页
// 文档：docs/03-页面/设置页.md（待写）
//
// 包含：主题切换 / 语言切换 / 字号调节 / 性能档切换 / 关于 / 退出登录

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/settings/uten_font_scaler.dart';
import '../../../components/settings/uten_locale_switcher.dart';
import '../../../components/settings/uten_performance_switcher.dart';
import '../../../components/settings/uten_theme_switcher.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../shared/providers/session_provider.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 外观区
            _SectionTitle(text: l10n.settingsSectionAppearance),
            const SizedBox(height: 8),
            UtenCard(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Column(
                children: [
                  _SectionItem(
                    title: l10n.settingsThemeMode,
                    child: const UtenThemeSwitcher(),
                  ),
                  const Divider(height: 1),
                  _SectionItem(
                    title: l10n.settingsLanguage,
                    child: const UtenLocaleSwitcher(),
                  ),
                  const Divider(height: 1),
                  _SectionItem(
                    title: l10n.settingsFontSize,
                    child: const UtenFontScaler(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 性能区
            _SectionTitle(text: l10n.settingsSectionPerformance),
            const SizedBox(height: 8),
            UtenCard(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: _SectionItem(
                title: l10n.settingsPerformanceTier,
                subtitle: l10n.settingsPerformanceHint,
                child: const UtenPerformanceTierSwitcher(),
              ),
            ),

            const SizedBox(height: 24),

            // 关于
            _SectionTitle(text: l10n.settingsSectionAbout),
            const SizedBox(height: 8),
            UtenCard(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: ListTile(
                leading: const Icon(Icons.info_outline, size: 20),
                title: Text(l10n.settingsVersion),
                trailing: const Text('0.1.0 (Phase 0)'),
                contentPadding: EdgeInsets.zero,
              ),
            ),

            const SizedBox(height: 24),

            // 账号
            _SectionTitle(text: '账号'),
            const SizedBox(height: 8),
            UtenCard(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  leading: const Icon(Icons.lock_outline_rounded, size: 20),
                  title: const Text('修改密码'),
                  subtitle: const Text('修改登录密码'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.go(RouteName.changePassword),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // 退出登录
            UtenCard(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  leading: const Icon(Icons.logout,
                      color: UtenColors.error, size: 20),
                  title: const Text(
                    '退出登录',
                    style: TextStyle(color: UtenColors.error),
                  ),
                  onTap: () => _confirmLogout(context, ref),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),

            const SizedBox(height: 32),

            // 页脚信息
            Center(
              child: Text(
                'Phase 0 地基 Demo\n完整功能将在 Phase 1+ 陆续开放',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settingsLogout),
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
      await ref.read(sessionProvider.notifier).logout();
      if (context.mounted) {
        context.go(RouteName.login);
      }
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
      ),
    );
  }
}

class _SectionItem extends StatelessWidget {
  const _SectionItem({required this.title, this.subtitle, this.child});

  final String title;
  final String? subtitle;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: ExpansionTile(
      title: Text(title, style: theme.textTheme.bodyLarge),
      subtitle: subtitle != null
          ? Text(subtitle!, style: theme.textTheme.bodySmall)
          : null,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      children: [
        if (child != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: child!,
          ),
      ],
      ),
    );
  }
}

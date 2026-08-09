// SettingsPage - 设置页
// 文档：docs/03-页面/设置页.md
//
// 包含：主题切换 / 语言切换 / 字号调节 / 性能档切换 / 关于 / 退出登录
// 外观 + 性能 + 关于 三段与 VisitorSettingsPage 共享 SettingsSection 布局。
// 全断点套 UtenContentContainer.narrow：长列表行在宽屏下收敛到 1120，保证可读性。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/settings/uten_font_scaler.dart';
import '../../../components/settings/uten_locale_switcher.dart';
import '../../../components/settings/uten_performance_switcher.dart';
import '../../../components/settings/uten_theme_switcher.dart';
import '../../../core/constants/app_info.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../widgets/settings_section.dart';
import '../widgets/server_switch_dialog.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final canViewAuditLog = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.auditLogView);
    final user = ref.watch(sessionProvider).user;

    return Scaffold(
      body: UtenContentContainer.narrow(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s16,
            bottom: 96, // 底部悬浮胶囊导航留白
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行：之前整页没有任何标题/当前账号提示，一进来就是「外观」分组，
              // 容易让人觉得"这页缺东西"（问题 #14）。
              Padding(
                padding: const EdgeInsets.only(
                  bottom: UtenSpacing.s16,
                  left: UtenSpacing.s4,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.settings_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      l10n.settingsTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (user != null) ...[
                UtenCard(
                  child: Row(
                    children: [
                      UtenUserAvatar(size: 44, name: user.name),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user.name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                user.code,
                                if (user.department != null) user.department!,
                              ].join(' · '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: UtenSpacing.s24),
              ],
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
                    trailing: const Text(AppInfo.version),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),

              const SizedBox(height: UtenSpacing.s24),

              // 账号
              SettingsSection(
                title: '账号',
                children: [
                  Material(
                    color: Colors.transparent,
                    child: ListTile(
                      leading: const Icon(Icons.dns_outlined, size: 20),
                      title: const Text('服务器'),
                      subtitle: const Text('切换公司内网 / 云端地址'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => const ServerSwitchDialog(),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s8,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  if (canViewAuditLog) ...[
                    Material(
                      color: Colors.transparent,
                      child: ListTile(
                        leading: const Icon(
                          Icons.devices_other_outlined,
                          size: 20,
                        ),
                        title: const Text('本机信息与操作回执'),
                        subtitle: const Text('按本地操作 ID 核查这台设备保存的回执'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () =>
                            context.push(RouteName.deviceAuditReceipts),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s8,
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                  ],
                  Material(
                    color: Colors.transparent,
                    child: ListTile(
                      leading: const Icon(Icons.lock_outline_rounded, size: 20),
                      title: const Text('修改密码'),
                      subtitle: const Text('修改登录密码'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.go(RouteName.changePassword),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s8,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: UtenSpacing.s24),

              // 退出登录
              UtenCard(
                padding: const EdgeInsets.symmetric(
                  vertical: UtenSpacing.s4,
                  horizontal: UtenSpacing.s8,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: ListTile(
                    leading: const Icon(
                      Icons.logout,
                      color: UtenColors.error,
                      size: 20,
                    ),
                    title: const Text(
                      '退出登录',
                      style: TextStyle(color: UtenColors.error),
                    ),
                    onTap: () => _confirmLogout(context, ref),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s8,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: UtenSpacing.s32),

              // 页脚信息
              Center(
                child: Text(
                  '${AppInfo.displayName}\n${AppInfo.copyright}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
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
    final confirmed = await UtenNotify.alert(
      context,
      title: l10n.settingsLogout,
      message: l10n.settingsLogoutConfirm,
      confirmLabel: l10n.commonConfirm,
      cancelLabel: l10n.commonCancel,
      icon: Icons.logout_rounded,
    );

    if (confirmed != true) return;

    // Capture the app-level host before logout changes the route. The warning
    // remains visible on the login page even if this Settings context unmounts.
    final notifications = ref.read(appNotificationProvider.notifier);
    try {
      await ref.read(sessionProvider.notifier).logout();
    } catch (_) {
      notifications.showError('退出未完全完成，请重新打开应用后再登录。', force: true);
    } finally {
      if (context.mounted) {
        context.go(RouteName.login);
      }
    }
  }
}

// SettingsPage - 设置页
// 文档：docs/03-页面/设置页.md
//
// 包含：主题切换 / 语言切换 / 界面大小 / 性能档切换 / 关于 / 退出登录
// 外观 + 性能 + 关于 三段与 VisitorSettingsPage 共享 SettingsSection 布局。
// 全断点套 UtenContentContainer.narrow：长列表行在宽屏下收敛到 1120，保证可读性。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../components/layout/uten_section_header.dart';

import '../../../components/layout/uten_floating_action_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/settings/uten_font_scaler.dart';
import '../../../components/settings/uten_locale_switcher.dart';
import '../../../components/settings/uten_performance_switcher.dart';
import '../../../components/settings/uten_theme_switcher.dart';
import '../../../components/settings/uten_time_display_switcher.dart';
import '../../../shared/platform_branding/platform_branding_provider.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/server_config.dart';
import '../../../core/network/server_selection.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/shared_providers.dart';
import '../widgets/settings_section.dart';
import '../widgets/app_version_tile.dart';
import '../../../shared/widgets/settings_about_extensions.dart';
import '../../../core/l10n/disaster_recovery_text.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final branding = ref.watch(platformBrandingSnapshotProvider);
    final canViewAuditLog = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.auditLogView);
    final user = ref.watch(sessionProvider).user;
    final serverEndpoint = ref.watch(apiBaseUrlProvider);
    final serverMode = readServerMode(ref.watch(sharedPreferencesProvider));

    return Scaffold(
      body: UtenContentContainer.narrow(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s16,
            bottom: UtenFloatingActionGroup.scrollClearance, // 底部悬浮导航留白
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
                    subtitle: l10n.settingsFontSizeHint,
                    child: const UtenFontScaler(),
                  ),
                  const SettingsItem(
                    title: '时间显示',
                    child: UtenTimeDisplaySwitcher(),
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
                  const AppVersionTile(),
                  ...SettingsAboutExtensions.of(context),
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
                      title: Text(recoveryText(context, '运行与灾备')),
                      subtitle: Text(
                        kIsWeb
                            ? serverEndpoint.startsWith('/')
                                  ? '同源接口：$serverEndpoint(由访问入口路由)'
                                  : 'Debug Web 接口：$serverEndpoint'
                            : '${_serverModeLabel(serverMode)} · $serverEndpoint',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push(RouteName.disasterRecovery),
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
                        title: const UtenSectionHeader(
                          title: '本机信息与操作回执',
                          info: '按本地操作 ID 核查这台设备保存的回执',
                        ),
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

              // 退出登录（网络段带忙碌态：确认后到跳登录页之间不再静默无反馈）
              const _LogoutTile(),

              const SizedBox(height: UtenSpacing.s32),

              // 页脚信息
              Center(
                child: Text(
                  '${branding.platformName}\n${branding.copyright(DateTime.now().year)}',
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
}

String _serverModeLabel(ServerMode mode) {
  switch (mode) {
    case ServerMode.auto:
      return '自动优先公司内网';
    case ServerMode.local:
      return '仅公司内网';
    case ServerMode.cloud:
      return '仅托管云端';
  }
}

/// 退出登录入口：确认弹窗关闭后的登出网络段自带忙碌态（尾图标位换转圈并禁点），
/// 不再「确认完了卡在原页看不出在退」（2026-10-18）。
class _LogoutTile extends ConsumerStatefulWidget {
  const _LogoutTile();

  @override
  ConsumerState<_LogoutTile> createState() => _LogoutTileState();
}

class _LogoutTileState extends ConsumerState<_LogoutTile> {
  bool _busy = false;

  Future<void> _confirmLogout() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await UtenNotify.alert(
      context,
      title: l10n.settingsLogout,
      message: l10n.settingsLogoutConfirm,
      confirmLabel: l10n.commonConfirm,
      cancelLabel: l10n.commonCancel,
      icon: Icons.logout_rounded,
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    // Capture the app-level host before logout changes the route. The warning
    // remains visible on the login page even if this Settings context unmounts.
    final notifications = ref.read(appNotificationProvider.notifier);
    try {
      await ref.read(sessionProvider.notifier).logout();
    } catch (_) {
      notifications.showError('退出未完全完成，请重新打开应用后再登录。', force: true);
    } finally {
      if (mounted) {
        context.go(RouteName.login);
      }
    }
  }

  @override
  Widget build(BuildContext context) => UtenCard(
    padding: const EdgeInsets.symmetric(
      vertical: UtenSpacing.s4,
      horizontal: UtenSpacing.s8,
    ),
    child: Material(
      color: Colors.transparent,
      child: ListTile(
        leading: const Icon(Icons.logout, color: UtenColors.error, size: 20),
        title: const Text('退出登录', style: TextStyle(color: UtenColors.error)),
        trailing: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : null,
        onTap: _busy ? null : _confirmLogout,
        contentPadding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
      ),
    ),
  );
}

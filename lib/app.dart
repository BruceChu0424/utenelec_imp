// App 入口
// 文档：docs/05-架构/架构总览.md

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'components/layout/uten_page_scrollbar_host.dart';
import 'core/constants/app_info.dart';

import 'components/feedback/uten_context_menu_policy.dart';
import 'core/l10n/gen/app_localizations.dart';
import 'core/platform/platform_window_title.dart';
import 'core/platform/desktop_window.dart';
import 'core/responsive/display_zoom.dart';
import 'core/router/app_router.dart';
import 'core/router/route_names.dart';
import 'core/theme/dark_theme.dart';
import 'core/theme/light_theme.dart';
import 'core/theme/uten_control_theme.dart';
import 'core/theme/uten_scroll_behavior.dart';
import 'core/ui/app_notification.dart';
import 'core/ui/connection_recovery_banner.dart';
import 'features/admin/widgets/impersonation_banner.dart';
import 'features/auth/services/pending_refresh_revocation_drainer.dart';
import 'features/notice/providers/notice_arrival.dart';
import 'features/notice/providers/review_pending_login_gate.dart';
import 'features/notice/providers/notice_route_read_bridge.dart';
import 'shared/auth/permissions.dart';
import 'shared/providers/font_scale_provider.dart';
import 'shared/providers/locale_provider.dart';
import 'shared/providers/session_provider.dart';
import 'shared/providers/session_rehydrate_gate.dart';
import 'shared/providers/theme_provider.dart';
import 'shared/platform_branding/platform_branding_provider.dart';
import 'shared/widgets/reauth_dialog.dart';
import 'shared/widgets/desktop_window_host.dart';
import 'features/auth/widgets/remote_mfa_prompt.dart';
import 'shared/widgets/user_activity_tracker.dart';
import 'shared/widgets/server_maintenance_host.dart';
import 'platform_tables_host.dart';
import 'features/client_update/client_update_host.dart';
import 'features/client_update/client_update_tile.dart';
import 'shared/widgets/settings_about_extensions.dart';
import 'core/network/server_config.dart';

String _notificationSessionKey(SessionState session) =>
    '${session.status.name}|${session.user?.id ?? ''}|'
    '${session.actor?.id ?? ''}|${session.isImpersonating}|'
    '${session.user?.can(Perm.noticeRead) ?? false}';

class UtenApp extends ConsumerWidget {
  const UtenApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep eventual server-side logout active even after local credentials are
    // gone and an app restart begins on the unauthenticated route.
    ref.watch(pendingRefreshRevocationDrainerProvider);
    ref.listen<String>(sessionProvider.select(_notificationSessionKey), (
      previous,
      next,
    ) {
      if (previous != null && previous != next) {
        ref.read(appNotificationProvider.notifier).clear();
      }
    });
    final themeMode = ref.watch(themeProvider);
    final branding = ref.watch(platformBrandingSnapshotProvider);
    ref.watch(platformWindowTitleSyncProvider);
    final locale = ref.watch(localeProvider);
    final fontScale = ref.watch(fontScaleProvider);
    final router = ref.watch(appRouterProvider);
    final session = ref.watch(sessionProvider);
    // 仅在「是否正在模拟身份」翻转时重建外壳，把顶部模拟横幅纳入/移出布局。
    final impersonating = session.isImpersonating;
    final noticeArrivalEnabled =
        session.status == AuthStatus.authenticated &&
        (session.user?.can(Perm.noticeRead) ?? false);
    final noticeIdentityKey = _notificationSessionKey(session);

    // 基础主题（字号档经下方 builder 的整体缩放生效）
    final lightTheme = buildLightTheme(branding: branding);
    final darkTheme = buildDarkTheme(branding: branding);

    return MaterialApp.router(
      onGenerateTitle: (context) => AppInfo.externalName,
      debugShowCheckedModeBanner: false,

      // 主题
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,

      // 全局滚动行为：隐藏所有页面滚动条（桌面端默认会自动加右侧滚动条）
      scrollBehavior: const UtenScrollBehavior(),

      // 国际化
      locale: locale,
      supportedLocales: supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      // 所有设备按个人界面倍率整体缩放 + 顶部横幅/通知宿主
      builder: (context, child) {
        final routedChild = noticeArrivalEnabled
            ? NoticeArrivalListener(
                identityKey: noticeIdentityKey,
                routeContext: () => appNavigatorKey.currentContext,
                child: child!,
              )
            : child!;
        final settingsChild = SettingsAboutExtensions(
          entries: const [ClientUpdateTile(), ClientReleasePublishTile()],
          child: routedChild,
        );
        // 最外层整体缩放：横幅、通知宿主与路由树一起等比放大/缩小（字号档不再只乘
        // textScaler——文字、图标、卡片、间距同步变化；自动档为 100%，
        // 系统无障碍曲线原样继承）。之下的 MediaQuery 已换算成画布口径，
        // 见 core/responsive/display_zoom.dart。
        final appContent = UtenContextMenuPolicy(
          child: PlatformTablesHost(
            key: ValueKey(
              'tables:${session.user?.id}:${session.actor?.id}:$impersonating',
            ),
            child: UtenDisplayZoomBox.adaptive(
              // null = 自动 100%；窗口变化不会降低所选界面倍率。
              fontFactor: fontScale.factor,
              autoLadder: FontScale.ladder,
              child: UtenControlTheme(
                child: ServerMaintenanceHost(
                  child: Column(
                    children: [
                      // 通知目标路由桥（不渲染）：导航到有通知指向的路由时自动已读。
                      const NoticeRouteReadBridge(),
                      // 敏感操作再认证宿主 (不渲染)：服务端要求重新输入密码时弹统一密码框 (ADR-110)。
                      const StepUpPromptHost(),
                      const RemoteMfaPromptHost(),
                      // 人为输入采集 (不渲染)：用户没在操作时发出的请求不续期服务端会话 (ADR-110)。
                      const UserActivityTracker(),
                      // 登录会话重建门（不渲染）：重新登录时立即重拉全局角标，
                      // 不再等 60s 轮询/手动刷新。
                      const SessionRehydrateGate(),
                      ClientUpdateHost(
                        key: ValueKey((
                          session.status,
                          session.user?.id,
                          session.actor?.id,
                          ref.watch(apiBaseUrlProvider),
                        )),
                        enabled: session.isLoggedIn && !impersonating,
                        dialogContext: () => appNavigatorKey.currentContext,
                      ),
                      // V459 登录检查门（不渲染）：登录后拉待审，有则弹居中审核弹窗。
                      ReviewPendingLoginGate(
                        enabled: noticeArrivalEnabled,
                        identityKey: noticeIdentityKey,
                        dialogContext: () => appNavigatorKey.currentContext,
                      ),
                      // 模拟身份横幅：占顶「固定」、把页面整体下推，不再覆盖 AppBar/返回键。
                      // 非模拟时返回 SizedBox.shrink，自动收起不占空间。
                      const ImpersonationBanner(),
                      // 连接恢复横幅：占顶「下推」通栏（与模拟身份横幅同形态）。断连期间
                      // 不再以悬浮卡片盖住页面搜索框/标签页；恢复后整条自动收起不占空间。
                      const ConnectionRecoveryBanner(),
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            // 取整体缩放之下（画布口径）的 MediaQuery，再按模拟态调 padding。
                            final mediaQuery = MediaQuery.of(context);
                            return MediaQuery(
                              // 模拟时状态栏 top 留白已由顶部横幅承担，下方页面 top 置 0，
                              // 避免 AppBar 再加一次状态栏高度（双重留白）。
                              // 非模拟时保持原 padding，由页面自己处理状态栏。
                              data: impersonating
                                  ? mediaQuery.copyWith(
                                      padding: mediaQuery.padding.copyWith(
                                        top: 0,
                                      ),
                                      viewPadding: mediaQuery.viewPadding
                                          .copyWith(top: 0),
                                    )
                                  : mediaQuery,
                              child: Stack(
                                children: [
                                  UtenPageScrollbarHost(child: settingsChild),
                                  const Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: SafeArea(
                                      bottom: false,
                                      // 普通通知横幅：瞬时悬浮居中、自动消失。连接横幅
                                      // 不在此处——它占顶下推，见上方 Column。
                                      child: AppNotificationHost(
                                        useSafeArea: false,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        return ListenableBuilder(
          listenable: router.routeInformationProvider,
          child: appContent,
          builder: (context, child) => DesktopWindowHost(
            // Rescue has its own access checks and needs the regular workspace
            // even when the business session is unavailable.
            mode:
                session.isLoggedIn ||
                    router.routeInformationProvider.value.uri.path ==
                        RouteName.disasterRecovery
                ? DesktopWindowMode.main
                : DesktopWindowMode.login,
            child: child!,
          ),
        );
      },

      // 路由
      routerConfig: router,
    );
  }
}

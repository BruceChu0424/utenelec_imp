// App 入口
// 文档：docs/05-架构/架构总览.md

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/l10n/gen/app_localizations.dart';
import 'core/responsive/display_zoom.dart';
import 'core/router/app_router.dart';
import 'core/theme/dark_theme.dart';
import 'core/theme/light_theme.dart';
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
import 'shared/widgets/reauth_dialog.dart';
import 'shared/widgets/user_activity_tracker.dart';

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
    final lightTheme = buildLightTheme();
    final darkTheme = buildDarkTheme();

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
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

      // 整体缩放（宽屏自动放大 × 字号档）+ 顶部横幅/通知宿主
      builder: (context, child) {
        final routedChild = noticeArrivalEnabled
            ? NoticeArrivalListener(
                identityKey: noticeIdentityKey,
                routeContext: () => appNavigatorKey.currentContext,
                child: child!,
              )
            : child!;
        // 最外层整体缩放：横幅、通知宿主与路由树一起等比放大/缩小（字号档不再只乘
        // textScaler——文字、图标、卡片、间距同步变化；窗口比 1920 宽时自动放大，
        // 宽屏观感与基准机器一致）。之下的 MediaQuery 已换算成画布口径，
        // 见 core/responsive/display_zoom.dart。
        return UtenDisplayZoomBox.adaptive(
          // null = 自动（按屏幕推荐）；手动档超出窗口容量时按上限生效（display_capacity.dart）。
          fontFactor: fontScale.factor,
          autoLadder: FontScale.ladder,
          child: Column(
            children: [
              // 通知目标路由桥（不渲染）：导航到有通知指向的路由时自动已读。
              const NoticeRouteReadBridge(),
              // 敏感操作再认证宿主 (不渲染)：服务端要求重新输入密码时弹统一密码框 (ADR-110)。
              const StepUpPromptHost(),
              // 人为输入采集 (不渲染)：用户没在操作时发出的请求不续期服务端会话 (ADR-110)。
              const UserActivityTracker(),
              // 登录会话重建门（不渲染）：重新登录时立即重拉全局角标，
              // 不再等 60s 轮询/手动刷新（清空业务数据后的重进即新数据）。
              const SessionRehydrateGate(),
              // V459 登录检查门（不渲染）：登录后拉待审，有则弹居中审核弹窗。
              ReviewPendingLoginGate(
                enabled: noticeArrivalEnabled,
                identityKey: noticeIdentityKey,
                dialogContext: () => appNavigatorKey.currentContext,
              ),
              // 模拟身份横幅：占顶「固定」、把页面整体下推，不再覆盖 AppBar/返回键。
              // 非模拟时返回 SizedBox.shrink，自动收起不占空间。
              const ImpersonationBanner(),
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
                              padding: mediaQuery.padding.copyWith(top: 0),
                              viewPadding: mediaQuery.viewPadding.copyWith(
                                top: 0,
                              ),
                            )
                          : mediaQuery,
                      child: Stack(
                        children: [
                          routedChild,
                          const Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: SafeArea(
                              bottom: false,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ConnectionRecoveryBanner(useSafeArea: false),
                                  AppNotificationHost(useSafeArea: false),
                                ],
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
        );
      },

      // 路由
      routerConfig: router,
    );
  }
}

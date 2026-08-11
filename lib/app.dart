// App 入口
// 文档：docs/05-架构/架构总览.md

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/l10n/gen/app_localizations.dart';
import 'core/router/app_router.dart';
import 'core/theme/dark_theme.dart';
import 'core/theme/light_theme.dart';
import 'core/theme/uten_scroll_behavior.dart';
import 'core/ui/app_notification.dart';
import 'core/ui/connection_recovery_banner.dart';
import 'features/admin/widgets/impersonation_banner.dart';
import 'features/auth/services/pending_refresh_revocation_drainer.dart';
import 'shared/providers/font_scale_provider.dart';
import 'shared/providers/locale_provider.dart';
import 'shared/providers/session_provider.dart';
import 'shared/providers/theme_provider.dart';

class UtenApp extends ConsumerWidget {
  const UtenApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep eventual server-side logout active even after local credentials are
    // gone and an app restart begins on the unauthenticated route.
    ref.watch(pendingRefreshRevocationDrainerProvider);
    final themeMode = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    final fontScale = ref.watch(fontScaleProvider);
    final router = ref.watch(appRouterProvider);
    // 仅在「是否正在模拟身份」翻转时重建外壳，把顶部模拟横幅纳入/移出布局。
    final impersonating = ref.watch(
      sessionProvider.select((s) => s.isImpersonating),
    );

    // 基础主题 + 字号缩放（通过 textScaler 乘到全局）
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

      // 字号缩放 + 顶部横幅/通知宿主
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        // textScaler 用 linear 缩放：原始 scaleFactor 乘以用户选择的字号因子
        final scaledTextScaler = TextScaler.linear(
          mediaQuery.textScaler.scale(1) * fontScale.factor,
        );
        return MediaQuery(
          // 外层：字号缩放（横幅与页面都吃）。padding 保留，供顶部横幅 SafeArea 用。
          data: mediaQuery.copyWith(textScaler: scaledTextScaler),
          child: Column(
            children: [
              // 模拟身份横幅：占顶「固定」、把页面整体下推，不再覆盖 AppBar/返回键。
              // 非模拟时返回 SizedBox.shrink，自动收起不占空间。
              const ImpersonationBanner(),
              Expanded(
                child: MediaQuery(
                  // 模拟时状态栏 top 留白已由顶部横幅承担，下方页面 top 置 0，
                  // 避免 AppBar 再加一次状态栏高度（双重留白）。
                  // 非模拟时保持原 padding，由页面自己处理状态栏。
                  data: impersonating
                      ? mediaQuery.copyWith(
                          textScaler: scaledTextScaler,
                          padding: mediaQuery.padding.copyWith(top: 0),
                          viewPadding: mediaQuery.viewPadding.copyWith(top: 0),
                        )
                      : mediaQuery.copyWith(textScaler: scaledTextScaler),
                  child: Stack(
                    children: [
                      child!,
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: ConnectionRecoveryBanner(),
                      ),
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: AppNotificationHost(),
                      ),
                    ],
                  ),
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

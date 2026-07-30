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
import 'shared/providers/font_scale_provider.dart';
import 'shared/providers/locale_provider.dart';
import 'shared/providers/theme_provider.dart';

class UtenApp extends ConsumerWidget {
  const UtenApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    final fontScale = ref.watch(fontScaleProvider);
    final router = ref.watch(appRouterProvider);

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

      // 字号缩放 + 顶部通知宿主（覆盖在所有页面之上）
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        // textScaler 用 linear 缩放：原始 scaleFactor 乘以用户选择的字号因子
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: TextScaler.linear(
              mediaQuery.textScaler.scale(1) * fontScale.factor,
            ),
          ),
          child: Stack(
            children: [
              child!,
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(),
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

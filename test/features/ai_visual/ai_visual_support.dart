// AI 程序截图审查的公共件: 视口、应用外壳(截图边界包住整个应用, 抽屉/弹窗也进图)、落盘。
//
// 只在 `--dart-define=UTEN_CAPTURE_UI=true` 时运行(见 ai_program_visual_review_test.dart),
// 图片写到 build/ui-audit/ai-*.png。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

const bool kCaptureUi = bool.fromEnvironment('UTEN_CAPTURE_UI');

/// 截图边界(包住 MaterialApp, 导航浮层里的抽屉/弹窗也在图里)。
final captureBoundary = GlobalKey(debugLabel: 'ai-visual-capture');

/// 桌面 1440x900 / 手机 390x844, 逻辑像素 = 物理像素(截图 1:1)。
const Size kDesktop = Size(1440, 900);
const Size kMobile = Size(390, 844);

Future<void> setCaptureView(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await loadAuditScreenshotFonts(tester);
}

ThemeData captureTheme({bool dark = false}) {
  final base = dark ? buildDarkTheme() : buildLightTheme();
  final theme = auditScreenshotTheme(base);
  TextStyle? withFont(TextStyle? style) =>
      style?.copyWith(fontFamily: 'NotoSansSC');
  return theme.copyWith(
    // 应用主题没给「选中 Chip」单独字样时, 选中与未选中同字号(截图助手默认会放大选中的)。
    chipTheme: theme.chipTheme.copyWith(
      secondaryLabelStyle: base.chipTheme.secondaryLabelStyle == null
          ? theme.chipTheme.labelStyle
          : theme.chipTheme.secondaryLabelStyle,
    ),
    // 弹窗标题/正文的主题字样不带字体族, 测试里会落到方块字体。
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: withFont(base.dialogTheme.titleTextStyle),
      contentTextStyle: withFont(base.dialogTheme.contentTextStyle),
    ),
  );
}

Future<List<Override>> baseOverrides() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return [sharedPreferencesProvider.overrideWithValue(prefs)];
}

/// `home` 版应用外壳。
Widget captureApp({
  required Widget home,
  required List<Override> overrides,
  bool dark = false,
}) => ProviderScope(
  overrides: overrides,
  child: RepaintBoundary(
    key: captureBoundary,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: captureTheme(dark: dark),
      home: home,
    ),
  ),
);

/// 路由版应用外壳(页面里用 go_router 跳转/返回的)。
Widget captureRouterApp({
  required GoRouter router,
  required List<Override> overrides,
  bool dark = false,
  TransitionBuilder? builder,
}) => ProviderScope(
  overrides: overrides,
  child: RepaintBoundary(
    key: captureBoundary,
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: captureTheme(dark: dark),
      routerConfig: router,
      builder: builder,
    ),
  ),
);

/// 落盘到 `build/ui-audit/ai-NAME.png`, 再确认没有布局溢出等异常。
Future<void> capture(WidgetTester tester, String name) async {
  final error = tester.takeException();
  // 先落盘(溢出也要看得见), 再把异常报出来。
  await saveAuditScreenshot(tester, captureBoundary, 'ai-$name');
  expect(error, isNull, reason: 'render exception in $name');
}

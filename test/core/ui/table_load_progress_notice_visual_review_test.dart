import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/table_load_progress_notice.dart';
import 'package:uten_imp/shared/paging/complete_read_progress.dart';

/// 顶部加载进度通知视觉快照：浅色/深色主题下「加载中百分比 / 不定进度 /
/// 完成态」相位冒烟 + 截图（`--dart-define=UI_CAPTURE=true` 时写出，与日期
/// 选择器视觉评审同惯例）。
///
/// 截图阶段套 `disableAnimations`：无限动画（旋转环/扫动光带）运行时
/// `runAsync` 内的 `toImage` 会得到空图层（实验验证），减少动态效果下
/// 细环为固定弧段、光带停驻，仍能完整核对卡片视觉。
void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  Future<void> stage(
    WidgetTester tester, {
    required GlobalKey boundary,
    required bool dark,
    required bool reduceMotion,
    required Future<void> Function() drive,
  }) async {
    final controller = TableLoadProgressNoticeController();
    addTearDown(controller.detach);
    tester.view.physicalSize = const Size(760, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget app = MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
        platform: TargetPlatform.windows,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 24),
            child: TableLoadProgressNoticeHost(controller: controller),
          ),
        ),
      ),
    );
    if (reduceMotion) {
      app = MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: app,
      );
    }
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: app));
    await drive();
    // 旋转环/扫动光带是无限动画，不 pumpAndSettle；定格一帧。
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// 真实文件 IO 必须走 runAsync（fake async 事件环不驱动真实磁盘回调）。
  Future<void> capture(
    WidgetTester tester,
    GlobalKey boundary,
    String name,
  ) async {
    await tester.runAsync(() async {
      final png =
          await (await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2))
              .toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/load-notice-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
    });
  }

  Future<void> driveLoading(
    WidgetTester tester, {
    int total = 1000,
    bool unknown = false,
  }) async {
    final handle = CompleteReadProgressReporter.start();
    await tester.pump();
    handle.update(loaded: unknown ? 130 : 420, total: unknown ? null : total);
    await tester.pump();
    await tester.pump(tableLoadNoticeShowDelay);
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('浅色主题：加载中百分比相位', (tester) async {
    final boundary = GlobalKey();
    await stage(
      tester,
      boundary: boundary,
      dark: false,
      reduceMotion: false,
      drive: () => driveLoading(tester),
    );
    expect(find.textContaining('正在加载数据：42%'), findsOneWidget);
    expect(find.byTooltip('关闭加载提示'), findsOneWidget);
  });

  testWidgets('浅色主题：不定进度相位', (tester) async {
    final boundary = GlobalKey();
    await stage(
      tester,
      boundary: boundary,
      dark: false,
      reduceMotion: false,
      drive: () => driveLoading(tester, unknown: true),
    );
    expect(find.textContaining('正在加载数据…'), findsOneWidget);
  });

  testWidgets('浅色主题：完成相位', (tester) async {
    final boundary = GlobalKey();
    await stage(
      tester,
      boundary: boundary,
      dark: false,
      reduceMotion: false,
      drive: () async {
        final handle = CompleteReadProgressReporter.start();
        await tester.pump();
        handle.update(loaded: 600, total: 600);
        await tester.pump();
        await tester.pump(tableLoadNoticeShowDelay);
        await tester.pump(const Duration(milliseconds: 600));
        handle.finish(succeeded: true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      },
    );
    expect(find.textContaining('数据加载完成：100%'), findsOneWidget);
    expect(find.byKey(const ValueKey('load-notice-done')), findsOneWidget);
  });

  testWidgets('深色主题：加载中百分比相位', (tester) async {
    final boundary = GlobalKey();
    await stage(
      tester,
      boundary: boundary,
      dark: true,
      reduceMotion: false,
      drive: () => driveLoading(tester),
    );
    expect(find.textContaining('正在加载数据：42%'), findsOneWidget);
  });

  // 截图在减少动态效果下定格（见文件头注释），四个相位一次写出。
  testWidgets(
    'UI_CAPTURE：四相位截图（reduceMotion 定格）',
    (tester) async {
      Future<void> shot(
        String name,
        bool dark,
        Future<void> Function() drive,
      ) async {
        final boundary = GlobalKey();
        await stage(
          tester,
          boundary: boundary,
          dark: dark,
          reduceMotion: true,
          drive: drive,
        );
        await capture(tester, boundary, name);
        // 每相位独立宿主：清场后重新搭。
        await tester.pumpWidget(const SizedBox.shrink());
      }

      await shot('light-loading-42', false, () => driveLoading(tester));
      await shot(
        'light-indeterminate',
        false,
        () => driveLoading(tester, unknown: true),
      );
      await shot('light-done', false, () async {
        final handle = CompleteReadProgressReporter.start();
        await tester.pump();
        handle.update(loaded: 600, total: 600);
        await tester.pump();
        await tester.pump(tableLoadNoticeShowDelay);
        await tester.pump(const Duration(milliseconds: 600));
        handle.finish(succeeded: true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      });
      await shot('dark-loading-42', true, () => driveLoading(tester));
    },
    skip: !const bool.fromEnvironment('UI_CAPTURE'),
  );
}

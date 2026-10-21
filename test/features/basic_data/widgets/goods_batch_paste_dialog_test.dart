import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_batch_paste_dialog.dart';

import '../../../support/audit_screenshot_support.dart';

const _copiesKey = Key('goods-batch-paste-copies');
const _confirmKey = Key('goods-batch-paste-confirm');
const _increaseKey = Key('goods-batch-paste-increase');
const _decreaseKey = Key('goods-batch-paste-decrease');

Finder get _copies => find.byKey(_copiesKey);
Finder get _confirm => find.byKey(_confirmKey);

class _DialogResult {
  bool completed = false;
  int? value;
}

Future<_DialogResult> _openDialog(
  WidgetTester tester, {
  int goodsCount = 3,
  Size size = const Size(1000, 760),
  double textScale = 1,
  double appZoom = 1,
  double keyboardHeight = 0,
  bool dark = false,
  bool realFonts = false,
  GlobalKey? screenshotKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (realFonts) await loadAuditScreenshotFonts(tester);
  final result = _DialogResult();
  var theme = dark ? buildDarkTheme() : buildLightTheme();
  if (realFonts) theme = auditScreenshotTheme(theme);
  await tester.pumpWidget(
    RepaintBoundary(
      key: screenshotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: EdgeInsets.only(bottom: keyboardHeight),
          ),
          child: UtenDisplayZoomBox(
            fontFactor: appZoom,
            child: UtenControlTheme(child: child!),
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  unawaited(
                    showGoodsBatchPasteDialog(
                      context,
                      goodsCount: goodsCount,
                    ).then((value) {
                      result.value = value;
                      result.completed = true;
                    }),
                  );
                },
                child: const Text('打开批量粘贴'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开批量粘贴'));
  await tester.pumpAndSettle();
  return result;
}

String _copiesText(WidgetTester tester) =>
    tester.widget<TextField>(_copies).controller!.text;

void main() {
  testWidgets('直接输入份数会实时更新总数并返回输入值', (tester) async {
    final result = await _openDialog(tester);
    await tester.enterText(_copies, '7');
    await tester.pump();
    expect(find.text('预计新增 21 个货品'), findsOneWidget);
    expect(tester.widget<UtenButton>(_confirm).onPressed, isNotNull);
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.value, 7);
    expect(find.byType(GoodsBatchPasteDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('直接输入后加减按钮与输入框和预览保持同步', (tester) async {
    await _openDialog(tester);
    await tester.enterText(_copies, '7');
    await tester.pump();
    await tester.tap(find.byKey(_increaseKey));
    await tester.pump();
    expect(_copiesText(tester), '8');
    expect(find.text('预计新增 24 个货品'), findsOneWidget);
    await tester.tap(find.byKey(_decreaseKey));
    await tester.pump();
    expect(_copiesText(tester), '7');
    expect(find.text('预计新增 21 个货品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加减不会越过1和50的原有范围', (tester) async {
    await _openDialog(tester);
    expect(_copiesText(tester), '1');
    await tester.tap(find.byKey(_decreaseKey));
    await tester.pump();
    expect(_copiesText(tester), '1');
    expect(tester.widget<UtenButton>(_confirm).onPressed, isNotNull);
    await tester.enterText(_copies, '50');
    await tester.pump();
    await tester.tap(find.byKey(_increaseKey));
    await tester.pump();
    expect(_copiesText(tester), '50');
    expect(find.text('预计新增 150 个货品'), findsOneWidget);
    expect(tester.widget<UtenButton>(_confirm).onPressed, isNotNull);
    await tester.tap(find.byKey(_decreaseKey));
    await tester.pump();
    expect(_copiesText(tester), '49');
    expect(tester.takeException(), isNull);
  });

  for (final invalid in ['', '0', '51']) {
    testWidgets('非法份数“$invalid”禁用确认且回车不关闭', (tester) async {
      final result = await _openDialog(tester);
      await tester.enterText(_copies, invalid);
      await tester.pump();
      expect(_copiesText(tester), invalid);
      expect(find.text('请输入 1 到 50 的整数'), findsOneWidget);
      expect(tester.widget<UtenButton>(_confirm).onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(result.completed, isFalse);
      expect(find.byType(GoodsBatchPasteDialog), findsOneWidget);
      await tester.enterText(_copies, '7');
      await tester.pump();
      expect(find.text('请输入 1 到 50 的整数'), findsNothing);
      expect(find.text('预计新增 21 个货品'), findsOneWidget);
      expect(tester.widget<UtenButton>(_confirm).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('小数负数或字母整串被拒绝并保留上个输入值', (tester) async {
    await _openDialog(tester);
    await tester.enterText(_copies, '7');
    await tester.pump();
    for (final invalid in ['1.5', '-2', 'abc', '7a']) {
      await tester.enterText(_copies, invalid);
      await tester.pump();
      expect(_copiesText(tester), '7', reason: '不能将 $invalid 删去字符后当成整数');
      expect(find.text('预计新增 21 个货品'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('有效份数按回车返回当前份数', (tester) async {
    final result = await _openDialog(tester);
    await tester.enterText(_copies, '12');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.value, 12);
    expect(find.byType(GoodsBatchPasteDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final barrierDismiss in [false, true]) {
    testWidgets(barrierDismiss ? '点击遮罩取消返回null' : '取消按钮返回null', (tester) async {
      final result = await _openDialog(tester);
      await tester.enterText(_copies, '7');
      await tester.pump();
      if (barrierDismiss) {
        await tester.tapAt(const Offset(8, 8));
      } else {
        await tester.tap(find.widgetWithText(UtenButton, '取消'));
      }
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.value, isNull);
      expect(find.byType(GoodsBatchPasteDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final layout in [
    (
      name: '320窄屏2倍文字',
      size: const Size(320, 720),
      scale: 2.0,
      keyboard: 0.0,
      dark: false,
    ),
    (
      name: '390窄屏2倍文字深色',
      size: const Size(390, 844),
      scale: 2.0,
      keyboard: 0.0,
      dark: true,
    ),
    (
      name: '横屏键盘',
      size: const Size(640, 360),
      scale: 1.0,
      keyboard: 160.0,
      dark: false,
    ),
    (
      name: '横屏2倍文字深色',
      size: const Size(640, 360),
      scale: 2.0,
      keyboard: 0.0,
      dark: true,
    ),
  ]) {
    testWidgets('${layout.name}无溢出且确认可滚动到达', (tester) async {
      final result = await _openDialog(
        tester,
        size: layout.size,
        textScale: layout.scale,
        keyboardHeight: layout.keyboard,
        dark: layout.dark,
        realFonts: true,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(_copies);
      await tester.enterText(_copies, '7');
      await tester.pumpAndSettle();
      expect(_copiesText(tester), '7');
      expect(find.text('预计新增 21 个货品'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(_confirm);
      await tester.pumpAndSettle();
      expect(_confirm.hitTestable(), findsOneWidget);
      final rect = tester.getRect(_confirm);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(layout.size.width));
      expect(
        rect.bottom,
        lessThanOrEqualTo(layout.size.height - layout.keyboard),
      );
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(result.value, 7);
      expect(result.completed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0]) {
    testWidgets('${width.toInt()}手机实际2倍界面缩放完整显示50并保持编辑', (tester) async {
      final size = Size(width, 844);
      final screenshotKey = GlobalKey();
      final result = await _openDialog(
        tester,
        size: size,
        appZoom: 2,
        realFonts: true,
        screenshotKey: screenshotKey,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(_copies);
      await tester.enterText(_copies, '50');
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(_copies);
      final controller = field.controller!;
      final focusNode = tester
          .widget<EditableText>(
            find.descendant(of: _copies, matching: find.byType(EditableText)),
          )
          .focusNode;
      expect(controller.text, '50');
      expect(focusNode.hasFocus, isTrue);
      final RenderEditable editable = tester
          .state<EditableTextState>(
            find.descendant(of: _copies, matching: find.byType(EditableText)),
          )
          .renderEditable;
      expect(
        editable.maxScrollExtent,
        closeTo(0, 0.01),
        reason: '最大份数50应完整可见，不能依赖输入框横向滚动',
      );

      // Cross the compact/regular layout boundary with an active selection.
      // A responsive rebuild must retain the user's edit and keyboard focus.
      const selection = TextSelection(baseOffset: 0, extentOffset: 2);
      controller.selection = selection;
      await tester.pump();
      tester.view.physicalSize = const Size(1000, 844);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_copies).controller, same(controller));
      expect(tester.widget<TextField>(_copies).focusNode, same(focusNode));
      expect(controller.text, '50');
      expect(controller.selection, selection);
      expect(focusNode.hasFocus, isTrue);
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_copies).controller, same(controller));
      expect(tester.widget<TextField>(_copies).focusNode, same(focusNode));
      expect(controller.selection, selection);
      expect(focusNode.hasFocus, isTrue);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(_decreaseKey));
      await tester.tap(find.byKey(_decreaseKey));
      await tester.pumpAndSettle();
      expect(controller.text, '49');
      await tester.ensureVisible(find.byKey(_increaseKey));
      await tester.tap(find.byKey(_increaseKey));
      await tester.pumpAndSettle();
      expect(controller.text, '50');
      expect(find.text('预计新增 150 个货品'), findsOneWidget);
      if (const bool.fromEnvironment('UTEN_CAPTURE_AUDIT') && width == 390) {
        await tester.ensureVisible(_copies);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await saveAuditScreenshot(
          tester,
          screenshotKey,
          'goods-batch-paste-mobile-zoom',
        );
      }
      await tester.ensureVisible(_confirm);
      await tester.pumpAndSettle();
      expect(_confirm.hitTestable(), findsOneWidget);
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.value, 50);
      expect(tester.takeException(), isNull);
    });
  }

  const capture = bool.fromEnvironment('UTEN_CAPTURE_AUDIT');
  if (capture) {
    for (final variant in [
      (name: 'light', size: const Size(1000, 760), dark: false),
      (name: 'dark', size: const Size(1000, 760), dark: true),
      (name: 'mobile', size: const Size(390, 844), dark: false),
    ]) {
      testWidgets('批量粘贴视觉记录 ${variant.name}', (tester) async {
        final screenshotKey = GlobalKey();
        await _openDialog(
          tester,
          size: variant.size,
          dark: variant.dark,
          realFonts: true,
          screenshotKey: screenshotKey,
        );
        await tester.enterText(_copies, '7');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(
          tester,
          screenshotKey,
          'goods-batch-paste-${variant.name}',
        );
      });
    }
  }
}

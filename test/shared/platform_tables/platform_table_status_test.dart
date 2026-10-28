import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/l10n/platform_table_recovery_text.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_widgets.dart';

const _statusKey = ValueKey('status-slot');
const _tableKey = ValueKey('table-continues');
const _detailsKey = ValueKey('platform-table-read-details');
const _retryKey = ValueKey('platform-table-read-retry');

Future<void> _mount(
  WidgetTester tester, {
  String language = 'zh',
  bool dark = false,
  double width = 280,
  double textScale = 1,
  String? error = '扩展列不存在或不属于当前模块',
  bool loading = false,
  VoidCallback? retry,
}) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: dark ? buildDarkTheme() : buildLightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: _statusKey,
                  child: PlatformTableStatus(
                    error: error,
                    loading: loading,
                    failure: PlatformTableReadFailure.recordsChanged,
                    retry: retry ?? () {},
                  ),
                ),
                const SizedBox(key: _tableKey, height: 44, child: Text('货品名称')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _dialogText(String text) => find.descendant(
  of: find.byType(UtenAlertDialog),
  matching: find.text(text),
);

void main() {
  for (final language in ['zh', 'en', 'ko']) {
    for (final dark in [false, true]) {
      testWidgets(
        '$language narrow status stays within 120px at double text size dark=$dark',
        (tester) async {
          await _mount(
            tester,
            language: language,
            dark: dark,
            width: 120,
            textScale: 2,
          );
          final status = tester.getRect(find.byKey(_statusKey));
          final details = tester.getRect(find.byKey(_detailsKey));
          final retry = tester.getRect(find.byKey(_retryKey));
          expect(details.left, greaterThanOrEqualTo(status.left));
          expect(details.right, lessThanOrEqualTo(status.right));
          expect(retry.right, lessThanOrEqualTo(status.right));
          expect(status.height, lessThanOrEqualTo(64));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final language in ['zh', 'en', 'ko']) {
    for (final textScale in [3.0, 3.5]) {
      for (final dark in [false, true]) {
        testWidgets(
          '$language 280px status accommodates ${textScale}x labels dark=$dark',
          (tester) async {
            await _mount(
              tester,
              language: language,
              dark: dark,
              textScale: textScale,
            );
            final status = tester.getRect(find.byKey(_statusKey));
            final details = tester.getRect(find.byKey(_detailsKey));
            final retry = tester.getRect(find.byKey(_retryKey));
            expect(details.left, greaterThanOrEqualTo(status.left));
            expect(details.right, lessThanOrEqualTo(retry.left));
            expect(retry.right, lessThanOrEqualTo(status.right));
            // UtenButton scales its minimum control extent with system text.
            expect(status.height, lessThanOrEqualTo(36 * textScale + 1));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final language in ['zh', 'en', 'ko']) {
    testWidgets('$language 60px status keeps retry reachable in its dialog', (
      tester,
    ) async {
      var retries = 0;
      await _mount(
        tester,
        language: language,
        width: 60,
        textScale: 2,
        retry: () => retries++,
      );
      expect(find.byKey(_retryKey), findsNothing);
      final status = tester.getRect(find.byKey(_statusKey));
      final details = tester.getRect(find.byKey(_detailsKey));
      expect(details.left, greaterThanOrEqualTo(status.left));
      expect(details.right, lessThanOrEqualTo(status.right));
      await tester.tap(find.byKey(_detailsKey));
      await tester.pumpAndSettle();
      final index = ['zh', 'en', 'ko'].indexOf(language);
      await tester.tap(
        _dialogText(platformTableRecoveryTexts['retry']![index]),
      );
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'long server reasons do not move the table or expand the status',
    (tester) async {
      await _mount(tester, error: '读取失败');
      final shortSize = tester.getSize(find.byKey(_statusKey));
      final tableTop = tester.getTopLeft(find.byKey(_tableKey));
      final longReason = List.generate(
        80,
        (index) => '第$index项：扩展列不存在或不属于当前模块，保留服务端返回的完整说明。',
      ).join('\n');
      await _mount(tester, error: longReason);
      expect(tester.getSize(find.byKey(_statusKey)), shortSize);
      expect(tester.getTopLeft(find.byKey(_tableKey)), tableTop);
      expect(find.text(longReason), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip && widget.message?.contains(longReason) == true,
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(_detailsKey));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == longReason,
        ),
        findsOneWidget,
      );
      final close = _dialogText(platformTableRecoveryTexts['close']!.first);
      expect(tester.getRect(close).bottom, lessThanOrEqualTo(700));
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(_tableKey)), tableTop);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('$kind opens selectable cause and a read-only retry action', (
      tester,
    ) async {
      var retries = 0;
      const reason = '扩展列不存在或不属于当前模块\n请核对列定义 e7c1。';
      await _mount(tester, error: reason, retry: () => retries++);
      final pointer = await tester.createGesture(kind: kind);
      await pointer.down(tester.getCenter(find.byKey(_detailsKey)));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data!.contains(reason),
        ),
        findsOneWidget,
      );
      expect(
        _dialogText(platformTableRecoveryTexts['recordsChanged']!.first),
        findsOneWidget,
      );
      expect(retries, 0);
      await tester.tap(_dialogText(platformTableRecoveryTexts['retry']!.first));
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(find.byKey(_tableKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('keyboard opens details and closes without retrying', (
    tester,
  ) async {
    var retries = 0;
    await _mount(tester, retry: () => retries++);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(UtenAlertDialog), findsOneWidget);
    await tester.tap(_dialogText(platformTableRecoveryTexts['close']!.first));
    await tester.pumpAndSettle();
    expect(find.byType(UtenAlertDialog), findsNothing);
    expect(retries, 0);
    expect(tester.takeException(), isNull);
  });

  for (final width in [120.0, 280.0]) {
    testWidgets('loading disables repeated retry at width $width', (
      tester,
    ) async {
      var retries = 0;
      await _mount(tester, width: width, loading: true, retry: () => retries++);
      final retry = find.byKey(_retryKey);
      final widget = tester.widget(retry);
      if (widget is UtenButton) {
        expect(widget.onPressed, isNull);
        expect(widget.isLoading, isTrue);
      } else {
        expect((widget as IconButton).onPressed, isNull);
      }
      await tester.tap(retry);
      await tester.pump(const Duration(milliseconds: 50));
      expect(retries, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('resolved status gives its space back to the table', (
    tester,
  ) async {
    await _mount(tester);
    expect(tester.getSize(find.byKey(_statusKey)).height, greaterThan(0));
    await _mount(tester, error: null);
    expect(find.byKey(_detailsKey), findsNothing);
    expect(find.byKey(_retryKey), findsNothing);
    expect(tester.getSize(find.byKey(_statusKey)).height, 0);
    expect(tester.getTopLeft(find.byKey(_tableKey)).dy, 0);
    expect(tester.takeException(), isNull);
  });
}

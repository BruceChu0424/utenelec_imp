import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_draft_status_layout.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import '../support/audit_screenshot_support.dart';

Future<GlobalKey?> _mount(
  WidgetTester tester,
  Widget child, {
  bool dark = false,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = const Size(375, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final capture = Platform.environment['UTEN_CAPTURE_DRAFT_STATUS'] == 'true'
      ? GlobalKey()
      : null;
  if (capture != null) await loadAuditScreenshotFonts(tester);
  final theme = dark ? buildDarkTheme() : buildLightTheme();
  await tester.pumpWidget(
    RepaintBoundary(
      key: capture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: capture == null ? theme : auditScreenshotTheme(theme),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return capture;
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'long draft error is scrollable and keyboard retry stays reachable dark=$dark',
      (tester) async {
        final gate = Completer<void>();
        var retries = 0;
        final status = List.filled(20, '本机保存失败，原输入仍保留。').join();
        final capture = await _mount(
          tester,
          UtenDraftStatusLayout(
            status: status,
            isError: true,
            onRetry: () async {
              retries++;
              await gate.future;
            },
            child: Scaffold(
              body: const SingleChildScrollView(child: Text('业务内容')),
              bottomNavigationBar: FilledButton(
                key: const Key('business'),
                onPressed: () {},
                child: const Text('业务保存'),
              ),
            ),
          ),
          dark: dark,
          keyboard: 220,
        );
        final retry = find.byKey(const Key('form-draft-save-retry'));
        final retryRect = tester.getRect(retry);
        expect(retryRect.bottom, lessThanOrEqualTo(348));
        expect(retryRect.height, greaterThanOrEqualTo(44));
        if (capture != null) {
          await saveAuditScreenshot(
            tester,
            capture,
            'draft-status-keyboard-375-${dark ? 'dark' : 'light'}',
          );
        }
        expect(
          retryRect.overlaps(tester.getRect(find.byKey(const Key('business')))),
          isFalse,
        );
        final statusScroll = find.descendant(
          of: find.byKey(const Key('form-draft-status-bar')),
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(statusScroll).position;
        expect(position.maxScrollExtent, greaterThan(0));
        await tester.drag(statusScroll, const Offset(0, -100));
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(0));
        // Both native keyboard and pointer paths use the same in-flight guard.
        for (var index = 0; index < 8 && retries == 0; index++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
        }
        expect(retries, 1, reason: 'Retry must be keyboard reachable');
        await tester.tap(retry);
        await tester.pump();
        expect(retries, 1);
        gate.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('draft footer works with a shrink-wrapped scroll parent', (
    tester,
  ) async {
    await _mount(
      tester,
      const Scaffold(
        body: SingleChildScrollView(
          child: UtenDraftStatusLayout(
            status: '已保存',
            isError: false,
            child: SizedBox(height: 120, child: Text('弹层内容')),
          ),
        ),
      ),
    );
    expect(find.text('已保存'), findsOneWidget);
    expect(
      tester.getRect(find.text('已保存')).top,
      greaterThanOrEqualTo(tester.getRect(find.byType(SizedBox).first).top),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'dialog actions remain reachable alongside draft error and keyboard',
    (tester) async {
      var saved = false;
      await _mount(
        tester,
        UtenDraftStatusLayout(
          status: '草稿保存失败，请重试',
          isError: true,
          onRetry: () async {},
          child: AlertDialog(
            title: const Text('编辑资料'),
            content: const SingleChildScrollView(child: Text('输入内容')),
            actions: [
              TextButton(
                onPressed: () => saved = true,
                child: const Text('完成编辑'),
              ),
            ],
          ),
        ),
        keyboard: 180,
      );
      await tester.tap(find.text('完成编辑'));
      expect(saved, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

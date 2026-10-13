import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template_download_button.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('UI_CAPTURE')) {
      await (FontLoader(
        'NotoSansSC',
      )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    }
  });
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final factor in [0.85, 1.0, 1.3, 2.0]) {
      testWidgets('$platform controls retain target geometry at $factor', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var pressed = 0;
        await tester.pumpWidget(
          _host(
            platform: platform,
            factor: factor,
            home: Scaffold(
              body: Center(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    UtenButton(
                      key: const Key('uten-action'),
                      onPressed: () => pressed++,
                      child: const Text('保存'),
                    ),
                    FilledButton(
                      key: const Key('native-action'),
                      onPressed: () => pressed++,
                      child: const Text('提交'),
                    ),
                    TextButton(
                      key: const Key('short-native-action'),
                      onPressed: () => pressed++,
                      child: const Text('I'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final custom = tester.getRect(find.byKey(const Key('uten-action')));
        final native = tester.getRect(find.byKey(const Key('native-action')));
        final short = tester.getRect(
          find.byKey(const Key('short-native-action')),
        );
        if (platform == TargetPlatform.android) {
          expect(custom.height, greaterThanOrEqualTo(48));
          expect(native.height, greaterThanOrEqualTo(48));
          expect(short.width, greaterThanOrEqualTo(48));
          expect(short.height, greaterThanOrEqualTo(48));
        } else if (factor == 1) {
          expect(custom.height, 40);
        }
        await tester.tap(find.byKey(const Key('uten-action')));
        await tester.tap(find.byKey(const Key('native-action')));
        expect(pressed, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final size in [
    const Size(320, 640),
    const Size(1280, 720),
    const Size(640, 320),
  ]) {
    for (final factor in [1.0, 1.5, 2.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          'long dialog $size $factor dark=$dark keeps actions and values',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            var result = false;
            final capture = GlobalKey();
            await tester.pumpWidget(
              _host(
                factor: factor,
                dark: dark,
                captureKey: capture,
                home: RepaintBoundary(
                  child: Scaffold(
                    body: Builder(
                      builder: (context) => Center(
                        child: UtenButton(
                          onPressed: () async {
                            result =
                                await UtenDialog.show(
                                  context,
                                  title: '核对本次操作',
                                  content: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        '数量 12345.6789 · 金额 9876543.21',
                                      ),
                                      for (var i = 0; i < 25; i++)
                                        Text('第 ${i + 1} 项来源与数量需要核对'),
                                    ],
                                  ),
                                ) ??
                                false;
                          },
                          child: const Text('打开'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('打开'));
            await tester.pumpAndSettle();
            expect(find.text('数量 12345.6789 · 金额 9876543.21'), findsOneWidget);
            final scrollCue = find.descendant(
              of: find.byType(UtenAlertDialog),
              matching: find.byType(Scrollbar),
            );
            expect(scrollCue, findsOneWidget);
            expect(tester.widget<Scrollbar>(scrollCue).thumbVisibility, isTrue);
            final confirm = find.text('确认');
            await tester.ensureVisible(confirm);
            await tester.pumpAndSettle();
            final rect = tester.getRect(confirm);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(size.width + 0.5));
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(size.height + 0.5));
            expect(tester.takeException(), isNull);
            if (const bool.fromEnvironment('UI_CAPTURE')) {
              await tester.runAsync(() async {
                // The screenshot is a rendered test fixture, never a production
                // business record or a claim about the installed application.
                final boundary = tester.renderObject<RenderRepaintBoundary>(
                  find.byKey(capture),
                );
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final path =
                    '.local-artifacts/ui-review/dialog-${size.width.toInt()}-$factor-${dark ? 'dark' : 'light'}.png';
                final file = File(path);
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            await tester.tap(confirm);
            await tester.pumpAndSettle();
            expect(result, isTrue);
          },
        );
      }
    }
  }

  testWidgets('a long icon button label wraps within a narrow viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var presses = 0;
    await tester.pumpWidget(
      _host(
        factor: 2,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: UtenButton(
                icon: Icons.check,
                onPressed: () => presses++,
                child: const Text('确认下达本次车间任务'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('确认下达本次车间任务'));
    expect(presses, 1);
  });
  testWidgets('an existing flexible label keeps one parent-data owner', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(
        factor: 2,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: UtenButton(
                onPressed: () => calls++,
                child: const Flexible(child: Text('完整业务动作名称')),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('完整业务动作名称'));
    expect(calls, 1);
  });

  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('template picker at 200% $size retains all actions and rows', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(
          factor: 2,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: UtenButton(
                  child: const Text('打开'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => SalesQuoteTemplatePicker(
                      canUpload: true,
                      templates: [
                        for (var i = 0; i < 20; i++)
                          SalesQuoteTemplate(id: '$i', name: '客户报价模板 $i'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('quote-template-19')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quote-template-19')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('quote-template-19')),
            )
            .value,
        isTrue,
      );
      await tester.ensureVisible(find.text('下载所选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载所选'));
      await tester.pumpAndSettle();
      expect(find.byType(SalesQuoteTemplatePicker), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'combined 200% interface and system text keeps keyboard dialog actionable',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      var confirmed = false;
      await tester.pumpWidget(
        _host(
          factor: 2,
          textScaler: const TextScaler.linear(2),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: UtenButton(
                  onPressed: () async {
                    confirmed =
                        await UtenDialog.show(
                          context,
                          title: '提交前核对',
                          content: const Text('来源与数量 12345.6789 保留完整，确认后才执行。'),
                        ) ??
                        false;
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.text('确认'));
      expect(rect.bottom, lessThanOrEqualTo(844 - 280));
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    },
  );
}

Widget _host({
  required Widget home,
  required double factor,
  bool dark = false,
  TargetPlatform platform = TargetPlatform.windows,
  GlobalKey? captureKey,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  scrollBehavior: const UtenScrollBehavior(),
  theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
    platform: platform,
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: RepaintBoundary(
      key: captureKey,
      child: UtenDisplayZoomBox(
        fontFactor: factor,
        child: UtenControlTheme(child: child!),
      ),
    ),
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: home,
);

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/inputs/uten_date_range_button.dart';
import 'package:uten_imp/core/utils/date_range_defaults.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('日期卡片内右侧红色关闭按钮预览', (tester) async {
    final card = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: card,
              child: ColoredBox(
                color: Colors.white,
                child: UtenDateRangeButton(
                  range: recentMonthDateRange(),
                  firstDate: DateTime(2010),
                  lastDate: DateTime(2100),
                  onChanged: (_) {},
                  onClear: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_CAPTURE')) {
      await tester.runAsync(() async {
        final boundary =
            card.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final png = await (await boundary.toImage(
          pixelRatio: 2,
        )).toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/date-picker-review/entry-card.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
      });
    }
  });

  for (final scenario in [
    (name: 'light-wide', size: const Size(1100, 850), dark: false, scale: 1.0),
    (name: 'dark-wide', size: const Size(1100, 850), dark: true, scale: 1.0),
    (name: 'light-narrow', size: const Size(390, 844), dark: false, scale: 1.5),
    (
      name: 'small-large-text',
      size: const Size(320, 600),
      dark: true,
      scale: 2.0,
    ),
  ]) {
    testWidgets('真实字体日期/年份/月份布局 ${scenario.name}', (tester) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: scenario.dark ? buildDarkTheme() : buildLightTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showUtenDateRangePicker(
                      context: context,
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2100),
                      initialDateRange: DateTimeRange(
                        start: DateTime(2026, 3),
                        end: DateTime(2026, 3, 25),
                      ),
                      helpText: '选择库存统计日期范围',
                    ),
                    child: const Text('选择日期'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择日期'));
      await tester.pumpAndSettle();

      Future<void> inspect(String mode) async {
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final png = await (await boundary.toImage()).toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/date-picker-review/${scenario.name}-$mode.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
          });
        }
      }

      await inspect('days');
      await tester.ensureVisible(
        find.byKey(const Key('uten-calendar-month-year')),
      );
      await tester.tap(find.byKey(const Key('uten-calendar-month-year')));
      await tester.pumpAndSettle();
      await inspect('years');
      await tester.tap(find.byKey(const ValueKey<int>(2026)));
      await tester.pumpAndSettle();
      await inspect('months');
      await tester.ensureVisible(
        find.byKey(const ValueKey('uten-calendar-month-8')),
      );
      await tester.tap(find.byKey(const ValueKey('uten-calendar-month-8')));
      await tester.pumpAndSettle();
      expect(find.text('2026年8月'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

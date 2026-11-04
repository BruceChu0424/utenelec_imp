import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/inputs/uten_date_range_button.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
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

  testWidgets('日期范围无图标短文案与工具栏按钮同高预览', (tester) async {
    final card = GlobalKey();
    final viewport = GlobalKey();
    final today = ChinaDateTime.today();
    tester.view.physicalSize = const Size(1440, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: viewport,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: card,
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        UtenDateRangeButton(
                          buttonKey: const Key('date-preview-entry'),
                          range: DateTimeRange(
                            start: today.subtract(const Duration(days: 89)),
                            end: today,
                          ),
                          firstDate: DateTime(2010),
                          lastDate: DateTime(2100),
                          onChanged: (_) {},
                          onClear: () {},
                        ),
                        const SizedBox(width: 8),
                        UtenButton(
                          key: const Key('date-preview-peer'),
                          type: UtenButtonType.secondary,
                          onPressed: () {},
                          child: const Text('重量单位: 自动'),
                        ),
                        const SizedBox(width: 8),
                        UtenButton(onPressed: () {}, child: const Text('下载表格')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('近90天'), findsOneWidget);
    // 2026-11-04 用户口径：清除入口 = 框内红色圆形关闭按钮，不再是文字按钮。
    expect(
      find.byKey(const Key('uten-date-range-clear')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('date-preview-entry'))).height,
      tester.getSize(find.byKey(const Key('date-preview-peer'))).height,
    );
    expect(find.byIcon(Icons.date_range_outlined), findsNothing);
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
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1400, 390));
    await mouse.moveTo(
      tester.getTopLeft(find.byKey(const Key('date-preview-entry'))) +
          const Offset(2, 2),
    );
    await tester.pumpAndSettle();
    if (const bool.fromEnvironment('UI_CAPTURE')) {
      await tester.runAsync(() async {
        final boundary =
            viewport.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final png = await (await boundary.toImage()).toByteData(
          format: ui.ImageByteFormat.png,
        );
        final file = File('build/date-picker-review/tooltip.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
      });
    }
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
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

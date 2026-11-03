import 'package:uten_imp/core/utils/date_range_defaults.dart';
// 全站日期范围选择弹窗的形态与选择契约。
//
// 2026-10-24 重设计后的口径：UtenRadius.dialog 圆角、右上角关闭、右下角
// 「确定」主按钮（无铅笔切换、无「应用」文字钮），起止值归一化为本地
// date-only。选择语义与 Material 一致：首击定起点、再击定终点或重设起点、
// 拖拽扩展区间。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';

Widget _harness({
  required ValueChanged<DateTimeRange?> onPicked,
  DateTime? firstDate,
  DateTime? lastDate,
  DateTimeRange? initialDateRange,
}) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              final picked = await showUtenDateRangePicker(
                context: context,
                firstDate: firstDate ?? DateTime(2020),
                lastDate: lastDate ?? DateTime(2030),
                initialDateRange: initialDateRange,
              );
              onPicked(picked);
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
}

Future<void> _tapDay(WidgetTester tester, int day) async {
  await tester.ensureVisible(find.text('$day'));
  await tester.tap(find.text('$day'));
  await tester.pump();
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('弹窗形态：20 圆角、右上关闭、右下确定、无铅笔无应用', (tester) async {
    DateTimeRange? picked;
    await tester.pumpWidget(_harness(onPicked: (value) => picked = value));
    await _openDialog(tester);

    final dialogMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(UtenDateRangePickerDialog),
            matching: find.byType(Material),
          )
          .first,
    );
    final shape = dialogMaterial.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, UtenRadius.dialogAll);

    final dialogCenter = tester
        .getCenter(find.byType(UtenDateRangePickerDialog))
        .dx;
    final closeCenter = tester.getCenter(find.byTooltip('关闭')).dx;
    final confirmCenter = tester.getCenter(find.text('确定')).dx;
    expect(closeCenter, greaterThan(dialogCenter));
    expect(confirmCenter, greaterThan(dialogCenter));

    expect(find.byIcon(Icons.edit), findsNothing);
    expect(find.text('应用'), findsNothing);

    // 默认最近一个月已选，但打开弹窗不会发布结果。
    final confirmButton = tester.widget<UtenButton>(
      find.ancestor(of: find.text('确定'), matching: find.byType(UtenButton)),
    );
    expect(confirmButton.onPressed, isNotNull);
    expect(picked, isNull);
  });

  testWidgets('点两天再确定：返回本地 date-only 区间', (tester) async {
    DateTimeRange? picked;
    await tester.pumpWidget(_harness(onPicked: (value) => picked = value));
    await _openDialog(tester);
    final now = recentMonthStart();

    await _tapDay(tester, 15);
    await _tapDay(tester, 20);
    await _confirm(tester);

    expect(picked, isNotNull);
    expect(picked!.start, DateTime(now.year, now.month, 15));
    expect(picked!.end, DateTime(now.year, now.month, 20));
    expect(picked!.start.hour, 0);
  });

  testWidgets('单日选择：起点终点同为一天', (tester) async {
    DateTimeRange? picked;
    await tester.pumpWidget(_harness(onPicked: (value) => picked = value));
    await _openDialog(tester);
    final now = recentMonthStart();

    await _tapDay(tester, 15);
    await _confirm(tester);

    expect(picked!.start, DateTime(now.year, now.month, 15));
    expect(picked!.end, picked!.start);
  });

  testWidgets('再击早于起点：重设起点而不是形成倒挂区间', (tester) async {
    DateTimeRange? picked;
    await tester.pumpWidget(_harness(onPicked: (value) => picked = value));
    await _openDialog(tester);
    final now = recentMonthStart();

    await _tapDay(tester, 20);
    await _tapDay(tester, 10);
    await _confirm(tester);

    expect(picked!.start, DateTime(now.year, now.month, 10));
    expect(picked!.end, picked!.start);
  });

  testWidgets('按住拖拽：一次手势扩展出完整区间', (tester) async {
    DateTimeRange? picked;
    await tester.pumpWidget(_harness(onPicked: (value) => picked = value));
    await _openDialog(tester);
    final now = recentMonthStart();

    final from = tester.getCenter(find.text('15'));
    final to = tester.getCenter(find.text('20'));
    final gesture = await tester.startGesture(from);
    await gesture.moveBy(to - from);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await _confirm(tester);

    expect(picked!.start, DateTime(now.year, now.month, 15));
    expect(picked!.end, DateTime(now.year, now.month, 20));
  });

  testWidgets('右上角关闭：取消返回 null', (tester) async {
    DateTimeRange? picked = DateTimeRange(
      start: DateTime(2026),
      end: DateTime(2026, 1, 31),
    );
    await tester.pumpWidget(
      _harness(
        onPicked: (value) => picked = value,
        initialDateRange: DateTimeRange(
          start: DateTime(2026, 3),
          end: DateTime(2026, 3, 31),
        ),
      ),
    );
    await _openDialog(tester);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(find.byType(UtenDateRangePickerDialog), findsNothing);
    expect(picked, isNull);
  });

  testWidgets('初始区间归一化为 date-only，并打开到所在月份', (tester) async {
    DateTimeRange? picked;
    await tester.pumpWidget(
      _harness(
        onPicked: (value) => picked = value,
        initialDateRange: DateTimeRange(
          start: DateTime(2025, 3, 2, 5, 30),
          end: DateTime(2025, 3, 18, 23, 59),
        ),
      ),
    );
    await _openDialog(tester);

    // 打开在初始区间所在月，而不是今天所在月。
    expect(find.text('2025年3月'), findsOneWidget);

    await _confirm(tester);
    expect(picked!.start, DateTime(2025, 3, 2));
    expect(picked!.end, DateTime(2025, 3, 18));
  });

  testWidgets('月导航按 firstDate/lastDate 收边', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      _harness(
        onPicked: (_) {},
        firstDate: DateTime(now.year, now.month),
        lastDate: DateTime(now.year, now.month, 28),
      ),
    );
    await _openDialog(tester);

    IconButton prevButton(Icon icon) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(icon.icon!),
        matching: find.byType(IconButton),
      ),
    );
    expect(prevButton(const Icon(Icons.chevron_left)).onPressed, isNull);
    expect(prevButton(const Icon(Icons.chevron_right)).onPressed, isNull);
  });
  testWidgets('年月标题跨几十年跳选，不改草稿直到选择日期', (tester) async {
    DateTimeRange? picked;
    await tester.pumpWidget(
      _harness(
        firstDate: DateTime(1900),
        lastDate: DateTime(2100),
        initialDateRange: DateTimeRange(
          start: DateTime(2025, 3, 2),
          end: DateTime(2025, 3, 18),
        ),
        onPicked: (value) => picked = value,
      ),
    );
    await _openDialog(tester);
    await tester.tap(find.byKey(const Key('uten-calendar-month-year')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('uten-calendar-years')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<int>(1950)),
      -400,
      scrollable: find.descendant(
        of: find.byKey(const Key('uten-calendar-years')),
        matching: find.byType(Scrollable),
      ),
      maxScrolls: 30,
    );
    await tester.tap(find.byKey(const ValueKey<int>(1950)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('uten-calendar-month-12')),
    );
    await tester.tap(find.byKey(const ValueKey('uten-calendar-month-12')));
    await tester.pumpAndSettle();
    expect(find.text('1950年12月'), findsOneWidget);
    // Browsing a different century does not replace the selected interval.
    await _confirm(tester);
    expect(
      picked,
      DateTimeRange(start: DateTime(2025, 3, 2), end: DateTime(2025, 3, 18)),
    );
  });

  testWidgets('跨年跳选后接续结束日期', (tester) async {
    DateTimeRange? picked;
    await tester.pumpWidget(
      _harness(
        initialDateRange: DateTimeRange(
          start: DateTime(2025, 12),
          end: DateTime(2025, 12, 2),
        ),
        onPicked: (value) => picked = value,
      ),
    );
    await _openDialog(tester);
    await _tapDay(tester, 25);
    await tester.tap(find.byKey(const Key('uten-calendar-month-year')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<int>(2026)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uten-calendar-month-2')));
    await tester.pumpAndSettle();
    await _tapDay(tester, 3);
    await _confirm(tester);
    expect(
      picked,
      DateTimeRange(start: DateTime(2025, 12, 25), end: DateTime(2026, 2, 3)),
    );
  });

  testWidgets('跳选年月仍严格遵守可选年月和日期界限', (tester) async {
    await tester.pumpWidget(
      _harness(
        firstDate: DateTime(2025, 3, 10),
        lastDate: DateTime(2025, 5, 20),
        onPicked: (_) {},
      ),
    );
    await _openDialog(tester);
    await tester.tap(find.byKey(const Key('uten-calendar-month-year')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<int>(2025)));
    await tester.pumpAndSettle();
    TextButton month(int n) =>
        tester.widget(find.byKey(ValueKey('uten-calendar-month-$n')));
    expect(month(2).onPressed, isNull);
    expect(month(6).onPressed, isNull);
    expect(month(3).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('uten-calendar-month-3')));
    await tester.pumpAndSettle();
    final before = tester
        .widget<Text>(find.byKey(const Key('uten-date-selection')))
        .data;
    await _tapDay(tester, 1);
    expect(
      tester.widget<Text>(find.byKey(const Key('uten-date-selection'))).data,
      before,
    );
  });

  testWidgets('反复开关与切换年月，取消不发布选择', (tester) async {
    var applied = 0;
    await tester.pumpWidget(
      _harness(
        onPicked: (value) {
          if (value != null) applied++;
        },
      ),
    );
    for (var i = 0; i < 20; i++) {
      await _openDialog(tester);
      await tester.tap(find.byKey(const Key('uten-calendar-month-year')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('uten-calendar-month-year')));
      await tester.pump();
      await _tapDay(tester, 15);
      await tester.ensureVisible(find.byTooltip('关闭'));
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(applied, 0);
  });

  for (final openStart in [true, false]) {
    testWidgets('开放端切回有限端不会发布隐藏逆序值 start=$openStart', (tester) async {
      UtenDateRangeSelection? result;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  result = await showUtenDateRangeSelectionPicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2030),
                    initialStart: DateTime(2026, 2),
                    initialEnd: DateTime(2026, 2, 28),
                    allowOpenRange: true,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await _openDialog(tester);
      final chip = find.widgetWithText(FilterChip, openStart ? '不限开始' : '不限结束');
      await tester.tap(chip);
      await tester.pump();
      await tester.tap(
        find.byIcon(openStart ? Icons.chevron_left : Icons.chevron_right),
      );
      await tester.pump();
      await _tapDay(tester, 15);
      await tester.tap(chip);
      await tester.pump();
      await _confirm(tester);
      expect(result, isNotNull);
      expect(result!.end!.isBefore(result!.start!), isFalse);
    });
  }

  testWidgets('单日字段也从年月标题跳选并只返回一天', (tester) async {
    DateTime? result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showUtenDatePicker(
                  context: context,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  initialDate: DateTime(2026, 3, 15),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await _openDialog(tester);
    await tester.tap(find.byKey(const Key('uten-calendar-month-year')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<int>(2025)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('uten-calendar-month-12')),
    );
    await tester.tap(find.byKey(const ValueKey('uten-calendar-month-12')));
    await tester.pumpAndSettle();
    await _tapDay(tester, 31);
    await _confirm(tester);
    expect(result, DateTime(2025, 12, 31));
  });
}

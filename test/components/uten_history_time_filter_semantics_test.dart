import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_table_action_scope.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import '../support/filter_segment_tap.dart';

void main() {
  testWidgets(
    'history all re-tap does not clear and an existing range reopens without losing dates',
    (tester) async {
      final value = ValueNotifier(const UtenHistoryTimeValue.none());
      addTearDown(value.dispose);
      final changes = <UtenHistoryTimeValue>[];
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder<UtenHistoryTimeValue>(
              valueListenable: value,
              builder: (_, current, _) => UtenHistoryTimeFilter(
                value: current,
                onChanged: (next) {
                  changes.add(next);
                  value.value = next;
                },
              ),
            ),
          ),
        ),
      );
      await selectFilterSegment(tester, '全部');
      await tester.pumpAndSettle();
      expect(changes, [const UtenHistoryTimeValue.all()]);
      await selectFilterSegment(tester, '全部');
      await tester.pumpAndSettle();
      expect(changes, [const UtenHistoryTimeValue.all()]);
      final original = UtenHistoryTimeValue.range(
        DateTimeRange(
          start: DateTime.utc(2024),
          end: DateTime.utc(2024, 1, 31),
        ),
      );
      value.value = original;
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        await selectFilterSegment(tester, '共31天');
        await tester.pumpAndSettle();
        expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
        final dialog = tester.widget<UtenDateRangePickerDialog>(
          find.byType(UtenDateRangePickerDialog),
        );
        final calendarRange = dialog.initialDateRange!;
        // Material normalizes calendar values to local date-only instances.
        // Compare their wall fields, retaining the domain's UTC date carrier.
        expect(
          DateTimeRange(
            start: ChinaDateTime.dateOnly(calendarRange.start),
            end: ChinaDateTime.dateOnly(calendarRange.end),
          ),
          original.range,
        );
        expect(
          ChinaDateTime.wallTimeToUtc(calendarRange.start),
          DateTime.utc(2023, 12, 31, 16),
        );
        expect(
          ChinaDateTime.wallTimeToUtc(calendarRange.end),
          DateTime.utc(2024, 1, 30, 16),
        );
        await tester.tap(find.byTooltip('关闭').hitTestable());
        await tester.pumpAndSettle();
        expect(value.value, original);
        expect(changes, [const UtenHistoryTimeValue.all()]);
      }
      await selectFilterSegment(tester, '全部');
      await tester.pumpAndSettle();
      expect(value.value, const UtenHistoryTimeValue.all());
      expect(changes, [
        const UtenHistoryTimeValue.all(),
        const UtenHistoryTimeValue.all(),
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'history toolbar keeps normal button height with compact dates and hover details',
    (tester) async {
      final selected = UtenHistoryTimeValue.range(
        DateTimeRange(
          start: DateTime.utc(2024),
          end: DateTime.utc(2024, 1, 31),
        ),
      );
      // 12bc07b99 起工具条内分段控件统一抬到 UtenTableToolbar.controlHeight
      //（40，与桌面工具条 UtenButton 一致）；显式用 ≥840 的桌面宽度钉
      // 「折合日期不高于普通工具条按钮」的原意（默认 800x600 会落进紧凑
      // 呈现，按钮改用 36 紧凑视觉，不构成本断言要保护的口径）。
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: UtenTableActionScope(
              child: Wrap(
                children: [
                  UtenHistoryTimeFilter(value: selected, onChanged: (_) {}),
                  UtenButton(onPressed: () {}, child: const Text('表头设置')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2024-01-01 ~ 2024-01-31'), findsNothing);
      final choose = find
          .ancestor(of: find.text('共31天'), matching: find.byType(Material))
          .first;
      final all = find
          .ancestor(of: find.text('全部'), matching: find.byType(Material))
          .first;
      final settings = find
          .ancestor(of: find.text('表头设置'), matching: find.byType(Material))
          .first;
      expect(tester.getSize(choose).height, tester.getSize(settings).height);
      expect(tester.getSize(all).height, tester.getSize(settings).height);
      expect(tester.getSize(settings).height, 40);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(799, 599));
      await mouse.moveTo(tester.getCenter(choose));
      await tester.pump();
      expect(find.text('2024.01.01-2024.01.31'), findsOneWidget);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(find.byType(UtenDateRangePickerDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabled history controls cannot open or change selection', (
    tester,
  ) async {
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenHistoryTimeFilter(
            value: const UtenHistoryTimeValue.all(),
            enabled: false,
            onChanged: (_) => changes++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择日期'));
    await tester.pumpAndSettle();
    expect(find.byType(UtenDateRangePickerDialog), findsNothing);
    expect(changes, 0);
  });

  testWidgets(
    'history range is compact, icon free, and reveals dates on hover',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: UtenHistoryTimeFilter(
                value: UtenHistoryTimeValue.range(
                  DateTimeRange(
                    start: DateTime.utc(2024),
                    end: DateTime.utc(2024, 1, 31),
                  ),
                ),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      final filter = find.byType(UtenHistoryTimeFilter);
      expect(
        find.descendant(of: filter, matching: find.text('共31天')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.date_range_outlined), findsNothing);
      expect(find.byIcon(Icons.all_inclusive_rounded), findsNothing);
      final dateCell = find
          .ancestor(of: find.text('共31天'), matching: find.byType(InkWell))
          .first;
      final allCell = find
          .ancestor(
            of: find.text('全部').hitTestable(),
            matching: find.byType(InkWell),
          )
          .first;
      expect(tester.getSize(dateCell).height, tester.getSize(allCell).height);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(799, 599));
      await mouse.moveTo(
        tester.getTopLeft(dateCell) +
            Offset(2, tester.getSize(dateCell).height / 2),
      );
      await tester.pump();
      expect(find.text('2024.01.01-2024.01.31'), findsOneWidget);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('2024.01.01-2024.01.31'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('compact history trigger keeps its short label without icons', (
    tester,
  ) async {
    final value = ValueNotifier(
      UtenHistoryTimeValue.range(
        DateTimeRange(
          start: DateTime.utc(2024),
          end: DateTime.utc(2024, 1, 31),
        ),
      ),
    );
    addTearDown(value.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 80,
            child: ValueListenableBuilder(
              valueListenable: value,
              builder: (_, current, _) => UtenHistoryTimeFilter(
                value: current,
                onChanged: (next) => value.value = next,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('共31天').hitTestable(), findsOneWidget);
    expect(
      find.byIcon(Icons.keyboard_arrow_down_rounded).hitTestable(),
      findsNothing,
    );
    await selectFilterSegment(tester, '共31天');
    await tester.pumpAndSettle();
    expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(value.value.range!.start, DateTime.utc(2024));
    expect(value.value.range!.end, DateTime.utc(2024, 1, 31));
    await selectFilterSegment(tester, '全部');
    await tester.pumpAndSettle();
    expect(value.value, const UtenHistoryTimeValue.all());
    expect(find.text('全部').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
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
        await selectFilterSegment(tester, '选择日期');
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
    'history toolbar uses normal button height and keeps date hints out of its label',
    (tester) async {
      final selected = UtenHistoryTimeValue.range(
        DateTimeRange(
          start: DateTime.utc(2024),
          end: DateTime.utc(2024, 1, 31),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
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
          .ancestor(of: find.text('选择日期'), matching: find.byType(Material))
          .first;
      final all = find
          .ancestor(of: find.text('全部'), matching: find.byType(Material))
          .first;
      final settings = find
          .ancestor(of: find.text('表头设置'), matching: find.byType(Material))
          .first;
      expect(tester.getSize(choose).height, tester.getSize(settings).height);
      expect(tester.getSize(all).height, tester.getSize(settings).height);
      await tester.tap(find.byTooltip('2024-01-01 ~ 2024-01-31'));
      await tester.pumpAndSettle();
      expect(find.text('2024-01-01 ~ 2024-01-31'), findsOneWidget);
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
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
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
        await selectFilterSegment(tester, '2024-01-01 ~ 2024-01-31');
        await tester.pumpAndSettle();
        expect(find.byType(DateRangePickerDialog), findsOneWidget);
        final calendarRange = tester
            .widget<DateRangePickerDialog>(find.byType(DateRangePickerDialog))
            .initialDateRange!;
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
        final cancel = find.text('取消').hitTestable();
        if (tester.any(cancel)) {
          await tester.tap(cancel);
        } else {
          await tester.tap(find.byTooltip('关闭').hitTestable());
        }
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
    await tester.tap(find.text('时间段'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsNothing);
    expect(changes, 0);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/features/finance/widgets/finance_date_range_filter.dart';
import 'package:uten_imp/features/report/shared/report_date_range.dart';

void main() {
  Widget app({
    DateTime? from,
    DateTime? to,
    bool open = false,
    double textScale = 1,
    required void Function(DateTime?, DateTime?) changed,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: FinanceDateRangeFilter(
          from: from,
          to: to,
          allowOpenRange: open,
          onChanged: changed,
        ),
      ),
    ),
  );

  testWidgets('quick ranges preserve calendar boundaries and apply once', (
    tester,
  ) async {
    final values = <(DateTime?, DateTime?)>[];
    final today = ChinaDateTime.today();
    await tester.pumpWidget(
      app(
        from: defaultReportFrom(),
        to: today,
        changed: (from, to) => values.add((from, to)),
      ),
    );
    await tester.tap(find.byType(UtenButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上月'));
    await tester.pumpAndSettle();
    expect(values, [
      (
        DateTime.utc(today.year, today.month - 1),
        DateTime.utc(today.year, today.month, 0),
      ),
    ]);

    await tester.tap(find.byType(UtenButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近一月'));
    await tester.pumpAndSettle();
    expect(values.last, (defaultReportFrom(), today));
    expect(values, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'custom range cancel discards draft and invalid interval cannot apply',
    (tester) async {
      final values = <(DateTime?, DateTime?)>[];
      await tester.pumpWidget(
        app(
          from: DateTime.utc(2026, 9),
          to: DateTime.utc(2026, 9, 30),
          changed: (from, to) => values.add((from, to)),
        ),
      );
      await tester.tap(find.byType(UtenButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      tester
          .widget<UtenDateField>(find.byType(UtenDateField).first)
          .onChanged(DateTime(2026, 10));
      await tester.pumpAndSettle();
      expect(find.text('结束日期不能早于开始日期'), findsOneWidget);
      final apply = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '应用'),
      );
      expect(apply.onPressed, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(values, isEmpty);
      expect(find.textContaining('2026-09-01'), findsOneWidget);
    },
  );

  testWidgets(
    'open-ended ranges keep independent endpoints and clear explicitly',
    (tester) async {
      final values = <(DateTime?, DateTime?)>[];
      await tester.pumpWidget(
        app(
          from: DateTime.utc(2026, 9),
          to: DateTime.utc(2026, 9, 30),
          open: true,
          changed: (from, to) => values.add((from, to)),
        ),
      );
      await tester.tap(find.byType(UtenButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清除日期').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(values.single, (null, DateTime.utc(2026, 9, 30)));
      await tester.tap(find.byType(UtenButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除日期'));
      await tester.pumpAndSettle();
      expect(values.last, (null, null));
    },
  );

  testWidgets('range entry and custom editor fit compact large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(
        from: DateTime.utc(2026, 9),
        to: DateTime.utc(2026, 10, 21),
        textScale: 1.5,
        changed: (_, _) {},
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(UtenButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('应用').hitTestable(), findsOneWidget);
  });
}

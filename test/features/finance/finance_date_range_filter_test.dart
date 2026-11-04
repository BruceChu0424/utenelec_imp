import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_date_range_selection_button.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/widgets/finance_date_range_filter.dart';

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

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(
      find
          .descendant(
            of: find.byType(UtenDateRangeSelectionButton),
            matching: find.byType(UtenButton),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
    expect(find.byType(UtenDateField), findsNothing);
    expect(find.byType(MenuAnchor), findsNothing);
  }

  testWidgets('single entry directly applies a calendar range as wall dates', (
    tester,
  ) async {
    final values = <(DateTime?, DateTime?)>[];
    await tester.pumpWidget(
      app(
        from: DateTime.utc(2026, 9),
        to: DateTime.utc(2026, 9, 30),
        changed: (from, to) => values.add((from, to)),
      ),
    );
    await openPicker(tester);
    await tester.tap(find.text('10'));
    await tester.tap(find.text('20'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(values, [(DateTime.utc(2026, 9, 10), DateTime.utc(2026, 9, 20))]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancel discards a draft and repeated opening keeps applied range',
    (tester) async {
      final values = <(DateTime?, DateTime?)>[];
      await tester.pumpWidget(
        app(
          from: DateTime.utc(2026, 9),
          to: DateTime.utc(2026, 9, 30),
          changed: (from, to) => values.add((from, to)),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await openPicker(tester);
        await tester.tap(find.text('10'));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(values, isEmpty);
      }
      await openPicker(tester);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(values.single, (DateTime.utc(2026, 9), DateTime.utc(2026, 9, 30)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open ranges retain one bound and explicitly support clearing both',
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
      await openPicker(tester);
      await tester.tap(find.widgetWithText(FilterChip, '不限开始'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(values.single, (null, DateTime.utc(2026, 9, 30)));
      await openPicker(tester);
      await tester.tap(find.widgetWithText(FilterChip, '不限开始'));
      await tester.tap(find.widgetWithText(FilterChip, '不限结束'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(values.last, (null, null));
    },
  );

  testWidgets('entry and calendar fit narrow screens with large text', (
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
    await openPicker(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('确定').hitTestable(), findsOneWidget);
  });
}

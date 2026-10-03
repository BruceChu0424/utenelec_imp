import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/features/finance/widgets/finance_receipt_totals.dart';

FinanceGridRow _row(String amount, String rate) =>
    FinanceGridRow(mode: ItemMode.settle)
      ..amount.text = amount
      ..exchangeRate.text = rate;

Widget _app(
  UtenEditableGridController<FinanceGridRow> controller, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: Scaffold(
    body: Builder(
      builder: (context) => Localizations.override(
        context: context,
        locale: const Locale('zh'),
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: FinanceReceiptTotals(controller: controller),
        ),
      ),
    ),
  ),
);

UtenTotalsSummaryBar _bar(WidgetTester tester) =>
    tester.widget<UtenTotalsSummaryBar>(find.byType(UtenTotalsSummaryBar));

void main() {
  testWidgets(
    'sums full 24 by 6 decimal products without a floating point round trip',
    (tester) async {
      final controller = UtenEditableGridController<FinanceGridRow>(
        initial: [
          _row('90071992547409.910000000000000000000001', '1.000001'),
          _row('0.000000000000000000000009', '0.000001'),
        ],
      );
      await tester.pumpWidget(_app(controller));
      expect(_bar(tester).rowCount, 2);
      expect(_bar(tester).density, isTrue);
      expect(_bar(tester).entries, hasLength(1));
      expect(_bar(tester).entries.single.label, '合计金额(人民币)');
      expect(_bar(tester).entries.single.danger, isTrue);
      expect(
        _bar(tester).entries.single.value,
        '90072082619402.45740991000000000000000100001',
      );
      expect(find.text('2 行'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'edits, added rows, disposed rows and replacements rebind exact totals',
    (tester) async {
      final first = _row('0.1', '0.2');
      final controller = UtenEditableGridController<FinanceGridRow>(
        initial: [first],
      );
      await tester.pumpWidget(_app(controller));
      expect(find.text('0.02'), findsOneWidget);

      controller.addRow(_row('0.2', '0.2'));
      await tester.pump();
      expect(find.text('0.06'), findsOneWidget);
      expect(_bar(tester).rowCount, 2);

      first.exchangeRate.text = '0.3';
      await tester.pump();
      expect(find.text('0.07'), findsOneWidget);
      controller.removeAt(0);
      await tester.pump();
      expect(find.text('0.04'), findsOneWidget);
      controller.rows.single.amount.text = '0.3';
      await tester.pump();
      expect(find.text('0.06'), findsOneWidget);
      controller.replaceAll([_row('2.5', '2')]);
      await tester.pump();
      expect(find.text('5.00'), findsOneWidget);

      controller.removeAt(0);
      await tester.pump();
      expect(_bar(tester).rowCount, 0);
      expect(find.text('合计金额(人民币): '), findsNothing);
      expect(find.text('0.00'), findsNothing);
      controller.addRow(_row('3', '2'));
      await tester.pump();
      expect(find.text('6.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'one missing or invalid conversion hides the total while explicit zero remains visible',
    (tester) async {
      final invalid = _row('', '1');
      final controller = UtenEditableGridController<FinanceGridRow>(
        initial: [_row('3', '2'), invalid],
      );
      await tester.pumpWidget(_app(controller));
      expect(_bar(tester).entries.single.value, '—');
      expect(find.text('2 行'), findsOneWidget);
      expect(find.text('合计金额(人民币): '), findsNothing);
      expect(find.text('6.00'), findsNothing);

      invalid.amount.text = '2';
      invalid.exchangeRate.text = '1e3';
      await tester.pump();
      expect(find.text('合计金额(人民币): '), findsNothing);
      invalid.exchangeRate.text = '1';
      await tester.pump();
      expect(find.text('8.00'), findsOneWidget);

      controller.replaceAll([_row('0', '1')]);
      await tester.pump();
      expect(find.text('0.00'), findsOneWidget);
      expect(find.text('合计金额(人民币): '), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'narrow large text total uses the $brightness error color and shared wrapping',
      (tester) async {
        tester.view.physicalSize = const Size(375, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = UtenEditableGridController<FinanceGridRow>(
          initial: [
            _row('90071992547409.910000000000000000000001', '1.000001'),
          ],
        );
        await tester.pumpWidget(
          _app(controller, brightness: brightness, textScale: 1.5),
        );
        final value = _bar(tester).entries.single.value;
        final amount = tester.widget<Text>(find.text(value));
        final theme = Theme.of(
          tester.element(find.byType(UtenTotalsSummaryBar)),
        );
        expect(amount.style!.color, theme.colorScheme.error);
        expect(amount.style!.fontWeight, FontWeight.w700);
        expect(
          tester.widget<Wrap>(find.byType(Wrap)).alignment,
          WrapAlignment.end,
        );
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}

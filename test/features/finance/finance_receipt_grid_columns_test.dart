import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';

class _Names extends Fake implements FinanceNameService {}

Widget _app(WidgetBuilder builder) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Builder(builder: builder)),
);

void main() {
  for (final expanded in [false, true]) {
    testWidgets(
      'receipt reconciliation=$expanded keeps conversion next to allocation',
      (tester) async {
        final bankReference = TextEditingController();
        addTearDown(bankReference.dispose);
        late List<EditableGridColumn<FinanceGridRow>> columns;
        await tester.pumpWidget(
          _app((context) {
            columns = financeGridColumns(
              ItemMode.settle,
              context: context,
              names: _Names(),
              type: FinanceDocType.receipt,
              showReceiptReconciliation: expanded,
              bankReferenceController: bankReference,
            );
            return const SizedBox();
          }),
        );
        expect(
          columns.map((column) => column.key),
          expanded
              ? [
                  'appliedBillNo',
                  'source',
                  'salesOrderNos',
                  'receivableOriginal',
                  'receivedOriginal',
                  'writtenOffOriginal',
                  'prepaymentAppliedOriginal',
                  'currency',
                  'exchangeRate',
                  'balanceOriginal',
                  'amount',
                  'amountLocal',
                  'balanceAfter',
                  'bankReference',
                  'remark',
                ]
              : [
                  'appliedBillNo',
                  'currency',
                  'balanceOriginal',
                  'amount',
                  'amountLocal',
                  'balanceAfter',
                  'bankReference',
                  'remark',
                ],
        );
        expect(
          columns.singleWhere((column) => column.key == 'amountLocal').label,
          '折算人民币',
        );
        final bank = columns.singleWhere(
          (column) => column.key == 'bankReference',
        );
        expect(bank.label, '银行流水号');
        expect(bank.required, isTrue);
        expect(bank.headerInfo, contains('共用'));
      },
    );
  }

  testWidgets(
    'receipt rows edit one bank reference and row removal preserves its owner',
    (tester) async {
      final bankReference = TextEditingController(text: 'BANK-001');
      final first = FinanceGridRow(mode: ItemMode.settle);
      final second = FinanceGridRow(mode: ItemMode.settle);
      final grid = UtenEditableGridController<FinanceGridRow>(
        initial: [first, second],
      );
      late EditableGridColumn<FinanceGridRow> bank;
      await tester.pumpWidget(
        _app((context) {
          bank = financeGridColumns(
            ItemMode.settle,
            context: context,
            names: _Names(),
            type: FinanceDocType.receipt,
            showReceiptReconciliation: false,
            bankReferenceController: bankReference,
          ).singleWhere((column) => column.key == 'bankReference');
          return ListenableBuilder(
            listenable: grid.rowsListenable,
            builder: (context, _) => Column(
              children: [
                for (final row in grid.rows)
                  KeyedSubtree(
                    key: ObjectKey(row),
                    child: bank.cellBuilder(context, row),
                  ),
              ],
            ),
          );
        }),
      );
      final editors = find.byKey(
        const ValueKey('finance-receipt-bank-reference'),
      );
      expect(editors, findsNWidgets(2));
      expect(bank.listenableOf!(first), same(bankReference));
      expect(bank.listenableOf!(second), same(bankReference));
      await tester.enterText(editors.first, 'BANK-002');
      await tester.pump();
      expect(find.text('BANK-002'), findsNWidgets(2));
      expect(bank.textOf!(second), 'BANK-002');
      await tester.enterText(editors.last, 'BANK-003');
      await tester.pump();
      expect(find.text('BANK-003'), findsNWidgets(2));
      expect(bank.textOf!(first), 'BANK-003');

      grid.removeAt(0);
      await tester.pump();
      expect(editors, findsOneWidget);
      await tester.enterText(editors, 'BANK-004');
      await tester.pump();
      expect(bankReference.text, 'BANK-004');
      expect(bank.textOf!(second), 'BANK-004');
      grid.removeAt(0);
      await tester.pump();
      bankReference.text = 'BANK-005';
      final replacement = FinanceGridRow(mode: ItemMode.settle);
      grid.addRow(replacement);
      await tester.pump();
      expect(find.text('BANK-005'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      grid.dispose();
      bankReference.dispose();
    },
  );

  testWidgets(
    'amount and rate edits update exact converted cell and column measurement',
    (tester) async {
      final row = FinanceGridRow(mode: ItemMode.settle);
      addTearDown(row.dispose);
      late EditableGridColumn<FinanceGridRow> local;
      await tester.pumpWidget(
        _app((context) {
          final columns = financeGridColumns(
            ItemMode.settle,
            context: context,
            names: _Names(),
            type: FinanceDocType.receipt,
            showReceiptReconciliation: false,
          );
          local = columns.singleWhere((column) => column.key == 'amountLocal');
          return Column(
            children: [
              TextField(key: const Key('rate'), controller: row.exchangeRate),
              KeyedSubtree(
                key: const Key('allocation'),
                child: columns
                    .singleWhere((column) => column.key == 'amount')
                    .cellBuilder(context, row),
              ),
              local.cellBuilder(context, row),
            ],
          );
        }),
      );
      final amount = find.descendant(
        of: find.byKey(const Key('allocation')),
        matching: find.byType(TextField),
      );
      final measured = <String>[];
      local.listenableOf!(row)!.addListener(
        () => measured.add(local.textOf!(row)),
      );

      await tester.enterText(find.byKey(const Key('rate')), '1.000001');
      await tester.enterText(amount, '90071992547409.91');
      await tester.pump();
      expect(find.text('90072082619402.45740991'), findsOneWidget);
      expect(measured.last, '90072082619402.45740991');

      await tester.enterText(find.byKey(const Key('rate')), '0.2');
      await tester.pump();
      expect(find.text('18014398509481.982'), findsOneWidget);
      expect(measured.last, '18014398509481.982');

      await tester.enterText(amount, '0.1');
      await tester.pump();
      expect(find.text('0.02'), findsOneWidget);
      expect(measured.last, '0.02');

      for (final invalid in ['', 'abc', '1e3']) {
        await tester.enterText(find.byKey(const Key('rate')), invalid);
        await tester.pump();
        expect(row.localAmountExactNotifier.value, isNull);
        expect(find.text('—'), findsOneWidget);
        expect(local.textOf!(row), '—');
        expect(find.text('0.00'), findsNothing);
      }
      await tester.enterText(find.byKey(const Key('rate')), '1');
      await tester.enterText(amount, '');
      await tester.pump();
      expect(row.localAmountExactNotifier.value, isNull);
      expect(local.textOf!(row), '—');

      await tester.enterText(amount, '0');
      await tester.pump();
      expect(find.text('0.00'), findsOneWidget);
      expect(local.textOf!(row), '0.00');
      expect(tester.takeException(), isNull);
    },
  );
}

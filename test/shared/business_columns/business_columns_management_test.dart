import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/business_columns/business_column_picker.dart';
import 'package:uten_imp/shared/business_columns/business_columns_repository.dart';
import 'package:uten_imp/shared/business_columns/business_columns_row.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

const _packing = BusinessColumn(
  id: 'packing',
  name: '包装费',
  type: 'AMOUNT',
  operation: 'ADD',
  value: '5',
);
const _reference = BusinessColumn(id: 'reference', name: '客户货号', value: 'A01');

class _Repository extends BusinessColumnsRepository {
  _Repository() : super(ApiClient(Dio()));

  @override
  Future<List<BusinessColumn>> search(String scope, String query) async => [];

  @override
  Future<bool> supportsArithmetic(String scope) async => true;
}

Future<void> _openPicker(
  WidgetTester tester, {
  required Iterable<BusinessColumnsRow> rows,
  required VoidCallback onChanged,
  Iterable<BusinessColumnsRow> Function()? currentRows,
  bool priceMasked = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        businessColumnsRepositoryProvider.overrideWithValue(_Repository()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => addBusinessGridColumn<EditableGridRow>(
              context,
              scope: 'sales_order',
              hiddenColumns: const [],
              rows: rows,
              currentRows: currentRows,
              onChanged: onChanged,
              priceMasked: priceMasked,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, BusinessColumnChoice choice) async {
  final context = tester.element(find.byKey(const Key('business-column-name')));
  Navigator.of(context).pop(choice);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  test('removing a fee recalculates sales purchase and subcontract totals', () {
    final sales = SalesGridRow(amountUsesDiscount: true)
      ..qty.text = '2'
      ..price.text = '10'
      ..discount.text = '0.9';
    final purchase = PurchaseGridRow()
      ..qty.text = '2'
      ..price.text = '10';
    final subcontract = SubcontractGridRow()
      ..qty.text = '2'
      ..price.text = '10';
    final cases = [
      (row: sales, total: sales.amountExactNotifier, before: '23', after: '18'),
      (
        row: purchase,
        total: purchase.amountExactNotifier,
        before: '25',
        after: '20',
      ),
      (
        row: subcontract,
        total: subcontract.amountExactNotifier,
        before: '25',
        after: '20',
      ),
    ];
    for (final entry in cases) {
      final row = entry.row as BusinessColumnsRow;
      addTearDown(row.dispose);
      row.addExtraColumn(_packing);
      row.addExtraColumn(_reference);
      expect(financeExactTrimmed(entry.total.value), entry.before);
      var changes = 0;
      row.extraColumnsChanged.addListener(() => changes++);

      expect(row.removeExtraColumn(_packing.id), isTrue);

      expect(financeExactTrimmed(entry.total.value), entry.after);
      expect(changes, 1);
      expect(row.extraColumnsPayload(), [
        {'columnId': 'reference', 'value': 'A01'},
      ]);
      expect(filledBusinessColumnKeys([row]), {'extra:reference'});
      expect(row.extraColumnsPreventMerge, isFalse);
      expect(row.removeExtraColumn(_packing.id), isFalse);
      expect(changes, 1);
    }
  });

  test(
    'removed fields stay absent in drafts copies and newly inherited rows',
    () {
      final row = SalesGridRow()
        ..addExtraColumn(_packing)
        ..addExtraColumn(_reference);
      addTearDown(row.dispose);
      expect(row.removeExtraColumn(_packing.id), isTrue);
      final restored = SalesGridRow.fromDraft(row.exportDraft());
      final copied = row.clone();
      final inherited = inheritBusinessColumns(SalesGridRow(), [row]);
      for (final other in [restored, copied, inherited]) {
        addTearDown(other.dispose);
        expect(other.extraColumnDefinitions.map((column) => column.id), [
          'reference',
        ]);
      }
      expect(restored.extraColumnSnapshots.single.value, 'A01');
      expect(copied.extraColumnSnapshots.single.value, 'A01');
      expect(inherited.extraColumnSnapshots.single.value, '');
      // Reusing a removed definition starts with a fresh operand controller.
      row.addExtraColumn(
        BusinessColumn.fromJson({..._packing.toSnapshot(), 'value': null}),
      );
      expect(row.extraColumnController(_packing).text, '');
    },
  );

  testWidgets(
    'remove applies to every current row and frees the 32-column limit',
    (tester) async {
      final first = SalesGridRow();
      final second = SalesGridRow();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      for (var i = 0; i < 32; i++) {
        final column = BusinessColumn(
          id: 'column-$i',
          name: '信息 $i',
          value: '$i',
        );
        first.addExtraColumn(column);
        second.addExtraColumn(column);
      }
      var changes = 0;
      await _openPicker(
        tester,
        rows: [first, second],
        onChanged: () => changes++,
      );
      await _choose(
        tester,
        const BusinessColumnChoice(removeColumnId: 'column-0'),
      );
      expect(changes, 1);
      expect(first.extraColumnDefinitions, hasLength(31));
      expect(second.extraColumnDefinitions, hasLength(31));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await _choose(tester, const BusinessColumnChoice(column: _packing));
      expect(changes, 2);
      expect(first.extraColumnDefinitions, hasLength(32));
      expect(second.extraColumnDefinitions, hasLength(32));
      expect(first.extraColumnsPayload().last['columnId'], 'packing');
      expect(second.extraColumnsPayload().last['columnId'], 'packing');
    },
  );

  testWidgets(
    'masked users cannot remove financial fields even from a stale choice',
    (tester) async {
      final row = SalesGridRow()
        ..addExtraColumn(_packing)
        ..addExtraColumn(_reference);
      addTearDown(row.dispose);
      var changes = 0;
      await _openPicker(
        tester,
        rows: [row],
        priceMasked: true,
        onChanged: () => changes++,
      );
      await _choose(
        tester,
        const BusinessColumnChoice(removeColumnId: 'packing'),
      );
      expect(changes, 0);
      expect(row.extraColumnDefinitions, hasLength(2));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await _choose(
        tester,
        const BusinessColumnChoice(removeColumnId: 'reference'),
      );
      expect(changes, 1);
      expect(row.extraColumnDefinitions.single.id, 'packing');
    },
  );

  testWidgets(
    'a document refresh while picking uses live rows without touching disposed rows',
    (tester) async {
      final old = SalesGridRow()..addExtraColumn(_packing);
      var live = <BusinessColumnsRow>[old];
      var changes = 0;
      await _openPicker(
        tester,
        rows: List.unmodifiable(live),
        currentRows: () => live,
        onChanged: () => changes++,
      );
      final current = SalesGridRow()..addExtraColumn(_packing);
      final appended = SalesGridRow()..addExtraColumn(_packing);
      addTearDown(current.dispose);
      addTearDown(appended.dispose);
      live = [current, appended];
      old.dispose();

      await _choose(
        tester,
        const BusinessColumnChoice(removeColumnId: 'packing'),
      );

      expect(changes, 1);
      expect(current.extraColumnDefinitions, isEmpty);
      expect(appended.extraColumnDefinitions, isEmpty);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';

void main() {
  testWidgets(
    'supplier header searches the same header fallback shown by the actual cell',
    (tester) async {
      final fallback = PurchaseGridRow();
      final overridden = PurchaseGridRow()..supplierId = 'other';
      final rows = UtenEditableGridController<PurchaseGridRow>(
        initial: [fallback, overridden],
      );
      addTearDown(rows.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final supplier = purchaseGridColumns(
                  (_) async {},
                  context: context,
                  supplierRequired: true,
                  headerSupplierId: 'header',
                  supplierEntries: {'header': '表头供应商', 'other': '另一供应商'},
                ).singleWhere((column) => column.key == 'supplier');
                return ListView(
                  children: [
                    UtenEditableGrid<PurchaseGridRow>(
                      controller: rows,
                      columns: [supplier],
                      showAddRow: false,
                      showRowDelete: false,
                      stickyHeader: false,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('表头供应商'), findsOneWidget);
      expect(find.text('另一供应商'), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GridHeaderFilterCell && widget.label == '供应商',
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '表头',
      );
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('表头供应商'), findsOneWidget);
      expect(find.text('另一供应商'), findsNothing);
      expect(rows.rows, hasLength(2));
      expect(fallback.supplierId, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'physical quantity header uses real charged plus gift input and reacts without dropping source rows',
    (tester) async {
      final first = PurchaseGridRow()
        ..unitId = 'u'
        ..qty.text = '1'
        ..giftQty.text = '2.5';
      final second = PurchaseGridRow()
        ..unitId = 'u'
        ..qty.text = '8';
      final rows = UtenEditableGridController<PurchaseGridRow>(
        initial: [first, second],
      );
      addTearDown(rows.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final physical = purchaseGridColumns(
                  (_) async {},
                  context: context,
                  unitEntries: {'u': '件'},
                ).singleWhere((column) => column.key == 'physicalQty');
                return ListView(
                  children: [
                    UtenEditableGrid<PurchaseGridRow>(
                      controller: rows,
                      columns: [physical],
                      showAddRow: false,
                      showRowDelete: false,
                      stickyHeader: false,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GridHeaderFilterCell && widget.label == '实物数量',
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '>=4',
      );
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('3.5 件'), findsNothing);
      expect(find.text('8 件'), findsOneWidget);
      expect(rows.rows, hasLength(2));
      first.qty.text = '2';
      await tester.pumpAndSettle();
      expect(find.text('4.5 件'), findsOneWidget);
      expect(rows.rows, hasLength(2));
      expect(first.qty.text, '2');
      expect(first.giftQty.text, '2.5');
      expect(tester.takeException(), isNull);
    },
  );
}

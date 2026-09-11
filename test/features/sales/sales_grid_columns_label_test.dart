import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';

Future<List<EditableGridColumn<SalesGridRow>>> _columnsFor(
  WidgetTester tester,
  SalesDocType docType,
) async {
  late final List<EditableGridColumn<SalesGridRow>> columns;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          columns = salesGridColumns(
            context: context,
            onPickGoods: (_) async {},
            docType: docType,
            colorEntries: const {},
            unitEntries: const {},
          );
          return const SizedBox();
        },
      ),
    ),
  );
  return columns;
}

void main() {
  test('销售订单折扣只接受 0 到 1 之间且最多四位小数的普通倍率', () {
    expect(isValidSalesOrderDiscountText('1'), isTrue);
    expect(isValidSalesOrderDiscountText('1.0000'), isTrue);
    expect(isValidSalesOrderDiscountText('0.9'), isTrue);
    expect(isValidSalesOrderDiscountText('0.0001'), isTrue);
    expect(isValidSalesOrderDiscountText('0'), isFalse);
    expect(isValidSalesOrderDiscountText('1.1'), isFalse);
    expect(isValidSalesOrderDiscountText('0.12345'), isFalse);
    expect(isValidSalesOrderDiscountText('NaN'), isFalse);
    expect(isValidSalesOrderDiscountText('1e-1'), isFalse);
  });

  test('复制订单行不会把既有冻结价冒充新行当前价，重新选货品可安全恢复', () {
    final original = SalesGridRow(amountUsesDiscount: true)
      ..goods = const GoodsOption(id: 'goods-a', name: '货品 A');
    original.price.text = '12.50';
    original.discount.text = '0.8';

    final copied = original.clone(requireOrderPriceRefresh: true);
    expect(copied.price.text, isEmpty);
    expect(copied.requiresOrderPriceRefresh, isTrue);
    expect(copied.discount.text, '0.8');

    copied.applyLockedPricePreview(13.25);
    expect(copied.price.text, '13.25');
    expect(copied.requiresOrderPriceRefresh, isFalse);

    copied.price.text = '99';
    copied.applyLockedPricePreview(null);
    expect(copied.price.text, isEmpty);
    expect(copied.requiresOrderPriceRefresh, isFalse);

    original.dispose();
    copied.dispose();
  });

  testWidgets('销售单据数量列统一使用“数量”', (tester) async {
    final orderColumns = await _columnsFor(tester, SalesDocType.order);
    final shipmentColumns = await _columnsFor(tester, SalesDocType.shipment);

    expect(
      orderColumns.singleWhere((column) => column.key == 'qty').label,
      '数量',
    );
    expect(
      shipmentColumns.singleWhere((column) => column.key == 'qty').label,
      '数量',
    );
  });

  testWidgets('销售订单单价只读而折扣可编辑并即时重算金额', (tester) async {
    final row = SalesGridRow(amountUsesDiscount: true);
    row.qty.text = '2';
    row.price.text = '10';
    final controller = UtenEditableGridController<SalesGridRow>(initial: [row]);
    addTearDown(controller.dispose);
    late final List<EditableGridColumn<SalesGridRow>> builtColumns;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            child: Builder(
              builder: (context) => UtenEditableGrid<SalesGridRow>(
                controller: controller,
                columns: builtColumns = salesGridColumns(
                  context: context,
                  onPickGoods: (_) async {},
                  docType: SalesDocType.order,
                  colorEntries: const {},
                  unitEntries: const {},
                ),
                showAddRow: false,
                showRowDelete: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final priceField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller == row.price,
    );
    final discountField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller == row.discount,
    );
    expect(tester.widget<TextField>(priceField).readOnly, isTrue);
    expect(tester.widget<TextField>(discountField).readOnly, isFalse);
    // 列说明已上移表头（2026-09-09 口径）：格内不再渲染 ⓘ，断言列头 headerInfo。
    final discountColumn = builtColumns.firstWhere((c) => c.key == 'discount');
    final priceColumn = builtColumns.firstWhere((c) => c.key == 'price');
    expect(discountColumn.headerInfo, contains('0.9'));
    expect(priceColumn.headerInfo, contains('不可在订货单修改'));

    await tester.enterText(discountField, '0.8');
    await tester.pump();

    expect(row.amountNotifier.value, 16);
    expect(find.text('16.00'), findsOneWidget);
  });
}

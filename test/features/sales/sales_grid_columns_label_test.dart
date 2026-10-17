import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
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
  testWidgets(
    'blank quote discount names the field and keeps the finance guidance',
    (tester) async {
      final row = SalesGridRow()..discount.clear();
      addTearDown(row.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  salesGridColumns(
                        context: context,
                        onPickGoods: (_) async {},
                        docType: SalesDocType.quote,
                        colorEntries: const {},
                        unitEntries: const {},
                      )
                      .singleWhere((column) => column.key == 'discount')
                      .cellBuilder(context, row),
            ),
          ),
        ),
      );
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && identical(widget.controller, row.discount),
      );
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).decoration?.hintText, '折扣');
      expect(row.discount.text, isEmpty);
      expect(
        tester.widget<UtenFieldHintIcon>(find.byType(UtenFieldHintIcon)).info,
        contains('财务核价时填写'),
      );
      await tester.enterText(field, '0.8765');
      await tester.pump();
      expect(row.discount.text, '0.8765');
      expect(tester.widget<TextField>(field).controller, same(row.discount));
    },
  );

  testWidgets(
    'client file text and remark keep field placeholders and controllers across AI review styling',
    (tester) async {
      final row = SalesGridRow();
      addTearDown(row.dispose);
      late List<EditableGridColumn<SalesGridRow>> columns;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                columns = salesGridColumns(
                  context: context,
                  onPickGoods: (_) async {},
                  docType: SalesDocType.order,
                  colorEntries: const {},
                  unitEntries: const {},
                );
                return Column(
                  children: [
                    for (final key in [
                      'clientModel',
                      'clientGoodsName',
                      'remark',
                    ])
                      columns
                          .singleWhere((column) => column.key == key)
                          .cellBuilder(context, row),
                  ],
                );
              },
            ),
          ),
        ),
      );
      final fields = {
        'clientModel': row.clientModel,
        'clientGoodsName': row.clientGoodsName,
        'remark': row.remark,
      };
      Finder field(TextEditingController controller) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && identical(widget.controller, controller),
      );
      for (final entry in fields.entries) {
        expect(field(entry.value), findsOneWidget);
        expect(entry.value.text, isEmpty);
        expect(
          tester.widget<TextField>(field(entry.value)).decoration?.hintText,
          columns.singleWhere((column) => column.key == entry.key).label,
        );
        await tester.enterText(field(entry.value), '客户原文 ${entry.key}');
      }
      row.aiFilledNotifier.value = {for (final key in fields.keys) key: '识别原文'};
      await tester.pump();
      for (final entry in fields.entries) {
        expect(
          tester.widget<TextField>(field(entry.value)).controller,
          same(entry.value),
        );
        expect(entry.value.text, '客户原文 ${entry.key}');
        await tester.enterText(field(entry.value), '');
        await tester.pump();
        expect(entry.value.text, isEmpty);
        expect(
          tester.widget<TextField>(field(entry.value)).decoration?.hintText,
          columns.singleWhere((column) => column.key == entry.key).label,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editable empty sales quantity and price identify their fields without inventing zero',
    (tester) async {
      final row = SalesGridRow()..unitId = 'piece';
      row.qty.clear();
      row.price.clear();
      addTearDown(row.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final columns = salesGridColumns(
                  context: context,
                  onPickGoods: (_) async {},
                  docType: SalesDocType.otherShipment,
                  colorEntries: const {},
                  unitEntries: const {'piece': '个'},
                );
                expect(
                  columns.singleWhere((column) => column.key == 'qty').required,
                  isTrue,
                );
                return Column(
                  children: [
                    for (final key in ['qty', 'price'])
                      columns
                          .singleWhere((column) => column.key == key)
                          .cellBuilder(context, row),
                  ],
                );
              },
            ),
          ),
        ),
      );
      Finder field(TextEditingController controller) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && identical(widget.controller, controller),
      );
      expect(
        tester.widget<TextField>(field(row.qty)).decoration?.hintText,
        '数量',
      );
      expect(
        tester.widget<TextField>(field(row.qty)).decoration?.suffixText,
        '个',
      );
      expect(
        tester.widget<TextField>(field(row.price)).decoration?.hintText,
        '单价',
      );
      expect(row.qty.text, isEmpty);
      expect(row.price.text, isEmpty);
      await tester.enterText(field(row.qty), '3.1256');
      await tester.enterText(field(row.price), '0.2501');
      await tester.pump();
      expect(row.qty.text, '3.1256');
      expect(row.price.text, '0.2501');
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(tester.widget<TextField>(discountField).decoration?.hintText, '折扣');
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

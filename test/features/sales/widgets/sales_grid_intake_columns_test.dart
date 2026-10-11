// 报价/订货明细的客户文件字段(ADR-134): 行模型的识别导入、草稿往返、复制; 列定义
// (文件型号/文件品名/文件单价、报价单价锁定与折扣可空、看不到价格时折扣只读)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_apply.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';

const _patchRow = SalesIntakePatchRow(
  goodsId: 'g-1',
  goodsCode: '280235165',
  goodsName: '两开多功能三极插座',
  colorId: 'color-white',
  unitId: 'unit-pcs',
  qty: '1800',
  listPrice: '21',
  discount: '0.95',
  clientModel: 'GZ23/D',
  clientGoodsName: 'DOUBLE 3 PIN SOCKET',
  clientPrice: '19.95',
  intakeLineKey: 'S1R9',
  setNameEn: true,
  reviewReason: '颜色没对上',
);

Future<List<EditableGridColumn<SalesGridRow>>> _columns(
  WidgetTester tester,
  SalesDocType docType, {
  bool showClientPrice = false,
  String? clientFileCurrency,
  bool priceMasked = false,
  Map<String, String> unitEntries = const {},
}) async {
  late List<EditableGridColumn<SalesGridRow>> columns;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          columns = salesGridColumns(
            context: context,
            onPickGoods: (_) async {},
            docType: docType,
            colorEntries: const {},
            unitEntries: unitEntries,
            showClientPrice: showClientPrice,
            clientFileCurrency: clientFileCurrency,
            priceMasked: priceMasked,
          );
          return const SizedBox();
        },
      ),
    ),
  );
  return columns;
}

void main() {
  test('完整销售草稿往返保留精确数量、来源、自身行ID及真实扩展列', () {
    final row = SalesGridRow.fromIntake(_patchRow)
      ..documentItemId = 'own-line'
      ..orderItemId = 'source-order-line'
      ..outItemId = 'source-shipment-line'
      ..unitRateExact = '1.000000123456789'
      ..solution = '换货'
      ..responsible = '物流'
      ..clientNo = 'client-order-19';
    row.qty.text = '9007199254740993.1250';
    row.weight.text = '12.345600';
    row.machiningPrice.text = '0.125000';
    row.circumference.text = '3.25';
    row.inboundQty.text = '2.5000';
    row.materialPrice.text = '4.50';
    row.dieCastPrice.text = '6.70';
    row.remark.text = '逐行保留';
    row.restoreExtraColumns([
      {
        'columnId': 'fee-1',
        'name': '包装费',
        'scope': 'sales_order',
        'type': 'AMOUNT',
        'operation': 'ADD',
        'value': '12.3400',
      },
      {
        'columnId': 'spec-1',
        'name': '客户规格',
        'scope': 'sales_order',
        'type': 'TEXT',
        'operation': 'NONE',
        'value': '包装 A',
      },
    ]);
    final snapshot = row.exportDraft();
    final restored = SalesGridRow.fromDraft(snapshot);
    expect(restored.exportDraft(), snapshot);
    expect(
      filledSalesOptionalColumnKeys([restored]),
      containsAll([
        'clientModel',
        'clientGoodsName',
        'clientPrice',
        'machiningPrice',
        'circumference',
        'inboundQty',
        'materialPrice',
        'dieCastPrice',
        'extra:fee-1',
        'extra:spec-1',
      ]),
    );
    expect(restored.extraColumnsPayload(), [
      {'columnId': 'fee-1', 'value': '12.3400'},
      {'columnId': 'spec-1', 'value': '包装 A'},
    ]);
    row.dispose();
    restored.dispose();
  });

  testWidgets('已撤价草稿不从单元格或固定列暴露旧价且不抹除原始值', (tester) async {
    final row = SalesGridRow.fromIntake(_patchRow)..priceSource = 'FINANCE';
    row.machiningPrice.text = '7.125';
    row.inboundQty.text = '2.0000';
    final before = row.exportDraft();
    final columns = await _columns(
      tester,
      SalesDocType.order,
      priceMasked: true,
      showClientPrice: true,
      unitEntries: const {'unit-pcs': 'PCS'},
    );
    final sensitive = columns
        .where(
          (c) =>
              {'price', 'discount', 'amount', 'machiningPrice'}.contains(c.key),
        )
        .toList();
    expect(sensitive, hasLength(4));
    for (final column in sensitive) {
      expect(column.frozenTextOf!(row), '***', reason: column.key);
    }
    final inbound = columns.singleWhere((c) => c.key == 'inboundQty');
    expect(inbound.label, '进仓数量(历史参考)');
    // 2026-10-10「数量 + 单位」内联口径：进仓数量只读快照按数字排版后跟行单位，
    // 不再原样透出录入文本（行模型原始值仍由 exportDraft 逐字保留，见文末断言）。
    expect(inbound.frozenTextOf!(row), '2 PCS');
    // 客户文件原价按既有服务端合同仍可见，不能误当成系统标价删掉。
    expect(
      columns.singleWhere((c) => c.key == 'clientPrice').frozenTextOf!(row),
      '19.95',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                for (final column in sensitive)
                  SizedBox(
                    width: 220,
                    height: 60,
                    child: column.cellBuilder(context, row),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('***'), findsNWidgets(4));
    expect(find.byType(TextField), findsNothing);
    expect(find.text('财务定价'), findsNothing);
    expect(row.exportDraft(), before);
    await tester.pumpWidget(const SizedBox());
    row.dispose();
  });

  test('识别导入的行: 单价只来自标价, 折扣/文件原文/学习键齐全, 需核对行带黄标', () {
    final row = SalesGridRow.fromIntake(_patchRow);
    expect(row.goods!.id, 'g-1');
    expect(row.goods!.code, '280235165');
    expect(row.price.text, '21');
    expect(row.discount.text, '0.95');
    expect(row.clientModel.text, 'GZ23/D');
    expect(row.clientGoodsName.text, 'DOUBLE 3 PIN SOCKET');
    expect(row.clientPrice, '19.95');
    expect(row.intakeLineKey, 'S1R9');
    expect(row.setNameEn, isTrue);
    expect(row.unitRate, 1);
    expect(row.aiReview, '颜色没对上');
    expect(row.amountExactNotifier.value, isNotNull);

    // 点进输入框(只改光标)不算核对; 改了数量才清黄标。
    row.qty.selection = const TextSelection.collapsed(offset: 1);
    expect(row.aiReview, '颜色没对上');
    row.qty.text = '1900';
    expect(row.aiReview, isNull);
    row.dispose();
  });

  test('组合件拆开的第一行带整套文件单价备注', () {
    final row = SalesGridRow.fromIntake(
      const SalesIntakePatchRow(
        goodsId: 'g-part',
        qty: '50',
        discount: '',
        remark: '组合件 A+B 整套文件单价 25 USD',
      ),
    );
    expect(row.remark.text, '组合件 A+B 整套文件单价 25 USD');
    expect(row.clientPrice, isNull);
    row.dispose();
  });

  testWidgets('复制报价保留议价单价且可编辑；无主档价也可填写', (tester) async {
    final source = SalesGridRow.fromIntake(_patchRow);
    final copy = source.clone();
    source.dispose();
    final unpriced = SalesGridRow.fromIntake(
      const SalesIntakePatchRow(goodsId: 'g-2', qty: '1', discount: ''),
    );
    // 行随表格控制器一起释放。
    final controller = UtenEditableGridController<SalesGridRow>(
      initial: [copy, unpriced],
    );
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(1900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1800,
            child: Builder(
              builder: (context) => UtenEditableGrid<SalesGridRow>(
                controller: controller,
                columns: salesGridColumns(
                  context: context,
                  onPickGoods: (_) async {},
                  docType: SalesDocType.quote,
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
    TextField priceOf(SalesGridRow r) => tester.widget<TextField>(
      find.byWidgetPredicate((w) => w is TextField && w.controller == r.price),
    );
    expect(copy.price.text, '21');
    expect(priceOf(copy).readOnly, isFalse);
    expect(priceOf(unpriced).readOnly, isFalse);
  });

  test('看不到价格/待财务定价的行: 折扣留空', () {
    final masked = SalesGridRow.fromIntake(
      const SalesIntakePatchRow(goodsId: 'g', qty: '1'),
    );
    expect(masked.discount.text, isEmpty);
    expect(masked.price.text, isEmpty);
    expect(masked.aiReview, isNull);
    masked.dispose();
  });

  test('草稿往返保留文件字段、学习标记与黄标; 复制只带文件原文', () {
    final row = SalesGridRow.fromIntake(_patchRow)
      ..clientNo = 'C-9'
      ..priceSource = 'FINANCE'
      ..quoteDiscountLocked = true
      ..userConfirmed = true
      ..prefilledNameEn = 'X';
    final restored = SalesGridRow.fromDraft(row.exportDraft());
    expect(restored.clientModel.text, 'GZ23/D');
    expect(restored.clientGoodsName.text, 'DOUBLE 3 PIN SOCKET');
    expect(restored.clientPrice, '19.95');
    expect(restored.clientNo, 'C-9');
    expect(restored.priceSource, 'FINANCE');
    expect(restored.quoteDiscountLocked, isTrue);
    expect(restored.intakeLineKey, 'S1R9');
    expect(restored.userConfirmed, isTrue);
    expect(restored.setNameEn, isTrue);
    expect(restored.prefilledNameEn, 'X');
    expect(restored.aiReview, '颜色没对上');
    expect(restored.discount.text, '0.95');

    final copy = row.clone(requireOrderPriceRefresh: true);
    expect(copy.clientModel.text, 'GZ23/D');
    expect(copy.clientGoodsName.text, 'DOUBLE 3 PIN SOCKET');
    expect(copy.clientPrice, '19.95');
    expect(copy.intakeLineKey, isNull);
    expect(copy.userConfirmed, isFalse);
    expect(copy.setNameEn, isFalse);
    expect(copy.priceSource, isNull);
    expect(copy.quoteDiscountLocked, isFalse);
    expect(copy.requiresOrderPriceRefresh, isTrue);
    for (final r in [row, restored, copy]) {
      r.dispose();
    }
  });

  testWidgets('报价/订货有文件型号、文件品名; 文件单价列只在有值时出现并带币种', (tester) async {
    final quote = await _columns(tester, SalesDocType.quote);
    final keys = quote.map((c) => c.key).toList();
    expect(keys, containsAll(<String>['clientModel', 'clientGoodsName']));
    expect(keys, isNot(contains('clientPrice')));
    expect(keys.indexOf('clientModel'), keys.indexOf('color') + 1);

    final withPrice = await _columns(
      tester,
      SalesDocType.order,
      showClientPrice: true,
      clientFileCurrency: 'USD',
    );
    final clientPrice = withPrice.singleWhere((c) => c.key == 'clientPrice');
    expect(clientPrice.label, '文件单价(USD)');
    expect(clientPrice.headerInfo, contains('只作核对参考'));

    final shipment = await _columns(tester, SalesDocType.shipment);
    expect(
      shipment.map((c) => c.key),
      isNot(contains('clientModel')),
      reason: '出货沿用订货单, 不录客户文件原文',
    );
  });

  testWidgets('报价: 单价可议价, 折扣列可空(非必填); 订货折扣仍必填', (tester) async {
    final quote = await _columns(tester, SalesDocType.quote);
    final price = quote.singleWhere((c) => c.key == 'price');
    expect(price.required, isFalse);
    expect(price.headerInfo, contains('不改变货品资料'));
    expect(quote.singleWhere((c) => c.key == 'discount').required, isFalse);

    final order = await _columns(tester, SalesDocType.order);
    expect(order.singleWhere((c) => c.key == 'discount').required, isTrue);
    final masked = await _columns(
      tester,
      SalesDocType.order,
      priceMasked: true,
    );
    expect(masked.singleWhere((c) => c.key == 'discount').required, isFalse);
    expect(masked.singleWhere((c) => c.key == 'price').required, isFalse);
  });

  testWidgets('报价单价格可编辑; 看不到价格时折扣只读', (tester) async {
    final row = SalesGridRow.fromIntake(_patchRow)..priceSource = 'FINANCE';
    final masked = SalesGridRow.fromIntake(
      const SalesIntakePatchRow(goodsId: 'g-2', qty: '1'),
    );
    Future<void> pumpGrid(SalesGridRow r, {bool priceMasked = false}) async {
      final controller = UtenEditableGridController<SalesGridRow>(initial: [r]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1800,
              child: Builder(
                builder: (context) => UtenEditableGrid<SalesGridRow>(
                  controller: controller,
                  columns: salesGridColumns(
                    context: context,
                    onPickGoods: (_) async {},
                    docType: SalesDocType.quote,
                    colorEntries: const {},
                    unitEntries: const {},
                    priceMasked: priceMasked,
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
    }

    await tester.binding.setSurfaceSize(const Size(1900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpGrid(row);
    final priceField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller == row.price,
      ),
    );
    expect(priceField.readOnly, isFalse);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller == row.price,
      ),
      '24.50',
    );
    expect(row.price.text, '24.50');
    final discountField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller == row.discount,
      ),
    );
    expect(discountField.readOnly, isFalse);
    // 需要核对的行: 货品格黄框(带原因)。
    expect(
      find.byKey(const ValueKey('sales-goods-ai-review-g-1')),
      findsOneWidget,
    );

    await pumpGrid(masked, priceMasked: true);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.controller == masked.price || w.controller == masked.discount),
      ),
      findsNothing,
    );
    expect(find.byTooltip('保存时自动计算'), findsOneWidget);
  });
}

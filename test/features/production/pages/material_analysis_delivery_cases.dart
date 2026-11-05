part of 'material_analysis_one_table_test.dart';

Map<String, dynamic> _mixedDeliveryTree(Map<String, dynamic> data) {
  final product = Map<String, dynamic>.from(
    (data['products'] as List).first as Map,
  );
  data['products'] = [
    {
      ...product,
      'analysisLineId': 'product-1',
      'rootMaterialLineId': 'delivery-root',
      'deliveryPlan': {
        'version': 1,
        'mode': 'BOM',
        'packaging': 'BULK',
        'bomFingerprint': 'frozen-order-delivery',
        'nodeModes': [
          {
            'path': ['whole'],
            'mode': 'WHOLE',
          },
          {
            'path': ['split'],
            'mode': 'CHILDREN',
          },
        ],
        'processes': [
          {
            'path': ['split', 'laser'],
            'operation': 'LASER',
            'required': true,
          },
        ],
      },
    },
  ];
  Map<String, dynamic> row(
    String id,
    String name,
    double quantity, {
    String? parent,
    int level = 1,
    bool context = false,
    bool frontier = false,
    bool laser = false,
  }) => {
    ..._material(
      line: id,
      name: name,
      confirmed: level == 0 ? 'MAKE' : 'BUY',
      requiredQty: quantity,
      stockQty: 0,
      netShortageQty: quantity,
      nodeRole: level == 0 ? 'ROOT_SUPPLY' : 'BOM_NODE',
      parentLine: parent,
      level: level,
    ),
    'sourceRequiredQty': quantity,
    'deliveryContext': context,
    'deliveryFrontier': frontier,
    'deliveryOperations': [if (laser) 'LASER'],
    'actionable': !context && quantity > 0,
  };
  data['flatMaterials'] = [
    row('delivery-root', '本单散装产品', 0, level: 0, context: true),
    row('whole', '保持整件的模块', 10, parent: 'delivery-root', frontier: true),
    row('whole-reference', '整件内部只读触点', 0, parent: 'whole', level: 2),
    row(
      'split',
      '本单取消组装的功能层',
      0,
      parent: 'delivery-root',
      context: true,
      laser: true,
    ),
    {
      ...row(
        'laser',
        '本单激光散件',
        20,
        parent: 'split',
        level: 2,
        frontier: true,
        laser: true,
      ),
      'goodsId': 'same-delivery-part',
      'goodsCode': 'SYNTHETIC-PART',
    },
    {
      ...row(
        'plain',
        '本单同码普通散件',
        30,
        parent: 'split',
        level: 2,
        frontier: true,
      ),
      'goodsId': 'same-delivery-part',
      'goodsCode': 'SYNTHETIC-PART',
    },
    {
      ...row(
        'other-unit',
        '本单同码不同单位散件',
        2,
        parent: 'split',
        level: 2,
        frontier: true,
        laser: true,
      ),
      'goodsId': 'same-delivery-part',
      'goodsCode': 'SYNTHETIC-PART',
      'unitId': 'unit-box',
      'unitName': '盒',
    },
  ];
  data['supplyActions'] = <Object>[];
  return data;
}

Object _deliveryPresentationRow(WidgetTester tester, String key) {
  final table = _presentationTable(tester);
  return table.items.cast<Object>().singleWhere(
    (row) => _presentationRowKey(table, row) == key,
  );
}

String? _deliveryPresentationValue(WidgetTester tester, Object row) {
  final table = _presentationTable(tester);
  final column = table.columns.singleWhere(
    (column) => column.key == 'deliveryPlan',
  );
  // The real row/callback retain the page library's private generic argument.
  // ignore: avoid_dynamic_calls
  final value = (column as dynamic).value as Function;
  return Function.apply(value, [row]) as String?;
}

void materialDeliveryCases() {
  testWidgets(
    'delivery tree keeps mixed whole/split references and necessary laser visible',
    (tester) async {
      await _pump(tester, mutate: _mixedDeliveryTree);
      final table = _presentationTable(tester);
      final context = _deliveryPresentationRow(tester, 'MATERIAL|split');
      final root = _deliveryPresentationRow(tester, 'PRODUCT|product-1');
      expect(
        _deliveryPresentationValue(tester, context),
        '按下级交付，无需该层组装 · 需激光打印',
      );
      expect(_deliveryPresentationValue(tester, root), contains('含必要激光打印'));
      expect(_presentationRowId(table, context), isNull);
      expect(_presentationRowId(table, root), isNull);
      expect(
        _deliveryPresentationValue(
          tester,
          _deliveryPresentationRow(tester, 'MATERIAL|laser'),
        ),
        '本单交付件 · 需激光打印',
      );
      expect(find.text('整件内部只读触点'), findsWidgets);
      expect(
        _presentationRowId(
          table,
          _deliveryPresentationRow(tester, 'MATERIAL|whole-reference'),
        ),
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('material-bom-search')),
        '本单激光散件',
      );
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      final filtered = _presentationTable(tester);
      expect(
        filtered.items.any(
          (row) =>
              _presentationRowKey(filtered, row as Object) == 'MATERIAL|split',
        ),
        isTrue,
      );
      expect(
        filtered.items.any(
          (row) =>
              _presentationRowKey(filtered, row as Object) == 'MATERIAL|laser',
        ),
        isTrue,
      );
      await tester.enterText(find.byKey(const Key('material-bom-search')), '');
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      expect(
        _deliveryPresentationRow(tester, 'MATERIAL|whole-reference'),
        isNotNull,
      );
      expect(
        requests.where((request) => request.method != 'GET'),
        isEmpty,
        reason:
            'order presentation never mutates engineering BOM or starts processing',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delivery material summary retains required operations without mixing units or sources',
    (tester) async {
      await _pump(tester, mutate: _mixedDeliveryTree);
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      final each = _deliveryPresentationRow(
        tester,
        'AGGREGATE|same-delivery-part|本色|unit-1',
      );
      final box = _deliveryPresentationRow(
        tester,
        'AGGREGATE|same-delivery-part|本色|unit-box',
      );
      expect(_deliveryPresentationValue(tester, each), '本单交付件 · 部分来源需激光打印');
      expect(_deliveryPresentationValue(tester, box), '本单交付件 · 需激光打印');
      expect(
        _deliveryPresentationValue(
          tester,
          _deliveryPresentationRow(tester, 'AGGREGATE|g-split|本色|unit-1'),
        ),
        '含无需组装层（只读来源） · 需激光打印',
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-product')),
      );
      await tester.pumpAndSettle();
      expect(_deliveryPresentationRow(tester, 'MATERIAL|laser'), isNotNull);
      expect(
        _deliveryPresentationRow(tester, 'MATERIAL|whole-reference'),
        isNotNull,
      );
      expect(requests.where((request) => request.method != 'GET'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

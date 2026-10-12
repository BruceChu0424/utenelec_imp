import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/widgets/doc_link_picker.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/models/procurement_quantity.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

Future<List<EditableGridColumn<PurchaseGridRow>>> _columnsWithSource(
  WidgetTester tester,
) async {
  late final List<EditableGridColumn<PurchaseGridRow>> columns;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          columns = purchaseGridColumns(
            (_) async {},
            context: context,
            showSource: true,
          );
          return const SizedBox();
        },
      ),
    ),
  );
  return columns;
}

void main() {
  test(
    'numeric recorded rates keep historical text without changing legacy payload types',
    () {
      final item = PurchaseDocItem.fromJson({'id': 'old', 'unitRate': 2.5});
      expect(item.unitRateText, '2.5');
      expect(item.unitRateExactText, isNull);
      final exact = PurchaseDocItem.fromJson({
        'id': 'new',
        'unitRate': 999999999999,
        'unitRateExact': '999999999999.000001',
      });
      expect(exact.unitRateText, '999999999999.000001');
      expect(exact.unitRateExactText, '999999999999.000001');
    },
  );

  test(
    '18,6 source unit rate survives linked row, clone and draft with its stock quantum',
    () {
      const exact = '999999999999.000001';
      final row = PurchaseGridRow.fromLinked(
        const LinkedItem(
          goodsId: 'g',
          qty: 100,
          unitId: 'u',
          unitRate: 999999999999,
          unitRateText: exact,
        ),
        const GoodsOption(id: 'g', name: 'Goods'),
      );
      final cloned = row.clone();
      final restored = PurchaseGridRow.fromDraft(row.exportDraft());
      for (final value in [row, cloned, restored]) {
        addTearDown(value.dispose);
        expect(value.unitRateText, exact);
        expect(value.unitRateInputValid, isTrue);
        expect(
          financeExactDecimalFromUnits(
            financeExactProductUnits(
              value.qty.text,
              value.recordedUnitRateText,
            )!,
          ),
          '99999999999900.0001',
        );
      }
    },
  );

  test(
    'manual ratio and identity changes clear old exact rates; old drafts remain numeric',
    () {
      final row = PurchaseGridRow()
        ..goods = const GoodsOption(id: 'g', name: 'Goods')
        ..unitId = 'u'
        ..unitRateText = '999999999999.000001';
      addTearDown(row.dispose);
      row.unitRate = 2.5;
      expect(row.unitRateText, isNull);
      expect(row.unitRate, 2.5);
      row.unitRateText = '999999999999.000001';
      row.unitId = 'another-unit';
      expect(row.unitRateText, isNull);
      row.unitRate = 3;
      expect(row.recordedUnitRateText, '3');
      row.unitRateText = '999999999999.000001';
      row.goods = const GoodsOption(id: 'other', name: 'Other');
      expect(row.unitRateText, isNull);
      final old = PurchaseGridRow.fromDraft({
        'goods': {'id': 'g'},
        'unitId': 'u',
        'unitRate': 2.5,
      });
      addTearDown(old.dispose);
      expect(old.unitRateText, isNull);
      expect(old.unitRate, 2.5);
      for (final invalid in ['0', '-1', 'bad', '0.0000001', '1000000000000']) {
        row.unitRateText = invalid;
        expect(row.unitRateInputValid, isFalse, reason: invalid);
      }
    },
  );

  test(
    'typed positive gift enables zero charged amount and updates when gift changes',
    () {
      final row = PurchaseGridRow(supportsTotalInput: true);
      addTearDown(row.dispose);
      row.qty.text = '0';
      row.price.text = '2';
      expect(row.pricing.validate(), contains('必须大于 0'));
      row.giftQty.text = '0.0001';
      expect(row.pricing.amountExact, '0');
      expect(row.pricing.validate(), isNull);
      for (final invalid in ['0', '-1', 'bad', '0.00001']) {
        row.giftQty.text = invalid;
        expect(row.pricing.validate(), contains('必须大于 0'), reason: invalid);
      }
    },
  );

  test('legacy gift annotations never authorize zero charged quantity', () {
    final row = PurchaseGridRow()
      ..quantitySemantics = procurementLegacyQuantity;
    addTearDown(row.dispose);
    row.qty.text = '0';
    row.price.text = '2';
    row.giftQty.text = '1';
    expect(row.physicalQtyText, '0');
    expect(row.pricing.validate(), contains('必须大于 0'));
  });

  test('purchase request item exposes already ordered quantity', () {
    final item = PurchaseDocItem.fromJson({
      'id': 'request-item-1',
      'goodsId': 'goods-1',
      'qty': 10,
      'orderedQty': 4,
    });

    expect(item.orderedQty, 4);
    expect((item.qty ?? 0) - (item.orderedQty ?? 0), 6);
  });

  test('linked purchase row locks source identity and keeps remaining cap', () {
    final row = PurchaseGridRow.fromLinked(
      const LinkedItem(
        goodsId: 'goods-1',
        qty: 6,
        maxQty: 6,
        upstreamItemId: 'request-item-1',
      ),
      const GoodsOption(id: 'goods-1', name: '轴套'),
    );
    addTearDown(row.dispose);

    expect(row.sourceLocked, isTrue);
    expect(row.upstreamItemId, 'request-item-1');
    expect(row.maxQty, 6);
    // 2026-09-24 展示口径去尾随零：上游带入 6.0 显示 "6"。
    expect(row.qty.text, '6');
  });

  testWidgets(
    'order source column surfaces request lineage for imported rows',
    (tester) async {
      final columns = await _columnsWithSource(tester);
      final source = columns.firstWhere((c) => c.key == 'source');
      expect(source.label, '申请来源');

      final row = PurchaseGridRow()
        ..sourceRequestNo = 'CG20260901-001'
        ..sourceRequestId = 'request-1';
      addTearDown(row.dispose);
      expect(source.textOf!(row), 'CG20260901-001');

      // 手动添加的无来源行不显示单号（列内以「—」占位），不参与来源谱系。
      final blank = PurchaseGridRow();
      addTearDown(blank.dispose);
      expect(source.textOf!(blank), '');
    },
  );

  testWidgets(
    'merged row joins multi-source doc nos and exposes jump ids (V463)',
    (tester) async {
      final columns = await _columnsWithSource(tester);
      final source = columns.firstWhere((c) => c.key == 'source');

      final row = PurchaseGridRow.fromLinked(
        const LinkedItem(
          goodsId: 'goods-1',
          qty: 50,
          maxQty: 50,
          upstreamItemId: 'request-item-1',
        ),
        const GoodsOption(id: 'goods-1', name: '轴套'),
      );
      addTearDown(row.dispose);
      row
        ..upstreamItemIds = [
          'request-item-1',
          'request-item-2',
          'request-item-3',
        ]
        ..sourceDocs = const [
          PurchaseSourceRequestRef(
            requestItemId: 'request-item-1',
            requestId: 'request-1',
            billNo: 'CG20260901-001',
          ),
          PurchaseSourceRequestRef(
            requestItemId: 'request-item-2',
            requestId: 'request-2',
            billNo: 'CG20260902-007',
          ),
          PurchaseSourceRequestRef(
            requestItemId: 'request-item-3',
            requestId: 'request-3',
            billNo: 'CG20260903-015',
          ),
        ];

      // 同货品合并行：来源单号顿号连接，任一来源带回申请单 id 即可点开跳转。
      expect(
        source.textOf!(row),
        'CG20260901-001、CG20260902-007、CG20260903-015',
      );
      expect(row.canOpenSourceDocs, isTrue);
      expect(row.upstreamItemIds.length, 3);
    },
  );

  test('detail item parses structured source requests (V463)', () {
    final item = PurchaseDocItem.fromJson({
      'id': 'order-item-1',
      'goodsId': 'goods-1',
      'qty': 50,
      'requestItemId': 'request-item-1',
      'sourceRequests': [
        {
          'requestItemId': 'request-item-1',
          'requestId': 'request-1',
          'billNo': 'CG20260901-001',
        },
        {
          'requestItemId': 'request-item-2',
          'requestId': 'request-2',
          'billNo': 'CG20260902-007',
        },
      ],
    });

    expect(item.sourceRequests.length, 2);
    expect(item.sourceRequests.first.requestItemId, 'request-item-1');
    expect(item.sourceRequests.first.requestId, 'request-1');
    expect(item.sourceRequests[1].billNo, 'CG20260902-007');
    // 历史行/手工行无 sources：空列表不炸。
    final legacy = PurchaseDocItem.fromJson({'id': 'order-item-2'});
    expect(legacy.sourceRequests, isEmpty);
  });
}

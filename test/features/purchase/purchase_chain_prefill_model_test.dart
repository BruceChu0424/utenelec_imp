import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/widgets/doc_link_picker.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

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
    expect(row.qty.text, '6.0');
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

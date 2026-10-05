import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_order_progress.dart';

void main() {
  test(
    'masked order progress keeps quantities but marks commercial facts hidden',
    () {
      final progress = SubcontractOrderProgress.fromJson(const {
        'orderId': 'order-1',
        'items': <Map<String, dynamic>>[],
        'issues': <Map<String, dynamic>>[],
        'receipts': [
          {
            'id': 'receipt-1',
            'totalQty': 8,
            'totalLocal': null,
            'iqcStatus': 'RESOLVED',
            'warehouseStockInStatus': 'PARTIAL_STOCK_IN',
            'iqcPassedBaseQty': 8,
            'warehouseStockedBaseQty': 3,
            'pendingStockInBaseQty': 5,
          },
        ],
        'returns': <Map<String, dynamic>>[],
        'wastes': [
          {'id': 'waste-1', 'totalQty': 2, 'deductAmount': null},
        ],
        'supplierLedger': <Map<String, dynamic>>[],
        'apPostedTotal': null,
        'wasteDeductTotal': null,
        'priceMasked': true,
      });

      expect(progress.priceMasked, isTrue);
      expect(progress.apPostedTotal, 0);
      expect(progress.receipts.single.totalQty, 8);
      expect(progress.receipts.single.totalLocal, isNull);
      expect(
        progress.receipts.single.warehouseStockInStatus,
        'PARTIAL_STOCK_IN',
      );
      expect(progress.receipts.single.iqcPassedBaseQty, 8);
      expect(progress.receipts.single.warehouseStockedBaseQty, 3);
      expect(progress.receipts.single.pendingStockInBaseQty, 5);
      expect(progress.wastes.single.totalQty, 2);
      expect(progress.wastes.single.deductAmount, isNull);
    },
  );

  test('missing warehouse stock-in projection stays unknown', () {
    final progress = SubcontractOrderProgress.fromJson(const {
      'orderId': 'order-missing-stock-in',
      'receipts': [
        {'id': 'receipt-1', 'status': 1, 'iqcStatus': 'RESOLVED'},
      ],
    });

    expect(progress.items, isEmpty);
    expect(progress.receipts.single.warehouseStockInStatus, isNull);
    expect(progress.receipts.single.warehouseStockedBaseQty, isNull);
    expect(progress.receipts.single.pendingStockInBaseQty, isNull);
  });

  test('each order item carries its own server timeline and draw facts', () {
    final progress = SubcontractOrderProgress.fromJson(const {
      'orderId': 'order-2',
      'status': 1,
      'planStatus': 'OPEN',
      'items': [
        {
          'orderItemId': 'item-1',
          'lineNo': 1,
          'goodsCode': 'FG-01',
          'goodsName': '喷涂外壳',
          'unitName': '件',
          'orderQty': 100,
          'materialMode': 'DRAW',
          'drawOpen': true,
          'materialKindCount': 2,
          'readyKindCount': 1,
          'drawnQty': 40,
          'pendingQty': 10,
          'drawableQty': 20,
          'shortQty': 30,
          'returnableQty': 40,
          'receivedQty': 30,
          'qualifiedQty': 28,
          'pendingInspectionQty': 2,
          'stockedQty': 20,
          'settledLossQty': 0,
          'materials': [
            {
              'planItemId': 'plan-b',
              'goodsName': '油漆',
              'unitName': 'kg',
              'perUnitQty': 0.25,
              'requiredQty': 25,
              'sentQty': 10,
              'pendingQty': 2.5,
              'availableQty': 5,
              'drawableQty': 5,
              'shortQty': 7.5,
              'usableQty': 10,
              'state': 'short',
              'supplySources': [
                {'kind': 'purchase', 'docNo': 'PO-001', 'openQty': 7.5},
              ],
            },
          ],
          'timeline': [
            {'key': 'ORDER', 'label': '下单', 'state': 'DONE'},
            {
              'key': 'draw',
              'label': '领料发外',
              'state': 'ACTIVE',
              'detail': '已领 40/100 件',
            },
            {'key': 'RETURN', 'state': 'SOMETHING_NEW'},
            {'key': 'CLOSE', 'label': '结案核销', 'state': 'SKIPPED'},
          ],
        },
      ],
    });

    final item = progress.items.single;
    expect(item.bomMissing, isFalse);
    expect(item.drawOpen, isTrue);
    expect(
      item.drawnQty + item.pendingQty + item.drawableQty + item.shortQty,
      item.orderQty,
    );
    expect(item.returnableQty, 40);
    expect(item.qualifiedQty, 28);
    expect(item.stockedQty, 20);

    final material = item.materials.single;
    expect(material.planItemId, 'plan-b');
    expect(material.perUnitQty, 0.25);
    expect(material.requiredQty, 25);
    expect(material.shortQty, 7.5);
    expect(material.state, 'SHORT');
    expect(material.supplySources.single.kind, 'PURCHASE');
    expect(material.supplySources.single.docNo, 'PO-001');

    expect(item.timeline.map((node) => node.key), [
      'ORDER',
      'DRAW',
      'RETURN',
      'CLOSE',
    ]);
    expect(item.timeline[0].state, SubcontractProgressNodeState.done);
    expect(item.timeline[1].state, SubcontractProgressNodeState.active);
    expect(item.timeline[1].detail, '已领 40/100 件');
    // 不认识的状态按「未开始」显示；缺 label 时按节点 key 补中文名。
    expect(item.timeline[2].state, SubcontractProgressNodeState.pending);
    expect(item.timeline[2].label, '加工回厂');
    expect(item.timeline[3].state, SubcontractProgressNodeState.skipped);
  });

  test('missing BOM items are flagged and carry no frozen materials', () {
    final progress = SubcontractOrderProgress.fromJson(const {
      'orderId': 'order-3',
      'status': 0,
      'items': [
        {
          'orderItemId': 'item-9',
          'goodsName': '组装件',
          'orderQty': 5,
          'materialMode': 'MISSING_BOM',
        },
      ],
    });

    final item = progress.items.single;
    expect(item.bomMissing, isTrue);
    expect(item.materials, isEmpty);
    expect(item.timeline, isEmpty);
    expect(item.drawnQty, 0);
  });

  test('progress widget renders only server timeline nodes', () {
    final source = File(
      'lib/features/subcontract/widgets/subcontract_order_progress.dart',
    ).readAsStringSync();

    // 节点状态由服务端判定；客户端不再从进仓单/出仓单反推时间线。
    expect(source, contains('item.timeline'));
    expect(source, contains("'仓库入库状态待回传'"));
    for (final retired in [
      'flowMode',
      'preparationStatus',
      'materialLines',
      'materialRequired',
      '目标件',
      '内部生产',
      '前置',
      'Perm.',
      'qualityResolved',
      RegExp(r'\bwarehouseStocked\b'),
    ]) {
      expect(source, isNot(contains(retired)), reason: '$retired');
    }
  });
}

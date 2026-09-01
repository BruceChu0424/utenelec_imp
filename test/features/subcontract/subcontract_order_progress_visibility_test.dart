import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_order_progress.dart';

void main() {
  test(
    'masked order progress keeps quantities but marks commercial facts hidden',
    () {
      final progress = SubcontractOrderProgress.fromJson(const {
        'orderId': 'order-1',
        'materialRequired': true,
        'materialLines': <Map<String, dynamic>>[],
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
      expect(progress.receipts.single.totalQty, 8);
      expect(progress.receipts.single.totalLocal, isNull);
      expect(progress.receipts.single.qualityResolved, isTrue);
      expect(progress.receipts.single.warehouseStocked, isFalse);
      expect(progress.receipts.single.iqcPassedBaseQty, 8);
      expect(progress.receipts.single.warehouseStockedBaseQty, 3);
      expect(progress.receipts.single.pendingStockInBaseQty, 5);
      expect(progress.wastes.single.totalQty, 2);
      expect(progress.wastes.single.deductAmount, isNull);
    },
  );

  test('missing warehouse stock-in projection remains fail closed', () {
    final progress = SubcontractOrderProgress.fromJson(const {
      'orderId': 'order-missing-stock-in',
      'receipts': [
        {'id': 'receipt-1', 'status': 1, 'iqcStatus': 'RESOLVED'},
      ],
    });

    expect(progress.receipts.single.qualityResolved, isTrue);
    expect(progress.receipts.single.warehouseStocked, isFalse);
    expect(progress.receipts.single.warehouseStockedBaseQty, isNull);
    expect(progress.receipts.single.pendingStockInBaseQty, isNull);
  });

  test('warehouse completion only accepts the explicit STOCKED status', () {
    final progress = SubcontractOrderProgress.fromJson(const {
      'orderId': 'order-stocked',
      'receipts': [
        {
          'id': 'receipt-1',
          'status': 1,
          'iqcStatus': 'RESOLVED',
          'warehouseStockInStatus': 'STOCKED',
          'iqcPassedBaseQty': 8,
          'warehouseStockedBaseQty': 8,
          'pendingStockInBaseQty': 0,
        },
      ],
    });

    expect(progress.receipts.single.warehouseStocked, isTrue);
  });

  test('progress strip separates quality release from warehouse stock-in', () {
    final source = File(
      'lib/features/subcontract/widgets/subcontract_order_progress.dart',
    ).readAsStringSync();

    expect(source, contains("_Node('品质检验'"));
    expect(source, contains("'仓库确认入仓'"));
    expect(source, contains('receipt.warehouseStocked'));
    expect(source, isNot(contains('品质合格入仓')));
  });

  test('new progress line keeps target-item preparation facts and blocker', () {
    final progress = SubcontractOrderProgress.fromJson(const {
      'orderId': 'order-2',
      'materialRequired': true,
      'materialLines': [
        {
          'planItemId': 'plan-item-2',
          'goodsCode': 'WIP-002',
          'goodsName': '待喷涂总成',
          'flowMode': 'MAKE_THEN_OUTBOUND',
          'preparationStatus': 'WAITING_FQC',
          'plannedQty': 20,
          'preparedQty': 12,
          'readyOutboundQty': 0,
          'issuedQty': 0,
          'remainingQty': 20,
          'blocker': '等待品质检查',
          'allowedActions': ['OPEN_ANALYSIS'],
        },
      ],
      'issues': <Map<String, dynamic>>[],
      'receipts': <Map<String, dynamic>>[],
      'returns': <Map<String, dynamic>>[],
      'wastes': <Map<String, dynamic>>[],
      'supplierLedger': <Map<String, dynamic>>[],
    });

    final line = progress.materialLines.single;
    expect(line.flowMode, 'MAKE_THEN_OUTBOUND');
    expect(line.preparationStatus, 'WAITING_FQC');
    expect(line.preparedQty, 12);
    expect(line.readyOutboundQty, 0);
    expect(line.remainingQty, 20);
    expect(line.blocker, '等待品质检查');
    expect(line.allowedActions, contains('OPEN_ANALYSIS'));
  });
}

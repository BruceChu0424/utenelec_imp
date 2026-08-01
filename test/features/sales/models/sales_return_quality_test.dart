import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_return_quality.dart';

void main() {
  test('parses the V189 projection and derives disposition guards', () {
    final item = SalesReturnQualityItem.fromJson(const {
      'id': 'quality-1',
      'returnId': 'return-1',
      'returnItemId': 'return-item-1',
      'warehouseId': 'warehouse-1',
      'goodsId': 'goods-1',
      'colorId': null,
      'unitId': 'unit-1',
      'unitRate': '2.000000',
      'receivedBaseQty': 20,
      'releasedBaseQty': 4.5,
      'scrappedBaseQty': 1,
      'reworkBaseQty': 0,
      'remainingBaseQty': 14.5,
      'status': 'PARTIAL',
      'receivedAt': '2026-08-01T10:00:00+08:00',
      'updatedAt': '2026-08-01T11:00:00+08:00',
    });

    expect(item.unitRate, 2);
    expect(item.disposedBaseQty, 5.5);
    expect(item.canDispose, isTrue);
    expect(item.blocksDirectReturnReversal, isTrue);
    expect(salesReturnQualityStatusLabel(item.status), '部分处置');
  });

  test('fully disposed projection fails closed for actions', () {
    final item = SalesReturnQualityItem.fromJson(const {
      'id': 'quality-1',
      'returnId': 'return-1',
      'returnItemId': 'return-item-1',
      'warehouseId': 'warehouse-1',
      'goodsId': 'goods-1',
      'unitRate': 1,
      'receivedBaseQty': 10,
      'releasedBaseQty': 10,
      'scrappedBaseQty': 0,
      'reworkBaseQty': 0,
      'remainingBaseQty': 0,
      'status': 'DISPOSED',
    });

    expect(item.canDispose, isFalse);
    expect(item.blocksDirectReturnReversal, isTrue);
  });

  test('unknown status also blocks direct return reversal', () {
    final item = SalesReturnQualityItem.fromJson(const {
      'id': 'quality-1',
      'returnId': 'return-1',
      'returnItemId': 'return-item-1',
      'warehouseId': 'warehouse-1',
      'goodsId': 'goods-1',
      'unitRate': 1,
      'receivedBaseQty': 10,
      'releasedBaseQty': 0,
      'scrappedBaseQty': 0,
      'reworkBaseQty': 0,
      'remainingBaseQty': 10,
      'status': 'FUTURE_STATUS',
    });

    expect(item.canDispose, isFalse);
    expect(item.blocksDirectReturnReversal, isTrue);
    expect(salesReturnQualityStatusLabel(item.status), '未知状态');
  });

  test('malformed quantity is rejected instead of defaulting to zero', () {
    expect(
      () => SalesReturnQualityItem.fromJson(const {
        'id': 'quality-1',
        'returnId': 'return-1',
        'returnItemId': 'return-item-1',
        'warehouseId': 'warehouse-1',
        'goodsId': 'goods-1',
        'unitRate': 1,
        'receivedBaseQty': 'not-a-number',
        'releasedBaseQty': 0,
        'scrappedBaseQty': 0,
        'reworkBaseQty': 0,
        'remainingBaseQty': 0,
        'status': 'PENDING',
      }),
      throwsFormatException,
    );
  });
}

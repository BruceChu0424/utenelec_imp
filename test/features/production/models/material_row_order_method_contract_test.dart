import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_aggregate_order.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

void main() {
  Map<String, dynamic> frozenRequest() => {
    'version': 7,
    'fingerprint': 'frozen-analysis-fingerprint',
    'idempotencyKey': 'unknown-command-original-key',
    'warehouseId': 'main-warehouse',
    'billDate': '2026-11-06',
    'approveNow': false,
    'skipAutoClaim': true,
    'groups': [
      {
        'clientGroupKey': 'original-group',
        'materialLineIds': ['original-source'],
        'route': 'BUY',
        'qty': '1000.000000000000000001',
        'allowPublicExtra': true,
        'safetyQty': '0',
        'sourceRequestedQtyByMaterialLineId': {
          'original-source': '1000.000000000000000001',
        },
      },
    ],
  };

  test('未知旧请求恢复不注入新下单方式或总覆盖语义', () {
    final original = frozenRequest();
    final restored = MaterialAggregateOrderRequest.fromExactJson(
      'analysis-id',
      original,
    );
    expect(restored.toJson(), original);
    expect(restored.groups.single.orderMethod, isNull);
    expect(restored.groups.single.quantityMode, isNull);
    expect(restored.groups.single.skipAutoClaim, isNull);
  });

  test('未知混合请求逐行保留三方式、总覆盖与追加数量原文和原幂等键', () {
    final original = frozenRequest();
    original.remove('skipAutoClaim');
    final group = (original['groups'] as List).single as Map;
    original['groups'] = [
      for (final (index, method)
          in MaterialPreparationOrderMethod.values.indexed)
        {
          ...group,
          'clientGroupKey': 'group-$index',
          'materialLineIds': ['source-$index'],
          'skipAutoClaim': method == MaterialPreparationOrderMethod.orderAll,
          'orderMethod': method.wireName,
          if (index != 2) 'quantityMode': 'COVERAGE_TOTAL',
          'sourceRequestedQtyByMaterialLineId': {
            'source-$index': '1000.000000000000000001',
          },
        },
    ];
    final restored = MaterialAggregateOrderRequest.fromExactJson(
      'analysis-id',
      original,
    );
    expect(restored.toJson(), original);
    expect(
      restored.groups.map((group) => group.orderMethod),
      MaterialPreparationOrderMethod.values,
    );
    expect(restored.groups.last.quantityMode, isNull, reason: '追加维持本次增量语义');
  });

  test('未知请求含无法识别的逐行方式时拒绝恢复，不能丢字段后重放', () {
    final original = frozenRequest();
    ((original['groups'] as List).single as Map)['orderMethod'] =
        'UNRECOGNIZED_FUTURE_METHOD';
    expect(
      () =>
          MaterialAggregateOrderRequest.fromExactJson('analysis-id', original),
      throwsFormatException,
    );
  });

  for (final method in MaterialPreparationOrderMethod.values) {
    test('采购委外与车间请求携带相同逐行方式 ${method.wireName}', () {
      const exact = '1000.000000000000000001';
      final supply = MaterialSupplyQuantityInput(
        materialLineId: 'source',
        qty: 1000,
        qtyExact: exact,
        safetyReplenishmentQty: 0,
        quantityMode: 'COVERAGE_TOTAL',
        orderMethod: method,
      ).toJson();
      final workshop = MaterialAnalysisIssueLine(
        analysisLineId: 'product',
        qty: 1000,
        qtyExact: exact,
        quantityMode: 'COVERAGE_TOTAL',
        orderMethod: method,
      ).toJson();
      for (final input in [supply, workshop]) {
        expect(input['qty'], exact);
        expect(input['orderMethod'], method.wireName);
        expect(input['quantityMode'], 'COVERAGE_TOTAL');
      }
    });
  }
}

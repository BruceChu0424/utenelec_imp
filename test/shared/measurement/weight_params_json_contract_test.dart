// 单重接口回包解析契约 (ADR-135 §7.2): 字段名逐个照服务端 StockWeightController 的 DTO
// (WeightParams / GoodsWeightView / WeightObservationRow / BalanceWeightView), 不认别名。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';

void main() {
  test('params carry the server scale resolution into predictions', () {
    final params = WeightParams.fromJson({
      'key': 'g1|',
      'goodsId': 'g1',
      'basis': 'LEARNED',
      'unitWeightKg': 0.002312,
      'logMean': -6.0696,
      'lotPrior': 0.0004,
      'df': 12,
      'gamma': 0.02,
      'tier': 'GREEN',
      'nInliers': 21,
      'scaleResKg': 0.001,
    });
    expect(params.scaleResKg, 0.001);
    final coarse = params.countFromWeight(0.05)!;
    final fine = WeightParams.fromJson({
      'key': 'g1|',
      'goodsId': 'g1',
      'basis': 'LEARNED',
      'logMean': -6.0696,
      'lotPrior': 0.0004,
      'df': 12,
      'gamma': 0.02,
    }).countFromWeight(0.05)!;
    expect(
      coarse.logHalfWidth,
      greaterThan(fine.logHalfWidth),
      reason: '秤越粗, 称重折算件数的区间越宽',
    );
    expect(
      WeightParams.fromJson({'key': 'k', 'goodsId': 'g'}).scaleResKg,
      WeightPredictor.defaultScaleResKg,
    );
  });

  test('goods detail reads the server profile, rows and outliers', () {
    final detail = GoodsWeightDetail.fromJson({
      'goodsId': 'g1',
      'profile': {
        'exists': true,
        'manualUnitWeightKg': 0.0023,
        'manualActive': true,
        'manualReason': '图纸单重',
        'manualSetBy': '6f1c1d2e-0000-0000-0000-000000000001',
        'manualSetByName': '李四',
        'learningEnabled': true,
        'regimeMode': 'MANUAL',
        'version': 3,
      },
      'resolved': {'key': 'g1|', 'goodsId': 'g1', 'basis': 'MANUAL'},
      'goodsRow': {'unitWeightKg': 0.00231, 'nObs': 5, 'nInliers': 4},
      'supplierRows': [
        {'supplierId': 's1', 'supplierName': '甲五金', 'diffPct': 1.5},
      ],
      'outliers': [
        {'observationId': 'o9', 'z': 4.2, 'hint': 'UNIT_1000'},
      ],
      'counts': {'total': 6, 'active': 5, 'excluded': 1},
    }, goodsId: 'g1');
    final profile = detail.profile!;
    expect(profile.manualActive, isTrue);
    expect(profile.manualSetByName, '李四', reason: '设定人显示姓名, 不回落到人员 id');
    expect(profile.regimeMode, 'MANUAL');
    expect(profile.version, 3);
    expect(detail.resolved!.basis, WeightBasis.manual);
    expect(detail.supplierRows.single.diffPct, 1.5);
    expect(detail.outliers.single.observationId, 'o9');
    expect(detail.counts['excluded'], 1);
  });

  test('observation rows follow WeightObservationRow', () {
    final row = WeightObservation.fromJson({
      'id': 'o1',
      'observedAt': '2026-09-26T02:00:00Z',
      'sourceKind': 'RECEIPT',
      'role': 'REFERENCE',
      'qtyBase': 1000,
      'weightKg': 2.4,
      'unitWeightKg': 0.0024,
      'sourceDocType': 'PURCHASE_RECEIPT',
      'sourceDocId': 'r1',
      'billNo': 'PR-001',
      'sourceDocCleared': true,
      'stage': 'ACTIVE',
      'excludedReason': 'ECHO',
      'outlier': false,
      'status': 'EXCLUDED',
      'recordedByName': '王五',
    });
    expect(row.sourceGone, isTrue);
    expect(row.status, 'EXCLUDED');
    expect(row.excluded, isTrue);
    expect(row.unitWeightKg, 0.0024);
    expect(row.recordedByName, '王五');
    expect(
      WeightObservation.fromJson({
        'id': 'o2',
        'sourceKind': 'SAMPLE',
        'qtyBase': 20,
        'weightKg': 0.05,
        'sourceDocCleared': null,
      }).sourceGone,
      isFalse,
      reason: '来源类型未知 (null) 不算已清空',
    );
  });

  test('balance weight result follows BalanceWeightView', () {
    final result = WeightBalanceSetResult.fromJson({
      'adjustmentId': 'adj-1',
      'warehouseId': 'w1',
      'goodsId': 'g1',
      'colorId': null,
      'qty': 5000,
      'weightKg': 0.85,
      'weightEstimated': false,
    });
    expect(result.adjustmentId, 'adj-1');
    expect(result.qty, 5000);
    expect(result.weightKg, 0.85);
    expect(result.weightEstimated, isFalse);
  });
}

// 单重接口回包解析契约 (ADR-135 §7.2): 字段名逐个照服务端 StockWeightController 的 DTO
// (WeightParams / GoodsWeightView / WeightObservationRow / BalanceWeightView), 不认别名。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';

void main() {
  test('请求行只带结构化身份: 4 个 UUID 齐全也不拼 key (ADR-151)', () {
    // 2026-10-04 实测: 旧契约把 goods|supplier|warehouse|color 拼成 147 字的 key,
    // 服务端限 100 字整批 422。现在每行只发结构化字段, 服务端不再要求 key。
    const uuid = '00000000-0000-0000-0000-000000000000';
    const line = WeightParamsLine(
      goodsId: uuid,
      supplierId: uuid,
      warehouseId: uuid,
      colorId: uuid,
    );
    expect(line.toJson(), {
      'goodsId': uuid,
      'supplierId': uuid,
      'warehouseId': uuid,
      'colorId': uuid,
    });
    const a = WeightParamsLine(
      goodsId: 'g',
      supplierId: 's',
      warehouseId: 'w1',
      colorId: 'red',
    );
    const b = WeightParamsLine(
      goodsId: 'g',
      supplierId: 's',
      warehouseId: 'w2',
      colorId: 'red',
    );
    expect(a.paramsIdentity, b.paramsIdentity, reason: '单重只按 (货品, 供应商)');
    expect(a.balanceIdentity, isNot(b.balanceIdentity), reason: '库存参考按仓库隔离');
  });

  test('响应按身份解析: 单重 items 与库存参考 stockBalances 分开, 行按仓库与颜色接上', () {
    const line = WeightParamsLine(
      goodsId: 'g',
      supplierId: 's',
      warehouseId: 'w',
      colorId: 'red',
    );
    final result = WeightParamsResult(
      params: {
        for (final raw in [
          {'goodsId': 'g', 'supplierId': 's', 'basis': 'NONE'},
        ])
          WeightParams.fromJson(raw).identity: WeightParams.fromJson(raw),
      },
      balances: {
        for (final raw in [
          {
            'warehouseId': 'w',
            'goodsId': 'g',
            'colorId': 'red',
            'qtyBase': 1000,
            'weightKg': 20,
            'estimated': false,
          },
          {
            'warehouseId': 'w',
            'goodsId': 'g',
            'colorId': null,
            'qtyBase': 1000,
            'weightKg': 99,
          },
        ])
          WeightStockBalance.fromJson(raw).identity:
              WeightStockBalance.fromJson(raw),
      },
    );
    final params = result.of(line)!;
    expect(params.supplierId, 's');
    expect(params.stockBalance!.weightKg, 20, reason: '颜色精确匹配, 不拿无色余额');
    expect(
      result
          .of(const WeightParamsLine(goodsId: 'g', supplierId: 's'))!
          .stockBalance,
      isNull,
      reason: '不带仓库就没有库存参考',
    );
    expect(result.paramsOf('g', supplierId: 's'), isNotNull);
    expect(result.paramsOf('g'), isNull, reason: '供应商不同是另一份单重');
  });

  test('同仓色库存余额可在学习前按数量比例给出参考并识别离谱重量', () {
    final params = WeightParams.fromJson({'goodsId': 'g', 'basis': 'NONE'})
        .withStockBalance(
          WeightStockBalance.fromJson({
            'warehouseId': 'w',
            'goodsId': 'g',
            'colorId': 'red',
            'qtyBase': 1000,
            'weightKg': 20,
            'estimated': false,
          }),
        );
    final stock = params.stockBalance!;
    expect(stock.colorId, 'red');
    expect(stock.expectedKgFor(500), 10);
    final suggestion = params.suggestionFor(
      1000,
      mode: WeightCaptureMode.outbound,
    )!;
    expect(suggestion.kg, 20);
    expect(suggestion.differsFrom(1), isTrue);
    expect(suggestion.differsFrom(20.2), isFalse);
    for (final qty in [null, 0.0, -1.0, double.nan, double.infinity]) {
      expect(params.suggestionFor(qty), isNull);
    }
  });

  test('未知或非法库存不估重，入库可信历史优先、出库对应库存优先', () {
    final params =
        WeightParams.fromJson({
          'goodsId': 'g',
          'basis': 'LEARNED',
          'logMean': -6.214608098422191,
          'lotPrior': 0.0004,
          'tier': 'GREEN',
        }).withStockBalance(
          WeightStockBalance.fromJson({
            'warehouseId': 'w',
            'goodsId': 'g',
            'qtyBase': 1000,
            'weightKg': 20,
          }),
        );
    expect(params.suggestionFor(1000)!.kg, closeTo(2, 0.0001));
    expect(
      params.suggestionFor(1000, mode: WeightCaptureMode.outbound)!.kg,
      20,
    );
    for (final weight in [null, 0, -1, 'NaN', 'Infinity']) {
      final unknown = WeightParams.fromJson({'goodsId': 'g'}).withStockBalance(
        WeightStockBalance.fromJson({
          'warehouseId': 'w',
          'goodsId': 'g',
          'qtyBase': 1000,
          'weightKg': weight,
        }),
      );
      expect(unknown.suggestionFor(1000), isNull);
    }
  });

  test('params carry the server scale resolution into predictions', () {
    final params = WeightParams.fromJson({
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
      WeightParams.fromJson({'goodsId': 'g'}).scaleResKg,
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
      'resolved': {'goodsId': 'g1', 'basis': 'MANUAL'},
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
}

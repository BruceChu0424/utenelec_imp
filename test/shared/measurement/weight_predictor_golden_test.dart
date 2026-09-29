// 单重预测金样对拍 (ADR-135 §6.1/§9): Dart WeightPredictor 与服务端 ApwPredictor 必须对
// 同一份金样 (fixtures/predictor_golden.json, 由 apw_proto.py 生成, 服务端测试持有同一份拷贝)
// 算出一样的数。金样文件只读, 不要手改——改公式先改原型再重新生成两边的拷贝。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';

const _fixture = 'test/shared/measurement/fixtures/predictor_golden.json';

Matcher _close(num expected) {
  final e = expected.toDouble();
  return closeTo(e, e.abs() * 1e-9 + 1e-12);
}

void main() {
  final golden =
      jsonDecode(File(_fixture).readAsStringSync()) as Map<String, dynamic>;
  final config = golden['config'] as Map<String, dynamic>;
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();

  test('金样配置与 Dart 常量一致 (gamma / 秤分辨率 / 各来源 eps)', () {
    expect(config['gamma'], WeightPredictor.defaultGamma);
    expect(config['scaleResKg'], WeightPredictor.defaultScaleResKg);
    final eps = (config['eps'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as num).toDouble()),
    );
    expect(
      eps.keys.toSet(),
      WeightSourceKind.values.map((k) => k.code).toSet(),
    );
    for (final kind in WeightSourceKind.values) {
      expect(eps[kind.code], kind.eps, reason: kind.code);
    }
    expect(cases, isNotEmpty);
  });

  for (final c in cases) {
    final name = c['name'] as String;
    final params = c['params'] as Map<String, dynamic>;
    final logMean = (params['logMean'] as num).toDouble();
    final lotPrior = (params['lotPrior'] as num).toDouble();
    final df = (params['df'] as num).toDouble();
    final expectMap = c['expect'] as Map<String, dynamic>;

    test('金样 $name', () {
      switch (c['op']) {
        case 'count':
          final rawSample = c['sample'] as Map<String, dynamic>?;
          final sample = rawSample == null
              ? null
              : WeightSampleInput(
                  qty: (rawSample['qty'] as num).toDouble(),
                  weightKg: (rawSample['weightKg'] as num).toDouble(),
                );
          final r = WeightPredictor.countFromWeight(
            logMean: logMean,
            lotPrior: lotPrior,
            df: df,
            weightKg: (c['weightKg'] as num).toDouble(),
            sample: sample,
          );
          expect(r.estimatedQty, _close(expectMap['estimatedQty'] as num));
          expect(r.qtyLow, _close(expectMap['qtyLow'] as num));
          expect(r.qtyHigh, _close(expectMap['qtyHigh'] as num));
          expect(r.logHalfWidth, _close(expectMap['logHalfWidth'] as num));
          expect(r.relHalfWidth, _close(expectMap['relHalfWidth'] as num));
          expect(r.exactUpToQty, _close(expectMap['exactUpToQty'] as num));
          expect(r.fusedLogMean, _close(expectMap['fusedLogMean'] as num));
          expect(r.fusedLotPrior, _close(expectMap['fusedLotPrior'] as num));
        case 'expected':
          final kind = WeightSourceKind.parse(c['kind'] as String)!;
          final r = WeightPredictor.expectedForQty(
            logMean: logMean,
            lotPrior: lotPrior,
            df: df,
            qty: (c['qty'] as num).toDouble(),
            weightKg: (c['weightKg'] as num).toDouble(),
            eps: kind.eps,
            tolerancePct: (c['tolerancePct'] as num).toDouble(),
          );
          expect(
            r.expectedWeightKg,
            _close(expectMap['expectedWeightKg'] as num),
          );
          expect(r.deviationPct, _close(expectMap['deviationPct'] as num));
          expect(r.z, _close(expectMap['z'] as num));
          expect(r.alert.code, expectMap['alert']);
        default:
          fail('未知金样操作 ${c['op']}');
      }
    });
  }

  group('参数桥接与辅助口径', () {
    WeightParams params({
      WeightTier tier = WeightTier.yellow,
      WeightBasis basis = WeightBasis.learned,
      String? evidence,
      bool stale = false,
    }) => WeightParams(
      key: 'g|A',
      goodsId: 'g',
      basis: basis,
      evidence: evidence,
      logMean: -6.214979467174846,
      lotPrior: 3.869930380683166e-05,
      df: 15,
      tier: tier,
      tolerancePct: 3,
      stale: stale,
    );

    test('check 与金样 S18 同档: 19.3 kg WARN, 18.5 kg ALERT, 20 kg NONE', () {
      final p = params();
      expect(
        p.check(qtyBase: 10000, weightKg: 19.3)!.level,
        WeightAlertLevel.warn,
      );
      expect(
        p.check(qtyBase: 10000, weightKg: 18.5)!.level,
        WeightAlertLevel.alert,
      );
      expect(
        p.check(qtyBase: 10000, weightKg: 20.0)!.level,
        WeightAlertLevel.none,
      );
      // 登记 10000, 称重折算约 9653 个 -> 偏少约 347 个。
      final check = p.check(qtyBase: 10000, weightKg: 19.3)!;
      expect(check.qtyDiff, closeTo(-346.6, 1));
    });

    test('未学准 / 设计单重不告警 (防假阳性)', () {
      expect(
        params(
          tier: WeightTier.red,
        ).check(qtyBase: 10000, weightKg: 18.5)!.level,
        WeightAlertLevel.none,
      );
      expect(
        params(
          basis: WeightBasis.masterPrior,
        ).check(qtyBase: 10000, weightKg: 18.5)!.level,
        WeightAlertLevel.none,
      );
    });

    test('请求档位: 未学准只有 >= 10 件抽样才能放行; 过期/按领料推算最高「可参考」', () {
      expect(
        WeightPredictor.requestTier(
          logHalfWidth: 0.005,
          baseTier: WeightTier.red,
        ),
        WeightTier.red,
      );
      expect(
        WeightPredictor.requestTier(
          logHalfWidth: 0.005,
          baseTier: WeightTier.red,
          sufficientSample: true,
        ),
        WeightTier.green,
      );
      expect(
        WeightPredictor.requestTier(
          logHalfWidth: 0.005,
          baseTier: WeightTier.green,
          capAtYellow: true,
        ),
        WeightTier.yellow,
      );
      // 先验很紧 (本应「可靠」), 但超过一年没称过 -> 本次最高「可参考」。
      const tight = WeightParams(
        key: 'g|',
        goodsId: 'g',
        basis: WeightBasis.learned,
        logMean: -6.2,
        lotPrior: 1e-6,
        df: 30,
        tier: WeightTier.green,
      );
      final estimate = tight.countFromWeight(20)!;
      expect(tight.requestTierFor(estimate), WeightTier.green);
      const staleTight = WeightParams(
        key: 'g|',
        goodsId: 'g',
        basis: WeightBasis.learned,
        logMean: -6.2,
        lotPrior: 1e-6,
        df: 30,
        tier: WeightTier.green,
        stale: true,
      );
      expect(staleTight.requestTierFor(estimate), WeightTier.yellow);
    });

    test('没有单重时只用同批抽样折算', () {
      const none = WeightParams(key: 'g|', goodsId: 'g');
      expect(none.countFromWeight(20), isNull);
      final r = none.countFromWeight(
        20,
        sample: const WeightSampleInput(qty: 20, weightKg: 0.040),
      )!;
      expect(r.estimatedQty, closeTo(10000, 1e-6));
    });

    test('取整 HALF_EVEN; 分档阈值; 建议抽样件数默认 16', () {
      expect(WeightPredictor.roundQty(2.5, integer: true), 2);
      expect(WeightPredictor.roundQty(3.5, integer: true), 4);
      expect(WeightPredictor.roundQty(3.49, integer: true), 3);
      expect(WeightPredictor.roundQty(1.23456, integer: false), 1.2346);
      expect(WeightPredictor.tierOf(0.01), WeightTier.green);
      expect(WeightPredictor.tierOf(0.0101), WeightTier.yellow);
      expect(WeightPredictor.tierOf(0.05), WeightTier.yellow);
      expect(WeightPredictor.tierOf(0.0501), WeightTier.red);
      expect(WeightPredictor.suggestedSampleSize(), 16);
      expect(WeightPredictor.t975(4), closeTo(2.7693, 1e-3));
    });
  });
}

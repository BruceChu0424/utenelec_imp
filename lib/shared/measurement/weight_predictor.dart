// 单重预测 (ADR-135 §5/§6.1): 服务端 ApwPredictor 的纯 Dart 镜像。
//
// 服务端只下发每个货品的「单重参数」(POST /stock/weight/params: logMean / lotPrior /
// df / gamma / tier ...), 表格里敲字时的称重折算件数、95% 区间、应称重量与偏差告警
// 全在客户端用本文件算——避免逐格往返。公式与服务端逐字一致 (review/stats.md
// 「Request-time」一节), 由 test/shared/measurement/fixtures/predictor_golden.json
// 金样 (apw_proto.py 生成, 服务端测试持有同一份拷贝) 锁定两端一致。
//
// 记号: 对数单重 mu = ln(每基本单位千克数); P = 批间先验方差 (lotPrior);
// gamma = 单件离散 (CV); r = 秤分辨率 0.00005 kg; t975(df) = Student-t 97.5% 分位近似。
import 'dart:math' as math;

/// 可靠度档位 (服务端同名): 可靠 / 可参考 / 未学准。
enum WeightTier {
  green('GREEN', '可靠'),
  yellow('YELLOW', '可参考'),
  red('RED', '未学准');

  const WeightTier(this.code, this.label);

  final String code;
  final String label;

  static WeightTier? parse(String? code) {
    final key = code?.trim().toUpperCase();
    for (final t in WeightTier.values) {
      if (t.code == key) return t;
    }
    return null;
  }
}

/// 称重偏差告警档位 (服务端 alert_level 同名)。
enum WeightAlertLevel {
  none('NONE'),
  warn('WARN'),
  alert('ALERT');

  const WeightAlertLevel(this.code);

  final String code;

  static WeightAlertLevel parse(String? code) {
    final key = code?.trim().toUpperCase();
    for (final a in WeightAlertLevel.values) {
      if (a.code == key) return a;
    }
    return WeightAlertLevel.none;
  }
}

/// 称重来源类别与其「件数本身的误差」eps (服务端 SourceKind 同表)。
/// REFERENCE 类 (独立点数) 训练单重; CHECK 类 (出库执行) 只用来核对偏差。
enum WeightSourceKind {
  sample('SAMPLE', 0.0, reference: true),
  count('COUNT', 0.005, reference: true),
  receipt('RECEIPT', 0.010, reference: true),
  finished('FINISHED', 0.010, reference: true),
  otherIn('OTHER_IN', 0.020, reference: true),
  draw('DRAW', 0.010),
  issue('ISSUE', 0.010),
  shipment('SHIPMENT', 0.010),
  returned('RETURN', 0.020),
  otherOut('OTHER_OUT', 0.010),
  transfer('TRANSFER', 0.010);

  const WeightSourceKind(this.code, this.eps, {this.reference = false});

  final String code;
  final double eps;
  final bool reference;

  static WeightSourceKind? parse(String? code) {
    final key = code?.trim().toUpperCase();
    for (final k in WeightSourceKind.values) {
      if (k.code == key) return k;
    }
    return null;
  }
}

/// 同批抽样 (件数按基本单位, 重量千克)。
class WeightSampleInput {
  const WeightSampleInput({required this.qty, required this.weightKg});

  final double qty;
  final double weightKg;

  /// 抽样达到 10 件才算「可用于放行填数」的有效抽样 (服务端同一门槛)。
  bool get sufficient => qty >= 10;
}

/// 先验与抽样融合后的对数均值与方差。
class FusedPrior {
  const FusedPrior(this.logMean, this.lotPrior);

  final double logMean;
  final double lotPrior;
}

/// 称重折算件数: 点估计 + 95% 区间 + 精确点数上限。
class CountEstimate {
  const CountEstimate({
    required this.estimatedQty,
    required this.qtyLow,
    required this.qtyHigh,
    required this.logHalfWidth,
    required this.exactUpToQty,
    required this.fusedLogMean,
    required this.fusedLotPrior,
  });

  final double estimatedQty;
  final double qtyLow;
  final double qtyHigh;

  /// 对数半宽 h (区间 = N x e^(+-h))。
  final double logHalfWidth;

  /// 件数不超过它时, 称重计数的区间在 +-0.5 件以内 (「超过 N 个时称重计数只是估算」)。
  final double exactUpToQty;

  final double fusedLogMean;
  final double fusedLotPrior;

  /// 相对半宽 e^h - 1。
  double get relHalfWidth => math.exp(logHalfWidth) - 1;

  /// 融合后的单重 (千克/基本单位)。
  double get unitWeightKg => math.exp(fusedLogMean);
}

/// 给定数量的应称重量, 有实称时附带偏差与告警。
class WeightExpectation {
  const WeightExpectation({
    required this.expectedWeightKg,
    required this.weightLowKg,
    required this.weightHighKg,
    this.deviationPct,
    this.z,
    this.alert = WeightAlertLevel.none,
  });

  final double expectedWeightKg;

  /// 应称重量 95% 区间 (只含批间先验、单件离散与秤分辨率, 不含来源件数误差)。
  final double weightLowKg;
  final double weightHighKg;

  /// 实称相对应称的偏差 % (W/E - 1) x 100; 没有实称时为 null。
  final double? deviationPct;
  final double? z;
  final WeightAlertLevel alert;
}

abstract final class WeightPredictor {
  /// 标准正态 97.5% 分位 (与金样同值)。
  static const double z975 = 1.959963985;

  /// 单件离散默认 2% (货品设置 piece_cv_pct 可覆盖)。
  static const double defaultGamma = 0.02;

  /// 秤分辨率 0.05 g (服务端属性 uten.stock.weight.scale-resolution-kg 默认值)。
  static const double defaultScaleResKg = 0.00005;

  /// 核对容差默认 3%。
  static const double defaultTolerancePct = 3.0;

  /// 批间先验伪自由度 nu0 (参数缺 df 时的兜底)。
  static const double priorDf = 4.0;

  /// Student-t 97.5% 分位近似: z + 2.37228/df + 2.82202/df^2 + 2.55605/df^3。
  static double t975(double df) {
    final d = df <= 0 ? priorDf : df;
    return z975 + 2.37228 / d + 2.82202 / (d * d) + 2.55605 / (d * d * d);
  }

  /// 同批抽样与先验融合: mu* = (mu/P + ys/Vs)/(1/P + 1/Vs), P* = 1/(1/P + 1/Vs)。
  /// 先验缺失 (没有单重) 时只用抽样本身。
  static FusedPrior fuseSample({
    required double? logMean,
    required double? lotPrior,
    required WeightSampleInput sample,
    double gamma = defaultGamma,
    double scaleResKg = defaultScaleResKg,
  }) {
    final ys = math.log(sample.weightKg / sample.qty);
    final vs =
        gamma * gamma / sample.qty +
        math.pow(scaleResKg / sample.weightKg, 2) / 3;
    if (logMean == null || lotPrior == null || lotPrior <= 0) {
      return FusedPrior(ys, vs);
    }
    final precision = 1 / lotPrior + 1 / vs;
    return FusedPrior(
      (logMean / lotPrior + ys / vs) / precision,
      1 / precision,
    );
  }

  /// 称重折算件数 (基本单位): N = W/e^mu*, sigma^2 = P* + gamma^2/max(N,1) + (r/W)^2/3,
  /// 区间 N x e^(+-t975 x sigma)。
  static CountEstimate countFromWeight({
    required double? logMean,
    required double? lotPrior,
    required double df,
    required double weightKg,
    WeightSampleInput? sample,
    double gamma = defaultGamma,
    double scaleResKg = defaultScaleResKg,
  }) {
    var mu = logMean;
    var p = lotPrior;
    if (sample != null) {
      final fused = fuseSample(
        logMean: mu,
        lotPrior: p,
        sample: sample,
        gamma: gamma,
        scaleResKg: scaleResKg,
      );
      mu = fused.logMean;
      p = fused.lotPrior;
    }
    if (mu == null || p == null) {
      throw ArgumentError('countFromWeight 需要单重参数或同批抽样');
    }
    final qq = t975(df);
    final n = weightKg / math.exp(mu);
    final variance =
        p +
        gamma * gamma / math.max(n, 1) +
        math.pow(scaleResKg / weightKg, 2) / 3;
    final hw = qq * math.sqrt(variance);
    final a = p;
    final b = gamma * gamma;
    final c = math.pow(0.5 / qq, 2);
    final nMax = (-b + math.sqrt(b * b + 4 * a * c)) / (2 * a);
    return CountEstimate(
      estimatedQty: n,
      qtyLow: n * math.exp(-hw),
      qtyHigh: n * math.exp(hw),
      logHalfWidth: hw,
      exactUpToQty: nMax,
      fusedLogMean: mu,
      fusedLotPrior: p,
    );
  }

  /// 数量 Q 的应称重量 E = Q x e^mu*; 给了实称 W 时按
  /// sigma^2 = P* + gamma^2/max(Q,1) + eps^2 + (r/W)^2/3 判偏差:
  /// d = ln(W/E), z = z975 x d/(t975 x sigma);
  /// |d| > ln(1+2tol) 且 |z| > 3 -> ALERT; |d| > ln(1+tol) 且 |z| > 1.96 -> WARN。
  static WeightExpectation expectedForQty({
    required double logMean,
    required double lotPrior,
    required double df,
    required double qty,
    double? weightKg,
    double eps = 0,
    double tolerancePct = defaultTolerancePct,
    WeightSampleInput? sample,
    double gamma = defaultGamma,
    double scaleResKg = defaultScaleResKg,
  }) {
    var mu = logMean;
    var p = lotPrior;
    if (sample != null) {
      final fused = fuseSample(
        logMean: mu,
        lotPrior: p,
        sample: sample,
        gamma: gamma,
        scaleResKg: scaleResKg,
      );
      mu = fused.logMean;
      p = fused.lotPrior;
    }
    final qq = t975(df);
    final expected = qty * math.exp(mu);
    final bandVariance =
        p +
        gamma * gamma / math.max(qty, 1) +
        math.pow(scaleResKg / expected, 2) / 3;
    final bandHw = qq * math.sqrt(bandVariance);
    final low = expected * math.exp(-bandHw);
    final high = expected * math.exp(bandHw);
    if (weightKg == null || weightKg <= 0) {
      return WeightExpectation(
        expectedWeightKg: expected,
        weightLowKg: low,
        weightHighKg: high,
      );
    }
    final variance =
        p +
        gamma * gamma / math.max(qty, 1) +
        eps * eps +
        math.pow(scaleResKg / weightKg, 2) / 3;
    final sdEff = math.sqrt(variance) * qq / z975;
    final d = math.log(weightKg / expected);
    final z = d / sdEff;
    return WeightExpectation(
      expectedWeightKg: expected,
      weightLowKg: low,
      weightHighKg: high,
      deviationPct: 100 * (weightKg / expected - 1),
      z: z,
      alert: alert(logDeviation: d, z: z, tolerancePct: tolerancePct),
    );
  }

  /// 偏差告警: 相对偏差与统计显著性同时越线才报 (防假阳性)。
  static WeightAlertLevel alert({
    required double logDeviation,
    required double z,
    double tolerancePct = defaultTolerancePct,
  }) {
    final tol = tolerancePct / 100;
    final d = logDeviation.abs();
    final az = z.abs();
    if (d > math.log(1 + 2 * tol) && az > 3.0) return WeightAlertLevel.alert;
    if (d > math.log(1 + tol) && az > z975) return WeightAlertLevel.warn;
    return WeightAlertLevel.none;
  }

  /// 按对数半宽分档: <= 1% 可靠, <= 5% 可参考, 否则未学准。
  static WeightTier tierOf(double logHalfWidth) {
    if (logHalfWidth <= 0.01) return WeightTier.green;
    if (logHalfWidth <= 0.05) return WeightTier.yellow;
    return WeightTier.red;
  }

  /// 本次请求的可靠度: 服务端档位为未学准 (或没有) 时, 只有同批抽样 >= 10 件才能放行;
  /// 过期 (最近一次称重超过 365 天) 或按过往领料推算的最高到「可参考」。
  static WeightTier requestTier({
    required double logHalfWidth,
    required WeightTier? baseTier,
    bool sufficientSample = false,
    bool capAtYellow = false,
  }) {
    if (!sufficientSample && (baseTier == null || baseTier == WeightTier.red)) {
      return WeightTier.red;
    }
    final tier = tierOf(logHalfWidth);
    if (capAtYellow && tier == WeightTier.green) return WeightTier.yellow;
    return tier;
  }

  /// 建议抽样件数 (服务端没给时的兜底, 同一公式):
  /// clamp(max(ceil((1.96 gamma/t)^2), ceil(100 r/APW)), 10, 200), t = min(1%, tol/3)。
  static int suggestedSampleSize({
    double gamma = defaultGamma,
    double tolerancePct = defaultTolerancePct,
    double? unitWeightKg,
    double scaleResKg = defaultScaleResKg,
  }) {
    final t = math.min(0.01, tolerancePct / 100 / 3);
    final byCv = (math.pow(1.96 * gamma / t, 2) as double).ceil();
    final byScale = unitWeightKg == null || unitWeightKg <= 0
        ? 0
        : (100 * scaleResKg / unitWeightKg).ceil();
    return math.max(byCv, byScale).clamp(10, 200);
  }

  /// 同批抽样相对当前单重的 z 值 (> 3 提示「差异较大: 换了供应商/批次?」)。
  static double sampleDeviationZ({
    required double logMean,
    required double lotPrior,
    required WeightSampleInput sample,
    double gamma = defaultGamma,
    double scaleResKg = defaultScaleResKg,
  }) {
    final ys = math.log(sample.weightKg / sample.qty);
    final vs =
        gamma * gamma / sample.qty +
        math.pow(scaleResKg / sample.weightKg, 2) / 3;
    return (ys - logMean) / math.sqrt(lotPrior + vs);
  }

  /// 估算件数取整: 按件计的单位 HALF_EVEN 到整数, 其余保留 4 位 (HALF_UP)。
  static double roundQty(double qty, {required bool integer}) {
    if (!qty.isFinite) return qty;
    if (!integer) return (qty * 10000).roundToDouble() / 10000;
    final floor = qty.floorToDouble();
    final diff = qty - floor;
    if (diff > 0.5) return floor + 1;
    if (diff < 0.5) return floor;
    return floor % 2 == 0 ? floor : floor + 1;
  }
}

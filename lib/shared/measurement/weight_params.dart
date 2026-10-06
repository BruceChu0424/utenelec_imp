// 单重参数与单重学习接口 (ADR-135 §7.2): 模型 + 仓储 + 页内缓存 + 预测桥接。
//
// - POST /stock/weight/params: 一页一次批量取每行 (货品, 供应商) 的单重参数 (<= 500 行/次),
//   表格敲字时的件数折算/应称重量/偏差告警全部在客户端用 [WeightPredictor] 算;
//   服务端仍是过账重量的权威 (估算永远不写进单据)。
//   请求行只带结构化身份 (goodsId/supplierId/warehouseId/colorId), 不拼字符串 key (ADR-151);
//   响应分开给单重 items (按货品+供应商) 与库存均重参考 stockBalances (按仓库+货品+颜色)。
// - 单货品详情/称重记录/称样校准/单重设置/排除恢复/重新学习/核重 走同一个 [WeightRepository]。
// - 权限: 称样 = warehouse_inbound:stock_in 或 stock_doc:edit 或 stock:weight:manage;
//   设定单重/排除/重新学习/设置/核重 = stock:weight:manage。
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../auth/permissions.dart';
import '../models/paged_result.dart';
import 'weight_predictor.dart';

/// 单重依据 (服务端解析优先级: 精确 > 人工设定 > 称重学习 > 货品资料设计单重 > 无)。
enum WeightBasis {
  exact('EXACT', '按数量精确换算'),
  manual('MANUAL', '人工设定单重'),
  learned('LEARNED', '称重学习'),
  masterPrior('MASTER_PRIOR', '货品资料设计单重'),
  none('NONE', '暂无单重');

  const WeightBasis(this.code, this.label);

  final String code;
  final String label;

  static WeightBasis parse(String? code) {
    final key = code?.trim().toUpperCase();
    for (final b in WeightBasis.values) {
      if (b.code == key) return b;
    }
    return WeightBasis.none;
  }
}

/// 采集场景: 决定占位文案 (约/应称)、偏差措辞与来源误差档。
enum WeightCaptureMode {
  /// 到货/入库登记 (登记数量 vs 称重折算)。
  inbound(WeightSourceKind.receipt),

  /// 领料/委外/销售出库 (应发数量 vs 实称, 反推「应称」)。
  outbound(WeightSourceKind.draw),

  /// 盘点/其它入库 (数量通常由称重折算填入)。
  count(WeightSourceKind.count);

  const WeightCaptureMode(this.sourceKind);

  /// 核对偏差时用的来源件数误差档。
  final WeightSourceKind sourceKind;
}

/// 单重身份: 单重只按 (货品, 供应商) 解析。
typedef WeightParamsIdentity = ({String goodsId, String? supplierId});

/// 库存均重参考身份: 同一实物仓库、货品、精确颜色 (null = 无色, 不是任意颜色)。
typedef WeightBalanceIdentity = ({
  String warehouseId,
  String goodsId,
  String? colorId,
});

String? _blankToNull(String? value) =>
    value == null || value.isEmpty ? null : value;

/// 取参请求行: 只带结构化身份, 不拼字符串 key (ADR-151)。
@immutable
class WeightParamsLine {
  const WeightParamsLine({
    required this.goodsId,
    this.supplierId,
    this.warehouseId,
    this.colorId,
  });

  final String goodsId;
  final String? supplierId;
  final String? warehouseId;
  final String? colorId;

  WeightParamsIdentity get paramsIdentity =>
      (goodsId: goodsId, supplierId: _blankToNull(supplierId));

  /// 不带仓库的行不取库存参考 (不会退回成「所有仓库」)。
  WeightBalanceIdentity? get balanceIdentity {
    final warehouse = _blankToNull(warehouseId);
    return warehouse == null
        ? null
        : (
            warehouseId: warehouse,
            goodsId: goodsId,
            colorId: _blankToNull(colorId),
          );
  }

  Map<String, Object?> toJson() => {
    'goodsId': goodsId,
    'supplierId': ?_blankToNull(supplierId),
    'warehouseId': ?_blankToNull(warehouseId),
    'colorId': ?_blankToNull(colorId),
  };

  @override
  bool operator ==(Object other) =>
      other is WeightParamsLine &&
      other.paramsIdentity == paramsIdentity &&
      other.balanceIdentity == balanceIdentity;

  @override
  int get hashCode => Object.hash(paramsIdentity, balanceIdentity);
}

/// 同仓库、货品、颜色的库存重量参考；重量未知时不得当作零。
class WeightStockBalance {
  const WeightStockBalance({
    required this.warehouseId,
    required this.qtyBase,
    required this.weightKg,
    this.goodsId = '',
    this.colorId,
    this.estimated = false,
  });

  final String warehouseId;
  final String goodsId;
  final String? colorId;

  WeightBalanceIdentity get identity =>
      (warehouseId: warehouseId, goodsId: goodsId, colorId: colorId);
  final double qtyBase;
  final double weightKg;
  final bool estimated;

  bool get usable =>
      warehouseId.isNotEmpty &&
      qtyBase.isFinite &&
      qtyBase > 0 &&
      weightKg.isFinite &&
      weightKg > 0;

  double? expectedKgFor(double? qty) {
    if (!usable || qty == null || !qty.isFinite || qty <= 0) return null;
    final result = qty / qtyBase * weightKg;
    return result.isFinite && result > 0 ? result : null;
  }

  factory WeightStockBalance.fromJson(Map<String, dynamic> j) =>
      WeightStockBalance(
        warehouseId: _str(j['warehouseId']) ?? '',
        goodsId: _str(j['goodsId']) ?? '',
        colorId: _str(j['colorId']),
        qtyBase: _num(j['qtyBase']) ?? 0,
        weightKg: _num(j['weightKg']) ?? 0,
        estimated: j['estimated'] == true,
      );
}

/// 仅用于预填/核对，不是实称事实，不写进单据重量与学习样本。
class WeightSuggestion {
  const WeightSuggestion({
    required this.kg,
    required this.source,
    required this.tolerancePct,
    this.inventoryBased = false,
  });
  final double kg;
  final String source;
  final double tolerancePct;
  final bool inventoryBased;

  bool differsFrom(
    double? measuredKg, {
    double scaleResKg = WeightPredictor.defaultScaleResKg,
  }) {
    if (measuredKg == null ||
        !measuredKg.isFinite ||
        measuredKg <= 0 ||
        !kg.isFinite ||
        kg <= 0) {
      return false;
    }
    final resolution = scaleResKg.isFinite && scaleResKg > 0
        ? scaleResKg
        : WeightPredictor.defaultScaleResKg;
    final tolerance = tolerancePct.isFinite && tolerancePct > 0
        ? tolerancePct
        : WeightPredictor.defaultTolerancePct;
    return (measuredKg - kg).abs() >
        math.max(kg * tolerance / 100, resolution * 2);
  }
}

/// 一行的单重参数 (POST /stock/weight/params items[]); 身份 = (货品, 供应商)。
///
/// [stockBalance] 不是服务端单重的一部分: 由 [WeightParamsCache.of] /
/// [WeightParamsResult.of] 按行的仓库与颜色把响应里单独的库存参考接上。
class WeightParams {
  const WeightParams({
    required this.goodsId,
    this.supplierId,
    this.basis = WeightBasis.none,
    this.supplierSpecific = false,
    this.evidence,
    this.unitWeightKg,
    this.logMean,
    this.lotPrior,
    this.gamma,
    this.df,
    this.tier,
    this.relHalfWidth,
    this.nInliers,
    this.suggestedSampleSize,
    this.exactUpToQty,
    this.tolerancePct,
    this.defaultTareKg,
    this.lastTareKg,
    this.massFactorKg,
    this.stale = false,
    this.lastObservedAt,
    this.drawBiasPct,
    this.manualConflictPct,
    this.baseUnitDimension,
    this.learningEnabled = true,
    this.scaleResKg = WeightPredictor.defaultScaleResKg,
    this.stockBalance,
  });

  final String goodsId;

  /// 请求的供应商 (null = 货品级)。
  final String? supplierId;
  final WeightBasis basis;

  /// 取的是该供应商自己的单重行 (不是全货品汇总)。
  final bool supplierSpecific;

  /// REFERENCE / DRAW_ONLY (按过往领料推算) / CONFLICT (两次称重互相矛盾)。
  final String? evidence;

  /// 单重: 每基本单位千克数。
  final double? unitWeightKg;
  final double? logMean;

  /// 批间先验方差 P。
  final double? lotPrior;
  final double? gamma;
  final double? df;
  final WeightTier? tier;
  final double? relHalfWidth;
  final int? nInliers;
  final int? suggestedSampleSize;
  final double? exactUpToQty;
  final double? tolerancePct;
  final double? defaultTareKg;
  final double? lastTareKg;

  /// 精确换算系数 (货品基本单位本身是重量单位时: 1 基本单位 = 多少千克)。
  final double? massFactorKg;

  /// 最近一次称重超过 365 天 (可靠度最高到「可参考」)。
  final bool stale;
  final DateTime? lastObservedAt;
  final double? drawBiasPct;
  final double? manualConflictPct;

  /// 基本单位计量维度: 'COUNT' / null (按件, 折算取整) / 其它 (如 LENGTH, 保留小数)。
  final String? baseUnitDimension;
  final bool learningEnabled;

  /// 秤分辨率 (千克; 服务端配置, 预测公式里的量化误差项, 与服务端 ApwPredictor 同值)。
  final double scaleResKg;
  final WeightStockBalance? stockBalance;

  WeightParamsIdentity get identity =>
      (goodsId: goodsId, supplierId: _blankToNull(supplierId));

  /// 接上 (或去掉) 本行仓库/颜色的库存均重参考, 单重本身不变。
  WeightParams withStockBalance(WeightStockBalance? balance) => WeightParams(
    goodsId: goodsId,
    supplierId: supplierId,
    basis: basis,
    supplierSpecific: supplierSpecific,
    evidence: evidence,
    unitWeightKg: unitWeightKg,
    logMean: logMean,
    lotPrior: lotPrior,
    gamma: gamma,
    df: df,
    tier: tier,
    relHalfWidth: relHalfWidth,
    nInliers: nInliers,
    suggestedSampleSize: suggestedSampleSize,
    exactUpToQty: exactUpToQty,
    tolerancePct: tolerancePct,
    defaultTareKg: defaultTareKg,
    lastTareKg: lastTareKg,
    massFactorKg: massFactorKg,
    stale: stale,
    lastObservedAt: lastObservedAt,
    drawBiasPct: drawBiasPct,
    manualConflictPct: manualConflictPct,
    baseUnitDimension: baseUnitDimension,
    learningEnabled: learningEnabled,
    scaleResKg: scaleResKg,
    stockBalance: balance,
  );

  /// 按件计 (折算件数取整)。
  bool get integerQty =>
      baseUnitDimension == null ||
      baseUnitDimension!.trim().isEmpty ||
      baseUnitDimension!.toUpperCase() == 'COUNT';

  /// 货品按重量计 (重量由数量精确换算, 格子只读)。
  bool get isExact =>
      basis == WeightBasis.exact &&
      massFactorKg != null &&
      massFactorKg!.isFinite &&
      massFactorKg! > 0;

  bool get drawOnly => evidence?.toUpperCase() == 'DRAW_ONLY';
  bool get conflict => evidence?.toUpperCase() == 'CONFLICT';

  /// 有可用的对数单重与先验 (能折算件数/应称重量)。
  bool get predictable =>
      basis != WeightBasis.exact &&
      basis != WeightBasis.none &&
      logMean != null &&
      logMean!.isFinite &&
      lotPrior != null &&
      lotPrior!.isFinite &&
      lotPrior! > 0;

  /// 生效档位 (没有档位按「未学准」)。
  WeightTier get effectiveTier => tier ?? WeightTier.red;

  /// 偏差核对只对「称重学习 / 人工设定」且不是未学准的单重生效 (防假阳性)。
  bool get alertsEnabled =>
      predictable &&
      (basis == WeightBasis.learned || basis == WeightBasis.manual) &&
      effectiveTier != WeightTier.red;

  double get effectiveGamma => gamma ?? WeightPredictor.defaultGamma;
  double get effectiveDf => df ?? WeightPredictor.priorDf;
  double get effectiveTolerancePct =>
      tolerancePct ?? WeightPredictor.defaultTolerancePct;

  /// 当前单重 (千克/基本单位)。
  double? get currentUnitWeightKg =>
      isExact ? massFactorKg : (unitWeightKg ?? _expOrNull(logMean));

  /// 建议抽样件数 (服务端没给时按同一公式兜底)。
  int get effectiveSuggestedSampleSize =>
      suggestedSampleSize ??
      WeightPredictor.suggestedSampleSize(
        gamma: effectiveGamma,
        tolerancePct: effectiveTolerancePct,
        unitWeightKg: currentUnitWeightKg,
      );

  /// 皮重预填: 货品默认皮重, 否则上次用过的皮重。
  double? get prefillTareKg => defaultTareKg ?? lastTareKg;

  factory WeightParams.fromJson(Map<String, dynamic> j) => WeightParams(
    goodsId: (j['goodsId'] ?? '').toString(),
    supplierId: _str(j['supplierId']),
    basis: WeightBasis.parse(j['basis']?.toString()),
    supplierSpecific: j['supplierSpecific'] == true,
    evidence: _str(j['evidence']),
    unitWeightKg: _num(j['unitWeightKg']),
    logMean: _num(j['logMean']),
    lotPrior: _num(j['lotPrior']),
    gamma: _num(j['gamma']),
    df: _num(j['df']),
    tier: WeightTier.parse(j['tier']?.toString()),
    relHalfWidth: _num(j['relHalfWidth']),
    nInliers: _int(j['nInliers']),
    suggestedSampleSize: _int(j['suggestedSampleSize']),
    exactUpToQty: _num(j['exactUpToQty']),
    tolerancePct: _num(j['tolerancePct']),
    defaultTareKg: _num(j['defaultTareKg']),
    lastTareKg: _num(j['lastTareKg']),
    massFactorKg: _num(j['massFactorKg']),
    stale: j['stale'] == true,
    lastObservedAt: _date(j['lastObservedAt']),
    drawBiasPct: _num(j['drawBiasPct']),
    manualConflictPct: _num(j['manualConflictPct']),
    baseUnitDimension: _str(j['baseUnitDimension']),
    learningEnabled: j['learningEnabled'] != false,
    scaleResKg: _num(j['scaleResKg']) ?? WeightPredictor.defaultScaleResKg,
  );
}

/// 一次取参的结果: 单重按 (货品, 供应商), 库存参考按 (仓库, 货品, 颜色), 分开保存。
class WeightParamsResult {
  const WeightParamsResult({this.params = const {}, this.balances = const {}});

  final Map<WeightParamsIdentity, WeightParams> params;
  final Map<WeightBalanceIdentity, WeightStockBalance> balances;

  /// 某一行的单重, 并接上该行仓库/颜色的库存参考。
  WeightParams? of(WeightParamsLine line) {
    final resolved = params[line.paramsIdentity];
    final balance = line.balanceIdentity;
    return balance == null
        ? resolved
        : resolved?.withStockBalance(balances[balance]);
  }

  WeightParams? paramsOf(String goodsId, {String? supplierId}) =>
      params[(goodsId: goodsId, supplierId: _blankToNull(supplierId))];
}

/// 一次「数量 vs 实称」核对的结果 (偏差 + 称重折算件数)。
class WeightCheck {
  const WeightCheck({
    required this.qtyBase,
    required this.weightKg,
    required this.expectation,
    required this.count,
    required this.level,
    required this.integerQty,
  });

  /// 登记/应发数量 (基本单位)。
  final double qtyBase;
  final double weightKg;
  final WeightExpectation expectation;

  /// 按实称折算的件数与区间。
  final CountEstimate count;

  /// 生效告警 (单重未学准时恒为 none)。
  final WeightAlertLevel level;
  final bool integerQty;

  double get expectedWeightKg => expectation.expectedWeightKg;
  double get deviationPct => expectation.deviationPct ?? 0;

  /// 称重折算件数 - 登记数量 (负 = 称重显示偏少)。
  double get qtyDiff => count.estimatedQty - qtyBase;
}

/// 参数 -> 预测的桥接 (纯计算, 不做文案)。
extension WeightParamsPrediction on WeightParams {
  /// 出库优先对应库存均重；入库优先可信单重，再参考同维度库存。
  WeightSuggestion? suggestionFor(
    double? qtyBase, {
    WeightCaptureMode mode = WeightCaptureMode.inbound,
  }) {
    if (isExact || qtyBase == null || !qtyBase.isFinite || qtyBase <= 0) {
      return null;
    }
    final stockKg = stockBalance?.expectedKgFor(qtyBase);
    final stock = stockKg == null
        ? null
        : WeightSuggestion(
            kg: stockKg,
            source: stockBalance!.estimated ? '按库存估算均重预填' : '按库存数量与重量比例预填',
            inventoryBased: true,
            tolerancePct: math.max(
              effectiveTolerancePct,
              stockBalance!.estimated ? 15 : 5,
            ),
          );
    if (mode == WeightCaptureMode.outbound && stock != null) return stock;
    final learned = alertsEnabled && !conflict ? expectedKgFor(qtyBase) : null;
    if (learned != null && learned.isFinite && learned > 0) {
      return WeightSuggestion(
        kg: learned,
        source: basis == WeightBasis.manual ? '按设定单重预填' : '按历史实称单重预填',
        tolerancePct: effectiveTolerancePct,
      );
    }
    return stock;
  }

  /// 数量 (基本单位) 的应称重量; 精确换算货品直接乘系数。
  double? expectedKgFor(double? qtyBase) {
    if (qtyBase == null || !qtyBase.isFinite || qtyBase <= 0) return null;
    if (isExact) return qtyBase * massFactorKg!;
    final unit = currentUnitWeightKg;
    if (!predictable || unit == null || !unit.isFinite || unit <= 0) {
      return null;
    }
    return qtyBase * unit;
  }

  /// 应称重量与 95% 区间 (出库反推「秤上应显示」用)。
  WeightExpectation? expectationFor(
    double qtyBase, {
    WeightSampleInput? sample,
  }) {
    if (!predictable || qtyBase <= 0) return null;
    return WeightPredictor.expectedForQty(
      logMean: logMean!,
      lotPrior: lotPrior!,
      df: effectiveDf,
      qty: qtyBase,
      sample: sample,
      gamma: effectiveGamma,
      scaleResKg: scaleResKg,
    );
  }

  /// 按实称折算件数 (基本单位); 没有单重也没有抽样时返回 null。
  CountEstimate? countFromWeight(double weightKg, {WeightSampleInput? sample}) {
    if (weightKg <= 0) return null;
    if (!predictable && sample == null) return null;
    return WeightPredictor.countFromWeight(
      logMean: predictable ? logMean : null,
      lotPrior: predictable ? lotPrior : null,
      df: effectiveDf,
      weightKg: weightKg,
      sample: sample,
      gamma: effectiveGamma,
      scaleResKg: scaleResKg,
    );
  }

  /// 本次请求的可靠度 (含同批抽样与实际件数)。
  WeightTier requestTierFor(
    CountEstimate estimate, {
    WeightSampleInput? sample,
  }) => WeightPredictor.requestTier(
    logHalfWidth: estimate.logHalfWidth,
    baseTier: predictable ? tier : null,
    sufficientSample: sample?.sufficient ?? false,
    capAtYellow: stale || drawOnly,
  );

  /// 数量 vs 实称核对; 不可预测/缺数时返回 null。
  WeightCheck? check({
    required double? qtyBase,
    required double? weightKg,
    WeightCaptureMode mode = WeightCaptureMode.inbound,
  }) {
    if (!predictable || qtyBase == null || weightKg == null) return null;
    if (qtyBase <= 0 || weightKg <= 0) return null;
    final expectation = WeightPredictor.expectedForQty(
      logMean: logMean!,
      lotPrior: lotPrior!,
      df: effectiveDf,
      qty: qtyBase,
      weightKg: weightKg,
      eps: mode.sourceKind.eps,
      tolerancePct: effectiveTolerancePct,
      gamma: effectiveGamma,
      scaleResKg: scaleResKg,
    );
    final count = WeightPredictor.countFromWeight(
      logMean: logMean,
      lotPrior: lotPrior,
      df: effectiveDf,
      weightKg: weightKg,
      gamma: effectiveGamma,
      scaleResKg: scaleResKg,
    );
    return WeightCheck(
      qtyBase: qtyBase,
      weightKg: weightKg,
      expectation: expectation,
      count: count,
      level: alertsEnabled ? expectation.alert : WeightAlertLevel.none,
      integerQty: integerQty,
    );
  }
}

/// 单货品单重设置 (goods_weight_profiles)。
class GoodsWeightProfile {
  const GoodsWeightProfile({
    required this.goodsId,
    this.defaultTareKg,
    this.tolerancePct,
    this.pieceCvPct,
    this.manualUnitWeightKg,
    this.manualActive = false,
    this.manualReason,
    this.manualSetByName,
    this.manualSetAt,
    this.learningEnabled = true,
    this.regimeMode = 'AUTO',
    this.manualRegimeStartAt,
    this.version = 0,
  });

  final String goodsId;
  final double? defaultTareKg;
  final double? tolerancePct;
  final double? pieceCvPct;
  final double? manualUnitWeightKg;

  /// 人工单重生效中 (设定时的基本单位与现在一致; 换了基本单位后人工单重自动失效)。
  final bool manualActive;
  final String? manualReason;
  final String? manualSetByName;
  final DateTime? manualSetAt;
  final bool learningEnabled;

  /// AUTO = 自动识别换批; MANUAL = 只认人工「从本次起作为新批次」。
  final String regimeMode;
  final DateTime? manualRegimeStartAt;
  final int version;

  factory GoodsWeightProfile.fromJson(
    Map<String, dynamic> j, {
    String? goodsId,
  }) => GoodsWeightProfile(
    goodsId: (j['goodsId'] ?? goodsId ?? '').toString(),
    defaultTareKg: _num(j['defaultTareKg']),
    tolerancePct: _num(j['tolerancePct']),
    pieceCvPct: _num(j['pieceCvPct']),
    manualUnitWeightKg: _num(j['manualUnitWeightKg']),
    manualActive: j['manualActive'] == true,
    manualReason: _str(j['manualReason']),
    manualSetByName: _str(j['manualSetByName']),
    manualSetAt: _date(j['manualSetAt']),
    learningEnabled: j['learningEnabled'] != false,
    regimeMode: _str(j['regimeMode']) ?? 'AUTO',
    manualRegimeStartAt: _date(j['manualRegimeStartAt']),
    version: _int(j['version']) ?? 0,
  );
}

/// 单重学习结果行 (goods_weight_estimates; 全货品汇总行或某供应商行)。
class GoodsWeightEstimateRow {
  const GoodsWeightEstimateRow({
    this.supplierId,
    this.supplierName,
    this.evidence,
    this.unitWeightKg,
    this.logMean,
    this.tier,
    this.relHalfWidth,
    this.nObs,
    this.nRef,
    this.nInliers,
    this.nDraw,
    this.diffPct,
    this.shrinkWeight,
    this.drawBiasPct,
    this.regimeStartedAt,
    this.regimeChangedAt,
    this.lastObservedAt,
    this.suggestedSampleSize,
    this.computedAt,
  });

  final String? supplierId;

  /// 供应商名 (无 stock_report:view / stock:weight:manage 时服务端打码)。
  final String? supplierName;
  final String? evidence;
  final double? unitWeightKg;
  final double? logMean;
  final WeightTier? tier;
  final double? relHalfWidth;
  final int? nObs;
  final int? nRef;
  final int? nInliers;
  final int? nDraw;

  /// 与全货品单重的差异 %。
  final double? diffPct;
  final double? shrinkWeight;
  final double? drawBiasPct;
  final DateTime? regimeStartedAt;
  final DateTime? regimeChangedAt;
  final DateTime? lastObservedAt;
  final int? suggestedSampleSize;
  final DateTime? computedAt;

  factory GoodsWeightEstimateRow.fromJson(Map<String, dynamic> j) =>
      GoodsWeightEstimateRow(
        supplierId: _str(j['supplierId']),
        supplierName: _str(j['supplierName']),
        evidence: _str(j['evidence']),
        unitWeightKg: _num(j['unitWeightKg']),
        logMean: _num(j['logMean']),
        tier: WeightTier.parse(j['tier']?.toString()),
        relHalfWidth: _num(j['relHalfWidth']),
        nObs: _int(j['nObs']),
        nRef: _int(j['nRef']),
        nInliers: _int(j['nInliers']),
        nDraw: _int(j['nDraw']),
        diffPct: _num(j['diffPct']),
        shrinkWeight: _num(j['shrinkWeight']),
        drawBiasPct: _num(j['drawBiasPct']),
        regimeStartedAt: _date(j['regimeStartedAt']),
        regimeChangedAt: _date(j['regimeChangedAt']),
        lastObservedAt: _date(j['lastObservedAt']),
        suggestedSampleSize: _int(j['suggestedSampleSize']),
        computedAt: _date(j['computedAt']),
      );
}

/// 离群记录 ({observationId, z, hint})。hint: UNIT_10/100/1000 / JIN_KG / LB_KG / DEVIATION。
class WeightOutlier {
  const WeightOutlier({required this.observationId, this.z, this.hint});

  final String observationId;
  final double? z;
  final String? hint;

  factory WeightOutlier.fromJson(Map<String, dynamic> j) => WeightOutlier(
    observationId: (j['observationId'] ?? '').toString(),
    z: _num(j['z']),
    hint: _str(j['hint']),
  );
}

/// GET /stock/weight/goods/{goodsId} 与称样后的刷新结果。
class GoodsWeightDetail {
  const GoodsWeightDetail({
    required this.goodsId,
    this.profile,
    this.resolved,
    this.goodsRow,
    this.supplierRows = const [],
    this.drawBiasPct,
    this.regimeStartedAt,
    this.regimeChangedAt,
    this.outliers = const [],
    this.counts = const {},
  });

  final String goodsId;
  final GoodsWeightProfile? profile;

  /// 当前生效的单重参数 (与 params 接口同形)。
  final WeightParams? resolved;
  final GoodsWeightEstimateRow? goodsRow;
  final List<GoodsWeightEstimateRow> supplierRows;
  final double? drawBiasPct;
  final DateTime? regimeStartedAt;
  final DateTime? regimeChangedAt;
  final List<WeightOutlier> outliers;

  /// 记录计数 (如 total / active / excluded / reversed; 键由服务端定)。
  final Map<String, int> counts;

  factory GoodsWeightDetail.fromJson(
    Map<String, dynamic> j, {
    required String goodsId,
  }) {
    final profile = j['profile'];
    final resolved = j['resolved'];
    final goodsRow = j['goodsRow'];
    final counts = <String, int>{};
    final rawCounts = j['counts'];
    if (rawCounts is Map) {
      rawCounts.forEach((k, v) {
        final n = _int(v);
        if (n != null) counts[k.toString()] = n;
      });
    }
    return GoodsWeightDetail(
      goodsId: (j['goodsId'] ?? goodsId).toString(),
      profile: profile is Map<String, dynamic>
          ? GoodsWeightProfile.fromJson(profile, goodsId: goodsId)
          : null,
      resolved: resolved is Map<String, dynamic>
          ? WeightParams.fromJson({'goodsId': goodsId, ...resolved})
          : null,
      goodsRow: goodsRow is Map<String, dynamic>
          ? GoodsWeightEstimateRow.fromJson(goodsRow)
          : null,
      supplierRows: _maps(
        j['supplierRows'],
      ).map(GoodsWeightEstimateRow.fromJson).toList(),
      drawBiasPct: _num(j['drawBiasPct']),
      regimeStartedAt: _date(j['regimeStartedAt']),
      regimeChangedAt: _date(j['regimeChangedAt']),
      outliers: _maps(j['outliers']).map(WeightOutlier.fromJson).toList(),
      counts: counts,
    );
  }
}

/// 一条称重记录 (goods_weight_observations)。
class WeightObservation {
  const WeightObservation({
    required this.id,
    required this.sourceKind,
    required this.qtyBase,
    required this.weightKg,
    this.unitWeightKg,
    this.role,
    this.observedAt,
    this.colorId,
    this.warehouseId,
    this.supplierId,
    this.supplierName,
    this.counterpartKind,
    this.counterpartId,
    this.counterpartName,
    this.grossKg,
    this.tareKg,
    this.sourceDocType,
    this.sourceDocId,
    this.sourceItemId,
    this.sourceDocCode,
    this.billNo,
    this.sourceGone = false,
    this.stage = 'ACTIVE',
    this.excludedReason,
    this.expectedUnitWeightKg,
    this.expectedWeightKg,
    this.deviationPct,
    this.alertLevel = WeightAlertLevel.none,
    this.estimateBasisUsed,
    this.estimateTierUsed,
    this.newRegime = false,
    this.outlier = false,
    this.status = 'NORMAL',
    this.remark,
    this.recordedByName,
  });

  final String id;

  /// SAMPLE/COUNT/RECEIPT/FINISHED/OTHER_IN/DRAW/ISSUE/SHIPMENT/RETURN/OTHER_OUT/TRANSFER。
  final String sourceKind;
  final String? role;
  final double qtyBase;
  final double weightKg;

  /// 本条单重 (千克/基本单位, 服务端 = 净重 / 数量)。
  final double? unitWeightKg;
  final DateTime? observedAt;
  final String? colorId;
  final String? warehouseId;
  final String? supplierId;
  final String? supplierName;
  final String? counterpartKind;
  final String? counterpartId;
  final String? counterpartName;
  final double? grossKg;
  final double? tareKg;
  final String? sourceDocType;
  final String? sourceDocId;
  final String? sourceItemId;
  final String? sourceDocCode;
  final String? billNo;

  /// 来源单据已被清空 (重置后只剩学习记录; 服务端 sourceDocCleared)。
  final bool sourceGone;

  /// ACTIVE / REVERSED (已红冲)。
  final String stage;

  /// MANUAL_EXCLUDE / ECHO / QTY_ECHO; null = 未排除。
  final String? excludedReason;
  final double? expectedUnitWeightKg;
  final double? expectedWeightKg;
  final double? deviationPct;
  final WeightAlertLevel alertLevel;
  final String? estimateBasisUsed;
  final String? estimateTierUsed;
  final bool newRegime;

  /// 本条被判为离群 (服务端按 outliers 标记)。
  final bool outlier;

  /// 服务端给的记录状态: REVERSED (已红冲) / EXCLUDED (已排除) / OUTLIER (离群) / NORMAL (正常)。
  final String status;
  final String? remark;
  final String? recordedByName;

  bool get reversed => stage.toUpperCase() == 'REVERSED';
  bool get excluded => excludedReason != null && excludedReason!.isNotEmpty;

  factory WeightObservation.fromJson(Map<String, dynamic> j) =>
      WeightObservation(
        id: (j['id'] ?? '').toString(),
        sourceKind: (j['sourceKind'] ?? '').toString(),
        role: _str(j['role']),
        qtyBase: _num(j['qtyBase']) ?? 0,
        weightKg: _num(j['weightKg']) ?? 0,
        unitWeightKg: _num(j['unitWeightKg']),
        observedAt: _date(j['observedAt']),
        colorId: _str(j['colorId']),
        warehouseId: _str(j['warehouseId']),
        supplierId: _str(j['supplierId']),
        supplierName: _str(j['supplierName']),
        counterpartKind: _str(j['counterpartKind']),
        counterpartId: _str(j['counterpartId']),
        counterpartName: _str(j['counterpartName']),
        grossKg: _num(j['grossKg']),
        tareKg: _num(j['tareKg']),
        sourceDocType: _str(j['sourceDocType']),
        sourceDocId: _str(j['sourceDocId']),
        sourceItemId: _str(j['sourceItemId']),
        sourceDocCode: _str(j['sourceDocCode']),
        billNo: _str(j['billNo']),
        sourceGone: j['sourceDocCleared'] == true,
        stage: _str(j['stage']) ?? 'ACTIVE',
        excludedReason: _str(j['excludedReason']),
        expectedUnitWeightKg: _num(j['expectedUnitWeightKg']),
        expectedWeightKg: _num(j['expectedWeightKg']),
        deviationPct: _num(j['deviationPct']),
        alertLevel: WeightAlertLevel.parse(j['alertLevel']?.toString()),
        estimateBasisUsed: _str(j['estimateBasisUsed']),
        estimateTierUsed: _str(j['estimateTierUsed']),
        newRegime: j['newRegime'] == true,
        outlier: j['outlier'] == true,
        status: _str(j['status']) ?? 'NORMAL',
        remark: _str(j['remark']),
        recordedByName: _str(j['recordedByName']),
      );
}

/// POST /goods/{goodsId}/samples 请求体。
///
/// [weight] 是扣皮后的**净重**, 单位为 [weightUnit] (抽样单位, 常用克);
/// [tareKg] 只是这次抽样扣掉的托盘/容器皮重 (千克, 留痕用), 服务端不再从 weight 里扣。
class WeightSampleRequest {
  const WeightSampleRequest({
    required this.qty,
    required this.weight,
    required this.weightUnitCode,
    required this.idempotencyKey,
    this.tareKg,
    this.supplierId,
    this.warehouseId,
    this.newRegime = false,
    this.remark,
  });

  /// 抽样件数 (基本单位)。
  final double qty;
  final double weight;
  final String weightUnitCode;
  final double? tareKg;
  final String? supplierId;
  final String? warehouseId;
  final bool newRegime;
  final String? remark;
  final String idempotencyKey;

  Map<String, Object?> toJson() => {
    'qty': qty,
    'weight': weight,
    'weightUnit': weightUnitCode,
    'tareKg': ?tareKg,
    'supplierId': ?supplierId,
    'warehouseId': ?warehouseId,
    'newRegime': newRegime,
    if (remark != null && remark!.trim().isNotEmpty) 'remark': remark!.trim(),
    'idempotencyKey': idempotencyKey,
  };
}

/// PUT /goods/{goodsId}/profile 请求体 (整份设置 + 乐观版本号; 版本不符服务端 409)。
class WeightProfileUpdate {
  const WeightProfileUpdate({
    required this.expectedVersion,
    this.defaultTareKg,
    this.tolerancePct,
    this.pieceCvPct,
    this.manualUnitWeightKg,
    this.manualReason,
    this.learningEnabled = true,
    this.regimeMode = 'AUTO',
  });

  /// 从现有设置出发只改一部分时用它, 其余字段原样带回。
  factory WeightProfileUpdate.from(GoodsWeightProfile? p) =>
      WeightProfileUpdate(
        expectedVersion: p?.version ?? 0,
        defaultTareKg: p?.defaultTareKg,
        tolerancePct: p?.tolerancePct,
        pieceCvPct: p?.pieceCvPct,
        manualUnitWeightKg: p?.manualUnitWeightKg,
        manualReason: p?.manualReason,
        learningEnabled: p?.learningEnabled ?? true,
        regimeMode: p?.regimeMode ?? 'AUTO',
      );

  final int expectedVersion;
  final double? defaultTareKg;
  final double? tolerancePct;
  final double? pieceCvPct;
  final double? manualUnitWeightKg;
  final String? manualReason;
  final bool learningEnabled;
  final String regimeMode;

  WeightProfileUpdate copyWith({
    double? defaultTareKg,
    bool clearDefaultTare = false,
    double? tolerancePct,
    double? pieceCvPct,
    double? manualUnitWeightKg,
    bool clearManual = false,
    String? manualReason,
    bool? learningEnabled,
    String? regimeMode,
  }) => WeightProfileUpdate(
    expectedVersion: expectedVersion,
    defaultTareKg: clearDefaultTare
        ? null
        : (defaultTareKg ?? this.defaultTareKg),
    tolerancePct: tolerancePct ?? this.tolerancePct,
    pieceCvPct: pieceCvPct ?? this.pieceCvPct,
    manualUnitWeightKg: clearManual
        ? null
        : (manualUnitWeightKg ?? this.manualUnitWeightKg),
    manualReason: clearManual ? null : (manualReason ?? this.manualReason),
    learningEnabled: learningEnabled ?? this.learningEnabled,
    regimeMode: regimeMode ?? this.regimeMode,
  );

  Map<String, Object?> toJson() => {
    'expectedVersion': expectedVersion,
    'defaultTareKg': defaultTareKg,
    'tolerancePct': tolerancePct,
    'pieceCvPct': pieceCvPct,
    'manualUnitWeightKg': manualUnitWeightKg,
    'manualReason': manualReason,
    'learningEnabled': learningEnabled,
    'regimeMode': regimeMode,
  };
}

class WeightRepository {
  WeightRepository(this.api);

  final ApiClient api;

  /// 服务端单次上限。
  static const maxParamsLines = 500;

  /// 批量取单重参数与库存参考; 超过 500 行自动分批。按结构化身份对行。
  Future<WeightParamsResult> params(Iterable<WeightParamsLine> lines) async {
    final all = {
      for (final line in lines)
        if (line.goodsId.isNotEmpty) line,
    }.toList(growable: false);
    final params = <WeightParamsIdentity, WeightParams>{};
    final balances = <WeightBalanceIdentity, WeightStockBalance>{};
    for (var i = 0; i < all.length; i += maxParamsLines) {
      final chunk = all.sublist(i, math.min(i + maxParamsLines, all.length));
      final json = await api.post(
        ApiEndpoints.stockWeightParams,
        body: {'lines': chunk.map((l) => l.toJson()).toList()},
      );
      for (final raw in _maps(json['items'])) {
        final p = WeightParams.fromJson(raw);
        if (p.goodsId.isNotEmpty) params[p.identity] = p;
      }
      for (final raw in _maps(json['stockBalances'])) {
        final balance = WeightStockBalance.fromJson(raw);
        if (balance.usable && balance.goodsId.isNotEmpty) {
          balances[balance.identity] = balance;
        }
      }
    }
    return WeightParamsResult(params: params, balances: balances);
  }

  Future<GoodsWeightDetail> goods(String goodsId) async {
    final json = await api.get(ApiEndpoints.stockWeightGoods(goodsId));
    return GoodsWeightDetail.fromJson(json, goodsId: goodsId);
  }

  Future<PagedResult<WeightObservation>> observations(
    String goodsId, {
    int page = 1,
    int size = 20,
    String? kind,
    String? supplierId,
    String? stage,
  }) async {
    final json = await api.get(
      ApiEndpoints.stockWeightGoodsObservations(goodsId),
      query: {
        'page': page,
        'size': size,
        'kind': ?kind,
        'supplierId': ?supplierId,
        'stage': ?stage,
      },
    );
    return PagedResult.fromJson(json, WeightObservation.fromJson);
  }

  /// 称样校准: 记一条 SAMPLE 并同步重算, 返回刷新后的单货品详情。
  Future<GoodsWeightDetail> recordSample(
    String goodsId,
    WeightSampleRequest request,
  ) async {
    final json = await api.post(
      ApiEndpoints.stockWeightGoodsSamples(goodsId),
      body: request.toJson(),
    );
    return GoodsWeightDetail.fromJson(json, goodsId: goodsId);
  }

  /// 改单重设置 (版本不符 409); 回包是刷新后的单货品详情。
  Future<GoodsWeightDetail> updateProfile(
    String goodsId,
    WeightProfileUpdate update,
  ) async {
    final json = await api.put(
      ApiEndpoints.stockWeightGoodsProfile(goodsId),
      body: update.toJson(),
    );
    return GoodsWeightDetail.fromJson(json, goodsId: goodsId);
  }

  Future<void> excludeObservation(String observationId, String reason) =>
      api.post(
        ApiEndpoints.stockWeightObservationExclude(observationId),
        body: {'reason': reason.trim()},
      );

  Future<void> includeObservation(String observationId) =>
      api.post(ApiEndpoints.stockWeightObservationInclude(observationId));

  /// 从今天起重新学习 (manual_regime_start_at = now)。
  Future<void> resetRegime(String goodsId) =>
      api.post(ApiEndpoints.stockWeightGoodsResetRegime(goodsId));
}

final weightRepositoryProvider = Provider<WeightRepository>(
  (ref) => WeightRepository(ref.watch(apiClientProvider)),
);

/// 页内单重参数缓存: 一页一次批量取, 取回后通知订阅的格子重绘。
///
/// 重量从不阻断数量过账, 但取参失败不再静默 (ADR-151): [lastError] 由
/// [WeightParamsLoadNotice] 显示在页面上, [retryFailed] 只重取失败的那几行。
class WeightParamsCache extends ChangeNotifier {
  WeightParamsCache(this._repository);

  final WeightRepository _repository;
  final Map<WeightParamsIdentity, WeightParams> _items = {};

  /// 已取过的库存参考; 值为 null = 该仓库/颜色没有可用的正数重量余额。
  final Map<WeightBalanceIdentity, WeightStockBalance?> _balances = {};
  final Map<WeightParamsLine, Object> _pending = {};
  final Set<WeightParamsLine> _failed = {};
  final Map<String, int> _generations = {};
  bool _disposed = false;

  /// 最近一次取参失败的原因; 成功或重试时清空。
  Object? lastError;

  /// 失败后可重试 (界面显示「单重参数读取失败 · 重试」)。
  bool get hasFailed => lastError != null && _failed.isNotEmpty;

  WeightParams? of(
    String? goodsId, {
    String? supplierId,
    String? warehouseId,
    String? colorId,
  }) {
    if (goodsId == null || goodsId.isEmpty) return null;
    final line = WeightParamsLine(
      goodsId: goodsId,
      supplierId: supplierId,
      warehouseId: warehouseId,
      colorId: colorId,
    );
    final params = _items[line.paramsIdentity];
    final balance = line.balanceIdentity;
    return balance == null
        ? params
        : params?.withStockBalance(_balances[balance]);
  }

  bool isLoading(
    String goodsId, {
    String? supplierId,
    String? warehouseId,
    String? colorId,
  }) => _pending.containsKey(
    WeightParamsLine(
      goodsId: goodsId,
      supplierId: supplierId,
      warehouseId: warehouseId,
      colorId: colorId,
    ),
  );

  bool _loaded(WeightParamsLine line) {
    final balance = line.balanceIdentity;
    return _items.containsKey(line.paramsIdentity) &&
        (balance == null || _balances.containsKey(balance));
  }

  /// 补齐缺的参数 (已有/在途的不重复取)。
  Future<void> ensure(Iterable<WeightParamsLine> lines) async {
    if (_disposed) return;
    final missing = <WeightParamsLine>[];
    final token = Object();
    final generations = <String, int>{};
    for (final line in lines) {
      if (line.goodsId.isEmpty) continue;
      if (_loaded(line) || _pending.containsKey(line)) continue;
      _pending[line] = token;
      generations[line.goodsId] = _generations[line.goodsId] ?? 0;
      missing.add(line);
    }
    if (missing.isEmpty) return;
    try {
      final fetched = await _repository.params(missing);
      if (_disposed) return;
      for (final line in missing) {
        if (generations[line.goodsId] != (_generations[line.goodsId] ?? 0)) {
          continue;
        }
        final params = fetched.params[line.paramsIdentity];
        if (params != null) {
          _items.putIfAbsent(line.paramsIdentity, () => params);
        }
        final balance = line.balanceIdentity;
        if (balance != null) _balances[balance] = fetched.balances[balance];
        _failed.remove(line);
      }
      if (_failed.isEmpty) lastError = null;
    } catch (e) {
      if (_disposed) return;
      lastError = e;
      _failed.addAll(missing);
    } finally {
      for (final line in missing) {
        if (identical(_pending[line], token)) _pending.remove(line);
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// 只重取上次失败的行。
  Future<void> retryFailed() async {
    if (_disposed || _failed.isEmpty) return;
    final lines = _failed.toList(growable: false);
    _failed.clear();
    lastError = null;
    notifyListeners();
    await ensure(lines);
  }

  /// 某货品的参数作废 (称样/改设置后), 下次 [ensure] 重新取。
  void invalidateGoods(String goodsId) {
    if (_disposed) return;
    final before = _items.length + _balances.length;
    _items.removeWhere((key, value) => key.goodsId == goodsId);
    _balances.removeWhere((key, value) => key.goodsId == goodsId);
    _generations[goodsId] = (_generations[goodsId] ?? 0) + 1;
    _pending.removeWhere((line, _) => line.goodsId == goodsId);
    if (_items.length + _balances.length != before) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 页面级缓存: 页面 watch 期间存活, 离开页面自动释放。
final weightParamsCacheProvider = Provider.autoDispose<WeightParamsCache>((
  ref,
) {
  final cache = WeightParamsCache(ref.watch(weightRepositoryProvider));
  ref.onDispose(cache.dispose);
  return cache;
});

/// 能否称样校准 (到货入库 / 仓库单据编辑 / 单重管理 任一)。
final weightSampleAllowedProvider = Provider<bool>((ref) {
  final perms = ref.watch(currentPermissionsProvider);
  return perms.contains(Perm.warehouseInboundStockIn) ||
      perms.contains(Perm.stockDocEdit) ||
      perms.contains(Perm.stockWeightManage);
});

/// 能否管理单重 (设置/人工单重/排除/重新学习/核重)。
final weightManageAllowedProvider = Provider<bool>(
  (ref) =>
      ref.watch(currentPermissionsProvider).contains(Perm.stockWeightManage),
);

double? _expOrNull(double? logMean) =>
    logMean == null ? null : math.exp(logMean);

double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

DateTime? _date(Object? v) {
  final s = _str(v);
  return s == null ? null : DateTime.tryParse(s)?.toLocal();
}

List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? v.whereType<Map<String, dynamic>>().toList(growable: false)
    : const [];

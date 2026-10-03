// 库存分析 (ADR-135 §7.4, review/product.md §1.6) 的数据模型。
//
// 四个分段对应四个接口 (GET /stock/insights/health | cycle-count | weight-alerts | learning,
// stock_report:view)。口径全在服务端一次算完 (一次 CTE 跑当前范围, 排序/分页/合计服务端做,
// asOf = 业务日), 本文件只解析, 字段名与服务端 DTO 一一对应:
// - 数量/重量/天数一律可空: null = 未知 (没称 / 没有入库记录), 页面显示「未称」「—」, 绝不当 0;
// - 重量一律千克, 页面按用户显示单位换算 (lib/shared/measurement);
// - 金额只有 goods:cost:view 才下发 (costMasked = false), 没下发就不出金额列 (页面不再自己判权限);
// - 分页一律平铺 {items, page (从 1 起), size, total, totalPages[, totals]}。
import '../../../core/utils/china_datetime.dart';
import '../../../shared/measurement/weight_predictor.dart';
import '../../../shared/models/paged_result.dart';

/// 库存分析的四个分段 (视图切换, 始终有一个选中)。[code] 用于 ?segment= 深链。
enum WarehouseInsightSegment {
  health('health', '呆滞与库龄'),
  cycleCount('cycle-count', '盘点建议'),
  weightAlerts('weight-alerts', '称重异常'),
  learning('learning', '单重学习');

  const WarehouseInsightSegment(this.code, this.label);

  final String code;
  final String label;

  static WarehouseInsightSegment? parse(String? code) {
    final key = code?.trim().toLowerCase();
    for (final s in values) {
      if (s.code == key) return s;
    }
    return null;
  }
}

/// 顶部 KPI 概览 (随 /health 一起下发, 与表格同一仓库范围, 不受表格筛选影响)。
class WarehouseInsightOverview {
  const WarehouseInsightOverview({
    this.skuWithStock,
    this.knownWeightKg,
    this.weightUnknownRows,
    this.weighedCoveragePct,
    this.deadSku,
    this.aged180QtyPct,
    this.movements30d,
    this.alerts30d,
    this.receiptShort30d,
    this.drawOver30d,
    this.needsSample,
  });

  /// 有库存的品项数 (货品 x 颜色)。
  final int? skuWithStock;

  /// 已知库存重量合计 (千克; 未称的不计入, 另见 [weightUnknownRows])。
  final double? knownWeightKg;
  final int? weightUnknownRows;

  /// 称重覆盖率 (%): 有库存的余额行里重量是实称 (已知且不是估算) 的占比。
  final double? weighedCoveragePct;

  /// 呆滞品项: 有库存、近 90 天无消耗且最新一层入库早于 90 天。
  final int? deadSku;

  /// 库龄超 180 天 (含无入库记录的期初部分) 占库存数量的百分比。
  final double? aged180QtyPct;
  final int? movements30d;

  /// 近 30 天称重异常条数。
  final int? alerts30d;

  /// 其中来料少数 (到货称重偏轻) 的条数。
  final int? receiptShort30d;

  /// 其中领料超发 (领料称重偏重) 的条数。
  final int? drawOver30d;

  /// 待称样货品数 (有动态但单重未学准)。
  final int? needsSample;

  factory WarehouseInsightOverview.fromJson(Map<String, dynamic> j) =>
      WarehouseInsightOverview(
        skuWithStock: _int(j['skuWithStock']),
        knownWeightKg: _num(j['knownWeightKg']),
        weightUnknownRows: _int(j['weightUnknownRows']),
        weighedCoveragePct: _num(j['weighedCoveragePct']),
        deadSku: _int(j['deadSku']),
        aged180QtyPct: _num(j['aged180QtyPct']),
        movements30d: _int(j['movements30d']),
        alerts30d: _int(j['alerts30d']),
        receiptShort30d: _int(j['receiptShort30d']),
        drawOver30d: _int(j['drawOver30d']),
        needsSample: _int(j['needsSample']),
      );
}

/// ABC 分类 (按近 90 天出库次数累计: A 前 80%, B 到 95%, C 其余; N = 近 90 天没有消耗)。
String insightAbcLabel(String? abc) => switch (abc?.trim().toUpperCase()) {
  'A' => 'A',
  'B' => 'B',
  'C' => 'C',
  'N' => '无消耗',
  _ => '—',
};

/// 呆滞与库龄一行 (货品 x 颜色, 当前范围内各仓合计)。
class InsightHealthRow {
  const InsightHealthRow({
    required this.goodsId,
    this.code,
    this.name,
    this.colorId,
    this.colorName,
    this.unitName,
    this.qty,
    this.weightKg,
    this.weightEstimated = false,
    this.lastInAt,
    this.lastOutAt,
    this.idleDays,
    this.age0to30,
    this.age31to90,
    this.age91to180,
    this.age181to365,
    this.ageOver365,
    this.ageUnknown,
    this.out30,
    this.out90,
    this.out365,
    this.avgDailyOut90,
    this.daysOfCover,
    this.picks90,
    this.abc,
    this.dead = false,
    this.amountLocal,
    this.amountLocalText,
    this.costMasked = true,
  });

  final String goodsId;
  final String? code;
  final String? name;
  final String? colorId;
  final String? colorName;
  final String? unitName;
  final double? qty;

  /// 库存重量 (千克); null = 有没称的部分。
  final double? weightKg;
  final bool weightEstimated;

  /// 最后入库 (仍有存量的最新入库批次)。
  final DateTime? lastInAt;

  /// 最后消耗 (近 365 天内; 更早为 null)。
  final DateTime? lastOutAt;
  final int? idleDays;
  final double? age0to30;
  final double? age31to90;
  final double? age91to180;
  final double? age181to365;
  final double? ageOver365;

  /// 找不到入库记录的数量 (期初/迁移结存)。
  final double? ageUnknown;
  final double? out30;
  final double? out90;
  final double? out365;
  final double? avgDailyOut90;
  final double? daysOfCover;
  final int? picks90;
  final String? abc;

  /// 呆滞: 有库存、近 90 天没有消耗、最新批次也早于 90 天。
  final bool dead;

  /// 库存金额 (本币); 只有 goods:cost:view 才下发。
  final double? amountLocal;

  /// Authorized decimal payload retained before a display-only double conversion.
  final String? amountLocalText;

  /// 金额已按成本权限遮住 (服务端没说就当遮住)。
  final bool costMasked;

  /// 行键 (货品 + 颜色)。
  String get rowKey => '$goodsId|${colorId ?? ''}';

  factory InsightHealthRow.fromJson(Map<String, dynamic> j) => InsightHealthRow(
    goodsId: (j['goodsId'] ?? '').toString(),
    code: _str(j['code']),
    name: _str(j['name']),
    colorId: _str(j['colorId']),
    colorName: _str(j['colorName']),
    unitName: _str(j['unitName']),
    qty: _num(j['qty']),
    weightKg: _num(j['weightKg']),
    weightEstimated: j['weightEstimated'] == true,
    lastInAt: _date(j['lastInAt']),
    lastOutAt: _date(j['lastOutAt']),
    idleDays: _int(j['idleDays']),
    age0to30: _num(j['age0_30']),
    age31to90: _num(j['age31_90']),
    age91to180: _num(j['age91_180']),
    age181to365: _num(j['age181_365']),
    ageOver365: _num(j['ageOver365']),
    ageUnknown: _num(j['ageUnknown']),
    out30: _num(j['out30']),
    out90: _num(j['out90']),
    out365: _num(j['out365']),
    avgDailyOut90: _num(j['avgDailyOut90']),
    daysOfCover: _num(j['daysOfCover']),
    picks90: _int(j['picks90']),
    abc: _str(j['abc']),
    dead: j['dead'] == true,
    amountLocal: _num(j['amountLocal']),
    amountLocalText:
        (j['amountLocalExact'] ??
                (j['amountLocal'] is String ? j['amountLocal'] : null))
            ?.toString(),
    costMasked: j['costMasked'] != false,
  );
}

/// GET /health 回包: 概览 + 当页行 + 服务端合计 (qty / weightKg + 伴随项 / out90 / amountLocal)。
class InsightHealthResult {
  const InsightHealthResult({required this.overview, required this.rows});

  final WarehouseInsightOverview overview;
  final PagedResult<InsightHealthRow> rows;

  factory InsightHealthResult.fromJson(Map<String, dynamic> j) {
    final overview = j['overview'];
    return InsightHealthResult(
      overview: overview is Map<String, dynamic>
          ? WarehouseInsightOverview.fromJson(overview)
          : const WarehouseInsightOverview(),
      rows: PagedResult.fromJson(j, InsightHealthRow.fromJson),
    );
  }
}

/// 盘点建议原因码 -> 中文。
String cycleCountReasonLabel(String code) =>
    switch (code.trim().toUpperCase()) {
      'DUE' => '到期',
      'RESIDUAL' => '近期尾差',
      'ESTIMATED_WEIGHT' => '重量为估算',
      'UNKNOWN_WEIGHT' => '重量未称',
      'RED_TIER' => '单重未学准',
      _ => code,
    };

/// 盘点建议一行 (仓库 x 货品 x 颜色, 与盘点单明细同粒度)。
class InsightCycleCountRow {
  const InsightCycleCountRow({
    required this.warehouseId,
    required this.goodsId,
    this.warehouseName,
    this.colorId,
    this.colorName,
    this.code,
    this.name,
    this.unitName,
    this.abc,
    this.lastCountedOn,
    this.daysSince,
    this.reasons = const [],
    this.score,
    this.qty,
    this.weightKg,
    this.weightEstimated = false,
  });

  final String warehouseId;
  final String? warehouseName;
  final String goodsId;

  /// 颜色 (无颜色货品为 null); 原样带进盘点单预填。
  final String? colorId;
  final String? colorName;
  final String? code;
  final String? name;
  final String? unitName;
  final String? abc;

  /// 上次盘点日 (该仓该颜色最近一张已审核盘点单); null = 从没盘过 (按首次出入库日起算)。
  final DateTime? lastCountedOn;
  final int? daysSince;
  final List<String> reasons;
  final double? score;
  final double? qty;
  final double? weightKg;
  final bool weightEstimated;

  /// 勾选键 (仓 + 货品 + 颜色)。
  String get rowKey => '$warehouseId|$goodsId|${colorId ?? ''}';

  /// 优先级 (按服务端分数分三档, 分数本身用于排序)。
  String get priorityLabel {
    final s = score;
    if (s == null) return '—';
    if (s >= 2) return '高';
    if (s >= 1) return '中';
    return '低';
  }

  String get reasonText => reasons.isEmpty
      ? '—'
      : reasons.map(cycleCountReasonLabel).toSet().join('、');

  factory InsightCycleCountRow.fromJson(Map<String, dynamic> j) =>
      InsightCycleCountRow(
        warehouseId: (j['warehouseId'] ?? '').toString(),
        warehouseName: _str(j['warehouseName']),
        goodsId: (j['goodsId'] ?? '').toString(),
        colorId: _str(j['colorId']),
        colorName: _str(j['colorName']),
        code: _str(j['code']),
        name: _str(j['name']),
        unitName: _str(j['unitName']),
        abc: _str(j['abc']),
        lastCountedOn: _date(j['lastCountedOn']),
        daysSince: _int(j['daysSince']),
        reasons: [
          if (j['reasons'] is List)
            for (final r in j['reasons'] as List)
              if (_str(r) != null) _str(r)!,
        ],
        score: _num(j['score']),
        qty: _num(j['qty']),
        weightKg: _num(j['weightKg']),
        weightEstimated: j['weightEstimated'] == true,
      );
}

/// 称重异常一行: 一条记录当时就告警的称重记录 (OBSERVATION), 或一次「单重可能已变化」(REGIME)。
/// 类别、折算数量与偏差都由服务端按记录当时的快照算好。
class InsightWeightAlertRow {
  const InsightWeightAlertRow({
    required this.id,
    required this.goodsId,
    this.rowType,
    this.alertKind,
    this.alertLabel,
    this.sourceKind,
    this.observedAt,
    this.code,
    this.name,
    this.colorName,
    this.unitName,
    this.supplierId,
    this.supplierName,
    this.counterpartKind,
    this.counterpartName,
    this.sourceDocType,
    this.sourceDocId,
    this.sourceDocCode,
    this.billNo,
    this.qtyBase,
    this.weightKg,
    this.estimatedQty,
    this.deviationQty,
    this.expectedWeightKg,
    this.expectedUnitWeightKg,
    this.deviationPct,
    this.alertLevel = WeightAlertLevel.none,
    this.tierUsed,
    this.integerQty = true,
  });

  final String id;
  final String goodsId;

  /// OBSERVATION / REGIME。
  final String? rowType;

  /// RECEIPT_SHORT / RECEIPT_OVER / DRAW_OVER / DRAW_SHORT / RETURN_MISMATCH / COUNT_MISMATCH /
  /// FINISHED_MISMATCH / INBOUND_MISMATCH / OUTBOUND_MISMATCH / SAMPLE_DEVIATION / REGIME_CHANGE。
  final String? alertKind;

  /// 类别中文名 (来料少数 / 领料超发 / 单重可能已变化(换批/换料?) …)。
  final String? alertLabel;

  /// 称重来源 RECEIPT / DRAW / RETURN / COUNT / FINISHED / SAMPLE …
  final String? sourceKind;
  final DateTime? observedAt;
  final String? code;
  final String? name;
  final String? colorName;
  final String? unitName;
  final String? supplierId;
  final String? supplierName;
  final String? counterpartKind;
  final String? counterpartName;
  final String? sourceDocType;
  final String? sourceDocId;
  final String? sourceDocCode;
  final String? billNo;

  /// 登记数量 (基本单位)。
  final double? qtyBase;
  final double? weightKg;

  /// 称重折算数量 (实称 / 记录当时的单重)。
  final double? estimatedQty;

  /// 折算数量 - 登记数量 (负 = 称重显示偏少)。
  final double? deviationQty;
  final double? expectedWeightKg;
  final double? expectedUnitWeightKg;
  final double? deviationPct;
  final WeightAlertLevel alertLevel;

  /// 记录当时的单重可靠度 (REGIME 为当前可靠度)。
  final WeightTier? tierUsed;

  /// 按件计 (数量取整显示)。
  final bool integerQty;

  bool get isRegimeChange => rowType == 'REGIME';

  /// 往来方 (供应商或车间/委外商/客户)。
  String? get counterpartText => supplierName ?? counterpartName;

  String get typeLabel => alertLabel ?? '—';

  factory InsightWeightAlertRow.fromJson(Map<String, dynamic> j) {
    final dimension = _str(j['baseUnitDimension'])?.toUpperCase();
    return InsightWeightAlertRow(
      id: (j['id'] ?? '').toString(),
      goodsId: (j['goodsId'] ?? '').toString(),
      rowType: _str(j['rowType'])?.toUpperCase(),
      alertKind: _str(j['alertKind']),
      alertLabel: _str(j['alertLabel']),
      sourceKind: _str(j['sourceKind']),
      observedAt: _date(j['observedAt']),
      code: _str(j['code']),
      name: _str(j['name']),
      colorName: _str(j['colorName']),
      unitName: _str(j['unitName']),
      supplierId: _str(j['supplierId']),
      supplierName: _str(j['supplierName']),
      counterpartKind: _str(j['counterpartKind']),
      counterpartName: _str(j['counterpartName']),
      sourceDocType: _str(j['sourceDocType']),
      sourceDocId: _str(j['sourceDocId']),
      sourceDocCode: _str(j['sourceDocCode']),
      billNo: _str(j['billNo']),
      qtyBase: _num(j['qtyBase']),
      weightKg: _num(j['weightKg']),
      estimatedQty: _num(j['estimatedQty']),
      deviationQty: _num(j['deviationQty']),
      expectedWeightKg: _num(j['expectedWeightKg']),
      expectedUnitWeightKg: _num(j['expectedUnitWeightKg']),
      deviationPct: _num(j['deviationPct']),
      alertLevel: WeightAlertLevel.parse(j['alertLevel']?.toString()),
      tierUsed: WeightTier.parse(j['estimateTierUsed']?.toString()),
      integerQty:
          dimension == null || dimension.isEmpty || dimension == 'COUNT',
    );
  }
}

/// 往来方汇总的一行 (服务端 WeightPartySummary): 供应商 = 来料少数, 车间 = 领料超发。
class InsightCounterpartSummary {
  const InsightCounterpartSummary({
    required this.kind,
    required this.partyId,
    this.partyName,
    this.events,
    this.flagged,
    this.avgPct,
    this.kg,
  });

  /// SUPPLIER / WORKSHOP (来自 supplierSummary / workshopSummary 哪个列表)。
  final String kind;
  final String partyId;
  final String? partyName;

  /// 到货称重次数 / 领料称重次数。
  final int? events;

  /// 来料少数次数 / 领料超发次数。
  final int? flagged;

  /// 这些异常次数的平均偏差 % (供应商为负 = 偏轻, 车间为正 = 偏重)。
  final double? avgPct;

  /// 少了的重量 / 多发的重量 (千克, 正数)。
  final double? kg;

  bool get isSupplier => kind == 'SUPPLIER';

  String get rowKey => '$kind|$partyId';

  factory InsightCounterpartSummary.fromJson(
    String kind,
    Map<String, dynamic> j,
  ) => InsightCounterpartSummary(
    kind: kind,
    partyId: (j['partyId'] ?? '').toString(),
    partyName: _str(j['partyName']),
    events: _int(j['events']),
    flagged: _int(j['flagged']),
    avgPct: _num(j['avgPct']),
    kg: _num(j['kg']),
  );
}

/// GET /weight-alerts 回包: 当页异常行 + 往来方汇总 (与异常行同一 days 窗口)。
class InsightWeightAlertsResult {
  const InsightWeightAlertsResult({
    required this.rows,
    this.supplierSummary = const [],
    this.workshopSummary = const [],
  });

  final PagedResult<InsightWeightAlertRow> rows;
  final List<InsightCounterpartSummary> supplierSummary;
  final List<InsightCounterpartSummary> workshopSummary;

  factory InsightWeightAlertsResult.fromJson(Map<String, dynamic> j) =>
      InsightWeightAlertsResult(
        rows: PagedResult.fromJson(j, InsightWeightAlertRow.fromJson),
        supplierSummary: [
          for (final m in _maps(j['supplierSummary']))
            InsightCounterpartSummary.fromJson('SUPPLIER', m),
        ],
        workshopSummary: [
          for (final m in _maps(j['workshopSummary']))
            InsightCounterpartSummary.fromJson('WORKSHOP', m),
        ],
      );
}

/// 单重学习清单的筛选 (服务端 filter 参数)。
enum InsightLearningFilter {
  needsSample('NEEDS_SAMPLE', '需称样'),
  masterMismatch('MASTER_MISMATCH', '与设计单重不符'),
  drawOnly('DRAW_ONLY', '仅按领料推算'),
  conflict('CONFLICT', '称重矛盾'),
  all('ALL', '全部');

  const InsightLearningFilter(this.code, this.label);

  final String code;
  final String label;
}

/// 单重学习清单一行 (货品级; 单重依据/可靠度与 /stock/weight/params 同一解析)。
class InsightLearningRow {
  const InsightLearningRow({
    required this.goodsId,
    this.code,
    this.name,
    this.unitName,
    this.basis,
    this.evidence,
    this.tier,
    this.unitWeightKg,
    this.relHalfWidth,
    this.nInliers,
    this.nRef,
    this.nDraw,
    this.lastObservedAt,
    this.masterUnitWeightKg,
    this.masterDiffPct,
    this.suggestedSampleSize,
    this.stale = false,
    this.baseUnitDimension,
    this.learningEnabled = true,
  });

  final String goodsId;
  final String? code;
  final String? name;

  /// 基本单位名 (抽样数量的单位)。
  final String? unitName;

  /// MANUAL / LEARNED / MASTER_PRIOR / NONE (按重量计的货品不在清单里)。
  final String? basis;

  /// REFERENCE / DRAW_ONLY / CONFLICT。
  final String? evidence;
  final WeightTier? tier;

  /// 当前单重 (千克/基本单位)。
  final double? unitWeightKg;
  final double? relHalfWidth;
  final int? nInliers;

  /// 货品总体学习结果的参考称重次数 / 领料称重次数。
  final int? nRef;
  final int? nDraw;
  final DateTime? lastObservedAt;

  /// 货品资料设计单重 (已折算成千克/基本单位)。
  final double? masterUnitWeightKg;

  /// 学到的单重与设计单重的差异 %。
  final double? masterDiffPct;
  final int? suggestedSampleSize;
  final bool stale;
  final String? baseUnitDimension;
  final bool learningEnabled;

  /// 按件计 (抽样数量取整)。
  bool get integerQty {
    final d = baseUnitDimension?.trim().toUpperCase();
    return d == null || d.isEmpty || d == 'COUNT';
  }

  /// 依据说明: 「近23次称重」「按过往领料推算 (领料12次)」「人工设定单重」…
  String get basisText {
    final e = evidence?.toUpperCase();
    final text = switch (basis?.toUpperCase()) {
      'EXACT' => '按数量精确换算',
      'MANUAL' => '人工设定单重',
      'MASTER_PRIOR' => '货品资料设计单重',
      'LEARNED' when e == 'DRAW_ONLY' =>
        nDraw == null ? '按过往领料推算' : '按过往领料推算 (领料$nDraw次)',
      'LEARNED' when e == 'CONFLICT' => '称重记录互相矛盾',
      'LEARNED' => nInliers == null ? '称重学习' : '近$nInliers次称重',
      _ => '暂无单重',
    };
    return stale ? '$text, 超过一年没称过' : text;
  }

  /// 称样保存后用服务端刷新的单重详情更新本行。
  InsightLearningRow copyWith({
    String? basis,
    String? evidence,
    WeightTier? tier,
    double? unitWeightKg,
    double? relHalfWidth,
    int? nInliers,
    DateTime? lastObservedAt,
    int? suggestedSampleSize,
    bool? stale,
  }) => InsightLearningRow(
    goodsId: goodsId,
    code: code,
    name: name,
    unitName: unitName,
    basis: basis ?? this.basis,
    evidence: evidence ?? this.evidence,
    tier: tier ?? this.tier,
    unitWeightKg: unitWeightKg ?? this.unitWeightKg,
    relHalfWidth: relHalfWidth ?? this.relHalfWidth,
    nInliers: nInliers ?? this.nInliers,
    nRef: nRef,
    nDraw: nDraw,
    lastObservedAt: lastObservedAt ?? this.lastObservedAt,
    masterUnitWeightKg: masterUnitWeightKg,
    masterDiffPct: masterDiffPct,
    suggestedSampleSize: suggestedSampleSize ?? this.suggestedSampleSize,
    stale: stale ?? this.stale,
    baseUnitDimension: baseUnitDimension,
    learningEnabled: learningEnabled,
  );

  factory InsightLearningRow.fromJson(Map<String, dynamic> j) =>
      InsightLearningRow(
        goodsId: (j['goodsId'] ?? '').toString(),
        code: _str(j['code']),
        name: _str(j['name']),
        unitName: _str(j['unitName']),
        basis: _str(j['basis']),
        evidence: _str(j['evidence']),
        tier: WeightTier.parse(j['tier']?.toString()),
        unitWeightKg: _num(j['unitWeightKg']),
        relHalfWidth: _num(j['relHalfWidth']),
        nInliers: _int(j['nInliers']),
        nRef: _int(j['nRef']),
        nDraw: _int(j['nDraw']),
        lastObservedAt: _date(j['lastObservedAt']),
        masterUnitWeightKg: _num(j['masterUnitWeightKg']),
        masterDiffPct: _num(j['masterDiffPct']),
        suggestedSampleSize: _int(j['suggestedSampleSize']),
        stale: j['stale'] == true,
        baseUnitDimension: _str(j['baseUnitDimension']),
        learningEnabled: j['learningEnabled'] != false,
      );
}

double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? double.tryParse(v.toString())?.toInt();
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

/// 业务日期/时间一律按中国墙上时间解析 (纯日期原样; 带时区的时间戳换算成北京时间)。
DateTime? _date(Object? v) => ChinaDateTime.tryParse(_str(v));

List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? v.whereType<Map<String, dynamic>>().toList(growable: false)
    : const [];

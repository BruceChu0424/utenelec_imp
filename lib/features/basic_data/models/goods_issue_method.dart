// 货品「发料方式 / 分摊方式」切换的预览与提交模型 (ADR-131)。
//
// 对应后端 GoodsPeriodicMaterialDtos (GET /master/goods/{id}/issue-method/preview、
// PUT /master/goods/issue-method/batch)。切换前先看影响：用到这种料的 BOM 行怎么处理
// (改成单个重量 / 从 BOM 去掉 / 改回齐套门槛 / 要先人工改)、还没核清的按工单领料需求、
// 车间内料仓账面、没结算的期间与理论用量、在做的工单、会作废的开工认料。服务端算好能不能切
// (canSwitch) 与不能切的原因 (blockers, 员工能看懂的中文)，页面只展示。
//
// 状态、动作字段是代码，页面按代码配中文；各处 note / blockers 是服务端写好的中文。
// 数值字段一律 (x as num?)?.toDouble()，防 int/double 序列化差异。

List<Map<String, dynamic>> _maps(Object? raw) => [
  for (final item in (raw is List ? raw : const []))
    if (item is Map<String, dynamic>) item,
];

String? _text(Object? raw) {
  if (raw is! String) return null;
  final t = raw.trim();
  return t.isEmpty ? null : t;
}

double? _num(Object? raw) => raw is num ? raw.toDouble() : null;

/// 用到这种料的一行 BOM 在切换时怎么处理 (后端 AffectedBomRow)。
class GoodsIssueMethodBomRow {
  const GoodsIssueMethodBomRow({
    this.bomItemId,
    this.productGoodsId,
    this.productCode,
    this.productName,
    this.qty,
    this.unitWeightGrams,
    this.action,
    this.note,
  });

  /// 改成单个重量 (开工前、按每件、不设齐套门槛)。
  static const actionConvert = 'CONVERT';

  /// 不用改。
  static const actionKeep = 'KEEP';

  /// 辅料 / 记车间费用的料不写进 BOM，从这个产品的 BOM 里去掉。
  static const actionRemove = 'REMOVE';

  /// 改回按工单领料的齐套门槛。
  static const actionRestore = 'RESTORE';

  /// 按包装、按批或基准产量折不成每件用量，要先人工改 (标红)。
  static const actionBlocked = 'BLOCKED';

  final String? bomItemId;
  final String? productGoodsId;
  final String? productCode;
  final String? productName;

  /// BOM 现在的用量 (这种料的基本单位)。
  final double? qty;

  /// 切换后的单个重量 (克)；不能按克换算时为 null。
  final double? unitWeightGrams;
  final String? action;

  /// 服务端给的一句话说明。
  final String? note;

  /// 必须先在 BOM 里改掉才能切换 (标红)。
  bool get mustFixFirst => action == actionBlocked;

  /// 给员工看的处理方式。
  String get actionLabel => switch (action) {
    actionConvert => '改成只填单个重量',
    actionRemove => '从这个产品的 BOM 里去掉',
    actionRestore => '改回按工单领料的齐套门槛',
    actionBlocked => '要先在 BOM 里改成按每件',
    _ => '不用改',
  };

  factory GoodsIssueMethodBomRow.fromJson(Map<String, dynamic> json) =>
      GoodsIssueMethodBomRow(
        bomItemId: _text(json['bomItemId']),
        productGoodsId: _text(json['productGoodsId']),
        productCode: _text(json['productCode']),
        productName: _text(json['productName']),
        qty: _num(json['qty']),
        unitWeightGrams: _num(json['unitWeightGrams']),
        action: _text(json['action']),
        note: _text(json['note']),
      );
}

/// 按工单领了这种料、还没核清的需求 (改为整批领料的前提是一条都没有)。
class GoodsIssueMethodUnclearedDemand {
  const GoodsIssueMethodUnclearedDemand({
    this.demandId,
    this.planNo,
    this.segmentCode,
    this.productCode,
    this.productName,
    this.unclearedQty,
    this.note,
  });

  final String? demandId;

  /// 生产计划单号。
  final String? planNo;

  /// 工单 (生产任务段) 编号。
  final String? segmentCode;
  final String? productCode;
  final String? productName;

  /// 已领 − 已退 − 已清账 (实耗 + 核定损耗)。
  final double? unclearedQty;

  /// 服务端给的一句话说明 (怎么清)。
  final String? note;

  /// 「计划单号 / 工单号」式的显示名。
  String get orderLabel {
    final parts = [planNo, segmentCode].whereType<String>().toList();
    return parts.isEmpty ? '工单' : parts.join(' / ');
  }

  factory GoodsIssueMethodUnclearedDemand.fromJson(Map<String, dynamic> json) =>
      GoodsIssueMethodUnclearedDemand(
        demandId: _text(json['demandId']),
        planNo: _text(json['planNo']),
        segmentCode: _text(json['segmentCode']),
        productCode: _text(json['productCode']),
        productName: _text(json['productName']),
        unclearedQty: _num(json['unclearedQty']),
        note: _text(json['note']),
      );
}

/// 车间内料仓里这种料的账面 (不为 0 时不能改回按工单领料或改分摊方式)。
class GoodsIssueMethodBinBalance {
  const GoodsIssueMethodBinBalance({this.warehouseName, this.qty});

  final String? warehouseName;
  final double? qty;

  factory GoodsIssueMethodBinBalance.fromJson(Map<String, dynamic> json) =>
      GoodsIssueMethodBinBalance(
        warehouseName: _text(json['warehouseName']),
        qty: _num(json['qty']),
      );
}

/// 还没结算、用到这种料的内料仓期间。
class GoodsIssueMethodOpenPeriod {
  const GoodsIssueMethodOpenPeriod({
    this.binName,
    this.periodNo,
    this.startDate,
    this.endDate,
    this.status,
  });

  final String? binName;
  final int? periodNo;
  final String? startDate;
  final String? endDate;

  /// OPEN / COUNTING / COUNTED。
  final String? status;

  factory GoodsIssueMethodOpenPeriod.fromJson(Map<String, dynamic> json) =>
      GoodsIssueMethodOpenPeriod(
        binName: _text(json['binName']),
        periodNo: (json['periodNo'] as num?)?.toInt(),
        startDate: _text(json['startDate']),
        endDate: _text(json['endDate']),
        status: _text(json['status']),
      );
}

/// 还没结算的日子里按这种料算了理论用量的产品 (按内料仓汇总)。
class GoodsIssueMethodUnsettledTheory {
  const GoodsIssueMethodUnsettledTheory({
    this.binName,
    this.productCount = 0,
    this.theoryQty,
  });

  final String? binName;
  final int productCount;
  final double? theoryQty;

  factory GoodsIssueMethodUnsettledTheory.fromJson(Map<String, dynamic> json) =>
      GoodsIssueMethodUnsettledTheory(
        binName: _text(json['binName']),
        productCount: (json['productCount'] as num?)?.toInt() ?? 0,
        theoryQty: _num(json['theoryQty']),
      );
}

/// 按整批领料用着这种料、还在生产中的工单。
class GoodsIssueMethodInProgressSegment {
  const GoodsIssueMethodInProgressSegment({
    this.segmentId,
    this.segmentCode,
    this.productCode,
    this.productName,
  });

  final String? segmentId;
  final String? segmentCode;
  final String? productCode;
  final String? productName;

  factory GoodsIssueMethodInProgressSegment.fromJson(
    Map<String, dynamic> json,
  ) => GoodsIssueMethodInProgressSegment(
    segmentId: _text(json['segmentId']),
    segmentCode: _text(json['segmentCode']),
    productCode: _text(json['productCode']),
    productName: _text(json['productName']),
  );
}

/// 认了这种料的产品 (切换后作废，下次开工重新认料)。
class GoodsIssueMethodChoice {
  const GoodsIssueMethodChoice({
    this.productGoodsId,
    this.productCode,
    this.productName,
  });

  final String? productGoodsId;
  final String? productCode;
  final String? productName;

  factory GoodsIssueMethodChoice.fromJson(Map<String, dynamic> json) =>
      GoodsIssueMethodChoice(
        productGoodsId: _text(json['productGoodsId']),
        productCode: _text(json['productCode']),
        productName: _text(json['productName']),
      );
}

/// 切换预览 (GET /master/goods/{id}/issue-method/preview?target=&costBasis=)。
class GoodsIssueMethodPreview {
  const GoodsIssueMethodPreview({
    required this.goodsId,
    required this.targetIssueMethod,
    this.targetCostBasis,
    this.goodsName,
    this.currentIssueMethod,
    this.currentCostBasis,
    this.version,
    this.unitName,
    this.massUnit = true,
    this.canSwitch = true,
    this.blockers = const [],
    this.suggestedBulkPackageQty,
    this.bomRows = const [],
    this.unclearedDemands = const [],
    this.binBalances = const [],
    this.openPeriods = const [],
    this.unsettledTheory = const [],
    this.inProgressSegments = const [],
    this.activeChoices = const [],
  });

  final String goodsId;

  /// ORDER / PERIODIC。
  final String targetIssueMethod;

  /// OWN / SHARED / EXPENSE；按工单领料为 null。
  final String? targetCostBasis;
  final String? goodsName;
  final String? currentIssueMethod;
  final String? currentCostBasis;

  /// 货品当前行版本 (提交时作 expectedVersion)。
  final int? version;

  /// 这种料的基本单位名。
  final String? unitName;

  /// 基本单位是不是重量单位 (整批领料必须是)。
  final bool massUnit;

  /// 服务端判定能否切换；false 时 [blockers] 说明先要做什么。
  final bool canSwitch;
  final List<String> blockers;

  /// 每袋净重预填值 (已填的每袋净重，没填时取整包装量)。
  final double? suggestedBulkPackageQty;

  final List<GoodsIssueMethodBomRow> bomRows;
  final List<GoodsIssueMethodUnclearedDemand> unclearedDemands;
  final List<GoodsIssueMethodBinBalance> binBalances;
  final List<GoodsIssueMethodOpenPeriod> openPeriods;
  final List<GoodsIssueMethodUnsettledTheory> unsettledTheory;
  final List<GoodsIssueMethodInProgressSegment> inProgressSegments;
  final List<GoodsIssueMethodChoice> activeChoices;

  /// 预览对应的是不是这组目标 (发料方式 + 分摊方式)；用户切得快时丢掉过期的预览。
  bool matches(String method, String? costBasis) =>
      targetIssueMethod == method &&
      (method != 'PERIODIC' || targetCostBasis == costBasis);

  factory GoodsIssueMethodPreview.fromJson(
    Map<String, dynamic> json, {
    required String goodsId,
    required String target,
  }) {
    final blockers = json['blockers'];
    return GoodsIssueMethodPreview(
      goodsId: _text(json['goodsId']) ?? goodsId,
      targetIssueMethod: _text(json['targetIssueMethod']) ?? target,
      targetCostBasis: _text(json['targetCostBasis']),
      goodsName: _text(json['goodsName']),
      currentIssueMethod: _text(json['currentIssueMethod']),
      currentCostBasis: _text(json['currentCostBasis']),
      version: (json['version'] as num?)?.toInt(),
      unitName: _text(json['unitName']),
      massUnit: json['massUnit'] != false,
      canSwitch: json['canSwitch'] != false,
      blockers: [
        for (final r in (blockers is List ? blockers : const []))
          if (r is String && r.trim().isNotEmpty) r.trim(),
      ],
      suggestedBulkPackageQty: _num(json['suggestedBulkPackageQty']),
      bomRows: _maps(
        json['bomRows'],
      ).map(GoodsIssueMethodBomRow.fromJson).toList(),
      unclearedDemands: _maps(
        json['unclearedDemands'],
      ).map(GoodsIssueMethodUnclearedDemand.fromJson).toList(),
      binBalances: _maps(
        json['binBalances'],
      ).map(GoodsIssueMethodBinBalance.fromJson).toList(),
      openPeriods: _maps(
        json['openPeriods'],
      ).map(GoodsIssueMethodOpenPeriod.fromJson).toList(),
      unsettledTheory: _maps(
        json['unsettledTheory'],
      ).map(GoodsIssueMethodUnsettledTheory.fromJson).toList(),
      inProgressSegments: _maps(
        json['inProgressSegments'],
      ).map(GoodsIssueMethodInProgressSegment.fromJson).toList(),
      activeChoices: _maps(
        json['activeChoices'],
      ).map(GoodsIssueMethodChoice.fromJson).toList(),
    );
  }
}

/// 一条切换请求 (PUT /master/goods/issue-method/batch 的 items[])。
class GoodsIssueMethodChange {
  const GoodsIssueMethodChange({
    required this.goodsId,
    required this.expectedVersion,
    required this.issueMethod,
    this.periodicCostBasis,
    this.bulkPackageQty,
    this.recycledMaterial = false,
  });

  final String goodsId;
  final int? expectedVersion;
  final String issueMethod;
  final String? periodicCostBasis;

  /// 每袋净重；null = 不改 (服务端保留原值)。
  final double? bulkPackageQty;
  final bool recycledMaterial;

  Map<String, dynamic> toJson() => {
    'goodsId': goodsId,
    'expectedVersion': expectedVersion,
    'issueMethod': issueMethod,
    // 按工单领料时分摊方式必须为空 (服务端与数据库约束)。
    'periodicCostBasis': issueMethod == 'PERIODIC' ? periodicCostBasis : null,
    'bulkPackageQty': bulkPackageQty,
    'isRecycledMaterial': recycledMaterial,
  };

  /// 幂等键的规范化内容：同一次切换重试得到同一个键。
  String canonical() =>
      '$goodsId|$expectedVersion|$issueMethod|'
      '${issueMethod == 'PERIODIC' ? periodicCostBasis ?? '' : ''}|'
      '${bulkPackageQty ?? ''}|$recycledMaterial';
}

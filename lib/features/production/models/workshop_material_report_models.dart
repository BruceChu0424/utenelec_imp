// 车间内料仓用量报表与结算状态模型 (ADR-131 §5.10 / 实现规格 §2.3)。
//
// 对应后端 /api/workshop-material 下：settings (选内料仓)、periods (选期间)、
// periods/{id}/close-status (结算状态)、reports/{bin-usage | product-usage |
// waste-trend | missing-weights | ledger}。
//
// 金额字段 (现值、结算时金额、单价、单件材料成本) 只对有「看成本」权限的人下发，
// 其余人收到 null——页面据此整列隐藏，不在客户端判断权限。
// 数值字段一律 (x as num?)?.toDouble()，防 int/double 序列化差异。

double? _d(Object? raw) => raw is num ? raw.toDouble() : null;

int? _i(Object? raw) => raw is num ? raw.toInt() : null;

String? _s(Object? raw) {
  if (raw is! String) return null;
  final t = raw.trim();
  return t.isEmpty ? null : t;
}

List<String> _strings(Object? raw) => [
  for (final item in (raw is List ? raw : const []))
    if (item is String && item.trim().isNotEmpty) item.trim(),
];

Map<String, dynamic>? _map(Object? raw) =>
    raw is Map<String, dynamic> ? raw : null;

/// 可选的车间内料仓 (来自 GET /workshop-material/settings，只取已指定内料仓的车间)。
class WmReportBin {
  const WmReportBin({
    required this.binWarehouseId,
    this.workshopDepartmentId,
    this.workshopName,
    this.binWarehouseName,
    this.periodicEnabled = false,
    this.currentPeriodId,
  });

  final String binWarehouseId;
  final String? workshopDepartmentId;
  final String? workshopName;
  final String? binWarehouseName;
  final bool periodicEnabled;
  final String? currentPeriodId;

  /// 下拉显示名：内料仓名优先，否则「车间名 内料仓」。
  String get label =>
      binWarehouseName ?? (workshopName == null ? '内料仓' : '$workshopName内料仓');

  /// settings 行没有内料仓 (从没开启过) 时返回 null。
  static WmReportBin? fromSettingsJson(Map<String, dynamic> json) {
    final binId = _s(json['binWarehouseId']);
    if (binId == null) return null;
    return WmReportBin(
      binWarehouseId: binId,
      workshopDepartmentId: _s(json['workshopDepartmentId']),
      workshopName: _s(json['workshopName']),
      binWarehouseName: _s(json['binWarehouseName']),
      periodicEnabled: json['periodicEnabled'] == true,
      currentPeriodId: _s(_map(json['currentPeriod'])?['id']),
    );
  }
}

/// 一个盘点期间 (两次盘点之间)。
class WmReportPeriod {
  const WmReportPeriod({
    required this.id,
    this.periodNo,
    this.startDate,
    this.endDate,
    this.status,
    this.closeState,
    this.rowVersion,
  });

  final String id;
  final int? periodNo;
  final String? startDate;

  /// 截止日；开着的那一期为 null。
  final String? endDate;

  /// OPEN / COUNTING / COUNTED / CLOSED。
  final String? status;

  /// NONE / QUEUED / BLOCKED / HELD / FAILED。
  final String? closeState;

  /// 期间行版本 (撤销结算的 expectedVersion)。
  final int? rowVersion;

  /// 「第 3 期 9/1 - 9/30」式的显示名。
  String get label {
    final no = periodNo == null ? '' : '第 $periodNo 期 ';
    final range = endDate == null
        ? '${startDate ?? ''} 起'
        : '${startDate ?? ''} 至 $endDate';
    return '$no$range'.trim();
  }

  factory WmReportPeriod.fromJson(Map<String, dynamic> json) => WmReportPeriod(
    id: json['id'] as String? ?? '',
    periodNo: _i(json['periodNo'] ?? json['no']),
    startDate: _s(json['startDate']),
    endDate: _s(json['endDate']),
    status: _s(json['status']),
    closeState: _s(json['closeState']),
    rowVersion: _i(json['rowVersion'] ?? json['version']),
  );
}

/// 结算被拦的一项：差什么、几条、谁来补、前几个样例名称。
class WmReportCloseBlocker {
  const WmReportCloseBlocker({
    required this.kind,
    this.count = 0,
    this.responsible,
    this.samples = const [],
  });

  /// PREVIOUS_PERIOD_OPEN / DRAFT_REPORT / MISSING_WEIGHT / THEORY_WITHOUT_STOCK。
  final String kind;
  final int count;

  /// 服务端给的责任人说明 (员工可读，如「报工审核人或制单人」)。
  final String? responsible;
  final List<String> samples;

  factory WmReportCloseBlocker.fromJson(Map<String, dynamic> json) =>
      WmReportCloseBlocker(
        kind: _s(json['kind']) ?? '',
        count: _i(json['count']) ?? 0,
        responsible: _s(json['responsible']),
        samples: _strings(json['samples']),
      );
}

/// 期间的结算状态 (GET /periods/{id}/close-status；页面每 2 秒轮询，最多 60 秒)。
class WmReportCloseStatus {
  const WmReportCloseStatus({
    required this.periodId,
    this.status,
    this.closeState,
    this.attempts = 0,
    this.failures = 0,
    this.attemptedAt,
    this.lastErrorMessage,
    this.blockers = const [],
    this.heldUntil,
    this.lastCloseNo,
    this.lastClosedAt,
    this.lastClosedByName,
    this.rowVersion,
    this.allowedActions = const {},
  });

  final String periodId;
  final String? status;
  final String? closeState;
  final int attempts;

  /// 连续失败次数 (到 3 次后系统改为每天重试一次)。
  final int failures;
  final String? attemptedAt;

  /// 只含业务文案 (服务端不下发技术细节)。
  final String? lastErrorMessage;
  final List<WmReportCloseBlocker> blockers;

  /// 撤销结算后保留到此时自动重结。
  final String? heldUntil;
  final int? lastCloseNo;
  final String? lastClosedAt;
  final String? lastClosedByName;

  /// 期间行最新版本 (撤销结算的 expectedVersion)。每次结算尝试都会让它 +1,
  /// 所以撤销前以结算状态里的这个值为准, 不用期间列表里读到的旧值。
  final int? rowVersion;

  /// 服务端按当前账号与对象范围算好的可用动作 (CLOSE_RETRY / REOPEN …)。
  final Set<String> allowedActions;

  bool get isClosed => status == 'CLOSED';

  /// 正在排队结算 (提交盘点后自动结算、或点了「立即重试」)。
  bool get isSettling => status == 'COUNTED' && closeState == 'QUEUED';

  bool can(String action) => allowedActions.contains(action);

  factory WmReportCloseStatus.fromJson(
    Map<String, dynamic> json, {
    required String periodId,
  }) {
    final lastClose = _map(json['lastClose']);
    return WmReportCloseStatus(
      periodId: _s(json['periodId']) ?? periodId,
      status: _s(json['status']),
      closeState: _s(json['closeState']),
      attempts: _i(json['attempts']) ?? 0,
      failures: _i(json['failures']) ?? 0,
      attemptedAt: _s(json['attemptedAt']),
      lastErrorMessage: _s(json['lastErrorMessage']),
      blockers: [
        for (final b
            in (json['blockers'] is List ? json['blockers'] as List : const []))
          if (b is Map<String, dynamic>) WmReportCloseBlocker.fromJson(b),
      ],
      heldUntil: _s(json['heldUntil']),
      lastCloseNo: _i(lastClose?['closeNo']),
      lastClosedAt: _s(lastClose?['closedAt']),
      lastClosedByName: _s(lastClose?['closedByName']),
      rowVersion: _i(json['rowVersion']),
      allowedActions: _strings(json['allowedActions']).toSet(),
    );
  }
}

/// 内料仓用量表一行 (每期 × 每种料)。
class WmBinUsageRow {
  const WmBinUsageRow({
    this.periodId,
    this.periodNo,
    this.startDate,
    this.endDate,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.unitName,
    this.costBasis,
    this.periodStatus,
    this.closeNo,
    this.closedAt,
    this.openingQty,
    this.transferInQty,
    this.returnQty,
    this.otherIssueQty,
    this.closingQty,
    this.actualQty,
    this.theoryQty,
    this.allocationBasisQty,
    this.diffQty,
    this.wasteRate,
    this.outcome,
    this.flags = const [],
    this.consumedQty,
    this.lossQty,
    this.unitCost,
    this.currentValue,
    this.valueAtClose,
  });

  final String? periodId;
  final int? periodNo;
  final String? startDate;
  final String? endDate;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitName;

  /// OWN 主料 / SHARED 辅料 / EXPENSE 记车间费用 (期间行快照)。
  final String? costBasis;

  /// 期间状态 (OPEN / COUNTING / COUNTED / CLOSED)。
  final String? periodStatus;

  /// 第几次结算 (撤销后重结会 +1)；未结算为 null。
  final int? closeNo;

  /// 结算时间 (带偏移的 ISO 时间)；未结算为 null。
  final String? closedAt;
  final double? openingQty;
  final double? transferInQty;
  final double? returnQty;
  final double? otherIssueQty;
  final double? closingQty;

  /// 实际用量 = 期初 + 领入 − 退回 − 其它耗用 − 期末。
  final double? actualQty;

  /// 理论用量 (只主料有)。
  final double? theoryQty;

  /// 分摊基数 (只辅料有)。
  final double? allocationBasisQty;

  /// 差额 = 实际 − 理论。
  final double? diffQty;

  /// 浪费率 (只算主料) = (实际 − 理论) / 理论，小数 (0.05 = 5%)。
  final double? wasteRate;

  /// ALLOCATED / UNALLOCATED_LOSS / GAIN / NOTHING / EXPENSED；未结算为 null。
  final String? outcome;

  /// WASTE_OUT_OF_RANGE / OTHER_ISSUE_LARGE / ACTUAL_WITHOUT_THEORY / GAIN_PRICE_ZERO。
  final List<String> flags;
  final double? consumedQty;
  final double? lossQty;

  // —— 金额 (无看成本权限时服务端下发 null) ——
  final double? unitCost;
  final double? currentValue;
  final double? valueAtClose;

  bool get hasCost =>
      unitCost != null || currentValue != null || valueAtClose != null;

  factory WmBinUsageRow.fromJson(Map<String, dynamic> json) => WmBinUsageRow(
    periodId: _s(json['periodId']),
    periodNo: _i(json['periodNo']),
    startDate: _s(json['startDate']),
    endDate: _s(json['endDate']),
    goodsId: _s(json['goodsId']),
    goodsCode: _s(json['goodsCode']),
    goodsName: _s(json['goodsName']),
    colorId: _s(json['colorId']),
    colorName: _s(json['colorName']),
    unitName: _s(json['unitName']),
    costBasis: _s(json['costBasis']),
    periodStatus: _s(json['periodStatus']),
    closeNo: _i(json['closeNo']),
    closedAt: _s(json['closedAt']),
    openingQty: _d(json['openingQty']),
    transferInQty: _d(json['transferInQty']),
    returnQty: _d(json['returnQty']),
    otherIssueQty: _d(json['otherIssueQty']),
    closingQty: _d(json['closingQty']),
    actualQty: _d(json['actualQty']),
    theoryQty: _d(json['theoryQty']),
    allocationBasisQty: _d(json['allocationBasisQty']),
    diffQty: _d(json['diffQty']),
    wasteRate: _d(json['wasteRate']),
    outcome: _s(json['outcome']),
    flags: _strings(json['flags']),
    consumedQty: _d(json['consumedQty']),
    lossQty: _d(json['lossQty']),
    unitCost: _d(json['unitCost']),
    currentValue: _d(json['currentValue']),
    valueAtClose: _d(json['valueAtClose']),
  );
}

/// 产品用料表一行 (每期 × 产品 × 料)。
class WmProductUsageRow {
  const WmProductUsageRow({
    this.periodId,
    this.periodNo,
    this.startDate,
    this.endDate,
    this.productGoodsId,
    this.productCode,
    this.productName,
    this.materialGoodsId,
    this.materialCode,
    this.materialName,
    this.materialColorName,
    this.costBasis,
    this.outputQty,
    this.unitWeightGrams,
    this.theoryQty,
    this.allocatedQty,
    this.exclusivePeriod = false,
    this.actualPerUnitGrams,
    this.materialAmount,
    this.valueAtClose,
    this.unitMaterialCost,
  });

  final String? periodId;
  final int? periodNo;
  final String? startDate;
  final String? endDate;
  final String? productGoodsId;
  final String? productCode;
  final String? productName;
  final String? materialGoodsId;
  final String? materialCode;
  final String? materialName;
  final String? materialColorName;

  /// OWN 主料 / SHARED 辅料 (辅料按主料理论分摊, 没有单个重量)。
  final String? costBasis;

  /// 完工 (报工耗料产量)。
  final double? outputQty;

  /// BOM 单个重量 (克)。
  final double? unitWeightGrams;
  final double? theoryQty;

  /// 按理论比例分摊到的实际用量。
  final double? allocatedQty;

  /// 独占期：本期这种料只有这一个产品用 → 标「真实单耗」。
  final bool exclusivePeriod;

  /// 独占期的真实单耗 = 实际 / 完工 (克)。
  final double? actualPerUnitGrams;

  // —— 金额 (无看成本权限时服务端下发 null) ——
  final double? materialAmount;
  final double? valueAtClose;
  final double? unitMaterialCost;

  bool get hasCost =>
      materialAmount != null ||
      valueAtClose != null ||
      unitMaterialCost != null;

  factory WmProductUsageRow.fromJson(Map<String, dynamic> json) {
    final gramsRaw = _d(json['unitWeightGrams']);
    final weightKg = _d(json['unitWeight']);
    final actualPerUnitRaw = _d(json['actualPerUnitGrams']);
    final actualPerUnitKg = _d(json['actualPerUnit']);
    return WmProductUsageRow(
      periodId: _s(json['periodId']),
      periodNo: _i(json['periodNo']),
      startDate: _s(json['startDate']),
      endDate: _s(json['endDate']),
      productGoodsId: _s(json['productGoodsId']),
      productCode: _s(json['productCode']),
      productName: _s(json['productName']),
      materialGoodsId: _s(json['materialGoodsId']),
      materialCode: _s(json['materialCode']),
      materialName: _s(json['materialName']) ?? _s(json['materialCode']),
      materialColorName: _s(json['materialColorName']),
      costBasis: _s(json['costBasis']),
      outputQty: _d(json['outputQty']),
      unitWeightGrams: gramsRaw ?? (weightKg == null ? null : weightKg * 1000),
      theoryQty: _d(json['theoryQty']),
      allocatedQty: _d(json['allocatedQty']),
      exclusivePeriod: json['exclusivePeriod'] == true,
      actualPerUnitGrams:
          actualPerUnitRaw ??
          (actualPerUnitKg == null ? null : actualPerUnitKg * 1000),
      materialAmount: _d(json['materialAmount'] ?? json['currentValue']),
      valueAtClose: _d(json['valueAtClose']),
      unitMaterialCost: _d(json['unitMaterialCost']),
    );
  }
}

/// 浪费率趋势的一个点 (按料、按期)。
class WmWasteTrendPoint {
  const WmWasteTrendPoint({
    this.periodId,
    this.periodNo,
    this.startDate,
    this.endDate,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.wasteRate,
  });

  final String? periodId;
  final int? periodNo;
  final String? startDate;
  final String? endDate;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final double? wasteRate;

  /// 料的分组键 (货品 + 颜色)。
  String get materialKey => '${goodsId ?? ''}|${colorId ?? colorName ?? ''}';

  String get materialLabel =>
      [goodsName, colorName].whereType<String>().join(' ');

  factory WmWasteTrendPoint.fromJson(Map<String, dynamic> json) =>
      WmWasteTrendPoint(
        periodId: _s(json['periodId']),
        periodNo: _i(json['periodNo']),
        startDate: _s(json['startDate']),
        endDate: _s(json['endDate']),
        goodsId: _s(json['goodsId']),
        goodsCode: _s(json['goodsCode']),
        goodsName: _s(json['goodsName']),
        colorId: _s(json['colorId']),
        colorName: _s(json['colorName']),
        wasteRate: _d(json['wasteRate']),
      );
}

/// 缺单重清单一行 (有产量、BOM 没填单个重量)。
class WmMissingWeightRow {
  const WmMissingWeightRow({
    this.periodId,
    this.periodNo,
    this.startDate,
    this.endDate,
    this.productGoodsId,
    this.productCode,
    this.productName,
    this.materialGoodsId,
    this.materialCode,
    this.materialName,
    this.materialColorName,
    this.outputQty,
  });

  final String? periodId;
  final int? periodNo;
  final String? startDate;
  final String? endDate;
  final String? productGoodsId;
  final String? productCode;
  final String? productName;
  final String? materialGoodsId;
  final String? materialCode;
  final String? materialName;
  final String? materialColorName;
  final double? outputQty;

  factory WmMissingWeightRow.fromJson(Map<String, dynamic> json) =>
      WmMissingWeightRow(
        periodId: _s(json['periodId']),
        periodNo: _i(json['periodNo']),
        startDate: _s(json['startDate']),
        endDate: _s(json['endDate']),
        productGoodsId: _s(json['productGoodsId']),
        productCode: _s(json['productCode']),
        productName: _s(json['productName']),
        materialGoodsId: _s(json['materialGoodsId']),
        materialCode: _s(json['materialCode']),
        materialName: _s(json['materialName']) ?? _s(json['materialCode']),
        materialColorName: _s(json['materialColorName']),
        outputQty: _d(json['outputQty']),
      );
}

/// 内料仓收发明细一行 (流水视图)。
class WmLedgerRow {
  const WmLedgerRow({
    this.id,
    this.sourceKind,
    this.businessDate,
    this.goodsId,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.signedQty,
    this.docNo,
    this.requestNo,
    this.operatorName,
    this.periodNo,
    this.isSupplement = false,
    this.remark,
  });

  final String? id;

  /// ISSUE / RETURN / OTHER_ISSUE / CONSUME / CONSUME_REVERSE / GAIN / GAIN_REVERSE。
  final String? sourceKind;
  final String? businessDate;
  final String? goodsId;
  final String? goodsName;
  final String? colorName;
  final String? unitName;

  /// 带符号数量 (进 +、出 −)。
  final double? signedQty;

  /// 库存单据号 (调拨单号 / 其它出库单号)；盘点过账没有单据号。
  final String? docNo;

  /// 领料单号或退回单号 (发料、退回才有)。
  final String? requestNo;

  /// 表格「来源单据」列：库存单据号优先，其次领料单号；盘点过账显示「盘点」。
  String get sourceLabel {
    final parts = [docNo, requestNo].whereType<String>().toList();
    if (parts.isNotEmpty) return parts.join(' / ');
    return switch (sourceKind) {
      'CONSUME' || 'CONSUME_REVERSE' || 'GAIN' || 'GAIN_REVERSE' => '盘点',
      _ => '',
    };
  }

  /// 操作人 (服务端随行返回姓名)。
  final String? operatorName;
  final int? periodNo;

  /// 补录到已盘点那一期的漏录发料。
  final bool isSupplement;

  /// 备注 (其它耗用的原因等)。
  final String? remark;

  factory WmLedgerRow.fromJson(Map<String, dynamic> json) => WmLedgerRow(
    id: _s(json['id'] ?? json['sourceRowId']),
    sourceKind: _s(json['sourceKind']),
    businessDate: _s(json['businessDate']),
    goodsId: _s(json['goodsId']),
    goodsName: _s(json['goodsName']),
    colorName: _s(json['colorName']),
    unitName: _s(json['unitName']),
    signedQty: _d(json['signedQty']),
    docNo: _s(json['docNo']),
    requestNo: _s(json['requestNo']),
    operatorName: _s(json['operatorName']),
    periodNo: _i(json['periodNo']),
    isSupplement: json['isSupplement'] == true || json['supplement'] == true,
    remark: _s(json['remark']),
  );
}

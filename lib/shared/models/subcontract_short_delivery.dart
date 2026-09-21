// ADR-098 委外回厂短交案件模型（/subcontract/short-deliveries）。
//
// 数量全部按订货单位；severity / status / effectiveStatus 的取值与服务端
// SubcontractShortDeliveryContracts.CaseRow 一致。文案函数集中在本文件，
// 判定页、任务中心状态列、供应商详情「委外损耗」段共用，避免三处各起一个名字。

class SubcontractShortDeliveryCase {
  const SubcontractShortDeliveryCase({
    required this.id,
    required this.orderId,
    required this.orderBillNo,
    required this.orderItemId,
    this.lineNo,
    this.supplierId,
    this.supplierName,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.receiptId,
    this.receiptBillNo,
    required this.orderedQty,
    this.allowedLossPct,
    this.floorQty,
    required this.deliveredQty,
    required this.shortfallQty,
    required this.shortfallPct,
    required this.severity,
    required this.status,
    required this.effectiveStatus,
    this.overdue = false,
    this.decision,
    this.expectedCompleteBy,
    this.decisionNote,
    this.arrivalCount = 1,
    this.ownerName,
    this.decidedByName,
    this.detectedAt,
    this.lastEvaluatedAt,
    this.decidedAt,
    this.closedAt,
    this.lossQty,
    this.lossPct,
    this.wasteId,
    this.wasteBillNo,
    required this.version,
    this.canDecide = false,
  });

  final String id;
  final String orderId;
  final String orderBillNo;
  final String orderItemId;
  final int? lineNo;
  final String? supplierId;
  final String? supplierName;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final String? receiptId;
  final String? receiptBillNo;
  final double orderedQty;
  final double? allowedLossPct;
  final double? floorQty;
  final double deliveredQty;
  final double shortfallQty;
  final double shortfallPct;

  /// SEVERE / BELOW_FLOOR / WITHIN_TOLERANCE / UNSET_TOLERANCE。
  final String severity;

  /// PENDING_OWNER / WAITING_MORE / ACCEPTED_LOSS / COMPLETED / CANCELED。
  final String status;

  /// 分批等待过了预计到齐日视同待判定（PENDING_OWNER），其余等于 [status]。
  final String effectiveStatus;
  final bool overdue;
  final String? decision;
  final String? expectedCompleteBy;
  final String? decisionNote;
  final int arrivalCount;
  final String? ownerName;
  final String? decidedByName;
  final String? detectedAt;
  final String? lastEvaluatedAt;
  final String? decidedAt;
  final String? closedAt;
  final double? lossQty;
  final double? lossPct;
  final String? wasteId;
  final String? wasteBillNo;
  final int version;
  final bool canDecide;

  bool get isOpen => status == 'PENDING_OWNER' || status == 'WAITING_MORE';

  /// 低于允许下限的两档：红色、紧急。
  bool get isBelowFloor => severity == 'SEVERE' || severity == 'BELOW_FLOOR';

  bool get isSevere => severity == 'SEVERE';

  String get severityLabel => subcontractShortDeliverySeverityLabel(severity);

  String get statusLabel =>
      subcontractShortDeliveryStatusLabel(effectiveStatus, overdue: overdue);

  String get goodsLabel => [
    goodsName,
    goodsCode,
    colorName,
  ].where((part) => part != null && part.isNotEmpty).join(' ');

  factory SubcontractShortDeliveryCase.fromJson(Map<String, dynamic> json) =>
      SubcontractShortDeliveryCase(
        id: json['id'] as String,
        orderId: json['orderId'] as String? ?? '',
        orderBillNo: json['orderBillNo'] as String? ?? '',
        orderItemId: json['orderItemId'] as String? ?? '',
        lineNo: (json['lineNo'] as num?)?.toInt(),
        supplierId: json['supplierId'] as String?,
        supplierName: json['supplierName'] as String?,
        goodsId: json['goodsId'] as String?,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        receiptId: json['receiptId'] as String?,
        receiptBillNo: json['receiptBillNo'] as String?,
        orderedQty: (json['orderedQty'] as num?)?.toDouble() ?? 0,
        allowedLossPct: (json['allowedLossPct'] as num?)?.toDouble(),
        floorQty: (json['floorQty'] as num?)?.toDouble(),
        deliveredQty: (json['deliveredQty'] as num?)?.toDouble() ?? 0,
        shortfallQty: (json['shortfallQty'] as num?)?.toDouble() ?? 0,
        shortfallPct: (json['shortfallPct'] as num?)?.toDouble() ?? 0,
        severity: json['severity'] as String? ?? 'UNSET_TOLERANCE',
        status: json['status'] as String? ?? 'PENDING_OWNER',
        effectiveStatus:
            json['effectiveStatus'] as String? ??
            json['status'] as String? ??
            'PENDING_OWNER',
        overdue: json['overdue'] == true,
        decision: json['decision'] as String?,
        expectedCompleteBy: json['expectedCompleteBy'] as String?,
        decisionNote: json['decisionNote'] as String?,
        arrivalCount: (json['arrivalCount'] as num?)?.toInt() ?? 1,
        ownerName: json['ownerName'] as String?,
        decidedByName: json['decidedByName'] as String?,
        detectedAt: json['detectedAt'] as String?,
        lastEvaluatedAt: json['lastEvaluatedAt'] as String?,
        decidedAt: json['decidedAt'] as String?,
        closedAt: json['closedAt'] as String?,
        lossQty: (json['lossQty'] as num?)?.toDouble(),
        lossPct: (json['lossPct'] as num?)?.toDouble(),
        wasteId: json['wasteId'] as String?,
        wasteBillNo: json['wasteBillNo'] as String?,
        version: (json['version'] as num?)?.toInt() ?? 1,
        canDecide: json['canDecide'] == true,
      );
}

class SubcontractShortDeliveryEvent {
  const SubcontractShortDeliveryEvent({
    required this.id,
    required this.eventType,
    this.actorName,
    this.createdAt,
    this.snapshot = const {},
  });

  final String id;
  final String eventType;
  final String? actorName;
  final String? createdAt;
  final Map<String, dynamic> snapshot;

  String get label => subcontractShortDeliveryEventLabel(eventType);

  factory SubcontractShortDeliveryEvent.fromJson(Map<String, dynamic> json) =>
      SubcontractShortDeliveryEvent(
        id: json['id'] as String? ?? '',
        eventType: json['eventType'] as String? ?? '',
        actorName: json['actorName'] as String?,
        createdAt: json['createdAt'] as String?,
        snapshot: json['snapshot'] is Map<String, dynamic>
            ? json['snapshot'] as Map<String, dynamic>
            : const {},
      );
}

class SubcontractShortDeliveryDetail {
  const SubcontractShortDeliveryDetail({
    required this.row,
    this.events = const [],
  });

  final SubcontractShortDeliveryCase row;
  final List<SubcontractShortDeliveryEvent> events;

  factory SubcontractShortDeliveryDetail.fromJson(Map<String, dynamic> json) =>
      SubcontractShortDeliveryDetail(
        row: SubcontractShortDeliveryCase.fromJson(
          json['row'] as Map<String, dynamic>,
        ),
        events: [
          for (final entry in (json['events'] as List<dynamic>? ?? const []))
            SubcontractShortDeliveryEvent.fromJson(
              entry as Map<String, dynamic>,
            ),
        ],
      );
}

/// 判定页分段计数：待判定（红徽章：低于允许下限或分批逾期）/ 容差内待结案（中性）/
/// 分批等待中（中性括号）。
class SubcontractShortDeliveryCounts {
  const SubcontractShortDeliveryCounts({
    this.pending = 0,
    this.tolerant = 0,
    this.waiting = 0,
  });

  final int pending;
  final int tolerant;
  final int waiting;

  factory SubcontractShortDeliveryCounts.fromJson(Map<String, dynamic> json) =>
      SubcontractShortDeliveryCounts(
        pending: (json['pending'] as num?)?.toInt() ?? 0,
        tolerant: (json['tolerant'] as num?)?.toInt() ?? 0,
        waiting: (json['waiting'] as num?)?.toInt() ?? 0,
      );
}

class SubcontractGoodsLossRow {
  const SubcontractGoodsLossRow({
    required this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.settledLineCount = 0,
    this.acceptedLossCount = 0,
    this.orderedQty = 0,
    this.lossQty = 0,
    this.lossPct = 0,
    this.maxLossPct = 0,
    this.lastLossAt,
  });

  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final int settledLineCount;
  final int acceptedLossCount;
  final double orderedQty;
  final double lossQty;
  final double lossPct;
  final double maxLossPct;
  final String? lastLossAt;

  factory SubcontractGoodsLossRow.fromJson(Map<String, dynamic> json) =>
      SubcontractGoodsLossRow(
        goodsId: json['goodsId'] as String? ?? '',
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        settledLineCount: (json['settledLineCount'] as num?)?.toInt() ?? 0,
        acceptedLossCount: (json['acceptedLossCount'] as num?)?.toInt() ?? 0,
        orderedQty: (json['orderedQty'] as num?)?.toDouble() ?? 0,
        lossQty: (json['lossQty'] as num?)?.toDouble() ?? 0,
        lossPct: (json['lossPct'] as num?)?.toDouble() ?? 0,
        maxLossPct: (json['maxLossPct'] as num?)?.toDouble() ?? 0,
        lastLossAt: json['lastLossAt'] as String?,
      );
}

/// 供应商委外损耗汇总（供应商详情「委外损耗」段）。
class SubcontractSupplierLossSummary {
  const SubcontractSupplierLossSummary({
    required this.supplierId,
    this.settledLineCount = 0,
    this.acceptedLossCount = 0,
    this.orderedQty = 0,
    this.lossQty = 0,
    this.lossPct = 0,
    this.maxLossPct = 0,
    this.lastLossAt,
    this.byGoods = const [],
    this.recentCases = const [],
  });

  final String supplierId;
  final int settledLineCount;
  final int acceptedLossCount;
  final double orderedQty;
  final double lossQty;
  final double lossPct;
  final double maxLossPct;
  final String? lastLossAt;
  final List<SubcontractGoodsLossRow> byGoods;
  final List<SubcontractShortDeliveryCase> recentCases;

  bool get isEmpty => settledLineCount == 0;

  factory SubcontractSupplierLossSummary.fromJson(
    Map<String, dynamic> json,
  ) => SubcontractSupplierLossSummary(
    supplierId: json['supplierId'] as String? ?? '',
    settledLineCount: (json['settledLineCount'] as num?)?.toInt() ?? 0,
    acceptedLossCount: (json['acceptedLossCount'] as num?)?.toInt() ?? 0,
    orderedQty: (json['orderedQty'] as num?)?.toDouble() ?? 0,
    lossQty: (json['lossQty'] as num?)?.toDouble() ?? 0,
    lossPct: (json['lossPct'] as num?)?.toDouble() ?? 0,
    maxLossPct: (json['maxLossPct'] as num?)?.toDouble() ?? 0,
    lastLossAt: json['lastLossAt'] as String?,
    byGoods: [
      for (final entry in (json['byGoods'] as List<dynamic>? ?? const []))
        SubcontractGoodsLossRow.fromJson(entry as Map<String, dynamic>),
    ],
    recentCases: [
      for (final entry in (json['recentCases'] as List<dynamic>? ?? const []))
        SubcontractShortDeliveryCase.fromJson(entry as Map<String, dynamic>),
    ],
  );
}

/// 数量显示：整数不带小数点，其余去尾零，可带单位（判定页/弹窗/供应商详情共用）。
String formatSubcontractQty(double value, [String? unit]) {
  final text = value == value.roundToDouble()
      ? value.toInt().toString()
      : value
            .toStringAsFixed(4)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
  return unit == null || unit.isEmpty ? text : '$text $unit';
}

/// 百分比显示：空 → 「—」；整数不带小数点；其余最多 2 位小数去尾零。
String formatSubcontractPct(double? value) {
  if (value == null) return '—';
  final text = value == value.roundToDouble()
      ? value.toInt().toString()
      : value
            .toStringAsFixed(2)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
  return '$text%';
}

String subcontractShortDeliverySeverityLabel(String code) =>
    switch (code.toUpperCase()) {
      'SEVERE' => '严重短交',
      'BELOW_FLOOR' => '低于允许下限',
      'WITHIN_TOLERANCE' => '容差内未到齐',
      'UNSET_TOLERANCE' => '未设允许损耗',
      _ => code,
    };

String subcontractShortDeliveryStatusLabel(
  String code, {
  bool overdue = false,
}) => switch (code.toUpperCase()) {
  'PENDING_OWNER' => overdue ? '待判定(已过预计到齐日)' : '待判定',
  'WAITING_MORE' => '分批等待中',
  'ACCEPTED_LOSS' => '已接受损耗结案',
  'COMPLETED' => '已到齐',
  'CANCELED' => '已作废',
  _ => code,
};

String subcontractShortDeliveryEventLabel(String code) =>
    switch (code.toUpperCase()) {
      'DETECTED' => '仓库登记发现短交',
      'REDETECTED' => '再次到货仍未到齐',
      'WAIT_MORE_DECIDED' => '判定：分批到货，继续等',
      'ACCEPT_LOSS_DECIDED' => '判定：接受损耗，结案',
      'COMPLETED' => '累计到齐，自动完成',
      'CANCELED' => '订货单红冲，案件作废',
      _ => code,
    };

/// 任务中心「进行中」状态列的文案（display_stage）。
String subcontractProgressStatusLabel(String code) =>
    switch (code.toUpperCase()) {
      'ORDER_PENDING_APPROVAL' => '等待财务审核',
      'FINANCE_REJECTED' => '财务已退回',
      'FINANCE_APPROVED' => '财务已通过',
      'AWAITING_OUTBOUND' => '待发料出仓',
      'AT_SUPPLIER' => '委外加工中',
      'PARTIAL_RECEIVED' => '部分回厂',
      'RECEIVED_PENDING_STOCK' => '已回厂待入库',
      'WAITING_MORE_BATCH' => '分批等待中',
      'SHORT_DELIVERY' => '回厂短交待判定',
      'TOLERANT_SHORT' => '容差内待结案',
      // 待处理段的行沿用既有「计划申请已下达 / 待分解」文案（与分段名区分），这里不翻译。
      'COMPLETED' => '已完成',
      _ => code,
    };

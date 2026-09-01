// 委外出仓工作台模型（V304 · 仓库视角：无价格/金额字段）。
//
// 新委外单只把订货目标件交给仓库：无子层级直接进入目标件出仓准备；有子层级
// 先完成前置自制/FQC/成品入仓，再按服务端 readyOutboundQty 交仓库。
// LEGACY_BOM_COMPONENT 仅兼容历史 V304 BOM 子件发料单。

enum SubcontractOutboundFlowMode {
  legacyBomComponent('LEGACY_BOM_COMPONENT', '历史 BOM 子件发料'),
  directOutbound('DIRECT_OUTBOUND', '目标件直接出仓'),
  makeThenOutbound('MAKE_THEN_OUTBOUND', '先自制再出仓'),
  unknown('UNKNOWN', '路线待确认');

  const SubcontractOutboundFlowMode(this.wireName, this.label);

  final String wireName;
  final String label;

  factory SubcontractOutboundFlowMode.fromWire(Object? value) {
    final wire = value?.toString().trim().toUpperCase();
    return values.firstWhere(
      (item) => item.wireName == wire,
      orElse: () => unknown,
    );
  }
}

enum SubcontractPreparationStatus {
  actionRequired('ACTION_REQUIRED', '待计划员开始前置自制'),
  waitingPreparation('WAITING_PREPARATION', '等待前置自制'),
  inPreparation('IN_PREPARATION', '前置自制中'),
  waitingFqc('WAITING_FQC', '等待品质检查'),
  waitingInbound('WAITING_INBOUND', '等待自制件入仓'),
  readyOutbound('READY_OUTBOUND', '可出仓'),
  outboundComplete('OUTBOUND_COMPLETE', '已出仓'),
  cancelled('CANCELLED', '已取消'),
  legacyReady('LEGACY_READY', '历史发料待出仓'),
  unknown('UNKNOWN', '状态待确认');

  const SubcontractPreparationStatus(this.wireName, this.label);

  final String wireName;
  final String label;

  factory SubcontractPreparationStatus.fromWire(Object? value) {
    final wire = value?.toString().trim().toUpperCase();
    return values.firstWhere(
      (item) => item.wireName == wire,
      orElse: () => unknown,
    );
  }
}

/// 待出仓任务列表行（一张 OPEN 发料计划 = 一个任务）。
class OutboundTask {
  const OutboundTask({
    required this.planId,
    required this.orderId,
    required this.orderBillNo,
    required this.supplierName,
    required this.deliverDate,
    required this.lineCount,
    required this.plannedQty,
    required this.issuedQty,
    required this.remainingQty,
    required this.draftId,
    required this.draftBillNo,
    this.readyOutboundQty = 0,
    this.readyLineCount = 0,
    this.waitingPreparationCount = 0,
    this.blockedLineCount = 0,
  });

  final String planId;
  final String orderId;
  final String? orderBillNo;
  final String? supplierName;
  final String? deliverDate;
  final int lineCount;
  final double plannedQty;
  final double issuedQty;
  final double remainingQty;
  final String? draftId;
  final String? draftBillNo;
  final double readyOutboundQty;
  final int readyLineCount;
  final int waitingPreparationCount;
  final int blockedLineCount;

  String get statusLabel {
    if (draftId != null) return '目标件出仓草稿待拣货';
    if (readyLineCount > 0 || readyOutboundQty > 0) return '目标件已备齐，待出仓';
    if (blockedLineCount > 0) return '前置自制受阻';
    if (waitingPreparationCount > 0) return '等待前置自制';
    return '待生成目标件出仓单';
  }

  factory OutboundTask.fromJson(Map<String, dynamic> json) => OutboundTask(
    planId: json['planId'] as String,
    orderId: json['orderId'] as String,
    orderBillNo: json['orderBillNo'] as String?,
    supplierName: json['supplierName'] as String?,
    deliverDate: json['deliverDate'] as String?,
    lineCount: (json['lineCount'] as num?)?.toInt() ?? 0,
    plannedQty: (json['plannedQty'] as num?)?.toDouble() ?? 0,
    issuedQty: (json['issuedQty'] as num?)?.toDouble() ?? 0,
    remainingQty: (json['remainingQty'] as num?)?.toDouble() ?? 0,
    draftId: json['draftId'] as String?,
    draftBillNo: json['draftBillNo'] as String?,
    readyOutboundQty:
        (json['readyOutboundQty'] as num?)?.toDouble() ??
        (json['remainingQty'] as num?)?.toDouble() ??
        0,
    readyLineCount: (json['readyLineCount'] as num?)?.toInt() ?? 0,
    waitingPreparationCount:
        (json['waitingPreparationCount'] as num?)?.toInt() ?? 0,
    blockedLineCount: (json['blockedLineCount'] as num?)?.toInt() ?? 0,
  );
}

/// One target-item outbound line. For new flows [goodsId] is the subcontract
/// target item itself. Parent/component fields are retained only for legacy
/// BOM-component issue documents.
class OutboundPlanLine {
  const OutboundPlanLine({
    required this.planItemId,
    required this.orderItemId,
    required this.parentGoodsId,
    required this.parentColorId,
    required this.parentGoodsCode,
    required this.parentGoodsName,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.goodsStockPlace,
    required this.colorId,
    required this.colorName,
    required this.unitId,
    required this.unitName,
    required this.bomUnitQty,
    required this.plannedQty,
    required this.issuedQty,
    required this.draftQty,
    this.flowMode = SubcontractOutboundFlowMode.legacyBomComponent,
    this.preparationStatus = SubcontractPreparationStatus.legacyReady,
    this.preparedQty = 0,
    this.readyOutboundQtySnapshot,
    this.remainingQtySnapshot,
    this.preparationAnalysisId,
    this.preparationAnalysisItemId,
    this.blocker,
    this.allowedActions = const {},
  });

  final String planItemId;
  final String orderItemId;
  final String? parentGoodsId;
  final String? parentColorId;
  final String? parentGoodsCode;
  final String? parentGoodsName;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? goodsStockPlace;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double bomUnitQty;
  final double plannedQty;
  final double issuedQty;
  final double draftQty;
  final SubcontractOutboundFlowMode flowMode;
  final SubcontractPreparationStatus preparationStatus;
  final double preparedQty;
  final double? readyOutboundQtySnapshot;
  final double? remainingQtySnapshot;
  final String? preparationAnalysisId;
  final String? preparationAnalysisItemId;
  final String? blocker;
  final Set<String> allowedActions;

  double get remainingQty {
    if (remainingQtySnapshot case final value?) return value < 0 ? 0 : value;
    final r = plannedQty - issuedQty - draftQty;
    return r < 0 ? 0 : r;
  }

  double get readyOutboundQty {
    if (flowMode == SubcontractOutboundFlowMode.unknown ||
        preparationStatus == SubcontractPreparationStatus.unknown) {
      return 0;
    }
    final value = readyOutboundQtySnapshot ?? remainingQty;
    return value < 0 ? 0 : value;
  }

  /// A loaded draft already reserves [draftQty], so editing that same draft may
  /// reuse its reservation in addition to currently free ready quantity.
  double get maxEditableQty =>
      flowMode == SubcontractOutboundFlowMode.unknown ||
          preparationStatus == SubcontractPreparationStatus.unknown
      ? 0
      : readyOutboundQty + draftQty;

  bool allows(String action) => allowedActions.contains(action);

  factory OutboundPlanLine.fromJson(Map<String, dynamic> json) =>
      OutboundPlanLine(
        planItemId: json['planItemId'] as String,
        orderItemId: json['orderItemId'] as String,
        parentGoodsId: json['parentGoodsId'] as String?,
        parentColorId: json['parentColorId'] as String?,
        parentGoodsCode: json['parentGoodsCode'] as String?,
        parentGoodsName: json['parentGoodsName'] as String?,
        goodsId: json['goodsId'] as String,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        goodsStockPlace: json['goodsStockPlace'] as String?,
        colorId: json['colorId'] as String?,
        colorName: json['colorName'] as String?,
        unitId: json['unitId'] as String?,
        unitName: json['unitName'] as String?,
        bomUnitQty: (json['bomUnitQty'] as num?)?.toDouble() ?? 0,
        plannedQty: (json['plannedQty'] as num?)?.toDouble() ?? 0,
        issuedQty: (json['issuedQty'] as num?)?.toDouble() ?? 0,
        draftQty:
            (json['draftReservedQty'] as num?)?.toDouble() ??
            (json['draftQty'] as num?)?.toDouble() ??
            0,
        flowMode: json.containsKey('flowMode')
            ? SubcontractOutboundFlowMode.fromWire(json['flowMode'])
            : SubcontractOutboundFlowMode.legacyBomComponent,
        preparationStatus: json.containsKey('preparationStatus')
            ? SubcontractPreparationStatus.fromWire(json['preparationStatus'])
            : SubcontractPreparationStatus.legacyReady,
        preparedQty: (json['preparedQty'] as num?)?.toDouble() ?? 0,
        readyOutboundQtySnapshot: (json['readyOutboundQty'] as num?)
            ?.toDouble(),
        remainingQtySnapshot: (json['remainingQty'] as num?)?.toDouble(),
        preparationAnalysisId: json['preparationAnalysisId'] as String?,
        preparationAnalysisItemId: json['preparationAnalysisItemId'] as String?,
        blocker: json['blocker'] as String?,
        allowedActions: {
          for (final action in (json['allowedActions'] as List? ?? const []))
            if (action != null) action.toString(),
        },
      );

  /// 按服务端发料计划快照构造出仓草稿行，颜色/单位 UUID 不由客户端重选。
  Map<String, dynamic> toMaterialIssueItemPayload({
    required double qty,
    double? weight,
  }) => {
    'goodsId': goodsId,
    'colorId': colorId,
    'unitId': unitId,
    'qty': qty,
    'weight': ?weight,
    'unitRate': 1,
    'orderItemId': orderItemId,
    'planItemId': planItemId,
    if (parentGoodsId != null) 'parentGoodsId': parentGoodsId,
    if (parentColorId != null) 'parentColorId': parentColorId,
  };
}

/// 计划关联的出仓单（草稿/已审/红冲历史）。
class OutboundDraftRef {
  const OutboundDraftRef({
    required this.issueId,
    required this.billNo,
    required this.status,
    required this.billDate,
    required this.warehouseName,
    required this.approverName,
    required this.totalQty,
  });

  final String issueId;
  final String? billNo;
  final int? status; // 0 草稿 / 1 已审 / -1 红冲
  final String? billDate;
  final String? warehouseName;
  final String? approverName;
  final double? totalQty;

  factory OutboundDraftRef.fromJson(Map<String, dynamic> json) =>
      OutboundDraftRef(
        issueId: json['issueId'] as String,
        billNo: json['billNo'] as String?,
        status: (json['status'] as num?)?.toInt(),
        billDate: json['billDate'] as String?,
        warehouseName: json['warehouseName'] as String?,
        approverName: json['approverName'] as String?,
        totalQty: (json['totalQty'] as num?)?.toDouble(),
      );
}

class OutboundTaskDetail {
  const OutboundTaskDetail({
    required this.planId,
    required this.orderId,
    required this.orderBillNo,
    required this.status,
    required this.supplierId,
    required this.supplierName,
    required this.deliverDate,
    required this.closeReason,
    required this.lines,
    required this.drafts,
  });

  final String planId;
  final String orderId;
  final String? orderBillNo;
  final String? status; // OPEN / CLOSED / CANCELED
  final String? supplierId;
  final String? supplierName;
  final String? deliverDate;
  final String? closeReason;
  final List<OutboundPlanLine> lines;
  final List<OutboundDraftRef> drafts;

  factory OutboundTaskDetail.fromJson(Map<String, dynamic> json) =>
      OutboundTaskDetail(
        planId: json['planId'] as String,
        orderId: json['orderId'] as String,
        orderBillNo: json['orderBillNo'] as String?,
        status: json['status'] as String?,
        supplierId: json['supplierId'] as String?,
        supplierName: json['supplierName'] as String?,
        deliverDate: json['deliverDate'] as String?,
        closeReason: json['closeReason'] as String?,
        lines: [
          for (final e in (json['lines'] as List? ?? const []))
            OutboundPlanLine.fromJson((e as Map).cast<String, dynamic>()),
        ],
        drafts: [
          for (final e in (json['drafts'] as List? ?? const []))
            OutboundDraftRef.fromJson((e as Map).cast<String, dynamic>()),
        ],
      );
}

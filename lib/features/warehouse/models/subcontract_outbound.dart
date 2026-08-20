// 委外出仓工作台模型（V304 · 仓库视角：无价格/金额字段）。
//
// 财务批准委外订货后，系统按当时 BOM 展开发料计划并自动生出仓草稿；
// 仓库在出仓工作台看任务、拣货改量、审核出仓。数量口径：
// 待出仓 remainingQty = 计划量 plannedQty − 已出仓 issuedQty − 未审草稿占用 draftQty。

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
  );
}

/// 发料计划行（父件→子件）。
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

  double get remainingQty {
    final r = plannedQty - issuedQty - draftQty;
    return r < 0 ? 0 : r;
  }

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
        draftQty: (json['draftQty'] as num?)?.toDouble() ?? 0,
      );

  /// 按服务端发料计划快照构造出仓草稿行，颜色/单位 UUID 不由客户端重选。
  Map<String, dynamic> toMaterialIssueItemPayload({required double qty}) => {
    'goodsId': goodsId,
    'colorId': colorId,
    'unitId': unitId,
    'qty': qty,
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

// 委外出仓工作台模型(ADR-143 §4.3 · 仓库视角：无价格/金额字段)。
//
// 一行 = 委外人员在委外任务中心提交、仓库还没发出的一张委外领料单(草稿)。
// 每张领料单只含一个委外订货单在一个仓库要发的直属物料；每条明细都是某个
// 委外件(回厂交回的委外件)的直属物料。仓库只能把数量改少(≤ 提交的领料数量)，
// 不能改多、不能加行；少发的部分委外下次领料时自动补齐。

/// 待发料列表行(GET /warehouse/subcontract-outbound/tasks)。
class OutboundTask {
  const OutboundTask({
    required this.issueId,
    required this.issueBillNo,
    required this.planId,
    required this.orderId,
    required this.orderBillNo,
    required this.supplierName,
    required this.warehouseId,
    required this.warehouseName,
    required this.lineCount,
    required this.materialKindCount,
    required this.submittedAt,
    required this.submittedByName,
  });

  final String issueId;
  final String? issueBillNo;
  final String? planId;
  final String? orderId;
  final String? orderBillNo;
  final String? supplierName;
  final String? warehouseId;
  final String? warehouseName;
  final int lineCount;
  final int materialKindCount;

  /// 委外人员提交领料的时刻(ISO 时刻串)。
  final String? submittedAt;
  final String? submittedByName;

  factory OutboundTask.fromJson(Map<String, dynamic> json) => OutboundTask(
    issueId: json['issueId'] as String,
    issueBillNo: json['issueBillNo'] as String?,
    planId: json['planId'] as String?,
    orderId: json['orderId'] as String?,
    orderBillNo: json['orderBillNo'] as String?,
    supplierName: json['supplierName'] as String?,
    warehouseId: json['warehouseId'] as String?,
    warehouseName: json['warehouseName'] as String?,
    lineCount: (json['lineCount'] as num?)?.toInt() ?? 0,
    materialKindCount: (json['materialKindCount'] as num?)?.toInt() ?? 0,
    submittedAt: json['submittedAt'] as String?,
    submittedByName: json['submittedByName'] as String?,
  );
}

/// 领料单的一条明细(直属物料)：数量只能在 (0, [requestedQty]] 之间改。
class OutboundPickLine {
  const OutboundPickLine({
    required this.issueItemId,
    required this.planItemId,
    required this.lineNo,
    required this.parentGoodsName,
    required this.parentGoodsCode,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.requestedQty,
    required this.qty,
    required this.stockAvailableQty,
    required this.locationHint,
  });

  final String issueItemId;
  final String planItemId;
  final int? lineNo;

  /// 回厂交回的委外件(本行物料属于它的直属物料)。
  final String? parentGoodsName;
  final String? parentGoodsCode;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;

  /// 委外人员提交的领料数量：仓库本次出库数量的上限，提交后不可变。
  final double requestedQty;

  /// 当前草稿里的本次出库数量(仓库保存过拣货修改则是改后的量)。
  final double qty;

  /// 领料单所在仓里这条物料当前可动用的合格量(服务端口径，仅供核对)。
  final double? stockAvailableQty;

  /// 库位提示。
  final String? locationHint;

  factory OutboundPickLine.fromJson(Map<String, dynamic> json) =>
      OutboundPickLine(
        issueItemId: json['issueItemId'] as String,
        planItemId: json['planItemId'] as String,
        lineNo: (json['lineNo'] as num?)?.toInt(),
        parentGoodsName: json['parentGoodsName'] as String?,
        parentGoodsCode: json['parentGoodsCode'] as String?,
        goodsId: json['goodsId'] as String,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        requestedQty: (json['requestedQty'] as num?)?.toDouble() ?? 0,
        qty: (json['qty'] as num?)?.toDouble() ?? 0,
        stockAvailableQty: (json['stockAvailableQty'] as num?)?.toDouble(),
        locationHint: json['locationHint'] as String?,
      );
}

/// 领料单拣货详情(GET /warehouse/subcontract-outbound/tasks/{issueId})。
class OutboundTaskDetail {
  const OutboundTaskDetail({
    required this.issueId,
    required this.issueBillNo,
    required this.planId,
    required this.orderId,
    required this.orderBillNo,
    required this.supplierName,
    required this.warehouseId,
    required this.warehouseName,
    required this.version,
    required this.lines,
  });

  final String issueId;
  final String? issueBillNo;
  final String? planId;
  final String? orderId;
  final String? orderBillNo;
  final String? supplierName;

  /// 委外人员提交时服务端选定的发料仓。
  final String? warehouseId;
  final String? warehouseName;
  final int? version;
  final List<OutboundPickLine> lines;

  factory OutboundTaskDetail.fromJson(Map<String, dynamic> json) =>
      OutboundTaskDetail(
        issueId: json['issueId'] as String,
        issueBillNo: json['issueBillNo'] as String?,
        planId: json['planId'] as String?,
        orderId: json['orderId'] as String?,
        orderBillNo: json['orderBillNo'] as String?,
        supplierName: json['supplierName'] as String?,
        warehouseId: json['warehouseId'] as String?,
        warehouseName: json['warehouseName'] as String?,
        version: (json['version'] as num?)?.toInt(),
        lines: [
          for (final e in (json['lines'] as List? ?? const []))
            OutboundPickLine.fromJson((e as Map).cast<String, dynamic>()),
        ],
      );
}

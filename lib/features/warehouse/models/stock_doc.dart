// 仓库单据模型（8 类统一，对应后端 StockDocListItem/Detail/ItemDto，端点 /api/stock/docs）。
// 8 类 doc_type：调拨/其它入/出/领料/退料/产成品进仓/出仓/盘点（损耗空，跳过）。
// 与采购单据模型同构（主从表 + 状态机）；UUID=String，金额/数量=(json as num?)，日期=ISO 串。

import 'package:flutter/material.dart';

enum StockDocType {
  transfer('TRANSFER', '仓库调拨'),
  otherIn('OTHER_IN', '其它入库'),
  otherOut('OTHER_OUT', '其它出库'),
  draw('DRAW', '生产领料'),
  wdraw('WDRAW', '生产退料'),
  finishedIn('FINISHED_IN', '产成品进仓'),
  finishedOut('FINISHED_OUT', '产成品出仓'),
  check('CHECK', '盘点');

  const StockDocType(this.code, this.label);
  final String code;
  final String label;
  bool get supportsManualDraft => this != StockDocType.wdraw;

  /// 列表刷新信号 key：列表页与其详情/编辑页共享，详情/编辑页操作成功后
  /// bump 此 key，列表页（即便被遮在栈下）收到即重拉，返回不再看到老数据。
  String get refreshKey => 'stock:$name';

  static StockDocType? tryByCode(String code) {
    for (final type in StockDocType.values) {
      if (type.code == code) return type;
    }
    return null;
  }

  static StockDocType byCode(String code) =>
      tryByCode(code) ?? (throw ArgumentError.value(code, 'code', '未知仓库单据路由段'));
}

class StockDocListItem {
  const StockDocListItem({
    required this.id,
    this.docType,
    this.billNo,
    this.billDate,
    this.warehouseId,
    this.toWarehouseId,
    this.totalLocal,
    this.status,
    this.closed = false,
    this.legacyId,
    this.assTeam,
    this.departmentId,
    this.issueStatus,
  });
  final String id;
  final String? docType;
  final String? billNo;
  final String? billDate;
  final String? warehouseId;
  final String? toWarehouseId;
  final double? totalLocal;
  final int? status;
  final bool closed;
  final int? legacyId;
  final String? assTeam;

  /// 领料车间/部门（DRAW 用）
  final String? departmentId;

  /// 出库进度（仅 DRAW）：0未出库/1部分出库/2已出完
  final int? issueStatus;

  factory StockDocListItem.fromJson(Map<String, dynamic> json) =>
      StockDocListItem(
        id: json['id'] as String,
        docType: json['docType'] as String?,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        warehouseId: json['warehouseId'] as String?,
        toWarehouseId: json['toWarehouseId'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        assTeam: json['assTeam'] as String?,
        departmentId: json['departmentId'] as String?,
        issueStatus: (json['issueStatus'] as num?)?.toInt(),
      );
}

class StockDocItem {
  const StockDocItem({
    required this.id,
    this.lineNo,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.qty,
    this.reportedQty,
    this.baseQty,
    this.price,
    this.amountLocal,
    this.weight,
    this.surplusQty,
    this.countQty,
    this.place,
    this.remark,
    this.issuedQty,
    this.requestedQty,
    this.unitRate,
    this.upstreamItemId,
    this.executionSegmentId,
    this.executionSegmentSalesAllocationId,
    this.sourceDailyReportItemId,
    this.sourceDocNo,
  });
  final String? id;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? qty;
  final double? reportedQty;
  final double? baseQty;
  final double? price;
  final double? amountLocal;
  final double? weight;
  final double? surplusQty;
  final double? countQty;
  final String? place;
  final String? remark;
  final double? unitRate;
  final String? upstreamItemId;
  final String? executionSegmentId;
  final String? executionSegmentSalesAllocationId;
  final String? sourceDailyReportItemId;
  final String? sourceDocNo;

  /// 已出库量（仅 DRAW 领料行；qty−issuedQty=剩余可出）
  final double? issuedQty;

  /// 累计车间申请量，原需求仍保留在 qty。
  final double? requestedQty;

  /// 剩余可出数量（仅 DRAW）
  double get remainingQty =>
      ((requestedQty ?? qty ?? 0) - (issuedQty ?? 0)).clamp(0, double.infinity);

  factory StockDocItem.fromJson(Map<String, dynamic> json) => StockDocItem(
    id: json['id'] as String?,
    lineNo: (json['lineNo'] as num?)?.toInt(),
    goodsId: json['goodsId'] as String?,
    colorId: json['colorId'] as String?,
    unitId: json['unitId'] as String?,
    qty: (json['qty'] as num?)?.toDouble(),
    reportedQty: (json['reportedQty'] as num?)?.toDouble(),
    baseQty: (json['baseQty'] as num?)?.toDouble(),
    price: (json['price'] as num?)?.toDouble(),
    amountLocal: (json['amountLocal'] as num?)?.toDouble(),
    weight: (json['weight'] as num?)?.toDouble(),
    surplusQty: (json['surplusQty'] as num?)?.toDouble(),
    countQty: (json['countQty'] as num?)?.toDouble(),
    place: json['place'] as String?,
    remark: json['remark'] as String?,
    issuedQty: (json['issuedQty'] as num?)?.toDouble(),
    requestedQty: (json['requestedQty'] as num?)?.toDouble(),
    unitRate: (json['unitRate'] as num?)?.toDouble(),
    upstreamItemId: json['upstreamItemId'] as String?,
    sourceDocNo: json['sourceDocNo'] as String?,
    executionSegmentId: json['executionSegmentId'] as String?,
    executionSegmentSalesAllocationId:
        json['executionSegmentSalesAllocationId'] as String?,
    sourceDailyReportItemId: json['sourceDailyReportItemId'] as String?,
  );
}

class StockDocDetail {
  const StockDocDetail({
    required this.id,
    this.docType,
    this.billNo,
    this.billDate,
    this.warehouseId,
    this.toWarehouseId,
    this.remark,
    this.totalLocal,
    this.status,
    this.closed = false,
    this.sourceDocNo,
    this.sourceDailyReportId,
    this.sourcePlanId,
    this.planNo,
    this.workerId,
    this.makerId,
    this.assTeam,
    this.departmentId,
    this.issueStatus,
    this.makerName,
    this.createdAt,
    this.items = const [],
    this.productionLinked = false,
    this.productionMaterialReturn = false,
    this.materialReturnSourceWarehouseId,
    this.materialReturnMainWarehouseId,
    this.canEdit = false,
    this.canDelete = false,
    this.restrictionReason,
    this.finishedInboundDecision,
    this.finishedInboundVarianceReason,
  });
  final String id;
  final String? docType;
  final String? billNo;
  final String? billDate;
  final String? warehouseId;
  final String? toWarehouseId;
  final String? remark;
  final double? totalLocal;
  final int? status;
  final bool closed;
  final String? sourceDocNo;
  final String? sourceDailyReportId;

  /// 来源生产计划 id（plan_draw_links 反查；DRAW/FINISHED_IN 溯源跳转用）
  final String? sourcePlanId;

  /// 来源生产计划编号（快照文本）
  final String? planNo;

  /// 领料/经办负责人（后端已返回，仓库端应显示是谁来领料）
  final String? workerId;
  final String? makerId;
  final String? assTeam;

  /// 领料车间/部门（DRAW 用）
  final String? departmentId;

  /// 出库进度（仅 DRAW）：0未出库/1部分出库/2已出完
  final int? issueStatus;

  /// 制单员姓名（服务端解析；只读展示，不可修改）
  final String? makerName;

  /// 制单时间 ISO（审计 created_at，创建后不可变）
  final String? createdAt;
  final List<StockDocItem> items;
  final bool productionLinked;
  final bool productionMaterialReturn;
  final String? materialReturnSourceWarehouseId;
  final String? materialReturnMainWarehouseId;
  final bool canEdit;
  final bool canDelete;
  final String? restrictionReason;

  /// 仓库实收确认决策（ACCEPTED/PARTIAL/REJECTED）；无确认记录为 null
  final String? finishedInboundDecision;

  /// 实收差异/拒收原因（确认记录为权威，不再从备注解析）
  final String? finishedInboundVarianceReason;

  factory StockDocDetail.fromJson(Map<String, dynamic> json) => StockDocDetail(
    id: json['id'] as String,
    docType: json['docType'] as String?,
    billNo: json['billNo'] as String?,
    billDate: json['billDate'] as String?,
    warehouseId: json['warehouseId'] as String?,
    toWarehouseId: json['toWarehouseId'] as String?,
    remark: json['remark'] as String?,
    totalLocal: (json['totalLocal'] as num?)?.toDouble(),
    status: (json['status'] as num?)?.toInt(),
    closed: (json['closed'] as bool?) ?? false,
    sourceDocNo: json['sourceDocNo'] as String?,
    sourceDailyReportId: json['sourceDailyReportId'] as String?,
    sourcePlanId: json['sourcePlanId'] as String?,
    planNo: json['planNo'] as String?,
    workerId: json['workerId'] as String?,
    makerId: json['makerId'] as String?,
    assTeam: json['assTeam'] as String?,
    departmentId: json['departmentId'] as String?,
    issueStatus: (json['issueStatus'] as num?)?.toInt(),
    makerName: json['makerName'] as String?,
    createdAt: json['createdAt'] as String?,
    productionLinked: (json['productionLinked'] as bool?) ?? false,
    productionMaterialReturn: json['productionMaterialReturn'] == true,
    materialReturnSourceWarehouseId:
        json['materialReturnSourceWarehouseId'] as String?,
    materialReturnMainWarehouseId:
        json['materialReturnMainWarehouseId'] as String?,
    canEdit: (json['canEdit'] as bool?) ?? false,
    canDelete: (json['canDelete'] as bool?) ?? false,
    restrictionReason: json['restrictionReason'] as String?,
    finishedInboundDecision: json['finishedInboundDecision'] as String?,
    finishedInboundVarianceReason:
        json['finishedInboundVarianceReason'] as String?,
    items:
        (json['items'] as List?)
            ?.map((e) => StockDocItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

// 状态标签/色（与采购同：0草稿/1已审/-1红冲）
String stockStatusLabel(int? s) => const {0: '草稿', 1: '已审', -1: '红冲'}[s] ?? '—';

/// DRAW 出库进度标签（部分出库）
String drawIssueStatusLabel(int? s) =>
    const {0: '未出库', 1: '部分出库', 2: '已出完'}[s] ?? '—';

/// 各单据类型图标。
IconData iconFor(StockDocType t) => {
  StockDocType.transfer: Icons.swap_horiz_rounded,
  StockDocType.otherIn: Icons.login_rounded,
  StockDocType.otherOut: Icons.logout_rounded,
  StockDocType.draw: Icons.outbond_outlined,
  StockDocType.wdraw: Icons.undo_outlined,
  StockDocType.finishedIn: Icons.inbox_rounded,
  StockDocType.finishedOut: Icons.outbox_rounded,
  StockDocType.check: Icons.fact_check_outlined,
}[t]!;

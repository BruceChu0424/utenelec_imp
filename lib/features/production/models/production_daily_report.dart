// 生产日报 model（生产管理 · 空结构保未来）。
//
// 对应后端 server/src/main/java/com/uten/imp/features/production/dailyreport/：
//   ProductionDailyReport（头）+ ProductionDailyReportItem（明细）。
// 老库 F_DateReport 从未启用（字段类型自相矛盾，见 docs/数据迁移/23 §2.2），
// 本期建空结构保未来启用零成本（贴采购/仓库先例）。UI 完整但预期 0 行。
//
// 状态机与生产计划一致（0/1/-1），复用 production_plan.dart 的状态助手。
// JSON：camelCase；boolean isClosed/isCanceled → closed/canceled。
//
// 重新导出状态助手，方便日报页面从一处 import（plan/daily 共用 0/1/-1）。
export 'production_plan.dart'
    show
        kProductionStatusDraft,
        kProductionStatusApproved,
        kProductionStatusReversed,
        productionStatusLabel,
        productionStatusColor;

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// 生产日报列表行（GET /production/daily-reports → DailyReportListItem）。
class ProductionDailyReportListItem {
  const ProductionDailyReportListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.warehouseId,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.supplierId,
    this.status,
    this.closed = false,
    this.canceled = false,
    this.legacyId,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? warehouseId;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final String? supplierId;
  final int? status;
  final bool closed;
  final bool canceled;
  final int? legacyId;

  factory ProductionDailyReportListItem.fromJson(Map<String, dynamic> json) =>
      ProductionDailyReportListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        warehouseId: json['warehouseId'] as String?,
        departmentId: json['departmentId'] as String?,
        workshopName: json['workshopName'] as String?,
        workerId: json['workerId'] as String?,
        supplierId: json['supplierId'] as String?,
        status: _asInt(json['status']),
        closed: (json['closed'] as bool?) ?? false,
        canceled: (json['canceled'] as bool?) ?? false,
        legacyId: _asInt(json['legacyId']),
      );
}

/// 生产日报明细行（DailyReportItemDto）。
class ProductionDailyReportItem {
  const ProductionDailyReportItem({
    required this.id,
    this.lineNo,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.qty,
    this.price,
    this.total,
    this.stotal,
    this.salesOrderItemId,
    this.salesOrderNo,
    this.planItemId,
    this.executionSegmentId,
    this.executionSegmentSalesAllocationId,
    this.fqcRecoveryAuthorizationId,
    this.planNo,
    this.outboundNo,
    this.outboundQty,
    this.orderQty,
    this.stepLegacyId,
    this.orderDate,
    this.boxes,
    this.perBoxQty,
    this.weight,
    this.clientName,
    this.sourceDocNo,
    this.remark,
    this.isFinal = false,
  });

  final String id;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double? qty; // 完工量
  final double? price;
  final double? total; // 金额
  final double? stotal; // 成本金额
  final String? salesOrderItemId;
  final String? salesOrderNo;
  final String? planItemId; // → production_plan_items.id
  final String? executionSegmentId; // → production_execution_segments.id
  final String? executionSegmentSalesAllocationId;
  final String? fqcRecoveryAuthorizationId;
  final String? planNo;
  final String? outboundNo;
  final double? outboundQty;
  final double? orderQty;
  final int? stepLegacyId;
  final String? orderDate;
  final double? boxes;
  final double? perBoxQty;
  final double? weight;
  final String? clientName;
  final String? sourceDocNo;
  final String? remark;

  /// 本批普通完工申报终结；不代表品质合格，后续按 FQC 结果封顶、恢复或补产。
  final bool isFinal;

  factory ProductionDailyReportItem.fromJson(Map<String, dynamic> json) =>
      ProductionDailyReportItem(
        id: json['id'] as String,
        lineNo: _asInt(json['lineNo']),
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        unitRate: _asDouble(json['unitRate']),
        qty: _asDouble(json['qty']),
        price: _asDouble(json['price']),
        total: _asDouble(json['total']),
        stotal: _asDouble(json['stotal']),
        salesOrderItemId: json['salesOrderItemId'] as String?,
        salesOrderNo: json['salesOrderNo'] as String?,
        planItemId: json['planItemId'] as String?,
        executionSegmentId: json['executionSegmentId'] as String?,
        executionSegmentSalesAllocationId:
            json['executionSegmentSalesAllocationId'] as String?,
        fqcRecoveryAuthorizationId:
            json['fqcRecoveryAuthorizationId'] as String?,
        planNo: json['planNo'] as String?,
        outboundNo: json['outboundNo'] as String?,
        outboundQty: _asDouble(json['outboundQty']),
        orderQty: _asDouble(json['orderQty']),
        stepLegacyId: _asInt(json['stepLegacyId']),
        orderDate: json['orderDate'] as String?,
        boxes: _asDouble(json['boxes']),
        perBoxQty: _asDouble(json['perBoxQty']),
        weight: _asDouble(json['weight']),
        clientName: json['clientName'] as String?,
        sourceDocNo: json['sourceDocNo'] as String?,
        remark: json['remark'] as String?,
        isFinal: json['isFinal'] == true,
      );
}

/// 生产日报详情（GET /production/daily-reports/{id} → DailyReportDetail）。
class ProductionDailyReportDetail {
  const ProductionDailyReportDetail({
    required this.id,
    this.legacyId,
    this.billNo,
    this.billDate,
    this.warehouseId,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.supplierId,
    this.makerId,
    this.approverId,
    this.makerName,
    this.createdAt,
    this.makerLegacyId,
    this.approverLegacyId,
    this.remark,
    this.status,
    this.closed = false,
    this.canceled = false,
    this.sourceDocNo,
    this.rowVersion = 0,
    this.items = const [],
  });

  final String id;
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? warehouseId;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final String? supplierId;
  final String? makerId;
  final String? approverId;

  /// 制单员姓名（服务端解析；只读展示，不可修改）
  final String? makerName;

  /// 制单时间 ISO（审计 created_at，创建后不可变）
  final String? createdAt;
  final int? makerLegacyId;
  final int? approverLegacyId;
  final String? remark;
  final int? status;
  final bool closed;
  final bool canceled;
  final String? sourceDocNo;
  final int rowVersion;
  final List<ProductionDailyReportItem> items;

  factory ProductionDailyReportDetail.fromJson(Map<String, dynamic> json) =>
      ProductionDailyReportDetail(
        id: json['id'] as String,
        legacyId: _asInt(json['legacyId']),
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        warehouseId: json['warehouseId'] as String?,
        departmentId: json['departmentId'] as String?,
        workshopName: json['workshopName'] as String?,
        workerId: json['workerId'] as String?,
        supplierId: json['supplierId'] as String?,
        makerId: json['makerId'] as String?,
        makerName: json['makerName'] as String?,
        createdAt: json['createdAt'] as String?,
        approverId: json['approverId'] as String?,
        makerLegacyId: _asInt(json['makerLegacyId']),
        approverLegacyId: _asInt(json['approverLegacyId']),
        remark: json['remark'] as String?,
        status: _asInt(json['status']),
        closed: (json['closed'] as bool?) ?? false,
        canceled: (json['canceled'] as bool?) ?? false,
        sourceDocNo: json['sourceDocNo'] as String?,
        rowVersion: _asInt(json['rowVersion']) ?? 0,
        items:
            (json['items'] as List?)
                ?.map(
                  (e) => ProductionDailyReportItem.fromJson(
                    e as Map<String, dynamic>,
                  ),
                )
                .toList() ??
            const [],
      );
}

// 生产报表行 model（生产管理 · 分析类）。
//
// 对应后端 server/src/main/java/com/uten/imp/features/production/report/：
//   GET /production/reports/plan/detail   → List<PlanDetailRow>（分页，非 PageResponse）
//   GET /production/reports/plan/summary  → List<MonthlySummaryRow>（MV 上卷）
//   GET /production/reports/daily/detail  → List<DailyDetailRow>（本期 0 行）
//   GET /production/reports/daily/summary → List<MonthlySummaryRow>（本期 0 行）
//
// 注意：4 个报表端点都返回裸 JSON 数组（不是 PageResponse 包装），
//   repository 用 api.getList 解析；前两个 detail 端点带 page/size 分页参数。
//
// 报表类型枚举见本文件 ProductionReportType（hub 4 卡片 + ProductionReportPage 共用）。

import 'package:flutter/material.dart';

/// 生产报表类型（hub 第二组「生产报表」4 入口；与路由 /production/reports/{x} 一一对应）。
enum ProductionReportType {
  /// 生产计划明细报表（按行展开，参数化：日期 + 货品 + 状态 + 单号 + 分页）。
  planDetail('plan-detail', '计划明细', Icons.list_alt_outlined),
  /// 生产计划汇总报表（production_monthly_mv WHERE doc_type='PLAN'，月×货品上卷）。
  planSummary('plan-summary', '计划汇总', Icons.bar_chart_outlined),
  /// 生产日报明细报表（空结构，本期 0 行）。
  dailyDetail('daily-detail', '日报明细', Icons.receipt_long_outlined),
  /// 生产日报汇总报表（MV doc_type='DAILY'，空结构，本期 0 行）。
  dailySummary('daily-summary', '日报汇总', Icons.insert_chart_outlined);

  const ProductionReportType(this.pathSegment, this.label, this.icon);

  /// 路径段（与 app_router 注册的 /production/reports/{pathSegment} 对齐）。
  final String pathSegment;
  final String label;
  final IconData icon;

  /// 是否为明细报表（带分页 + 状态/单号过滤）；汇总走 MV，仅日期过滤 + limit。
  bool get isDetail => this == ProductionReportType.planDetail ||
      this == ProductionReportType.dailyDetail;

  /// 是否为计划类（plan*）；否则为日报类（daily*）。
  bool get isPlan =>
      this == ProductionReportType.planDetail ||
      this == ProductionReportType.planSummary;

  static ProductionReportType byPath(String seg) {
    for (final t in ProductionReportType.values) {
      if (t.pathSegment == seg) return t;
    }
    return ProductionReportType.planDetail;
  }
}

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

/// 生产计划明细报表行（GET /reports/plan/detail → PlanDetailRow）。
/// 比 ProductionPlanItem 多 planStatus/planClosed/deliveryDate（JOIN plans 取）。
class ProductionPlanDetailReportRow {
  const ProductionPlanDetailReportRow({
    required this.id,
    this.billNo,
    this.billDate,
    this.planId,
    this.lineNo,
    this.productNo,
    this.goodsId,
    this.colorId,
    this.mgoodsId,
    this.unitId,
    this.unitRate,
    this.salesOrderItemId,
    this.salesOrderNo,
    this.clientName,
    this.clientNo,
    this.oqty,
    this.qty,
    this.lqty,
    this.iqty,
    this.fqty,
    this.rqty,
    this.bqty,
    this.tqty,
    this.paqty,
    this.isrqty,
    this.cpqty,
    this.poqty,
    this.piqty,
    this.deliveryDate,
    this.orderDate,
    this.outboundDate,
    this.planBeginDate,
    this.planEndDate,
    this.finishedWeight,
    this.inboundWeight,
    this.lstatus,
    this.cstatus,
    this.planStatus,
    this.planClosed = false,
    this.legacyId,
    this.remark,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? planId;
  final int? lineNo;
  final String? productNo;
  final String? goodsId;
  final String? colorId;
  final String? mgoodsId;
  final String? unitId;
  final double? unitRate;
  final String? salesOrderItemId;
  final String? salesOrderNo;
  final String? clientName;
  final String? clientNo;
  final double? oqty;
  final double? qty;
  final double? lqty;
  final double? iqty;
  final double? fqty;
  final double? rqty;
  final double? bqty;
  final double? tqty;
  final double? paqty;
  final double? isrqty;
  final double? cpqty;
  final double? poqty;
  final double? piqty;
  final String? deliveryDate;
  final String? orderDate;
  final String? outboundDate;
  final String? planBeginDate;
  final String? planEndDate;
  final double? finishedWeight;
  final double? inboundWeight;
  final int? lstatus;
  final int? cstatus;
  final int? planStatus; // 父计划 status（过滤用）
  final bool planClosed; // 父计划 is_closed
  final int? legacyId;
  final String? remark;

  factory ProductionPlanDetailReportRow.fromJson(Map<String, dynamic> json) =>
      ProductionPlanDetailReportRow(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        planId: json['planId'] as String?,
        lineNo: _asInt(json['lineNo']),
        productNo: json['productNo'] as String?,
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        mgoodsId: json['mgoodsId'] as String?,
        unitId: json['unitId'] as String?,
        unitRate: _asDouble(json['unitRate']),
        salesOrderItemId: json['salesOrderItemId'] as String?,
        salesOrderNo: json['salesOrderNo'] as String?,
        clientName: json['clientName'] as String?,
        clientNo: json['clientNo'] as String?,
        oqty: _asDouble(json['oqty']),
        qty: _asDouble(json['qty']),
        lqty: _asDouble(json['lqty']),
        iqty: _asDouble(json['iqty']),
        fqty: _asDouble(json['fqty']),
        rqty: _asDouble(json['rqty']),
        bqty: _asDouble(json['bqty']),
        tqty: _asDouble(json['tqty']),
        paqty: _asDouble(json['paqty']),
        isrqty: _asDouble(json['isrqty']),
        cpqty: _asDouble(json['cpqty']),
        poqty: _asDouble(json['poqty']),
        piqty: _asDouble(json['piqty']),
        deliveryDate: json['deliveryDate'] as String?,
        orderDate: json['orderDate'] as String?,
        outboundDate: json['outboundDate'] as String?,
        planBeginDate: json['planBeginDate'] as String?,
        planEndDate: json['planEndDate'] as String?,
        finishedWeight: _asDouble(json['finishedWeight']),
        inboundWeight: _asDouble(json['inboundWeight']),
        lstatus: _asInt(json['lstatus']),
        cstatus: _asInt(json['cstatus']),
        planStatus: _asInt(json['planStatus']),
        planClosed: (json['planClosed'] as bool?) ?? false,
        legacyId: _asInt(json['legacyId']),
        remark: json['remark'] as String?,
      );
}

/// 生产日报明细报表行（GET /reports/daily/detail → DailyDetailRow，本期 0 行）。
class ProductionDailyDetailReportRow {
  const ProductionDailyDetailReportRow({
    required this.id,
    this.billNo,
    this.billDate,
    this.reportId,
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
    this.status,
    this.legacyId,
    this.remark,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? reportId;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double? qty;
  final double? price;
  final double? total;
  final double? stotal;
  final String? salesOrderItemId;
  final String? salesOrderNo;
  final String? planItemId;
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
  final int? status;
  final int? legacyId;
  final String? remark;

  factory ProductionDailyDetailReportRow.fromJson(Map<String, dynamic> json) =>
      ProductionDailyDetailReportRow(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        reportId: json['reportId'] as String?,
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
        status: _asInt(json['status']),
        legacyId: _asInt(json['legacyId']),
        remark: json['remark'] as String?,
      );
}

/// 月度上卷行（GET /reports/plan/summary 和 /reports/daily/summary → MonthlySummaryRow）。
class ProductionMonthlySummaryRow {
  const ProductionMonthlySummaryRow({
    this.docType,
    this.ym,
    this.goodsId,
    this.clientId, // 生产无 client FK，恒 null
    this.planQtySum,
    this.orderQtySum,
    this.finishedQtySum,
    this.inboundQtySum,
    this.lineCnt,
  });

  final String? docType; // 'PLAN' / 'DAILY'
  final String? ym; // 月首日期 yyyy-MM-dd
  final String? goodsId;
  final String? clientId;
  final double? planQtySum;
  final double? orderQtySum;
  final double? finishedQtySum;
  final double? inboundQtySum;
  final int? lineCnt;

  factory ProductionMonthlySummaryRow.fromJson(Map<String, dynamic> json) =>
      ProductionMonthlySummaryRow(
        docType: json['docType'] as String?,
        ym: json['ym'] as String?,
        goodsId: json['goodsId'] as String?,
        clientId: json['clientId'] as String?,
        planQtySum: _asDouble(json['planQtySum']),
        orderQtySum: _asDouble(json['orderQtySum']),
        finishedQtySum: _asDouble(json['finishedQtySum']),
        inboundQtySum: _asDouble(json['inboundQtySum']),
        lineCnt: _asInt(json['lineCnt']),
      );
}

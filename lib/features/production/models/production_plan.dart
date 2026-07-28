// 生产计划单 model（生产管理 / production）。
//
// 对应后端 server/src/main/java/com/uten/imp/features/production/plan/：
//   ProductionPlan（头）+ ProductionPlanItem（明细，41 字段含 12 数量族）。
// DTO 形状：PlanListItem（列表行）/ PlanDetail（详情含 items）/ PlanItemDto（明细行）。
//
// 状态机：0=草稿 / 1=已审 / -1=红冲（与采购/日报一致；记忆 purchase-module-progress）。
// JSON 注意：Jackson 把 boolean isClosed/isStopped/isCanceled 序列化为 closed/stopped/canceled
//   （去掉 is 前缀）；日期为 yyyy-MM-dd 字符串；数量/金额 NUMERIC(18,4) 按 num? 容错。
// 容错助手 _asInt/_asDouble 同时处理 int/double/String（记忆 flutter-int-cast-fromjson）。
import 'package:flutter/material.dart';

/// 生产单据状态常量（plan/daily 共用；与后端 status SMALLINT 0/1/-1 对齐）。
const int kProductionStatusDraft = 0;
const int kProductionStatusApproved = 1;
const int kProductionStatusReversed = -1;

String productionStatusLabel(int? code) {
  switch (code) {
    case kProductionStatusDraft:
      return '草稿';
    case kProductionStatusApproved:
      return '已审';
    case kProductionStatusReversed:
      return '红冲';
    default:
      return '—';
  }
}

/// 截取日期字符串为 yyyy-MM-dd；null/空/不足 10 位则原样返回（避免 substring 越界：
/// 后端日期可能为 null 或短串，`''.substring(0,10)` 会抛 RangeError 整页渲染失败）。
String productionDateOnly(String? s) {
  if (s == null) return '';
  return s.length >= 10 ? s.substring(0, 10) : s;
}

Color productionStatusColor(int? code, ThemeData theme) {
  switch (code) {
    case kProductionStatusApproved:
      return Colors.green;
    case kProductionStatusReversed:
      return theme.colorScheme.error;
    default:
      return theme.colorScheme.onSurfaceVariant;
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

/// 生产计划单列表行（GET /production/plans → PlanListItem）。
class ProductionPlanListItem {
  const ProductionPlanListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.deliveryDate,
    this.departmentId,
    this.workshopName,
    this.workerName,
    this.sellerName,
    this.status,
    this.closed = false,
    this.stopped = false,
    this.canceled = false,
    this.legacyId,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? deliveryDate;
  final String? departmentId;
  final String? workshopName;
  final String? workerName;
  final String? sellerName;
  final int? status;
  final bool closed;
  final bool stopped;
  final bool canceled;
  final int? legacyId;

  factory ProductionPlanListItem.fromJson(Map<String, dynamic> json) =>
      ProductionPlanListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        deliveryDate: json['deliveryDate'] as String?,
        departmentId: json['departmentId'] as String?,
        workshopName: json['workshopName'] as String?,
        workerName: json['workerName'] as String?,
        sellerName: json['sellerName'] as String?,
        status: _asInt(json['status']),
        closed: (json['closed'] as bool?) ?? false,
        stopped: (json['stopped'] as bool?) ?? false,
        canceled: (json['canceled'] as bool?) ?? false,
        legacyId: _asInt(json['legacyId']),
      );
}

/// 生产计划明细行（PlanItemDto，含 12 数量族；BOM 展开挂 billItemId→本 id）。
class ProductionPlanItem {
  const ProductionPlanItem({
    required this.id,
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
    this.orderDate,
    this.outboundDate,
    this.planBeginDate,
    this.planEndDate,
    this.finishedWeight,
    this.inboundWeight,
    this.lstatus,
    this.cstatus,
    this.stepLegacyId,
    this.veilLegacyId,
    this.assTeamLegacyId,
    this.fittings,
    this.requestNote,
    this.customerModel,
    this.discount,
    this.labelNo,
    this.planAppNo,
    this.sourceDocNo,
    this.remark,
  });

  final String id;
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

  /// 数量族（12 个，NUMERIC(18,4)；触发器游标回写累计量，本期不重算）。
  final double? oqty; // 销售订货量
  final double? qty; // 本单排产数量
  final double? lqty; // BOM 展开锁定用量
  final double? iqty; // 完工/进仓数量（仓库回写）
  final double? fqty; // 完工数量（工序回写）
  final double? rqty; // 入库数量
  final double? bqty; // 在产数量
  final double? tqty; // 开工数量
  final double? paqty; // 已排产量
  final double? isrqty; // 已入库量
  final double? cpqty; // 应排数量
  final double? poqty; // 已订货（采购回写）
  final double? piqty; // 已收货（采购回写）

  final String? orderDate;
  final String? outboundDate;
  final String? planBeginDate;
  final String? planEndDate;
  final double? finishedWeight;
  final double? inboundWeight;
  final int? lstatus;
  final int? cstatus;
  final int? stepLegacyId;
  final int? veilLegacyId;
  final int? assTeamLegacyId;
  final String? fittings;
  final String? requestNote;
  final String? customerModel;
  final double? discount;
  final String? labelNo;
  final String? planAppNo;
  final String? sourceDocNo;
  final String? remark;

  factory ProductionPlanItem.fromJson(Map<String, dynamic> json) =>
      ProductionPlanItem(
        id: json['id'] as String,
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
        orderDate: json['orderDate'] as String?,
        outboundDate: json['outboundDate'] as String?,
        planBeginDate: json['planBeginDate'] as String?,
        planEndDate: json['planEndDate'] as String?,
        finishedWeight: _asDouble(json['finishedWeight']),
        inboundWeight: _asDouble(json['inboundWeight']),
        lstatus: _asInt(json['lstatus']),
        cstatus: _asInt(json['cstatus']),
        stepLegacyId: _asInt(json['stepLegacyId']),
        veilLegacyId: _asInt(json['veilLegacyId']),
        assTeamLegacyId: _asInt(json['assTeamLegacyId']),
        fittings: json['fittings'] as String?,
        requestNote: json['requestNote'] as String?,
        customerModel: json['customerModel'] as String?,
        discount: _asDouble(json['discount']),
        labelNo: json['labelNo'] as String?,
        planAppNo: json['planAppNo'] as String?,
        sourceDocNo: json['sourceDocNo'] as String?,
        remark: json['remark'] as String?,
      );
}

/// 生产计划单详情（GET /production/plans/{id} → PlanDetail）。
class ProductionPlanDetail {
  const ProductionPlanDetail({
    required this.id,
    this.legacyId,
    this.billNo,
    this.billDate,
    this.fStyle,
    this.deliveryDate,
    this.departmentId,
    this.workshopName,
    this.workerName,
    this.sellerName,
    this.makerId,
    this.approverId,
    this.makerLegacyId,
    this.approverLegacyId,
    this.remark,
    this.status,
    this.closed = false,
    this.stopped = false,
    this.canceled = false,
    this.sourceDocNo,
    this.items = const [],
  });

  final String id;
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? fStyle;
  final String? deliveryDate;
  final String? departmentId;
  final String? workshopName;
  final String? workerName;
  final String? sellerName;
  final String? makerId;
  final String? approverId;
  final int? makerLegacyId;
  final int? approverLegacyId;
  final String? remark;
  final int? status;
  final bool closed;
  final bool stopped;
  final bool canceled;
  final String? sourceDocNo;
  final List<ProductionPlanItem> items;

  factory ProductionPlanDetail.fromJson(Map<String, dynamic> json) =>
      ProductionPlanDetail(
        id: json['id'] as String,
        legacyId: _asInt(json['legacyId']),
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        fStyle: json['fStyle'] as String?,
        deliveryDate: json['deliveryDate'] as String?,
        departmentId: json['departmentId'] as String?,
        workshopName: json['workshopName'] as String?,
        workerName: json['workerName'] as String?,
        sellerName: json['sellerName'] as String?,
        makerId: json['makerId'] as String?,
        approverId: json['approverId'] as String?,
        makerLegacyId: _asInt(json['makerLegacyId']),
        approverLegacyId: _asInt(json['approverLegacyId']),
        remark: json['remark'] as String?,
        status: _asInt(json['status']),
        closed: (json['closed'] as bool?) ?? false,
        stopped: (json['stopped'] as bool?) ?? false,
        canceled: (json['canceled'] as bool?) ?? false,
        sourceDocNo: json['sourceDocNo'] as String?,
        items: (json['items'] as List?)
                ?.map((e) =>
                    ProductionPlanItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

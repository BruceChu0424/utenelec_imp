// 采购单据模型（4 单据统一超集，对应后端 *ListItem/*Detail/*ItemDto）。
//
// 4 单据差异由 doc_type 决定可选字段是否非空（申请无供应商/币种；收货有 sender/receiver；
// 退货明细有 receiptItemId+orderItemId；等）。一个超集模型 ×4 配置，避免 4 套重复。
// UUID=String；金额/数量=(json as num?)；日期=ISO 字符串直存（后端 LocalDate）。

import 'package:flutter/material.dart';

import '../../../shared/models/procurement_finance_approval.dart';

/// 采购单据类型。pathSegment 对齐后端 /api/purchase/{requests|orders|receipts|returns}。
enum PurchaseDocType {
  request('requests'),
  order('orders'),
  receipt('receipts'),
  returnDoc('returns');

  const PurchaseDocType(this.pathSegment);
  final String pathSegment;

  static PurchaseDocType? tryByPath(String seg) {
    for (final type in PurchaseDocType.values) {
      if (type.pathSegment == seg) return type;
    }
    return null;
  }

  static PurchaseDocType byPath(String seg) =>
      tryByPath(seg) ?? (throw ArgumentError.value(seg, 'seg', '未知采购单据路由段'));
}

/// 单据状态：0草稿 / 1已审 / -1红冲 / 2已取消（2026-09-05 起草稿单可取消，
/// 保留轨迹；在审单取消时审批 case 同步置 CANCELED）。
const int kPurchaseStatusDraft = 0;
const int kPurchaseStatusApproved = 1;
const int kPurchaseStatusReversed = -1;
const int kPurchaseStatusCanceled = 2;

String purchaseStatusLabel(int? code) {
  switch (code) {
    case kPurchaseStatusDraft:
      return '草稿';
    case kPurchaseStatusApproved:
      return '已审';
    case kPurchaseStatusReversed:
      return '红冲';
    case kPurchaseStatusCanceled:
      return '已取消';
    default:
      return '—';
  }
}

/// 状态对应的主题色（徽章用）。
Color purchaseStatusColor(int? code, ThemeData theme) {
  switch (code) {
    case kPurchaseStatusDraft:
      return theme.colorScheme.onSurfaceVariant;
    case kPurchaseStatusApproved:
      return Colors.green;
    case kPurchaseStatusReversed:
      return theme.colorScheme.error;
    case kPurchaseStatusCanceled:
      return theme.colorScheme.outline;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

class PurchaseDocListItem {
  const PurchaseDocListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.warehouseId,
    this.totalLocal,
    this.priceMasked = false,
    this.status,
    this.closed = false,
    this.legacyId,
    this.financeApproval,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final double? totalLocal;

  /// 价格已对当前用户脱敏（金额族为 null；渲染 ***，V302 收货单价格脱敏）。
  final bool priceMasked;
  final int? status;
  final bool closed;
  final int? legacyId;
  final ProcurementFinanceApproval? financeApproval;

  factory PurchaseDocListItem.fromJson(Map<String, dynamic> json) =>
      PurchaseDocListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        priceMasked: (json['priceMasked'] as bool?) ?? false,
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        financeApproval: json['financeApproval'] is Map
            ? ProcurementFinanceApproval.fromJson(
                (json['financeApproval'] as Map).cast<String, dynamic>(),
              )
            : null,
      );
}

class PurchaseDocItem {
  const PurchaseDocItem({
    required this.id,
    this.lineNo,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.qty,
    this.price,
    this.amountOriginal,
    this.amountLocal,
    this.orderedQty,
    this.receivedQty,
    this.returnedQty,
    this.giftQty,
    this.requestItemId,
    this.orderItemId,
    this.orderId,
    this.orderBillNo,
    this.receiptItemId,
    this.deliverDate,
    this.weight,
    this.sourceDocNo,
    this.productionPlanNo,
    this.salesOrderNo,
    this.remark,
    this.sourceRequests = const [],
  });

  final String? id;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double? qty;
  final double? price;
  final double? amountOriginal;
  final double? amountLocal;
  final double? orderedQty;
  final double? receivedQty;
  final double? returnedQty;
  final double? giftQty;
  final String? requestItemId;
  final String? orderItemId;

  /// 来源订货单 id（收货/进仓明细级，点击跳订货详情用）；无订货关联为 null。
  final String? orderId;

  /// 来源订货单编号（收货/进仓明细级展示：编号而非 id）；无订货关联为 null。
  final String? orderBillNo;
  final String? receiptItemId;
  final String? deliverDate;
  final double? weight;
  final String? sourceDocNo;
  final String? productionPlanNo;
  final String? salesOrderNo;
  final String? remark;

  /// 全部来源申请（V463 同货品合并行多来源）：明细 id + 申请单 id + 单号，
  /// 稳定顺序与 sources.line_no 一致；单来源行一条、手工/历史行为空。
  final List<PurchaseSourceRequestRef> sourceRequests;

  factory PurchaseDocItem.fromJson(Map<String, dynamic> json) =>
      PurchaseDocItem(
        id: json['id'] as String?,
        lineNo: (json['lineNo'] as num?)?.toInt(),
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        unitRate: (json['unitRate'] as num?)?.toDouble(),
        qty: (json['qty'] as num?)?.toDouble(),
        price: (json['price'] as num?)?.toDouble(),
        amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
        orderedQty: (json['orderedQty'] as num?)?.toDouble(),
        receivedQty: (json['receivedQty'] as num?)?.toDouble(),
        returnedQty: (json['returnedQty'] as num?)?.toDouble(),
        giftQty: (json['giftQty'] as num?)?.toDouble(),
        requestItemId: json['requestItemId'] as String?,
        orderItemId: json['orderItemId'] as String?,
        orderId: json['orderId'] as String?,
        orderBillNo: json['orderBillNo'] as String?,
        receiptItemId: json['receiptItemId'] as String?,
        deliverDate: json['deliverDate'] as String?,
        weight: (json['weight'] as num?)?.toDouble(),
        sourceDocNo: json['sourceDocNo'] as String?,
        productionPlanNo: json['productionPlanNo'] as String?,
        salesOrderNo: json['salesOrderNo'] as String?,
        remark: json['remark'] as String?,
        sourceRequests: [
          for (final entry
              in (json['sourceRequests'] as List<dynamic>? ??
                  const <dynamic>[]))
            PurchaseSourceRequestRef.fromJson(entry as Map<String, dynamic>),
        ],
      );
}

/// 订货行的来源采购申请引用（V463 合并行多来源）。
class PurchaseSourceRequestRef {
  const PurchaseSourceRequestRef({
    required this.requestItemId,
    this.requestId,
    this.billNo,
  });

  final String requestItemId;
  final String? requestId;
  final String? billNo;

  factory PurchaseSourceRequestRef.fromJson(Map<String, dynamic> json) =>
      PurchaseSourceRequestRef(
        requestItemId: json['requestItemId'] as String,
        requestId: json['requestId'] as String?,
        billNo: json['billNo'] as String?,
      );
}

class PurchaseDocDetail {
  const PurchaseDocDetail({
    required this.id,
    this.legacyId,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.warehouseId,
    this.departmentId,
    this.currencyId,
    this.exchangeRate,
    this.taxRate,
    this.applicantId,
    this.purchaserId,
    this.settlementMethodId,
    this.settlementStyleLegacy,
    this.senderId,
    this.receiverId,
    this.makerId,
    this.approverId,
    this.makerName,
    this.createdAt,
    this.needDate,
    this.deliverDate,
    this.remark,
    this.totalOriginal,
    this.totalLocal,
    this.priceMasked = false,
    this.status,
    this.closed = false,
    this.sourceDocNo,
    this.items = const [],
    this.productionLinked = false,
    this.canEdit = false,
    this.canDelete = false,
    this.canReverse = false,
    this.restrictionReason,
    this.financeApproval,
    this.sourceRequestId,
    this.sourceRequestNo,
    this.sourceOrderId,
    this.sourceOrderNo,
  });

  final String id;
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final String? departmentId;
  final String? currencyId;
  final double? exchangeRate;
  final double? taxRate;
  final String? applicantId;
  final String? purchaserId;
  final String? settlementMethodId;
  final int? settlementStyleLegacy;
  final String? senderId;
  final String? receiverId;
  final String? makerId;
  final String? approverId;

  /// 制单员姓名（服务端解析；只读展示，不可修改）
  final String? makerName;

  /// 制单时间 ISO（审计 created_at，创建后不可变）
  final String? createdAt;
  final String? needDate;
  final String? deliverDate;
  final String? remark;
  final double? totalOriginal;
  final double? totalLocal;

  /// 价格已对当前用户脱敏（金额族/明细价格族为 null；渲染 ***，V302 收货单价格脱敏）。
  final bool priceMasked;
  final int? status;
  final bool closed;
  final String? sourceDocNo;
  final List<PurchaseDocItem> items;
  final bool productionLinked;
  final bool canEdit;
  final bool canDelete;
  final bool canReverse;
  final String? restrictionReason;
  final ProcurementFinanceApproval? financeApproval;

  /// 来源采购申请（订货单全部明细同源时给出，供跳转；跨申请分解为 null）
  final String? sourceRequestId;
  final String? sourceRequestNo;

  /// 来源采购订货单（收货单全部明细同源时给出，供跳转；跨订单为 null）
  final String? sourceOrderId;
  final String? sourceOrderNo;

  factory PurchaseDocDetail.fromJson(Map<String, dynamic> json) =>
      PurchaseDocDetail(
        id: json['id'] as String,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        departmentId: json['departmentId'] as String?,
        currencyId: json['currencyId'] as String?,
        exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
        taxRate: (json['taxRate'] as num?)?.toDouble(),
        applicantId: json['applicantId'] as String?,
        purchaserId: json['purchaserId'] as String?,
        settlementMethodId: json['settlementMethodId'] as String?,
        settlementStyleLegacy: (json['settlementStyleLegacy'] as num?)?.toInt(),
        senderId: json['senderId'] as String?,
        receiverId: json['receiverId'] as String?,
        makerId: json['makerId'] as String?,
        makerName: json['makerName'] as String?,
        createdAt: json['createdAt'] as String?,
        approverId: json['approverId'] as String?,
        needDate: json['needDate'] as String?,
        deliverDate: json['deliverDate'] as String?,
        remark: json['remark'] as String?,
        totalOriginal: (json['totalOriginal'] as num?)?.toDouble(),
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        priceMasked: (json['priceMasked'] as bool?) ?? false,
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        sourceDocNo: json['sourceDocNo'] as String?,
        productionLinked: (json['productionLinked'] as bool?) ?? false,
        canEdit: (json['canEdit'] as bool?) ?? false,
        canDelete: (json['canDelete'] as bool?) ?? false,
        canReverse: (json['canReverse'] as bool?) ?? false,
        restrictionReason: json['restrictionReason'] as String?,
        sourceRequestId: json['sourceRequestId'] as String?,
        sourceRequestNo: json['sourceRequestNo'] as String?,
        sourceOrderId: json['sourceOrderId'] as String?,
        sourceOrderNo: json['sourceOrderNo'] as String?,
        financeApproval: json['financeApproval'] is Map
            ? ProcurementFinanceApproval.fromJson(
                (json['financeApproval'] as Map).cast<String, dynamic>(),
              )
            : null,
        items:
            (json['items'] as List?)
                ?.map(
                  (e) => PurchaseDocItem.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
      );
}

class ProcurementDecompositionLine {
  const ProcurementDecompositionLine({
    required this.sourceDocumentId,
    required this.sourceDocumentNo,
    required this.sourceItemId,
    required this.goodsId,
    required this.requestedQty,
    required this.orderedQty,
    required this.pendingQty,
    required this.remainingQty,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.needDate,
    this.warehouseId,
    this.sourcePlanNo,
  });

  final String sourceDocumentId;
  final String sourceDocumentNo;
  final String sourceItemId;
  final String goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double requestedQty;
  final double orderedQty;
  final double pendingQty;
  final double remainingQty;
  final String? needDate;
  final String? warehouseId;
  final String? sourcePlanNo;

  factory ProcurementDecompositionLine.fromJson(Map<String, dynamic> json) {
    double number(String key) {
      final value = json[key];
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    return ProcurementDecompositionLine(
      sourceDocumentId: json['sourceDocumentId'] as String,
      sourceDocumentNo: json['sourceDocumentNo'] as String? ?? '',
      sourceItemId: json['sourceItemId'] as String,
      goodsId: json['goodsId'] as String,
      colorId: json['colorId'] as String?,
      unitId: json['unitId'] as String?,
      unitRate: json['unitRate'] == null ? null : number('unitRate'),
      requestedQty: number('requestedQty'),
      orderedQty: number('orderedQty'),
      pendingQty: number('pendingQty'),
      remainingQty: number('remainingQty'),
      needDate: json['needDate'] as String?,
      warehouseId: json['warehouseId'] as String?,
      sourcePlanNo: json['sourcePlanNo'] as String?,
    );
  }
}

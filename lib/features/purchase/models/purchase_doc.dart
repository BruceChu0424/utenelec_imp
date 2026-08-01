// 采购单据模型（4 单据统一超集，对应后端 *ListItem/*Detail/*ItemDto）。
//
// 4 单据差异由 doc_type 决定可选字段是否非空（申请无供应商/币种；收货有 sender/receiver；
// 退货明细有 receiptItemId+orderItemId；等）。一个超集模型 ×4 配置，避免 4 套重复。
// UUID=String；金额/数量=(json as num?)；日期=ISO 字符串直存（后端 LocalDate）。

import 'package:flutter/material.dart';

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

/// 单据状态：0草稿 / 1已审 / -1红冲。
const int kPurchaseStatusDraft = 0;
const int kPurchaseStatusApproved = 1;
const int kPurchaseStatusReversed = -1;

String purchaseStatusLabel(int? code) {
  switch (code) {
    case kPurchaseStatusDraft:
      return '草稿';
    case kPurchaseStatusApproved:
      return '已审';
    case kPurchaseStatusReversed:
      return '红冲';
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
    this.status,
    this.closed = false,
    this.legacyId,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final double? totalLocal;
  final int? status;
  final bool closed;
  final int? legacyId;

  factory PurchaseDocListItem.fromJson(Map<String, dynamic> json) =>
      PurchaseDocListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
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
    this.receiptItemId,
    this.deliverDate,
    this.weight,
    this.sourceDocNo,
    this.remark,
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
  final String? receiptItemId;
  final String? deliverDate;
  final double? weight;
  final String? sourceDocNo;
  final String? remark;

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
        receiptItemId: json['receiptItemId'] as String?,
        deliverDate: json['deliverDate'] as String?,
        weight: (json['weight'] as num?)?.toDouble(),
        sourceDocNo: json['sourceDocNo'] as String?,
        remark: json['remark'] as String?,
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
    this.currencyId,
    this.exchangeRate,
    this.taxRate,
    this.applicantId,
    this.purchaserId,
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
    this.status,
    this.closed = false,
    this.sourceDocNo,
    this.items = const [],
    this.productionLinked = false,
    this.canEdit = true,
    this.canDelete = true,
    this.canReverse = true,
    this.restrictionReason,
  });

  final String id;
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final String? currencyId;
  final double? exchangeRate;
  final double? taxRate;
  final String? applicantId;
  final String? purchaserId;
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
  final int? status;
  final bool closed;
  final String? sourceDocNo;
  final List<PurchaseDocItem> items;
  final bool productionLinked;
  final bool canEdit;
  final bool canDelete;
  final bool canReverse;
  final String? restrictionReason;

  factory PurchaseDocDetail.fromJson(Map<String, dynamic> json) =>
      PurchaseDocDetail(
        id: json['id'] as String,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        currencyId: json['currencyId'] as String?,
        exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
        taxRate: (json['taxRate'] as num?)?.toDouble(),
        applicantId: json['applicantId'] as String?,
        purchaserId: json['purchaserId'] as String?,
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
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        sourceDocNo: json['sourceDocNo'] as String?,
        productionLinked: (json['productionLinked'] as bool?) ?? false,
        canEdit: (json['canEdit'] as bool?) ?? true,
        canDelete: (json['canDelete'] as bool?) ?? true,
        canReverse: (json['canReverse'] as bool?) ?? true,
        restrictionReason: json['restrictionReason'] as String?,
        items:
            (json['items'] as List?)
                ?.map(
                  (e) => PurchaseDocItem.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
      );
}

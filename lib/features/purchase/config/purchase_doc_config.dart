// 采购单据配置（4 单据差异声明，驱动 list/detail/edit 页）。
//
// 一套页面 ×4 配置，保证 UI 一致。差异：申请无供应商/币种；订货有采购员/交货日+链到申请；
// 收货有交货人/收货人+链到订货+审核入库；退货有收货人+链到收货&订货+审核出库。
import 'package:flutter/material.dart';

import '../../../shared/auth/permissions.dart';
import '../models/purchase_doc.dart';

class PurchaseDocConfig {
  const PurchaseDocConfig({
    required this.type,
    required this.label,
    required this.shortLabel,
    required this.icon,
    required this.listPerm,
    required this.editPerm,
    this.hasSupplier = false,
    this.hasCurrency = false,
    this.supplierRequired = false,
    this.hasApplicant = false,
    this.hasPurchaser = false,
    this.hasSender = false,
    this.hasReceiver = false,
    this.hasNeedDate = false,
    this.hasDeliverDate = false,
    // 明细链路（选上游明细回填）
    this.linkToRequestItem = false,
    this.linkToOrderItem = false,
    this.linkToReceiptItem = false,
    // 明细列开关
    this.showReceived = false,
    this.showReturned = false,
    // 管理卡片点进直达新增页（true=跳过列表，列表仍可从新增页"查看历史"进入）
    this.skipListOnCreate = false,
  });

  final PurchaseDocType type;
  final String label; // 采购申请单
  final String shortLabel; // 申请
  final IconData icon;
  final String listPerm;
  final String editPerm;

  // 主表头字段差异
  final bool hasSupplier;
  final bool hasCurrency;
  final bool supplierRequired;
  final bool hasApplicant;
  final bool hasPurchaser;
  final bool hasSender;
  final bool hasReceiver;
  final bool hasNeedDate;
  final bool hasDeliverDate;

  // 明细链路差异
  final bool linkToRequestItem; // 订货明细 → 申请明细
  final bool linkToOrderItem; // 收货/退货明细 → 订货明细
  final bool linkToReceiptItem; // 退货明细 → 收货明细

  // 明细列差异（回写量展示）
  final bool showReceived; // 订货/收货明细显示已收
  final bool showReturned; // 订货/收货/退货明细显示已退

  /// 管理卡片点进是否直达新增页（跳过列表）。
  final bool skipListOnCreate;

  /// 明细是否可链路引入（决定编辑页是否显示"从上游引入"按钮）。
  bool get hasUpstreamLink =>
      linkToRequestItem || linkToOrderItem || linkToReceiptItem;

  /// 单据号前缀（新建页预览占位用，与后端 DocNumberPrefix 对齐）。
  String get billNoPrefix => switch (type) {
        PurchaseDocType.request => 'CS',
        PurchaseDocType.order => 'CD',
        PurchaseDocType.receipt => 'CJ',
        PurchaseDocType.returnDoc => 'CT',
      };

  static const request = PurchaseDocConfig(
    type: PurchaseDocType.request,
    label: '采购申请单',
    shortLabel: '申请',
    icon: Icons.request_page_outlined,
    listPerm: Perm.purchaseRequestView,
    editPerm: Perm.purchaseRequestEdit,
    hasApplicant: true,
    hasNeedDate: true,
    skipListOnCreate: true,
  );

  static const order = PurchaseDocConfig(
    type: PurchaseDocType.order,
    label: '采购订货单',
    shortLabel: '订货',
    icon: Icons.shopping_cart_checkout_outlined,
    listPerm: Perm.purchaseOrderView,
    editPerm: Perm.purchaseOrderEdit,
    hasSupplier: true,
    hasCurrency: true,
    hasPurchaser: true,
    hasDeliverDate: true,
    linkToRequestItem: true,
    showReceived: true,
    showReturned: true,
    skipListOnCreate: true,
  );

  static const receipt = PurchaseDocConfig(
    type: PurchaseDocType.receipt,
    label: '采购收货单',
    shortLabel: '收货',
    icon: Icons.inbox_outlined,
    listPerm: Perm.purchaseReceiptView,
    editPerm: Perm.purchaseReceiptEdit,
    hasSupplier: true,
    hasCurrency: true,
    supplierRequired: true,
    hasSender: true,
    hasReceiver: true,
    linkToOrderItem: true,
    showReturned: true,
    skipListOnCreate: true,
  );

  static const returnDoc = PurchaseDocConfig(
    type: PurchaseDocType.returnDoc,
    label: '采购退货单',
    shortLabel: '退货',
    icon: Icons.outbound_outlined,
    listPerm: Perm.purchaseReturnView,
    editPerm: Perm.purchaseReturnEdit,
    hasSupplier: true,
    hasCurrency: true,
    supplierRequired: true,
    hasReceiver: true,
    linkToOrderItem: true,
    linkToReceiptItem: true,
    showReturned: true,
    skipListOnCreate: true,
  );

  static PurchaseDocConfig by(PurchaseDocType t) {
    switch (t) {
      case PurchaseDocType.request:
        return request;
      case PurchaseDocType.order:
        return order;
      case PurchaseDocType.receipt:
        return receipt;
      case PurchaseDocType.returnDoc:
        return returnDoc;
    }
  }
}

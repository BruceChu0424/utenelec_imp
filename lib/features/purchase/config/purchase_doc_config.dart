// 采购单据配置（4 单据差异声明，驱动 list/detail/edit 页）。
//
// 一套页面 ×4 配置，保证 UI 一致。差异：申请无供应商/币种；订货有采购员/交货日+链到申请；
// 收货有交货人/收货人+链到订货+审核入库；退货有收货人+链到收货&订货+审核出库。
import 'package:flutter/material.dart';

import '../../../shared/auth/document_permission_set.dart';
import '../models/purchase_doc.dart';

class PurchaseDocConfig {
  const PurchaseDocConfig({
    required this.type,
    required this.label,
    required this.shortLabel,
    required this.icon,
    required this.permissions,
    this.hasSupplier = false,
    this.hasCurrency = false,
    this.hasSettlement = false,
    this.settlementRequired = false,
    this.supplierRequired = false,
    this.warehouseRequired = false,
    this.hasWarehouse = true,
    this.hasDepartment = false,
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
    this.allowDirectCreate = true,
  });

  final PurchaseDocType type;
  final String label; // 采购申请单
  final String shortLabel; // 申请
  final IconData icon;
  final DocumentPermissionSet permissions;

  String get listPerm => permissions.view;
  String? get createPerm => permissions.create;
  String? get editPerm => permissions.edit;
  String? get deletePerm => permissions.delete;
  String? get approvePerm => permissions.approve;
  String? get reversePerm => permissions.reverse;

  // 主表头字段差异
  final bool hasSupplier;
  final bool hasCurrency;
  final bool hasSettlement;

  /// 结账方式是否必填（仅采购订货单；收货/退货沿用来源快照兼容）。
  final bool settlementRequired;
  final bool supplierRequired;

  /// 仓库是否必填（现仅收货/退货强制；订货/申请可空）。
  final bool warehouseRequired;

  /// 单据是否涉及仓库选择。订货单=false：订货只管向供应商下单，
  /// 入哪个仓库到收货登记时再定（业务规则：到货才产生入库仓库事实）。
  final bool hasWarehouse;
  final bool hasDepartment;
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
  final bool allowDirectCreate;

  /// 明细是否可链路引入（决定编辑页是否显示"从上游引入"按钮）。
  bool get hasUpstreamLink =>
      linkToRequestItem || linkToOrderItem || linkToReceiptItem;

  /// 列表刷新信号 key：列表页与其详情/编辑页共享，详情/编辑页操作成功后
  /// bump 此 key，列表页（即便被遮在栈下）收到即重拉，返回不再看到老数据。
  String get refreshKey => 'purchase:${type.name}';

  static const request = PurchaseDocConfig(
    type: PurchaseDocType.request,
    label: '计划下达的采购申请',
    shortLabel: '申请(只读)',
    icon: Icons.request_page_outlined,
    permissions: DocumentPermissionCatalog.purchaseRequest,
    hasApplicant: true,
    hasDepartment: true,
    hasNeedDate: true,
    allowDirectCreate: false,
  );

  static const order = PurchaseDocConfig(
    type: PurchaseDocType.order,
    label: '采购订货单',
    shortLabel: '订货',
    icon: Icons.shopping_cart_checkout_outlined,
    permissions: DocumentPermissionCatalog.purchaseOrder,
    hasSupplier: true,
    hasCurrency: true,
    hasSettlement: true,
    settlementRequired: true,
    supplierRequired: true,
    hasPurchaser: true,
    hasDeliverDate: true,
    // 订货不选仓库：入库仓库在收货登记（到货）时填写。
    hasWarehouse: false,
    linkToRequestItem: true,
    showReceived: true,
    showReturned: true,
    // 管理卡片点进直达新建（与销售/财务一致）；明细经「从上游引入」从计划申请拉取。
    skipListOnCreate: true,
  );

  static const receipt = PurchaseDocConfig(
    type: PurchaseDocType.receipt,
    label: '采购收货单',
    shortLabel: '收货',
    icon: Icons.inbox_outlined,
    permissions: DocumentPermissionCatalog.purchaseReceipt,
    hasSupplier: true,
    hasCurrency: true,
    hasSettlement: true,
    supplierRequired: true,
    warehouseRequired: true,
    hasPurchaser: true,
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
    permissions: DocumentPermissionCatalog.purchaseReturn,
    hasSupplier: true,
    hasCurrency: true,
    hasSettlement: true,
    supplierRequired: true,
    warehouseRequired: true,
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

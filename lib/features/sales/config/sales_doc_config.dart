// 销售单据配置（5 单据差异声明，驱动 list/detail/edit 页）。
//
// 一套页面 ×5 配置，保证 UI 一致。差异声明：
//  - quote（报价）：无仓库/币种/业务员；含有效期；明细无链路。
//  - order（订货）：含币种/业务员/合同信息/交货日；明细含已发/已退；可中止。
//  - shipment（出货）：含仓库/币种/业务员/发货人/应收标志；明细链到订货；审核出库+立应收。
//  - other_shipment（其它出货）：含仓库/币种/业务员/发货人/出库类型；不挂单/不立应收。
//  - return（退货）：含仓库/币种/业务员/应收标志；明细双挂（订货+出货）；审核入库+立红字应收。
//
import 'package:flutter/material.dart';

import '../../../shared/auth/permissions.dart';
import '../models/sales_doc.dart';

/// 销售权限点常量（与后端 V51__sales_documents.sql 的 seed 对齐）。
/// 保留模块别名以兼容既有调用，实际值统一来自全局 [Perm]。
class SalesPerm {
  static const quoteView = Perm.salesQuoteView;
  static const quoteEdit = Perm.salesQuoteEdit;
  static const orderView = Perm.salesOrderView;
  static const orderEdit = Perm.salesOrderEdit;
  static const shipmentView = Perm.salesShipmentView;
  static const shipmentEdit = Perm.salesShipmentEdit;
  static const otherShipmentView = Perm.salesOtherShipmentView;
  static const otherShipmentEdit = Perm.salesOtherShipmentEdit;
  static const returnView = Perm.salesReturnView;
  static const returnEdit = Perm.salesReturnEdit;
  static const reportView = Perm.salesReportView;
}

class SalesDocConfig {
  const SalesDocConfig({
    required this.type,
    required this.label,
    required this.shortLabel,
    required this.icon,
    required this.listPerm,
    required this.editPerm,
    // 主表头字段差异
    this.hasClient = true,
    this.clientRequired = false,
    this.hasWarehouse = false,
    this.hasCurrency = false,
    this.hasSeller = false,
    this.hasSender = false,
    this.hasValidUntil = false,
    this.hasDeliverDate = false,
    this.hasContractInfo = false, // 合同号/联系电话/签约地/收货地址/订金（order）
    this.hasShipInfo = false, // 收货地址/联系电话/件数（shipment/other_shipment）
    this.hasOutType = false, // 出库类型（other_shipment）
    // 状态位/标志位（详情显示）
    this.showStopped = false, // 订单中止位
    this.showArPosted = false, // 应收已立帐（shipment/return）
    // 明细链路（选上游明细回填）
    this.linkToOrderItem = false, // 出货/退货 → 订货明细
    this.linkToOutItem = false, // 退货 → 出货明细
    // 明细列差异（详情展示）
    this.showShipped = false, // 订货明细显示已发
    this.showReturned = false, // 讂货/出货明细显示已退
    // 管理卡片点进直达新增页（true=跳过列表）
    this.skipListOnCreate = false,
  });

  final SalesDocType type;
  final String label; // 销售报价单
  final String shortLabel; // 报价
  final IconData icon;
  final String listPerm;
  final String editPerm;

  // 主表头字段差异
  final bool hasClient;
  final bool clientRequired;
  final bool hasWarehouse;
  final bool hasCurrency;
  final bool hasSeller;
  final bool hasSender;
  final bool hasValidUntil;
  final bool hasDeliverDate;
  final bool hasContractInfo;
  final bool hasShipInfo;
  final bool hasOutType;

  // 状态位显示差异
  final bool showStopped;
  final bool showArPosted;

  // 明细链路差异
  final bool linkToOrderItem;
  final bool linkToOutItem;

  // 明细列差异（详情展示）
  final bool showShipped;
  final bool showReturned;

  /// 管理卡片点进是否直达新增页（跳过列表）。
  final bool skipListOnCreate;

  /// 明细是否可链路引入（决定编辑页是否显示"从上游引入"按钮）。
  bool get hasUpstreamLink => linkToOrderItem || linkToOutItem;

  /// 单据号前缀（新建页预览占位用，与后端 DocNumberPrefix 对齐）。
  String get billNoPrefix => switch (type) {
    SalesDocType.quote => 'XB',
    SalesDocType.order => 'XD',
    SalesDocType.shipment => 'XC',
    SalesDocType.otherShipment => 'OC',
    SalesDocType.returnDoc => 'XT',
  };

  static const quote = SalesDocConfig(
    type: SalesDocType.quote,
    label: '销售报价单',
    shortLabel: '报价',
    icon: Icons.request_quote_outlined,
    listPerm: SalesPerm.quoteView,
    editPerm: SalesPerm.quoteEdit,
    clientRequired: true,
    hasValidUntil: true,
    skipListOnCreate: true,
  );

  static const order = SalesDocConfig(
    type: SalesDocType.order,
    label: '销售订货单',
    shortLabel: '订货',
    icon: Icons.shopping_cart_checkout_outlined,
    listPerm: SalesPerm.orderView,
    editPerm: SalesPerm.orderEdit,
    clientRequired: true,
    hasCurrency: true,
    hasSeller: true,
    hasDeliverDate: true,
    hasContractInfo: true,
    showStopped: true,
    showShipped: true,
    showReturned: true,
    skipListOnCreate: true,
  );

  static const shipment = SalesDocConfig(
    type: SalesDocType.shipment,
    label: '销售出货单',
    shortLabel: '出货',
    icon: Icons.outbox_outlined,
    listPerm: SalesPerm.shipmentView,
    editPerm: SalesPerm.shipmentEdit,
    clientRequired: true,
    hasWarehouse: true,
    hasCurrency: true,
    hasSeller: true,
    hasSender: true,
    hasShipInfo: true,
    showArPosted: true,
    linkToOrderItem: true,
    showReturned: true,
    skipListOnCreate: true,
  );

  static const otherShipment = SalesDocConfig(
    type: SalesDocType.otherShipment,
    label: '其它出货单',
    shortLabel: '其它出货',
    icon: Icons.move_up_outlined,
    listPerm: SalesPerm.otherShipmentView,
    editPerm: SalesPerm.otherShipmentEdit,
    hasWarehouse: true,
    hasCurrency: true,
    hasSeller: true,
    hasSender: true,
    hasShipInfo: true,
    hasOutType: true,
    skipListOnCreate: true,
  );

  static const returnDoc = SalesDocConfig(
    type: SalesDocType.returnDoc,
    label: '销售退货单',
    shortLabel: '退货',
    icon: Icons.outbound_outlined,
    listPerm: SalesPerm.returnView,
    editPerm: SalesPerm.returnEdit,
    clientRequired: true,
    hasWarehouse: true,
    hasCurrency: true,
    hasSeller: true,
    showArPosted: true,
    linkToOrderItem: true,
    linkToOutItem: true,
    skipListOnCreate: true,
  );

  static SalesDocConfig by(SalesDocType t) {
    switch (t) {
      case SalesDocType.quote:
        return quote;
      case SalesDocType.order:
        return order;
      case SalesDocType.shipment:
        return shipment;
      case SalesDocType.otherShipment:
        return otherShipment;
      case SalesDocType.returnDoc:
        return returnDoc;
    }
  }
}

/// 销售模块路由路径拼接（route_names.dart 由上层统一加 sales_* 常量；
/// 在那之前本文件用字符串自洽，避免改共享文件）。
class SalesRoutePath {
  static const hub = '/sales';
  static const report = '/sales/report';
  static const reportDetail = '/sales/report/detail';
  static const reportSummary = '/sales/report/summary';

  /// [seg] = quotes | orders | shipments | other-shipments | returns
  static String list(String seg) => '/sales/$seg';
  static String docNew(String seg) => '/sales/$seg/new';
  static String docDetail(String seg, String id) => '/sales/$seg/$id';
  static String docEdit(String seg, String id) => '/sales/$seg/$id/edit';
}

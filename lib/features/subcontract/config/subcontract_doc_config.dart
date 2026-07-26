// 委外单据配置（8 单据差异声明，驱动 list/detail/edit 页）。
//
// 一套页面 ×8 配置，保证 UI 一致。委外 8 单据差异较大：
//  - 询价/申请：无供应商/币种/人员，仅货品+数量+单价；老库 0 行（结构建立），enabled=false 灰显。
//  - 订货：供应商+币种+采购员+交货日；明细链到申请；带 BOM 成本子表（只读，本期不展开）。
//  - 进仓(收回成品)：供应商+币种+交货人+lastDate；明细链到订货；审核正向入库+立应付(ap_posted)。
//  - 退货(成品退)：供应商+仓库(必)+币种+lastDate；明细链到进仓&订货；审核出库+反向立应付(ap_posted)。
//  - 发料(材料出仓)：仓库(必)+经办人+交货日；无币种/单价(材料按成本)；明细链到订货；审核出库。
//  - 材料退：仓库(必)+经办人+bStyle；无币种/单价；明细链到发料&订货；审核入库。
//  - 损耗：仓库(必)+经办人+总重；无币种/单价；明细含 ending/standard/waste_rate/cause；链到发料；审核出库+回写损耗。
//
// 路由路径（路由表在共享 app_router 注册；此处仅约定字符串，不依赖 route_names.dart）：
//   /subcontract                          hub
//   /subcontract/{pathSegment}            列表
//   /subcontract/{pathSegment}/new        新建
//   /subcontract/{pathSegment}/{id}       详情
//   /subcontract/{pathSegment}/{id}/edit  编辑
//   /subcontract/report                   报表
import 'package:flutter/material.dart';

import '../models/subcontract_doc.dart';

class SubcontractDocConfig {
  const SubcontractDocConfig({
    required this.type,
    required this.label,
    required this.shortLabel,
    required this.icon,
    required this.listPerm,
    required this.editPerm,
    this.enabled = true,
    // 主表头
    this.hasSupplier = false,
    this.hasCurrency = false,
    this.supplierRequired = false,
    this.warehouseRequired = false,
    this.hasPurchaser = false,
    this.hasSender = false,
    this.hasWorker = false,
    this.hasDeliverDate = false,
    this.hasLastDate = false,
    this.hasTaxRate = false,
    this.hasBStyle = false,
    this.hasTotalWeight = false,
    this.hasApPosted = false,
    this.hasSettlement = false, // 结帐方式（进仓/退货；材料出/退无）
    // 明细列
    this.itemHasPrice = true,
    this.itemHasWeight = false,
    this.itemHasWasteFields = false,
    this.itemHasParent = false,
    this.itemHasGirth = false, // 围数（进仓/退货/材料退明细）
    this.itemHasStep = false, // 工序（进仓/退货明细；B_Step 未迁→暂空白）
    this.itemHasBoxQty = false, // 胶箱数量（材料出明细；老库无源→留空）
    // 明细链路
    this.linkToApplicationItem = false,
    this.linkToOrderItem = false,
    this.linkToReceiptItem = false,
    this.linkToMaterialIssueItem = false,
    // 回写量展示列
    this.showReceived = false,
    this.showReturned = false,
    this.showWasted = false,
    // 审核效果文案（确认对话框用）
    this.approveEffect = '',
  });

  final SubcontractDocType type;
  final String label; // 委外进仓单
  final String shortLabel; // 进仓
  final IconData icon;
  final String listPerm;
  final String editPerm;
  final bool enabled; // inquiry/application 老库 0 行，灰显

  // 主表头字段差异
  final bool hasSupplier; // 委外商（=suppliers）
  final bool hasCurrency; // 币种+汇率
  final bool supplierRequired;
  final bool warehouseRequired;
  final bool hasPurchaser; // 订货
  final bool hasSender; // 进仓（交货人）
  final bool hasWorker; // 发料/材料退/损耗（经办人）
  final bool hasDeliverDate; // 订货/发料
  final bool hasLastDate; // 进仓/退货
  final bool hasTaxRate; // 订货/进仓/退货
  final bool hasBStyle; // 材料退
  final bool hasTotalWeight; // 损耗
  final bool hasApPosted; // 进仓/退货（立应付标志）
  final bool hasSettlement; // 结帐方式（进仓/退货）

  // 明细列差异
  final bool itemHasPrice; // false=发料/材料退/损耗（材料按成本，无单价）
  final bool itemHasWeight;
  final bool itemHasWasteFields; // 损耗：ending/standard/waste_rate/cause
  final bool itemHasParent; // 发料/材料退：parent_goods/color（BOM 父件，可选）
  final bool itemHasGirth; // 围数（进仓/退货/材料退）
  final bool itemHasStep; // 工序（进仓/退货）
  final bool itemHasBoxQty; // 胶箱数量（材料出）

  // 明细链路差异（编辑页"从上游引入"按钮 + 回写 *ItemId）
  final bool linkToApplicationItem; // 订货 → 申请
  final bool linkToOrderItem; // 进仓/发料/材料退 → 订货
  final bool linkToReceiptItem; // 退货 → 进仓
  final bool linkToMaterialIssueItem; // 材料退/损耗 → 发料

  // 明细回写量展示列
  final bool showReceived; // 订货明细显示已收
  final bool showReturned; // 发料/材料退明细显示已退
  final bool showWasted; // 发料明细显示已损耗

  /// 审核联动效果说明（确认对话框 + 详情页提示）。
  final String approveEffect;

  /// 明细是否可链路引入。
  bool get hasUpstreamLink =>
      linkToApplicationItem ||
      linkToOrderItem ||
      linkToReceiptItem ||
      linkToMaterialIssueItem;

  /// 列表是否带金额合计列（无单价的三类没有金额）。
  bool get hasAmount => itemHasPrice;

  /// 路由路径段（与后端 @RequestMapping 对齐）。
  String get pathSegment => type.pathSegment;

  // ============ 8 单据配置 ============

  /// 委外询价单（老库 0 行，结构建立；灰显入口）。
  static const inquiry = SubcontractDocConfig(
    type: SubcontractDocType.inquiry,
    label: '委外询价单',
    shortLabel: '询价',
    icon: Icons.help_outline_rounded,
    listPerm: 'subcontract_inquiry:view',
    editPerm: 'subcontract_inquiry:edit',
    enabled: false,
    hasSupplier: true,
    itemHasWeight: true,
    approveEffect: '审核仅变更状态（询价为链路起点，无库存/ArAp 联动）。',
  );

  /// 委外申请单（老库 0 行，结构建立；灰显入口）。
  static const application = SubcontractDocConfig(
    type: SubcontractDocType.application,
    label: '委外申请单',
    shortLabel: '申请',
    icon: Icons.assignment_outlined,
    listPerm: 'subcontract_application:view',
    editPerm: 'subcontract_application:edit',
    enabled: false,
    hasSupplier: true,
    itemHasWeight: true,
    approveEffect: '审核仅变更状态（申请无库存/ArAp 联动）。',
  );

  /// 委外订货单（2 行；链到申请；BOM 成本子表只读本期不展开）。
  static const order = SubcontractDocConfig(
    type: SubcontractDocType.order,
    label: '委外订货单',
    shortLabel: '订货',
    icon: Icons.shopping_cart_checkout_outlined,
    listPerm: 'subcontract_order:view',
    editPerm: 'subcontract_order:edit',
    hasSupplier: true,
    hasCurrency: true,
    hasTaxRate: true,
    hasPurchaser: true,
    hasDeliverDate: true,
    itemHasWeight: true,
    linkToApplicationItem: true,
    showReceived: true,
    approveEffect: '审核将回写申请明细已订量（无库存/ArAp 联动）。',
  );

  /// 委外进仓单（收回成品；10732 行；链到订货；审核入库+立应付）。
  static const receipt = SubcontractDocConfig(
    type: SubcontractDocType.receipt,
    label: '委外进仓单',
    shortLabel: '进仓',
    icon: Icons.inbox_outlined,
    listPerm: 'subcontract_receipt:view',
    editPerm: 'subcontract_receipt:edit',
    hasSupplier: true,
    hasCurrency: true,
    hasTaxRate: true,
    hasSender: true,
    hasLastDate: true,
    hasApPosted: true,
    hasSettlement: true,
    itemHasWeight: true,
    itemHasGirth: true,
    itemHasStep: true,
    linkToOrderItem: true,
    approveEffect: '审核将正向入库（成品）+ 回写订货已收 + 立应付。',
  );

  /// 委外发料单（材料出仓；10627 行；链到订货；审核出库）。
  static const materialIssue = SubcontractDocConfig(
    type: SubcontractDocType.materialIssue,
    label: '委外发料单',
    shortLabel: '发料',
    icon: Icons.outbound_outlined,
    listPerm: 'subcontract_material_issue:view',
    editPerm: 'subcontract_material_issue:edit',
    hasSupplier: true,
    warehouseRequired: true,
    hasWorker: true,
    hasDeliverDate: true,
    itemHasPrice: false,
    itemHasWeight: true,
    itemHasParent: true,
    itemHasBoxQty: true,
    linkToOrderItem: true,
    showReturned: true,
    showWasted: true,
    approveEffect: '审核将出库（材料）+ 回写订货已发料。',
  );

  /// 委外退货单（成品退；442 行；链到进仓&订货；审核出库+反向立应付）。
  static const returnDoc = SubcontractDocConfig(
    type: SubcontractDocType.returnDoc,
    label: '委外退货单',
    shortLabel: '退货',
    icon: Icons.undo_outlined,
    listPerm: 'subcontract_return:view',
    editPerm: 'subcontract_return:edit',
    hasSupplier: true,
    warehouseRequired: true,
    hasCurrency: true,
    hasTaxRate: true,
    hasLastDate: true,
    hasApPosted: true,
    hasSettlement: true,
    itemHasWeight: true,
    itemHasGirth: true,
    itemHasStep: true,
    linkToReceiptItem: true,
    linkToOrderItem: true,
    approveEffect: '审核将出库（成品退）+ 反向立应付。',
  );

  /// 委外材料退货单（65 行；链到发料&订货；审核入库）。
  static const materialReturn = SubcontractDocConfig(
    type: SubcontractDocType.materialReturn,
    label: '委外材料退货单',
    shortLabel: '材料退',
    icon: Icons.assignment_return_outlined,
    listPerm: 'subcontract_material_return:view',
    editPerm: 'subcontract_material_return:edit',
    hasSupplier: true,
    warehouseRequired: true,
    hasWorker: true,
    hasBStyle: true,
    itemHasPrice: false,
    itemHasWeight: true,
    itemHasParent: true,
    itemHasGirth: true,
    linkToMaterialIssueItem: true,
    linkToOrderItem: true,
    showReturned: true,
    approveEffect: '审核将入库（材料退）+ 回写发料已退 / 订货已材料退。',
  );

  /// 委外材料损耗单（3 行；链到发料；审核出库+回写损耗）。
  static const waste = SubcontractDocConfig(
    type: SubcontractDocType.waste,
    label: '委外材料损耗单',
    shortLabel: '损耗',
    icon: Icons.delete_sweep_outlined,
    listPerm: 'subcontract_waste:view',
    editPerm: 'subcontract_waste:edit',
    hasSupplier: true,
    warehouseRequired: true,
    hasWorker: true,
    hasTotalWeight: true,
    itemHasPrice: false,
    itemHasWeight: true,
    itemHasWasteFields: true,
    linkToMaterialIssueItem: true,
    approveEffect: '审核将出库 + 回写发料明细已损耗。',
  );

  static SubcontractDocConfig by(SubcontractDocType t) {
    switch (t) {
      case SubcontractDocType.inquiry:
        return inquiry;
      case SubcontractDocType.application:
        return application;
      case SubcontractDocType.order:
        return order;
      case SubcontractDocType.receipt:
        return receipt;
      case SubcontractDocType.materialIssue:
        return materialIssue;
      case SubcontractDocType.returnDoc:
        return returnDoc;
      case SubcontractDocType.materialReturn:
        return materialReturn;
      case SubcontractDocType.waste:
        return waste;
    }
  }

  /// 按路径段反查（路由参数 pathSegment → config）。
  static SubcontractDocConfig byPath(String seg) =>
      by(SubcontractDocType.byPath(seg));
}

/// 路由路径拼接（不依赖共享 route_names.dart；由调用方在 app_router 注册）。
abstract final class SubcontractRoute {
  static const hub = '/subcontract';
  static const report = '/subcontract/report';

  static String list(String pathSegment) => '/subcontract/$pathSegment';
  static String newList(String pathSegment) => '/subcontract/$pathSegment/new';
  static String detail(String pathSegment, String id) =>
      '/subcontract/$pathSegment/$id';
  static String edit(String pathSegment, String id) =>
      '/subcontract/$pathSegment/$id/edit';

  /// 9 张委外报表之一（kind = SubcontractReportKind.name）。
  static String reportTable(String kind) => '/subcontract/report/$kind';
}

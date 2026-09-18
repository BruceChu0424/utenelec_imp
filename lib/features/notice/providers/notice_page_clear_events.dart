// 通知页面级自动已读映射（2026-09-18 根治方案）。
//
// 背景：链路通知的 action_route 指向「单据详情页」（如 /sales/orders/{id}），
// 而接收人实际看任务的地方是「队列/工作台/列表页」（如 /sales/progress、
// /warehouse/tasks/draw）。后端 read-by-route 只做 action_route 精确匹配，
// 进队列页永远清不掉这些通知。
//
// 本表是「页面 ↔ 事件」的权威映射：NoticeRouteReadBridge 在用户落定到某个
// 页面（或其子路径）时，按该页对应的事件集调 read-by-source 批量置已读——
// 与 ChainNoticeService 各 notify* 方法写入的 source_event 常量一一对应。
// 新增业务通知时：若 action_route 是详情页，则把事件登记到接收人的自然
// 工作台路由下；若 action_route 已是列表页则无需登记（精确匹配已覆盖）。
//
// 语义边界（与既有产品口径一致）：
// - 只置已读，不代办结/待办完成（task_completed_at / resolved_at 独立）；
// - 审核弹卡的重弹由 popup_acknowledged / snooze / 办结撤回控制，不受已读影响；
// - 事件按当前登录用户清理（audience_user_id = 本人），不影响他人。

/// 路由（path，不含 query）→ 该页承载的业务事件（source_event）。
///
/// 命中规则见 NoticeRouteReadBridge：落点等于 key，或落点以 `key/` 开头
/// （详情子页视为同一队列的更深视图，如 /finance/sales-order-confirmations/{id}）。
const Map<String, List<String>> noticePageClearEvents = {
  // —— 运营任务工作台（采购/委外/仓库看任务的实际入口页，不是单据列表）——
  // 采购任务台：申请待分解/等待财务审核/财务已通过/已完成 全生命周期卡。
  '/operations/workbench/purchase': [
    'PREPLAN_SUPPLY_ACTION_CREATED',
    'PREPLAN_SUPPLY_DOCUMENT_CREATED',
    'PROCUREMENT_FINANCE_APPROVED',
    'PROCUREMENT_FINANCE_REJECTED',
  ],
  // 委外任务台（分解订货页）：申请待分解→订货→财务 全链路。
  '/operations/workbench/subcontract': [
    'PREPLAN_SUPPLY_ACTION_CREATED',
    'PREPLAN_SUPPLY_DOCUMENT_CREATED',
    'SUBCONTRACT_MAKE_NOTIFIED',
    'SUBCONTRACT_ORDER_PREPARATION_ARRIVED',
    'PROCUREMENT_FINANCE_APPROVED',
    'PROCUREMENT_FINANCE_REJECTED',
  ],
  // 仓库履约任务台：领料/备料域（一行=一张 DRAW 领料单）。
  '/operations/workbench/warehouse': ['PRODUCTION_DRAW_PENDING'],
  // —— 销售：订单进度工作台（排产/报工/入库/完工可发货/取消/交期/预留/驳回）——
  '/sales/progress': [
    'PRODUCTION_PLAN_SCHEDULED',
    'PRODUCTION_REPORTED',
    'PRODUCTION_FINISHED_INBOUND',
    'PRODUCTION_REMAKE_CREATED',
    'PRODUCTION_SEGMENT_DISPATCHED',
    'PRODUCTION_SEGMENT_STARTED',
    'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP',
    'SALES_ORDER_CANCELED',
    'SALES_ORDER_FINANCE_REJECTED',
    'SALES_DELIVERY_DUE',
    'SALES_RESERVATION_HOLD_OVERDUE',
    'SALES_RESERVATION_YIELDED',
  ],
  // —— 销售：出货单列表（发货回执 / 仓库驳回 / 财务退回修改）——
  '/sales/shipments': [
    'SALES_SHIPMENT_APPROVED',
    'SALES_SHIPMENT_REJECTED',
    'SALES_SHIPMENT_FINANCE_REJECTED',
  ],
  '/sales/customer-shipments': [
    'SALES_SHIPMENT_APPROVED',
    'DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED',
  ],
  // —— 财务：订单确认 / 改量复核 / 出货财审 / 采购委外审批队列 ——
  '/finance/sales-order-confirmations': ['SALES_ORDER_PENDING_FINANCE_CONFIRM'],
  '/finance/sales-order-changes': ['SALES_ORDER_PENDING_FINANCE_CONFIRM'],
  '/finance/sales-shipment-audits': ['SALES_SHIPMENT_PENDING_FINANCE_AUDIT'],
  '/finance/procurement-approvals': [
    'PROCUREMENT_FINANCE_SUBMITTED',
    'PROCUREMENT_FINANCE_CHANGE_SUBMITTED',
  ],
  // —— 计划/生产：物料分析工作台（新订单待分析 / 交货预警计划侧 / 委外前置自制）——
  '/production/material-analysis': [
    'SALES_ORDER_APPROVED',
    'SALES_DELIVERY_DUE',
    'SUBCONTRACT_PREPARATION_REQUIRED',
    'SUBCONTRACT_PREPARE_SHORTAGE',
  ],
  // 物料分析历史与分析摘要详情（/production/material-analyses/{id}/summary）
  '/production/material-analyses': [
    'SUBCONTRACT_MAKE_TASK_CREATED',
    'SUBCONTRACT_ORDER_PREPARATION_DISPATCHED',
    'SUBCONTRACT_OUTBOUND_COMPLETED',
    'PROCUREMENT_IQC_RESOLVED',
  ],
  // 计划单列表（缺料提醒的 buyer/planner 副本指向 /production/plans/{id} 详情）
  '/production/plans': ['PRODUCTION_PLAN_SCHEDULED'],
  // 报工单列表（成品入库拒收/红冲指向 /production/daily-reports/{id} 详情）
  '/production/daily-reports': [
    'PRODUCTION_FINISHED_INBOUND_REJECTED',
    'PRODUCTION_FINISHED_INBOUND_REVERSED',
  ],
  // —— 采购：申请列表（新采购需求指向 /purchase/requests/{id} 详情）——
  '/purchase/requests': [
    'PREPLAN_SUPPLY_ACTION_CREATED',
    'PREPLAN_SUPPLY_DOCUMENT_CREATED',
  ],
  // 订货单列表（财务通过/驳回回执指向 /purchase/orders/{id} 详情）
  '/purchase/orders': [
    'PROCUREMENT_FINANCE_APPROVED',
    'PROCUREMENT_FINANCE_REJECTED',
  ],
  // —— 委外：申请列表（新委外需求 / 前置自制已入库通知指向详情页）——
  '/subcontract/applications': [
    'PREPLAN_SUPPLY_ACTION_CREATED',
    'PREPLAN_SUPPLY_DOCUMENT_CREATED',
    'SUBCONTRACT_MAKE_NOTIFIED',
  ],
  // 订货单列表（委外全链路状态 + IQC 结案 + 财务回执的详情路由落点）
  '/subcontract/orders': [
    'SUBCONTRACT_PREPARATION_REQUIRED',
    'SUBCONTRACT_PREPARE_SHORTAGE',
    'SUBCONTRACT_ORDER_PREPARATION_ARRIVED',
    'SUBCONTRACT_OUTBOUND_READY',
    'SUBCONTRACT_OUTBOUND_COMPLETED',
    'SUBCONTRACT_OUTBOUND_REVERSED',
    'SUBCONTRACT_RETURN_DUE',
    'PROCUREMENT_IQC_RESOLVED',
    'PROCUREMENT_FINANCE_APPROVED',
    'PROCUREMENT_FINANCE_REJECTED',
  ],
  // —— 仓库：领料 / 拣货任务队列（通知详情路由在 /sales、/warehouse/DRAW 下）——
  '/warehouse/tasks/draw': ['PRODUCTION_DRAW_PENDING'],
  '/warehouse/tasks/outbound': [
    'SALES_SHIPMENT_PENDING_PICK',
    'SALES_SHIPMENT_FINANCE_RELEASE_REVOKED',
  ],
  // 成品入库单列表（待审核通知指向 /warehouse/FINISHED_IN/{id} 详情）
  '/warehouse/FINISHED_IN': ['PRODUCTION_FINISHED_INBOUND_PENDING'],
  // 品质结论页（放行待入库 / 检验结案通知指向 {type}/{id} 详情子页）
  '/warehouse/quality-results': [
    'PROCUREMENT_IQC_STOCK_IN_PENDING',
    'PROCUREMENT_IQC_RESOLVED',
  ],
  // 待检明细列表（先入库后检通知指向 /warehouse/inspections/{type}/{id} 详情）
  '/warehouse/inspections': ['PROCUREMENT_IQC_PRE_STOCKED'],
  // 委外出仓列表（待执行通知指向 /warehouse/subcontract-outbound/{planId} 详情）
  '/warehouse/subcontract-outbound': ['SUBCONTRACT_OUTBOUND_READY'],
  // —— 采购/品质：IQC 拒收处置列表（通知指向 /procurement/iqc-rejections/{id} 详情）——
  '/procurement/iqc-rejections': [
    'PROCUREMENT_IQC_REJECTION_OPENED',
    'PROCUREMENT_IQC_REJECTION_RETURNED',
    'PROCUREMENT_IQC_CREDIT_CONFIRMED',
    'PROCUREMENT_IQC_REJECTION_NO_CREDIT',
    'PROCUREMENT_IQC_REJECTION_REVERSED',
    'PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION',
  ],
};

/// 落点路由（path）命中的清理事件集：等于某 key，或位于其子路径下。
/// 例：/finance/sales-order-confirmations/{orderId} 命中确认队列事件。
List<String> noticeClearEventsForLocation(String location) {
  final exact = noticePageClearEvents[location];
  if (exact != null) return exact;
  for (final entry in noticePageClearEvents.entries) {
    if (location.startsWith('${entry.key}/')) return entry.value;
  }
  return const [];
}

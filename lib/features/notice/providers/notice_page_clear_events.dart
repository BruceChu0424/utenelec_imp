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
// 新增业务通知时：若 action_route 是详情页或带查询参数的页面（?caseId= 等，
// read-by-route 精确匹配命中不了），把事件登记到接收人的自然工作台路由下；
// 若 action_route 已是不带参数的列表/队列页则无需登记（精确匹配已覆盖）。
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
  // 委外任务中心：申请待处理(物料齐套可下单卡)→订货→财务→领料(可领料卡、发料回执)
  // 全链路；领料页 /operations/workbench/subcontract/draw-request 作为子路径同样命中。
  '/operations/workbench/subcontract': [
    'PREPLAN_SUPPLY_ACTION_CREATED',
    'PREPLAN_SUPPLY_DOCUMENT_CREATED',
    'PROCUREMENT_FINANCE_APPROVED',
    'PROCUREMENT_FINANCE_REJECTED',
    // ADR-156 可下单卡(action_route 带 ?segment=pending&keyword=，精确匹配不到)。
    'SUBCONTRACT_ORDER_KIT_READY',
    'SUBCONTRACT_DRAW_AVAILABLE',
    'SUBCONTRACT_DRAW_RETURNED',
    'SUBCONTRACT_OUTBOUND_COMPLETED',
    'SUBCONTRACT_OUTBOUND_REVERSED',
  ],
  // 仓库履约任务台：领料/备料域（一行=一张 DRAW 领料单）。
  '/operations/workbench/warehouse': ['PRODUCTION_DRAW_PENDING'],
  // —— 销售：订单进度工作台（排产/报工/入库/完工可发货/取消/交期/预留/驳回/确认回执）——
  '/sales/progress': [
    'PRODUCTION_PLAN_SCHEDULED',
    'PRODUCTION_REPORTED',
    'PRODUCTION_FINISHED_INBOUND',
    'PRODUCTION_REMAKE_CREATED',
    'PRODUCTION_SEGMENT_DISPATCHED',
    'PRODUCTION_SEGMENT_STARTED',
    'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP',
    'SALES_ORDER_CANCELED',
    // 财务确认结果回执（2026-10-09 后端补发；action_route 是 /sales/orders/{id}
    // 详情页，销售在订单进度页看结果，进页即清）。
    'SALES_ORDER_FINANCE_CONFIRMED',
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
  // ADR-134 报价核价队列(含 /finance/quote-review/{id} 详情子页)。
  '/finance/quote-review': ['SALES_QUOTE_PENDING_FINANCE_REVIEW'],
  '/finance/procurement-approvals': [
    'PROCUREMENT_FINANCE_SUBMITTED',
    'PROCUREMENT_FINANCE_CHANGE_SUBMITTED',
  ],
  // —— 计划/生产：物料分析工作台（新订单待分析 / 交货预警计划侧）——
  // 物料分析历史与分析摘要详情（/production/material-analyses/{id}/summary）
  '/production/material-analyses': ['PROCUREMENT_IQC_RESOLVED'],
  // 报工单列表（成品入库拒收/红冲指向 /production/daily-reports/{id} 详情）
  '/production/overproduction-rate-requests': [
    'PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED',
    'PRODUCTION_OVERPRODUCTION_RATE_APPROVED',
    'PRODUCTION_OVERPRODUCTION_RATE_RETURNED',
  ],
  '/production/material-increment-requests': [
    'PRODUCTION_MATERIAL_INCREMENT_SUBMITTED',
    'PRODUCTION_MATERIAL_INCREMENT_APPROVED',
    'PRODUCTION_MATERIAL_INCREMENT_RETURNED',
    'PRODUCTION_MATERIAL_INCREMENT_CANCELLED',
  ],
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
  // —— 委外：申请列表（新委外需求通知指向详情页）——
  '/subcontract/applications': [
    'PREPLAN_SUPPLY_ACTION_CREATED',
    'PREPLAN_SUPPLY_DOCUMENT_CREATED',
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
  // 委外出仓工作台(委外领料待发料 / 领料已撤回通知都指向
  // /warehouse/subcontract-outbound/{issueId} 拣货页，一张领料出仓草稿一条)
  '/warehouse/subcontract-outbound': [
    'SUBCONTRACT_OUTBOUND_READY',
    'SUBCONTRACT_DRAW_WITHDRAWN',
  ],
  // —— 采购/品质：IQC 拒收处置列表（通知指向 /procurement/iqc-rejections/{id} 详情）——
  '/procurement/iqc-rejections': [
    'PROCUREMENT_IQC_REJECTION_OPENED',
    'PROCUREMENT_IQC_REJECTION_RETURNED',
    'PROCUREMENT_IQC_CREDIT_CONFIRMED',
    'PROCUREMENT_IQC_REJECTION_NO_CREDIT',
    'PROCUREMENT_IQC_REJECTION_REVERSED',
    'PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION',
  ],
  // —— 报价核价结果回执（发给负责销售；action_route 是 /sales/quotes/{id} 详情，
  // 销售在报价列表处理核价结果，2026-10-09 补齐"操作了还挂着未读"缺口）——
  '/sales/quotes': [
    'SALES_QUOTE_FINANCE_RETURNED',
    'SALES_QUOTE_FINANCE_CONFIRMED',
    'SALES_QUOTE_FINANCE_REOPENED',
  ],
  // —— 委外短交判定页（action_route 带 ?caseId= 查询参数，read-by-route
  // 精确匹配命中不了；判定/到齐/作废虽会办结撤卡，但打开判定页即应视为已读）——
  '/subcontract/short-deliveries': [
    'SUBCONTRACT_SHORT_DELIVERY_DETECTED',
    'SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE',
  ],
  // —— BOM 完善回执 / 研发任务完成回执（等 BOM 的人散布在计划/委外；
  // 落点是 ?analysisId= 查询路由或 /production/plans/{id}、/subcontract/orders/{id}
  // 详情页，靠这些自然工作台页清理）——
  '/production/material-analysis': [
    'SALES_ORDER_APPROVED',
    'SALES_DELIVERY_DUE',
    // ADR-117 车间催计划下单(卡片本身在计划下够单后由服务端撤回)。
    'PRODUCTION_PLANNING_URGED',
    'GOODS_BOM_UPDATED',
    'RD_TASK_RESOLVED',
  ],
  '/production/plans': [
    'PRODUCTION_PLAN_SCHEDULED',
    'GOODS_BOM_UPDATED',
    'RD_TASK_RESOLVED',
  ],
  '/subcontract/orders': [
    'SUBCONTRACT_OUTBOUND_COMPLETED',
    'SUBCONTRACT_OUTBOUND_REVERSED',
    'SUBCONTRACT_RETURN_DUE',
    'PROCUREMENT_IQC_RESOLVED',
    'PROCUREMENT_FINANCE_APPROVED',
    'PROCUREMENT_FINANCE_REJECTED',
    'GOODS_BOM_UPDATED',
    'RD_TASK_RESOLVED',
  ],
  // —— 盘点结果回执（发给提交人；action_route 带 ?requestId= 查询参数）——
  '/stock/count-requests': [
    'STOCK_COUNT_APPROVED',
    'STOCK_COUNT_REJECTED',
    'STOCK_COUNT_CANCELLED',
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

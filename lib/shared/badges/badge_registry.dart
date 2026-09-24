// 徽章注册表 —— 全站红(待办)/黄(进行中)徽章的「入口 → 显示位置」映射(ADR-108)。
//
// ## 口径在服务端, 这里只剩映射
//
// 2026-09-23 起全部徽章数字由 GET /api/workbench/badges 一次带回(见
// [badgeSummaryProvider]): 服务端按当前身份、复用各入口原计数端点的资格判定与查询,
// 在一个只读事务里算出 入口 → 红黄两数、容器 → 入口之和、总数 → 容器之和。
// 此前这里是两张注册表 + 约 40 个各自 60s 轮询的计数 provider, 在前端求和;
// 两套求和、两份口径, 回一次工作台打出约 40 个请求。现在:
//   · [BadgeEntry] 与服务端 WorkbenchBadgeCatalog 逐字一致(badge_registry_contract_test
//     读服务端源码核对), 只声明「这个入口画在哪个容器里」;
//   · 页面/卡片按入口或容器取数, **不做加法**(工作台自定义分组的卡片合计除外——
//     那是用户自己摆的卡, 不是业务口径);
//   · 页内分段要的细分数(各类草稿、品质结果分来源、车间任务分段等)走 [BadgeFact]。
//
// ## 两条硬口径(docs/00-项目准则/14-徽章与计数口径.md, 由服务端目录承载)
//
// 1. 只有待办进红、只有在办进黄; 浏览型计数走中性括号数字, 不登记。
// 2. 同一条链内同一件活只计一次; 跨链(同一张单既等我动手又还在跑)不算双计。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'badge_module.dart';
import 'badge_summary_provider.dart';

export 'badge_module.dart';
export 'badge_summary_provider.dart';

/// 一个徽章入口 —— 用户能点进去干活的一张卡/一个页面, 右上角最多红黄两枚数字。
///
/// 名字即服务端入口键; 只声明归属容器, 数字口径全部在服务端。
enum BadgeEntry {
  // —— 人事与访客 ——
  /// 我的访客: 红 = 待我确认; 黄 = 我已确认、这趟来访还没走完。
  visitorHost(BadgeModule.people),

  /// 访客审批: 红 = HR 待审批; 黄 = 已批准、访客还没来核验。
  visitorApproval(BadgeModule.people),

  /// 信息变更审核: 员工资料变更待审。
  hrProfileReview(BadgeModule.people),

  /// HR 任务中心: 今日转正/逾期转正/今日生日/今日周年。
  hrTaskCenter(BadgeModule.people),

  /// 我的报销: 红 = 草稿 + 驳回待修订; 黄 = 已提交在审批/待付款。
  expenseMine(BadgeModule.people),

  // —— 钱流 ——
  /// 业务审核中心(一张卡承载全部审核队列, 页内按队列分段)。
  financeAuditCenter(BadgeModule.finance),

  /// 财务报销: 待审批 + 待付款。
  expenseFinance(BadgeModule.finance),

  /// 钱流草稿(收款/付款/费用/其它收入/银行转账)。
  financeDrafts(BadgeModule.finance),

  // —— 生产(计划员) ——
  /// 生产调度: 待排产行。
  productionSchedule(BadgeModule.production),
  productionRateApprovals(BadgeModule.production),
  productionMaterialIncrementApprovals(BadgeModule.production),

  /// 生产计划(物料分析): 车间在催计划下单子层物料、计划还没下够单的车间任务(ADR-117)。
  productionPlanningUrges(BadgeModule.production),

  /// 生产管理: 进行中的物料分析 / 根计划批次(黄)。
  productionBatches(BadgeModule.production),

  /// 生产草稿(生产计划 / 生产日报)。
  productionDrafts(BadgeModule.production),

  // —— 车间 ——
  /// 我的车间任务: 红 = 等待物料; 黄 = 生产中。
  productionWorkshop(BadgeModule.workshop),

  // —— 研发 ——
  /// 工程研发部任务中心: 红 = 待认领; 黄 = 已认领在办。
  rdTaskCenter(BadgeModule.rd),

  // —— 仓库(一张任务中心卡一个入口; 卡内分段读 [BadgeFact]) ——
  /// 出库任务中心: 销售待出库 + 委外待出仓。
  warehouseOutboundCenter(BadgeModule.warehouse),

  /// 入库任务中心: 预计到货 + 到货异常(仓库侧) + 产成品待点收。
  warehouseInboundCenter(BadgeModule.warehouse),

  /// 生产领料任务中心: 待领任务 + 车间已提交待确认实收的退料。
  warehouseDrawCenter(BadgeModule.warehouse),

  /// 品质部检查结果: 红 = 轮到仓库动手; 黄 = 等待检查结果。
  warehouseQualityResult(BadgeModule.warehouse),

  /// 仓库草稿(stock_documents 全类型合计)。
  warehouseDrafts(BadgeModule.warehouse),

  // —— 采购 ——
  /// 采购任务中心: 红 = 待分解 + 财务驳回; 黄 = 进行中。
  purchaseTaskCenter(BadgeModule.purchase),

  /// 采购「待退回供应商」任务。
  purchaseSupplierReturn(BadgeModule.purchase),

  /// 采购草稿(订货/收货/退货)。
  purchaseDrafts(BadgeModule.purchase),

  // —— 委外 ——
  /// 委外任务中心: 红 = 待处理 + 财务驳回; 黄 = 进行中。
  subcontractTaskCenter(BadgeModule.subcontract),

  /// 委外「待退回供应商」任务。
  subcontractSupplierReturn(BadgeModule.subcontract),

  /// 委外草稿(订货/退货/退料/废品)。
  subcontractDrafts(BadgeModule.subcontract),

  // —— 品质 ——
  /// 待检处置 · IQC 待检收货单。
  qualityIqcPending(BadgeModule.quality),

  /// 待检处置 · FQC 自制产成品待检。
  qualityFqcPending(BadgeModule.quality),

  // —— 销售 ——
  /// 订单进度: 红 = 财务驳回待修正 + 可分批发货待开单。
  salesAttention(BadgeModule.sales),

  /// 订单进度: 黄 = 在途订单(待排产 + 生产中 + 出货待财审 + 等仓库出货)。
  salesOrderInFlight(BadgeModule.sales),

  /// 销售出货「财务已退回」。
  salesShipmentFinanceRejected(BadgeModule.sales),

  /// 销售草稿(订货/发货/退货/报价)。
  salesDrafts(BadgeModule.sales),

  // —— 系统管理 ——
  /// 服务器状态: 越过警告或危急阈值的告警条数。
  serverStatusAlert(BadgeModule.system);

  const BadgeEntry(this.module);

  /// 该入口画在哪个容器(hub / 工作台模块卡)里。
  final BadgeModule module;
}

/// 汇总里的原始事实数键(来源键 + "." + 原端点字段名), 供页内分段使用。
///
/// 与服务端各模块 *WorkbenchBadgeSources 的来源键和原端点返回字段逐字一致。
abstract final class BadgeFact {
  static const visitorHostPending = 'visitorHost.pending';
  static const visitorHostOngoing = 'visitorHost.ongoing';
  static const visitorHostHrReviewing = 'visitorHost.hrReviewing';
  static const visitorHostAwaitingVisit = 'visitorHost.awaitingVisit';
  static const visitorApprovalPending = 'visitorApproval.pending';
  static const visitorApprovalOngoing = 'visitorApproval.ongoing';

  static const expenseDraft = 'expense.draftCount';
  static const expenseRejected = 'expense.rejectedCount';
  static const expensePendingApproval = 'expense.pendingApprovalCount';
  static const expensePendingPayment = 'expense.pendingPaymentCount';
  static const expenseProcessing = 'expense.processingCount';

  static const salesOrderFinance = 'salesOrderFinance.count';
  static const shipmentFinance = 'shipmentFinance.count';
  static const procurementApproval = 'procurementApproval.count';
  static const financeArrivalException = 'financeArrivalException.count';

  /// IQC 退回贷项仍需财务处理的案件(待退回 + 已登记退回 + 财务异常, 服务端算好)。
  static const iqcRejectionOpen = 'iqcRejection.open';

  static const productionScheduleCount = 'productionSchedule.count';
  static const productionOverproductionRate =
      'productionOverproductionRate.count';
  static const productionMaterialIncrement =
      'productionMaterialIncrement.count';
  static const productionPlanningUrge = 'productionPlanningUrge.count';
  static const productionScheduleUrgent = 'productionSchedule.urgent';
  static const productionScheduleOverdue = 'productionSchedule.overdue';
  static const productionExecution = 'productionExecution.count';
  static const workshopTotal = 'workshopTask.count';
  static const workshopPreparing = 'workshopTask.preparing';
  static const workshopInProgress = 'workshopTask.inProgress';

  static const rdOpen = 'rdTask.open';
  static const rdInProgress = 'rdTask.inProgress';

  static const purchaseTaskPending = 'purchaseTask.pending';
  static const purchaseTaskInProgress = 'purchaseTask.inProgress';
  static const subcontractTaskPending = 'subcontractTask.pending';
  static const subcontractTaskInProgress = 'subcontractTask.inProgress';
  static const purchaseSupplierReturn = 'purchaseSupplierReturn.count';
  static const subcontractSupplierReturn = 'subcontractSupplierReturn.count';
  static const subcontractShortDeliveryPending =
      'subcontractShortDelivery.pending';
  static const subcontractShortDeliveryTolerant =
      'subcontractShortDelivery.tolerant';
  static const subcontractShortDeliveryWaiting =
      'subcontractShortDelivery.waiting';

  static const warehouseInboundExpectation =
      'warehouseInboundExpectation.count';
  static const warehouseArrivalException = 'warehouseArrivalException.count';
  static const finishedInbound = 'finishedInbound.count';
  static const productionDraw = 'productionDraw.count';
  static const productionReturn = 'productionReturn.count';
  static const warehouseSalesOutboundPendingPick =
      'warehouseSalesOutbound.PENDING_PICK';
  static const warehouseSalesOutboundShipped = 'warehouseSalesOutbound.SHIPPED';
  static const warehouseSalesOutboundLegacyPending =
      'warehouseSalesOutbound.LEGACY_PENDING';
  static const subcontractOutbound = 'subcontractOutbound.count';
  static const subcontractOutboundWaitingComponent =
      'subcontractOutbound.waitingComponent';

  /// 品质结果「轮到仓库动手」按来源大类(后缀 = 收货单类型 apiValue)。
  static String qualityResultActionable(String receiptType) =>
      'qualityResult.actionable.$receiptType';

  /// 品质结果「等待检查结果」按来源大类。
  static String qualityResultInProgress(String receiptType) =>
      'qualityResult.inProgress.$receiptType';

  static const iqcPending = 'iqcPending.count';
  static const fqcPending = 'fqcPending.count';

  /// 订单进度阶段计数(后缀 = 服务端 stage)。
  static String salesStage(String stage) => 'salesStage.$stage';

  /// 某类单据草稿数(后缀 = DraftDocKind 名, 与服务端 DraftCountsResponse 字段一致)。
  static String draft(String kind) => 'drafts.$kind';

  /// 某类单据「财务已退回」张数。
  static String financeRejected(String kind) => 'financeRejected.$kind';

  static const serverStatusAlerts = 'serverStatus.alerts';

  static const noticesUnread = 'notices.unread';
  static const noticesDigest = 'notices.digest';
  static const noticesLatestPublishedAt = 'notices.latestPublishedAt';
}

/// 入口红数(待办)。汇总未到 / 无权访问按 0。
final badgeEntryTodoProvider = Provider.family<int, BadgeEntry>(
  (ref, entry) =>
      ref.watch(badgeSummaryProvider.select((s) => s.entryTodo(entry))),
);

/// 入口黄数(进行中)。
final badgeEntryInProgressProvider = Provider.family<int, BadgeEntry>(
  (ref, entry) =>
      ref.watch(badgeSummaryProvider.select((s) => s.entryInProgress(entry))),
);

/// 容器红数 = 服务端算好的该容器入口之和。
final badgeModuleTodoProvider = Provider.family<int, BadgeModule>(
  (ref, module) =>
      ref.watch(badgeSummaryProvider.select((s) => s.moduleTodo(module))),
);

/// 容器黄数。
final badgeModuleInProgressProvider = Provider.family<int, BadgeModule>(
  (ref, module) =>
      ref.watch(badgeSummaryProvider.select((s) => s.moduleInProgress(module))),
);

/// 导航「工作台」Tab 红色总数。
final badgeTotalTodoProvider = Provider<int>(
  (ref) => ref.watch(badgeSummaryProvider.select((s) => s.total.todo)),
);

/// 导航「工作台」Tab 黄色总数。
final badgeTotalInProgressProvider = Provider<int>(
  (ref) => ref.watch(badgeSummaryProvider.select((s) => s.total.inProgress)),
);

/// 单个事实数(页内分段用)。没有该来源(无权 / 未到)按 0。
final badgeFactProvider = Provider.family<int, String>(
  (ref, key) => ref.watch(badgeSummaryProvider.select((s) => s.fact(key))),
);

/// 单个事实数, 汇总还没到或当前身份对该来源无权时为 null(页内分段据此不渲染数字,
/// 不把「未知」伪装成 0)。
final badgeFactOrNullProvider = Provider.family<int?, String>((ref, key) {
  final source = key.substring(0, key.indexOf('.'));
  return ref.watch(
    badgeSummaryProvider.select(
      (s) => s.hasSource(source) ? s.fact(key) : null,
    ),
  );
});

/// 某来源是否对当前身份可见(汇总里带回了它的事实数)。
final badgeSourceGrantedProvider = Provider.family<bool, String>(
  (ref, source) =>
      ref.watch(badgeSummaryProvider.select((s) => s.hasSource(source))),
);

/// 通知未读数(导航「通知」Tab 角标), 随徽章汇总一起带回。
final unreadNoticeCountProvider = Provider<int>(
  (ref) => ref.watch(
    badgeSummaryProvider.select((s) => s.fact(BadgeFact.noticesUnread)),
  ),
);

/// 数据变了(保存/审核/删除成功、返回工作台、新通知到达)后立即重拉一次徽章汇总。
///
/// 单飞合并: 同一帧里多处调用只发一个请求, 请求在途时再调用只在其返回后补一次。
/// 取 [WidgetRef] 或 [Ref] 皆可(函数体只用 read)。
Future<void> refreshBadges(WidgetRef ref) =>
    ref.read(badgeSummaryProvider.notifier).refresh();

/// [refreshBadges] 的 [ProviderContainer] 版本(通知横幅点击等延迟回调用)。
Future<void> refreshBadgesIn(ProviderContainer container) =>
    container.read(badgeSummaryProvider.notifier).refresh();

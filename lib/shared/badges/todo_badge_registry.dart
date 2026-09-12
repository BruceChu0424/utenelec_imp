// 待办徽章注册表 —— 全站「红色数量徽章」的唯一登记处与唯一累加实现。
//
// ## 为什么存在
//
// 徽章数字此前散在十几个页面里各写各的加法：工作台「采购管理」卡只数采购任务台，
// 而采购 hub 里其实还有一张「待退回供应商」卡也带徽章——于是外层写 1、内层合计 5。
// 本文件把「入口 → 计数源 → 归属容器」登记成一张表，容器徽章一律由表求和得出，
// 新增入口只改这张表，不再在每个 hub / 工作台里手写加法。
//
// ## 两条硬口径（docs/00-项目准则/14-徽章与计数口径.md）
//
// 1. **只有待办才登记**。红色数量徽章 = 「需要我处理、不处理会出事」：待审 / 待确认 /
//    待收货 / 待出库 / 待检 / 被驳回 / 超期 / 异常。我的某某、历史/记录、报表、
//    基础资料等「有多少条、供我掂量」的浏览型计数一律走中性括号数字
//    （[UtenCountSuffix]），**不登记、不累加**。
//    **草稿是例外（2026-09-11 用户口径反转）**：草稿 = 本人还没提交、必须处理完的活，
//    改走红色徽章并按模块登记（`TodoEntry.*Drafts`）逐级累加。
// 2. **同一件活只计一次**。两个入口指向同一批单据时，只让其中一个登记进表，另一个
//    在自己的语义标签里说明「已计入 xxx」。见文件末尾「已知切片」一节。
//
// ## 层级
//
//   TodoEntry（入口，如「采购任务中心」）
//     → TodoModule（hub / 工作台模块卡，如「采购管理」= 该模块全部入口之和）
//       → [todoTotalCountProvider]（导航「工作台」Tab 总数 = 全部模块之和）
//
// 加载中 / 失败一律按 0 计（与既有降级口径一致：不把「未知」放大成异常态）。
//
// ## 接线状态（2026-09-11）
//
// 本表已是权威口径，但工作台模块卡与导航 Tab 仍走旧的
// `features/dashboard/widgets/module_badge_sum.dart`（该目录由另一会话持有）。
// 待 `_resolveCount` 改为委托 [todoModuleCountProvider]、`workbenchTotalTodoCountProvider`
// 改为委托 [todoTotalCountProvider] 后，工作台「采购/委外管理」卡才会把
// 「待退回供应商」计进去、「钱流管理」卡才会把 IQC 驳回计进去。
// **两处必须同批切换**，否则 Tab 总数会一时高于各卡之和。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/finance/providers/finance_procurement_approval_count_provider.dart';
import '../../features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import '../../features/hr_task/providers/hr_task_count_provider.dart';
import '../../features/procurement_iqc_rejection/repositories/procurement_iqc_rejection_repository.dart';
import '../../features/production/providers/production_pending_provider.dart';
import '../../features/production/providers/production_workshop_task_count_provider.dart';
import '../../features/admin/providers/server_status_alert_count_provider.dart';
import '../../features/purchase/providers/purchase_task_count_provider.dart';
import '../../features/rd_task/providers/rd_task_count_provider.dart';
import '../../features/sales/providers/sales_completion_count_provider.dart';
import '../../features/subcontract/providers/subcontract_task_count_provider.dart';
import '../../features/visitor_approval/providers/visitor_pending_count_provider.dart';
import '../../features/warehouse/providers/procurement_inbound_count_providers.dart';
import '../../features/warehouse/providers/production_draw_count_provider.dart';
import '../../features/warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../../features/warehouse/providers/warehouse_quality_result_count_provider.dart';
import '../../features/warehouse/providers/warehouse_sales_outbound_count_provider.dart';
import '../../features/warehouse/repositories/warehouse_subcontract_outbound_repository.dart'
    show warehouseSubcontractOutboundCountProvider;
import '../auth/pending_review_provider.dart';
import '../auth/permissions.dart';
import '../models/procurement_inbound.dart';
import '../providers/production_fqc_pending_count_provider.dart';
import '../providers/draft_counts_provider.dart';
import '../providers/sales_shipment_finance_count_provider.dart';

/// 待办容器：一个 [TodoModule] 对应工作台上的一张模块卡 / 一个 hub。
enum TodoModule {
  /// 人事与访客（我的访客 / 访客审批 / 信息变更审核 / HR 任务中心）。
  people,

  /// 钱流管理 hub。
  finance,

  /// 生产管理（生产调度 + 我的车间任务）。
  production,

  /// 工程研发部任务中心。
  rd,

  /// 仓库管理 hub（三张方向任务中心 + 品质部检查结果）。
  warehouse,

  /// 采购管理 hub。
  purchase,

  /// 委外管理 hub。
  subcontract,

  /// 品质任务中心。
  quality,

  /// 销售管理 hub。
  sales,

  /// 系统管理（服务器状态告警）。
  system,
}

/// 一个「待办入口」——用户能点进去干活的一个页面/分段集合。
///
/// 每个枚举值就是全站对该入口计数口径的唯一声明：归属哪个容器、数字从哪来。
enum TodoEntry {
  // —— 人事与访客 ——
  /// 我的访客：被访人待确认。
  visitorHostConfirm(TodoModule.people),

  /// 访客审批：HR 待审批。
  visitorApproval(TodoModule.people),

  /// 信息变更审核：员工资料变更待审。
  hrProfileReview(TodoModule.people),

  /// HR 任务中心：今日转正/逾期转正/今日生日/今日周年。
  hrTaskCenter(TodoModule.people),

  // —— 钱流 ——
  /// 销售订单财务确认（含「销售订单修改」队列，见「已知切片」）。
  financeSalesOrderConfirmation(TodoModule.finance),

  /// 出货财务审核。
  financeShipmentAudit(TodoModule.finance),

  /// 订货审批任务中心。
  financeProcurementApproval(TodoModule.finance),

  /// 超量到货财务审批。
  financeArrivalException(TodoModule.finance),

  /// IQC 不合格退回与贷项（财务确认贷项/结案）。
  financeIqcRejection(TodoModule.finance),

  // —— 生产 ——
  /// 生产调度：待排产行。
  productionSchedule(TodoModule.production),

  /// 我的车间任务：当前可行动执行段。
  productionWorkshop(TodoModule.production),

  // —— 研发 ——
  /// 工程研发部任务中心。
  rdTaskCenter(TodoModule.rd),

  // —— 仓库（四张任务中心卡，各自已是其内部分段之和）——
  /// 出库任务中心 · 销售待出库。
  warehouseSalesOutbound(TodoModule.warehouse),

  /// 出库任务中心 · 委外出仓。
  warehouseSubcontractOutbound(TodoModule.warehouse),

  /// 入库任务中心 · 预计到货。
  warehouseInboundExpectation(TodoModule.warehouse),

  /// 入库任务中心 · 到货异常（仓库侧）。
  warehouseArrivalException(TodoModule.warehouse),

  /// 生产领料任务中心 · 待领任务。
  warehouseProductionDraw(TodoModule.warehouse),

  /// 入库任务中心 · 产成品待点收。
  warehouseFinishedInbound(TodoModule.warehouse),

  /// 品质部检查结果 · 未完结任务。
  warehouseQualityResult(TodoModule.warehouse),

  // —— 采购 ——
  /// 采购任务中心：待分解 + 待采购完成。
  purchaseTaskCenter(TodoModule.purchase),

  /// 采购「待退回供应商」任务。
  purchaseSupplierReturn(TodoModule.purchase),

  // —— 委外 ——
  /// 委外任务中心。
  subcontractTaskCenter(TodoModule.subcontract),

  /// 委外「待退回供应商」任务。
  subcontractSupplierReturn(TodoModule.subcontract),

  // —— 品质 ——
  /// 待检处置 · IQC 待检收货单。
  qualityIqcPending(TodoModule.quality),

  /// 待检处置 · FQC 自制产成品待检。
  qualityFqcPending(TodoModule.quality),

  // —— 销售 ——
  /// 订单进度查询：财务驳回待修正 + 未读完工提醒。
  salesAttention(TodoModule.sales),

  // —— 草稿（2026-09-11 起计入累加；每个模块一条，数字来自 draftCountsProvider）——
  /// 销售模块草稿（订货/发货/退货/报价）。
  salesDrafts(TodoModule.sales),

  /// 采购模块草稿（订货/收货/退货）。
  purchaseDrafts(TodoModule.purchase),

  /// 委外模块草稿（订货/退货/退料/废品）。
  subcontractDrafts(TodoModule.subcontract),

  /// 钱流模块草稿（收款/付款/费用/其它收入/银行转账）。
  financeDrafts(TodoModule.finance),

  /// 仓库模块草稿（stock_documents 全类型合计，不用切片以免双计）。
  warehouseDrafts(TodoModule.warehouse),

  /// 生产模块草稿（生产计划 / 生产日报）。
  productionDrafts(TodoModule.production),

  // —— 系统管理 ——
  /// 服务器状态告警（磁盘/内存/数据库/备份越过警告或危急阈值的条数）。
  /// 2026-09-11 补：此前这些告警只活在状态页里，不点开就无人知晓。
  serverStatusAlert(TodoModule.system);

  const TodoEntry(this.module);

  /// 该入口归属的容器（hub / 工作台模块卡）。
  final TodoModule module;
}

/// `ref.watch` 的最小签名；provider 与 ConsumerWidget 都能传进来。
typedef TodoWatch = T Function<T>(ProviderListenable<T> listenable);

/// 单个入口的待办数。加载中/失败按 0。
int todoEntryCount(TodoEntry entry, TodoWatch watch) => switch (entry) {
  TodoEntry.visitorHostConfirm => watch(visitorHostPendingCountProvider),
  TodoEntry.visitorApproval => watch(visitorPendingCountProvider),
  TodoEntry.hrProfileReview => watch(pendingReviewCountProvider),
  TodoEntry.hrTaskCenter => watch(hrTaskCountProvider),
  TodoEntry.financeSalesOrderConfirmation => _async(
    watch,
    salesOrderFinanceConfirmationCountProvider,
  ),
  TodoEntry.financeShipmentAudit => _async(
    watch,
    salesShipmentFinanceCountProvider,
  ),
  TodoEntry.financeProcurementApproval => _async(
    watch,
    financeProcurementApprovalCountProvider,
  ),
  TodoEntry.financeArrivalException => _async(
    watch,
    financeArrivalExceptionCountProvider,
  ),
  // 该 provider 自身没有权限自卫（非 autoDispose 的裸 FutureProvider），
  // 聚合侧先查权限再决定是否 watch，避免给无权账号发请求。
  TodoEntry.financeIqcRejection =>
    _can(watch, Perm.procurementIqcRejectionView)
        ? _async(watch, procurementIqcRejectionOpenCountProvider)
        : 0,
  TodoEntry.productionSchedule => watch(productionPendingCountProvider).count,
  TodoEntry.productionWorkshop => watch(
    productionWorkshopTaskCountProvider,
  ).count,
  TodoEntry.rdTaskCenter => watch(rdTaskCountProvider),
  TodoEntry.warehouseSalesOutbound => _async(
    watch,
    warehouseSalesOutboundPendingCountProvider,
  ),
  TodoEntry.warehouseSubcontractOutbound => _async(
    watch,
    warehouseSubcontractOutboundCountProvider,
  ),
  TodoEntry.warehouseInboundExpectation => _async(
    watch,
    warehouseInboundExpectationCountProvider,
  ),
  TodoEntry.warehouseArrivalException => _async(
    watch,
    warehouseArrivalExceptionCountProvider,
  ),
  TodoEntry.warehouseProductionDraw => _async(
    watch,
    warehouseProductionDrawPendingCountProvider,
  ),
  TodoEntry.warehouseFinishedInbound => _async(
    watch,
    warehouseProductionFinishedInboundPendingCountProvider,
  ),
  TodoEntry.warehouseQualityResult => _async(
    watch,
    warehouseQualityResultPendingCountProvider,
  ),
  TodoEntry.purchaseTaskCenter => watch(purchaseTaskCountProvider),
  TodoEntry.purchaseSupplierReturn => _async(
    watch,
    procurementArrivalReturnCountProvider(ProcurementInboundOrderType.purchase),
  ),
  TodoEntry.subcontractTaskCenter => watch(subcontractTaskCountProvider),
  TodoEntry.subcontractSupplierReturn => _async(
    watch,
    procurementArrivalReturnCountProvider(
      ProcurementInboundOrderType.subcontract,
    ),
  ),
  TodoEntry.qualityIqcPending => _async(
    watch,
    procurementInspectionPendingCountProvider,
  ),
  TodoEntry.qualityFqcPending => _async(
    watch,
    productionFqcPendingCountProvider,
  ),
  TodoEntry.salesAttention => _async(watch, salesAttentionCountProvider),
  // 草稿：一次请求带回全部 21 类，这里按模块切片求和（每类都已在服务端按
  // *:view 权限 + 对象级归属收敛，无权限的类型固定为 0，不用再判权限）。
  TodoEntry.salesDrafts => _drafts(watch, const [
    DraftDocKind.salesOrder,
    DraftDocKind.salesShipment,
    DraftDocKind.salesReturn,
    DraftDocKind.salesQuote,
  ]),
  TodoEntry.purchaseDrafts => _drafts(watch, const [
    DraftDocKind.purchaseOrder,
    DraftDocKind.purchaseReceipt,
    DraftDocKind.purchaseReturn,
  ]),
  TodoEntry.subcontractDrafts => _drafts(watch, const [
    DraftDocKind.subcontractOrder,
    DraftDocKind.subcontractReturn,
    DraftDocKind.subcontractMaterialReturn,
    DraftDocKind.subcontractWaste,
  ]),
  TodoEntry.financeDrafts => _drafts(watch, const [
    DraftDocKind.financeReceipt,
    DraftDocKind.financePayment,
    DraftDocKind.financeExpense,
    DraftDocKind.financeOtherIncome,
    DraftDocKind.financeBankTransfer,
  ]),
  // 仓库用 stockDocument 合计，**不能**用 stockTransfer/stockCheck 切片（会双计）。
  TodoEntry.warehouseDrafts => _drafts(watch, const [
    DraftDocKind.stockDocument,
  ]),
  TodoEntry.productionDrafts => _drafts(watch, const [
    DraftDocKind.productionPlan,
    DraftDocKind.productionDailyReport,
  ]),
  // 计数源自身已做权限自卫（无 server_status:view 固定 0 且不发请求）。
  TodoEntry.serverStatusAlert => _async(watch, serverStatusAlertCountProvider),
};

/// 草稿切片求和；加载中/失败按 0（与其它入口同款降级）。
int _drafts(TodoWatch watch, List<DraftDocKind> kinds) =>
    watch(draftCountsProvider).valueOrNull?.sumOf(kinds) ?? 0;

/// 某容器（hub / 工作台模块卡）的待办数 = 其登记入口之和。
int todoModuleCount(TodoModule module, TodoWatch watch) =>
    sumTodoEntries(entriesOfModule(module), watch);

/// 若干入口之和（工作台分组徽章、自定义组合用）。
int sumTodoEntries(Iterable<TodoEntry> entries, TodoWatch watch) {
  var total = 0;
  for (final entry in entries) {
    total += todoEntryCount(entry, watch);
  }
  return total;
}

/// 某容器下登记的全部入口（声明顺序即展示顺序）。
List<TodoEntry> entriesOfModule(TodoModule module) => TodoEntry.values
    .where((entry) => entry.module == module)
    .toList(growable: false);

/// 单个入口的待办数（徽章组件直接 watch）。
final todoEntryCountProvider = Provider.family<int, TodoEntry>(
  (ref, entry) => todoEntryCount(entry, ref.watch),
);

/// 容器（hub / 工作台模块卡）待办数 = 其内部入口徽章之和。
final todoModuleCountProvider = Provider.family<int, TodoModule>(
  (ref, module) => todoModuleCount(module, ref.watch),
);

/// 导航「工作台」Tab 总数 = 全部模块之和（= 全部登记入口之和）。
final todoTotalCountProvider = Provider<int>(
  (ref) => sumTodoEntries(TodoEntry.values, ref.watch),
);

/// 失效全部「待办」计数缓存（`FutureProvider.autoDispose` 那批）。
///
/// 返回工作台 / 新通知到达 / 新会话建立时调用，让角标立即重拉而不等 60s 轮询；
/// provider 未存活时 invalidate 是空操作。
///
/// 放在本文件的理由与求和一致：**登记处只有一个**。新增入口时在 [TodoEntry] 加一条、
/// 在这里补一行 invalidate 即可，不必再去翻 `workbench_refresh.dart`
/// ——历史上 IQC 驳回计数就是因为漏在那份名单外，返回工作台时角标一直是旧值。
///
/// 60s 轮询的 `StateNotifier` 角标（生产待排产/车间/采购/委外/研发/访客/HR/通知）
/// 走各自的 `notifier.refresh()`，不在此列。
void invalidateTodoBadgeCaches(WidgetRef ref) {
  ref.invalidate(salesOrderFinanceConfirmationCountProvider);
  ref.invalidate(salesShipmentFinanceCountProvider);
  ref.invalidate(financeProcurementApprovalCountProvider);
  ref.invalidate(financeArrivalExceptionCountProvider);
  ref.invalidate(procurementIqcRejectionOpenCountProvider);
  ref.invalidate(warehouseSalesOutboundPendingCountProvider);
  ref.invalidate(warehouseSubcontractOutboundCountProvider);
  ref.invalidate(warehouseInboundExpectationCountProvider);
  ref.invalidate(warehouseArrivalExceptionCountProvider);
  ref.invalidate(warehouseProductionDrawPendingCountProvider);
  ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
  ref.invalidate(warehouseQualityResultPendingCountProvider);
  ref.invalidate(
    procurementArrivalReturnCountProvider(ProcurementInboundOrderType.purchase),
  );
  ref.invalidate(
    procurementArrivalReturnCountProvider(
      ProcurementInboundOrderType.subcontract,
    ),
  );
  ref.invalidate(procurementInspectionPendingCountProvider);
  ref.invalidate(productionFqcPendingCountProvider);
  ref.invalidate(salesCompletionCountProvider);
  ref.invalidate(salesAttentionCountProvider);
  ref.invalidate(serverStatusAlertCountProvider);
}

/// 异步计数取值：**刷新期间保留上一次的数**，只有从没成功过才按 0。
///
/// 此前写成 `loading: () => 0`，于是每 60 秒自失效轮询都把徽章打回 0 再弹回来
/// ——用户 2026-09-11 反馈的「徽章会突然消失下又出现，然后又消失又出现」就是它。
/// AsyncValue 在 refresh/invalidate 期间会带住旧值（copyWithPrevious），
/// `valueOrNull` 正好取到；错误态同理保留旧值，不让一次网络抖动清空整列徽章。
/// 前提是 provider 常驻（不 autoDispose），否则销毁重建后没有「上一次」可留。
int _async(TodoWatch watch, ProviderListenable<AsyncValue<int>> provider) =>
    watch(provider).valueOrNull ?? 0;

bool _can(TodoWatch watch, String permission) =>
    watch(isSuperAdminProvider) ||
    watch(currentPermissionsProvider).contains(permission);

// ============================ 已知切片（不登记，避免双计）============================
//
// · 钱流「销售订单修改」卡：与「销售订单财务确认」卡同一批单据的两个队列切片
//   （salesOrderFinanceQueueCountProvider(changesOnly)）。登记的是总数
//   [TodoEntry.financeSalesOrderConfirmation]，两张卡各自显示自己的队列数但都不进累加。
//
// · 仓库三张任务中心卡的卡面角标是「卡内各分段之和」，分段本身不单独登记。
//
// · 采购 hub「采购申请」卡：申请单的待处理量已由
//   [TodoEntry.purchaseTaskCenter]（待分解）计入，故该卡不挂待办徽章。
//
// · 销售 hub「客户零星发货」卡：其草稿与「销售出货」卡同属 sales_shipments，
//   且 /sales/shipments 列表本就包含这批单，若两张卡各显一次会双计——
//   故客户零星发货卡不显草稿数，口径写在卡副标题/文档里。

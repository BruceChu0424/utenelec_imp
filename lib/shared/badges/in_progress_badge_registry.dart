// 进行中徽章注册表 —— 全站「黄色数量徽章」的唯一登记处与唯一累加实现。
//
// ## 为什么存在
//
// 红色那条链(todo_badge_registry.dart)回答「我还欠多少活」; 本表回答另一个问题:
// **「我手上还有多少在跑」**。准则 §四之二 早就把「球在别人手上」的档单独列出来说明
// 「页内照常以中性计数呈现, 但不进红徽章、不参与上卷」—— 2026-09-21 用户要求给那一类
// 数字一个自己的颜色(黄色), 并且「工作台就是汇总」, 于是它们也要上卷, 走的就是本表。
//
// ## 三条硬口径(ADR-100 / docs/00-项目准则/14-徽章与计数口径.md)
//
// 1. **只有「在办中」才登记**。黄色 = 已经在办、还没完、**现在不用我动手**:
//    生产中 / 加工中 / 执行中 / 在途 / 等待财务审核 / 财务已通过待执行 / 等待检查结果。
//    轮到我动手的走红表; 已完成 / 已审 / 红冲 / 历史 / 全部走中性括号, 两者都不登记。
// 2. **同一条链内同一件活只计一次**。跨链不算双计 —— 同一张单据可以既在红数里
//    (等你动手)又在黄数里(还在跑), 那是两个问题的两个答案。链内去重见文件末尾。
// 3. **累加只有一处实现**, 就是本文件。新增入口只改这张表, 不要在 hub 页或工作台里
//    手写加法。分段计数**永不登记**(累加只认入口, 与红表同规矩)。
//
// ## 层级
//
//   InProgressEntry(入口, 如「委外任务中心·进行中」)
//     -> BadgeModule(hub 卡 / 工作台模块卡) = 该容器全部在办入口之和
//       -> [inProgressTotalCountProvider](导航「工作台」Tab 的黄色总数)
//
// 加载中 / 失败一律保留上一次的数(见 [_async]), 与红表同款降级, 免得 60s 轮询
// 每转一圈把徽章打回 0 再弹回来。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/expense/providers/expense_counts_provider.dart';
import '../../features/production/providers/production_execution_group_count_provider.dart';
import '../../features/production/providers/production_workshop_task_count_provider.dart';
import '../../features/purchase/providers/purchase_task_count_provider.dart';
import '../../features/rd_task/providers/rd_task_count_provider.dart';
import '../../features/sales/providers/sales_order_in_progress_count_provider.dart';
import '../../features/subcontract/providers/subcontract_task_count_provider.dart';
import '../../features/visitor_approval/providers/visitor_pending_count_provider.dart';
import '../../features/warehouse/providers/warehouse_quality_result_count_provider.dart';
import 'badge_module.dart';

export 'badge_module.dart';

/// 一个「在办入口」—— 用户点进去能看到一批正在跑的活的页面/分段集合。
///
/// 每个枚举值就是全站对该入口黄色计数口径的唯一声明: 归属哪个容器、数字从哪来。
enum InProgressEntry {
  // —— 人事与访客 ——
  /// 我的访客: 我已确认、这趟来访还没走完(HR 审批中 + 已通过待来访)。
  /// 页内两个黄分段之和 = 本数(服务端同一次扫描保证)。
  visitorHostOngoing(BadgeModule.people),

  /// 访客审批: 我已批准、访客还没来核验的申请(页内「已通过」分段同数)。
  visitorApprovalOngoing(BadgeModule.people),

  /// 我的报销: 本人已提交、正在审批或待付款的单(球在审批人/出纳手上)。
  expenseMineProcessing(BadgeModule.people),

  // —— 生产 ——
  /// 生产管理: 进行中的物料分析 / 根计划**批次**数(计划员视角)。
  productionBatches(BadgeModule.production),

  /// 我的车间任务: 本人**生产中的执行段**数(车间工视角)。
  ///
  /// 与 [productionBatches] **不是同一批活的两次计数**: 一个是批次、一个是工单段,
  /// 读取范围也不同(全部可见 vs 仅指派给本人)。两张卡在红表里本来也是各登记各的。
  productionWorkshop(BadgeModule.production),

  // —— 研发 ——
  /// 工程研发部任务中心: 已认领、正在做的任务(IN_PROGRESS)。
  rdTaskCenter(BadgeModule.rd),

  // —— 仓库 ——
  /// 品质部检查结果 · 等待检查结果(货已收、等品质部出结论, 仓库不用动手)。
  warehouseQualityWaiting(BadgeModule.warehouse),

  // —— 采购 ——
  /// 采购任务中心 · 进行中(等待财务审核 + 财务已通过 + 财务驳回, 与页内同段同数)。
  purchaseTaskCenter(BadgeModule.purchase),

  // —— 委外 ——
  /// 委外任务中心 · 进行中(同上三档合计)。
  subcontractTaskCenter(BadgeModule.subcontract),

  // —— 销售 ——
  /// 订单进度查询: 在途订单数(待排产 + 生产中 + 出货待财审 + 等仓库出货)。
  salesOrderInFlight(BadgeModule.sales);

  const InProgressEntry(this.module);

  /// 该入口归属的容器(hub / 工作台模块卡)。
  final BadgeModule module;
}

/// `ref.watch` 的最小签名; provider 与 ConsumerWidget 都能传进来。
typedef InProgressWatch = T Function<T>(ProviderListenable<T> listenable);

/// 单个入口的在办数。加载中/失败保留上一次的数。
int inProgressEntryCount(InProgressEntry entry, InProgressWatch watch) =>
    switch (entry) {
      InProgressEntry.visitorHostOngoing => watch(
        visitorHostOngoingCountProvider,
      ),
      InProgressEntry.visitorApprovalOngoing => watch(
        visitorApprovalOngoingCountProvider,
      ),
      InProgressEntry.expenseMineProcessing => watch(
        expenseMineProcessingCountProvider,
      ),
      InProgressEntry.productionBatches => watch(
        productionExecutionInProgressCountProvider,
      ),
      // 后端一次请求带回 {count, preparing, inProgress}: 红取 preparing(等待物料),
      // 黄取 inProgress(生产中)。2026-09-21 之前红错取了 count(两者之和)。
      InProgressEntry.productionWorkshop => watch(
        productionWorkshopTaskCountProvider,
      ).inProgress,
      InProgressEntry.rdTaskCenter => watch(rdTaskInProgressCountProvider),
      InProgressEntry.warehouseQualityWaiting => _async(
        watch,
        warehouseQualityResultWaitingCountProvider,
      ),
      InProgressEntry.purchaseTaskCenter => watch(
        purchaseTaskInProgressCountProvider,
      ),
      InProgressEntry.subcontractTaskCenter => watch(
        subcontractTaskInProgressCountProvider,
      ),
      InProgressEntry.salesOrderInFlight => _async(
        watch,
        salesOrderInProgressCountProvider,
      ),
    };

/// 某容器(hub / 工作台模块卡)的在办数 = 其登记入口之和。
int inProgressModuleCount(BadgeModule module, InProgressWatch watch) =>
    sumInProgressEntries(inProgressEntriesOfModule(module), watch);

/// 若干入口之和(工作台分组徽章、自定义组合用)。
int sumInProgressEntries(
  Iterable<InProgressEntry> entries,
  InProgressWatch watch,
) {
  var total = 0;
  for (final entry in entries) {
    total += inProgressEntryCount(entry, watch);
  }
  return total;
}

/// 某容器下登记的全部入口(声明顺序即展示顺序)。
List<InProgressEntry> inProgressEntriesOfModule(BadgeModule module) =>
    InProgressEntry.values
        .where((entry) => entry.module == module)
        .toList(growable: false);

/// 单个入口的在办数(徽章组件直接 watch)。
final inProgressEntryCountProvider = Provider.family<int, InProgressEntry>(
  (ref, entry) => inProgressEntryCount(entry, ref.watch),
);

/// 容器(hub / 工作台模块卡)在办数 = 其内部入口徽章之和。
final inProgressModuleCountProvider = Provider.family<int, BadgeModule>(
  (ref, module) => inProgressModuleCount(module, ref.watch),
);

/// 导航「工作台」Tab 的黄色总数 = 全部模块之和(= 全部登记入口之和)。
final inProgressTotalCountProvider = Provider<int>(
  (ref) => sumInProgressEntries(InProgressEntry.values, ref.watch),
);

/// 失效全部「在办」计数缓存(`FutureProvider` 那批)。
///
/// 返回工作台 / 新通知到达 / 新会话建立时调用, 让角标立即重拉而不等 60s 轮询;
/// provider 未存活时 invalidate 是空操作。60s 轮询的 `StateNotifier` 角标走各自的
/// `notifier.refresh()`, 不在此列 —— 与 [invalidateTodoBadgeCaches] 同款分工。
void invalidateInProgressBadgeCaches(WidgetRef ref) {
  // 「等待检查结果」与红表那支同出一份来源分段计数, 失效打在源头(两条链失效的是
  // 同一支, 同一帧里合并成一次重拉)。
  ref.invalidate(warehouseQualityResultTypeCountsProvider);
  ref.invalidate(salesOrderInProgressCountProvider);
  ref.invalidate(expenseCountsProvider);
}

/// 异步计数取值: **刷新期间保留上一次的数**, 只有从没成功过才按 0。
///
/// 与红表 `_async` 同款理由: 写成 `loading: () => 0` 会让 60s 自失效轮询每转一圈
/// 把徽章打回 0 再弹回来。前提是 provider 常驻(不 autoDispose), 否则销毁重建后
/// 没有「上一次」可留。
int _async(
  InProgressWatch watch,
  ProviderListenable<AsyncValue<int>> provider,
) => watch(provider).valueOrNull ?? 0;

// ======================== 已知重叠(不登记, 避免链内双计)========================
//
// · 销售「出货 / 订货 / 报价 / 退货」四张单据卡的在途数: 订单进度的
//   「出货待财审 / 等仓库出货」两段本就是从出货单派生的(服务端 progressStageExpr
//   看的是 shipment_*_qty), 再按单据数一遍就是同一批出货翻倍。销售只登记
//   [InProgressEntry.salesOrderInFlight] 一个入口。
//
// · 委外「回厂短交判定」卡的 容差内待结案 + 分批等待中: 短交案件只挂在已回厂/
//   在途的 FINANCE_APPROVED 订货单上, 那些单已全部落在
//   [InProgressEntry.subcontractTaskCenter] 的 IN_PROGRESS 里。
//
// · 钱流模块整体不登记黄色: 财务的活清一色是审批队列, 要么等财务动手(红),
//   要么球已经离开财务、落在采购/仓库/销售那几张卡上; 在钱流再数一遍是跨卡双计。
//
// · 品质任务中心不登记黄色: IQC/FQC 只有「待检(红)」与「已出结论(终态)」两档,
//   没有中间的在办态。仓库侧的「等待检查结果」由
//   [InProgressEntry.warehouseQualityWaiting] 计一次(那是仓库在等品质部)。
//
// · 基础资料 / 报表 / 主档 / 历史只读页一律不挂: 准则 §二 的结论对黄色同样成立。

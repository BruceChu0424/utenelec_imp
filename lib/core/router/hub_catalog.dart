// hub 目录：每个模块首页(hub)上全部卡片可能的落点(ADR-109「工作台权限管理总设计」)。
//
// 这是 hub 入口权限的唯一数据源：
//   · hub 路由守卫 = 子卡守卫的并集——任一子卡能进，hub 就能进；不再手写 any-of 清单
//     (过去 /warehouse 漏了库存查询、/finance 漏了应付结算，持码人点不进)。
//   · hub 页与工作台只按 [locationAllowedFor](与路由守卫同一份 any/all 契约)过滤卡片，
//     页面里不再写 perms.contains。
//   · 页面上出现的每张卡都必须登记在这里([hubCardAllowed] 在调试态断言)，
//     hub_guard_union_test 再锁住「hub 守卫 ⊇ 子卡守卫并集」与「经 GoRouter 真实可达」。
//
// 同一张卡按权限切换落点(如「新建页 / 列表页」)时两个落点都登记。
import 'route_names.dart';

/// hub 路径 → 该 hub 上全部卡片落点(只含路径，不含查询参数)。
final Map<String, List<String>> hubCardLocations = <String, List<String>>{
  RouteName.basicinfo: const [
    RouteName.basicinfoGoods,
    RouteName.basicinfoMould,
    RouteName.basicinfoClient,
    RouteName.basicinfoSupplier,
    RouteName.basicinfoColor,
    RouteName.basicinfoUnit,
    RouteName.basicinfoCurrency,
    RouteName.basicinfoWarehouse,
    RouteName.basicinfoAccount,
    RouteName.basicinfoPaymentStyle,
    RouteName.basicinfoSettlementMethod,
  ],
  RouteName.warehouse: [
    // 2026-09-24 三段式：任务中心一张卡（合并页）+ 新建单据六卡（creator-only）。
    // 调拨/盘点列表卡与委外两张历史只读卡撤下（浏览并入任务中心大类）。
    RouteName.warehouseTasks,
    RoutePath.stockDocNew('OTHER_OUT'),
    RoutePath.stockDocNew('FINISHED_OUT'),
    RoutePath.stockDocNew('OTHER_IN'),
    RoutePath.stockDocNew('FINISHED_IN'),
    RoutePath.stockDocNew('TRANSFER'),
    RoutePath.stockDocNew('CHECK'),
    RouteName.stockInstantInventory,
    RouteName.warehouseShelfLabels,
    '${RouteName.warehouseReport}/detail',
    '${RouteName.warehouseReport}/summary',
  ],
  RouteName.finance: [
    RouteName.financeAudits,
    '/expense/approval',
    '/expense/settings',
    RoutePath.financeDocNew('receipts'),
    RoutePath.financeDocNew('payments'),
    RoutePath.financeDocNew('expenses'),
    RoutePath.financeDocNew('incomes'),
    RoutePath.financeDocNew('bank-transfers'),
    RouteName.financeChecks,
    RouteName.financeAssets,
    RouteName.financePayables,
    RouteName.financeReportOverview,
    RouteName.financeReportDetail,
    RouteName.financeReportSummary,
    RouteName.financeReportStatement,
    RouteName.financeReportAccountFlow,
    RouteName.financeReportCustomerPrepayment,
    RouteName.financeReportRecon,
    RouteName.financeReportCost,
    RouteName.financeReportGl,
  ],
  RouteName.production: const [
    // 2026-09-24 三段式：任务中心置顶（调度台更名生产任务中心）+ 两个审批队列；
    // 计划/日报列表卡撤下（浏览走任务中心与既有深链），新建卡直达分析/新建页。
    RouteName.productionSchedule,
    RouteName.productionOverproductionRateRequests,
    RouteName.productionMaterialIncrementRequests,
    RouteName.productionMaterialAnalysis,
    '/production/daily-reports/new',
    '/production/reports/plan-detail',
    '/production/reports/plan-summary',
    RouteName.productionWhereUsed,
    RouteName.productionChainHealth,
  ],
  RouteName.purchase: [
    RouteName.operationsPurchaseWorkbench,
    RouteName.procurementArrivalExceptions,
    // 2026-09-24 三段式：订货/收货/退货 creator-only 新建卡 + 催料跟单入口；
    // 「计划下达的采购申请」只读卡已撤（浏览走任务中心「申请待分解」段）。
    for (final seg in const ['orders', 'receipts', 'returns'])
      RoutePath.purchaseDocNew(seg),
    '/purchase/report/expediting',
    for (final kind in const ['detail', 'summary'])
      '${RouteName.purchaseReport}/$kind',
  ],
  RouteName.sales: [
    // 2026-09-24 三段式：任务中心一张卡 + 新建单据五卡（creator-only，
    // 直达 /new）；列表页与订单进度查询不再是 hub 卡（浏览收进任务中心）。
    RouteName.salesTasks,
    for (final seg in const [
      'quotes',
      'orders',
      'shipments',
      'customer-shipments',
      'returns',
    ])
      '/sales/$seg/new',
    '${RouteName.salesReport}/detail',
    '${RouteName.salesReport}/summary',
    RouteName.salesScarcity,
  ],
  RouteName.subcontract: [
    RouteName.operationsSubcontractWorkbench,
    RouteName.subcontractShortDeliveries,
    RouteName.procurementArrivalExceptions,
    // 2026-09-24 三段式：订货/成品退回/余料退回/损耗改 creator-only 新建卡；
    // 历史 BOM 子件发料是只读历史，保留列表入口。
    for (final seg in const ['orders', 'returns', 'material-returns', 'wastes'])
      '/subcontract/$seg/new',
    '/subcontract/material-issues',
    for (final kind in const ['detail', 'summary', 'in-out-status'])
      '${RouteName.subcontractReport}/$kind',
  ],
};

/// 去掉查询参数与片段，只留路径(hub 卡片可能带 `?orderType=` 之类的参数)。
String hubCardPath(String location) =>
    Uri.tryParse(location)?.path ?? location.split('?').first;

/// 该路径是否为某个 hub 的入口。
bool isHubLocation(String location) =>
    hubCardLocations.containsKey(hubCardPath(location));

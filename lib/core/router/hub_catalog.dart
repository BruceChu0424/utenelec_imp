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
    RouteName.warehouseOutboundTasks,
    RouteName.warehouseInboundTasks,
    RouteName.warehouseDrawTasks,
    RouteName.warehouseQualityResults,
    RoutePath.stockDocList('TRANSFER'),
    RoutePath.stockDocList('CHECK'),
    RouteName.warehouseSubcontractFinishedReturnHistory,
    RouteName.warehouseSubcontractWasteHistory,
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
    RouteName.productionSchedule,
    RouteName.productionMaterialAnalysis,
    RouteName.productionPlanList,
    RouteName.productionOverproductionRateRequests,
    RouteName.productionMaterialIncrementRequests,
    RouteName.productionDailyReportList,
    '/production/reports/plan-detail',
    '/production/reports/plan-summary',
    RouteName.productionWhereUsed,
    RouteName.productionChainHealth,
  ],
  RouteName.purchase: [
    RouteName.operationsPurchaseWorkbench,
    RouteName.procurementArrivalExceptions,
    for (final seg in const ['requests', 'orders', 'receipts', 'returns']) ...[
      '/purchase/$seg',
      RoutePath.purchaseDocNew(seg),
    ],
    for (final kind in const ['detail', 'summary', 'expediting'])
      '${RouteName.purchaseReport}/$kind',
  ],
  RouteName.sales: [
    RouteName.salesOrderProgress,
    for (final seg in const [
      'quotes',
      'orders',
      'shipments',
      'customer-shipments',
      'other-shipments',
      'returns',
    ]) ...['/sales/$seg', '/sales/$seg/new'],
    '${RouteName.salesReport}/detail',
    '${RouteName.salesReport}/summary',
    RouteName.salesScarcity,
  ],
  RouteName.subcontract: [
    RouteName.operationsSubcontractWorkbench,
    RouteName.subcontractShortDeliveries,
    RouteName.procurementArrivalExceptions,
    for (final seg in const [
      'orders',
      'returns',
      'material-returns',
      'wastes',
      'material-issues',
    ])
      '/subcontract/$seg',
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

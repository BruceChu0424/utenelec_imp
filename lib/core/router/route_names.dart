// 路由名称常量
// 文档：docs/05-架构/路由设计.md
import '../../features/stock/models/instant_inventory_scope.dart';

/// Defines which portal may consume a preserved post-authentication route.
enum ReturnToScope { any, employee, visitor }

/// Validates and canonicalizes an in-app post-authentication route.
///
/// Only absolute paths inside this application are accepted. Authentication
/// and entry routes are rejected to prevent redirect loops.
String? sanitizeReturnTo(String? candidate, {required ReturnToScope scope}) {
  if (candidate == null ||
      candidate.isEmpty ||
      candidate != candidate.trim() ||
      !candidate.startsWith('/') ||
      candidate.startsWith('//') ||
      candidate.contains(r'\')) {
    return null;
  }

  final uri = Uri.tryParse(candidate);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      !uri.path.startsWith('/') ||
      uri.path.startsWith('//') ||
      _isAuthenticationLoop(uri.path)) {
    return null;
  }

  final visitorPath =
      uri.path == '/visitor' || uri.path.startsWith('/visitor/');
  if (scope == ReturnToScope.employee && visitorPath) return null;
  if (scope == ReturnToScope.visitor && !visitorPath) return null;
  return uri.toString();
}

/// Reads a validated `returnTo` value from [uri].
String? returnToFromUri(Uri uri, {required ReturnToScope scope}) {
  return sanitizeReturnTo(uri.queryParameters['returnTo'], scope: scope);
}

/// Returns a carried `returnTo`, or the current route when no value is carried.
String? intendedReturnTo(Uri uri, {required ReturnToScope scope}) {
  if (uri.queryParameters.containsKey('returnTo')) {
    return returnToFromUri(uri, scope: scope);
  }
  return sanitizeReturnTo(uri.toString(), scope: scope);
}

bool _isAuthenticationLoop(String path) {
  return _isRouteOrDescendant(path, RouteName.entry) ||
      _isRouteOrDescendant(path, RouteName.login) ||
      _isRouteOrDescendant(path, RouteName.changePassword) ||
      _isRouteOrDescendant(path, RouteName.visitorLogin);
}

bool _isRouteOrDescendant(String path, String route) =>
    path == route || path.startsWith('$route/');

/// 路由路径常量
abstract final class RouteName {
  static const String login = '/login';
  static const String home = '/';
  static const String dashboard = '/dashboard';
  static const String accessDenied = '/access-denied';
  static const String notFound = '/not-found';
  static const String profile = '/profile';
  static const String settings = '/settings';
  static const String deviceAuditReceipts = '/settings/device-receipts';
  static const String changePassword = '/change-password';
  static const String department = '/department';

  // 基础资料（hub 与详情均按对应主档查看权限守卫）
  // /basicinfo       = 资料入口 hub（货品资料 / 模具资料 / ...）
  // /basicinfo/goods = 货品资料（分类树 + 货品）
  // /basicinfo/mould = 模具资料（分类树 + 模具）
  static const String basicinfo = '/basicinfo';
  static const String basicinfoGoods = '/basicinfo/goods';
  // 货品新增 / 详情整页（列表「添加货品」/ 双击行进；静态段 new 须在 :id 前注册）。
  static const String basicinfoGoodsNew = '/basicinfo/goods/new';
  static const String basicinfoGoodsDetail = '/basicinfo/goods/:id';
  static const String basicinfoMould = '/basicinfo/mould';
  static const String basicinfoClient = '/basicinfo/client';
  static const String basicinfoClientDetail = '/basicinfo/client/:id';
  static const String basicinfoSupplier = '/basicinfo/supplier';
  static const String basicinfoSupplierDetail = '/basicinfo/supplier/:id';
  static const String basicinfoColor = '/basicinfo/color';
  static const String basicinfoUnit = '/basicinfo/unit';
  static const String basicinfoCurrency = '/basicinfo/currency';
  static const String basicinfoWarehouse = '/basicinfo/warehouse';
  static const String basicinfoAccount = '/basicinfo/account';
  static const String basicinfoAccountDetail = '/basicinfo/account/:id';
  static const String basicinfoPaymentStyle = '/basicinfo/payment-style';
  static const String basicinfoSettlementMethod =
      '/basicinfo/settlement-methods';

  // 工资条
  static const String payrollSlipList = '/payroll/slip';
  static const String payrollSlipDetail = '/payroll/slip/:id';

  // 报销
  static const String expense = '/expense';
  static const String expenseNew = '/expense/new';
  static const String expenseEdit = '/expense/:id/edit';
  static const String expenseDetail = '/expense/:id';

  // 通知
  static const String notice = '/notice';
  static const String noticePublish = '/notice/publish';
  static const String noticeDetail = '/notice/:id';

  // 建议
  static const String suggestion = '/suggestion';
  static const String suggestionNew = '/suggestion/new';
  static const String suggestionDetail = '/suggestion/:id';

  // 官网询盘
  static const String websiteInquiry = '/webinquiry';
  static const String websiteInquiryDetail = '/webinquiry/:id';

  // 独立草稿页(基础资料/建议箱/HR 工作台/品质任务中心顶栏「草稿」按钮落点，
  // :categoryId 见 shared/drafts/form_drafts_page.dart 注册表)
  static const String formDrafts = '/form-drafts/:categoryId';
  static String formDraftsLocation(String categoryId) =>
      '/form-drafts/$categoryId';

  // 员工档案
  static const String employee = '/employee';
  static const String employeeDetail = '/employee/:id';

  // 个人信息修改
  static const String profileEdit = '/profile/edit';
  static const String profileMyChanges = '/profile/me/changes';
  static const String profileMyDepartment = '/profile/me/department';
  // 我的车辆与号码(/profile/me/vehicles)、我的文件(/profile/me/documents)
  // 独立路由已下线：内容吸收为「我的」页 Tab（我的页 v7）。

  // HR 端：员工个人信息修改审批
  static const String hrProfileChanges = '/hr/profile-changes';
  static const String hrProfileChangeDetail = '/hr/profile-changes/:id';

  // HR 端：工作台（今日概览 + 事务办理子页，ADR-021）
  static const String hrTaskCenter = '/hr/tasks';
  static String hrTaskList(String type) => '/hr/tasks/$type';

  /// 员工资料核对更正页(ADR-160)：静态段，注册时须先于 :type 子路由声明。
  static const String hrReconcile = '/hr/tasks/reconcile';

  // 入口选择页已退役(2026-09-25)：/entry 仅作旧深链兼容，由 redirect 落到 /login。
  static const String entry = '/entry';

  // 访客端（独立流程，不进 ShellRoute）。
  // 2026-09-25 访客门户前端下线：redirect 把 /visitor* 全部拦到员工登录页，
  // 常量与页面代码保留（后端访客能力不动），将来另做独立入口时恢复。
  static const String visitorLogin = '/visitor/login';
  static const String visitorHome = '/visitor/home';
  static const String visitorSettings = '/visitor/settings';
  static const String visitorApply = '/visitor/apply';
  static const String visitorApplyDetail = '/visitor/apply/:id';

  // 访客审批 / 被访人 / 保安（员工登录后，进 ShellRoute）
  static const String visitorApproval = '/visitor-approval';
  static const String visitorApprovalDetail = '/visitor-approval/:id';
  static const String myVisitors = '/my-visitors';
  static const String securityScan = '/security/scan';
  static const String securityBlacklist = '/security/blacklist';

  // 账号支持 + 超级管理员授权管理
  static const String adminPermissions = '/admin/permissions';
  // 审计中心（独立 audit_log:view 只读核查；导出另需 audit_log:export）
  static const String adminAuditLogs = '/admin/audit-logs';
  static const String adminAuditSession =
      '/admin/audit-logs/sessions/:sessionId';
  // 系统设置（安全/业务策略阈值；超管 authorization:manage，改设置二次密码确认）
  static const String adminSystemSettings = '/admin/system-settings';
  static const String adminServerStatus = '/admin/server-status';
  // AI 服务设置(ADR-133: 服务商/密钥/连接测试; 超管, 写操作再认证)
  static const String adminAiSettings = '/admin/ai-settings';
  // AI 用量看板与按人限额(ADR-164): 看板 + 人员详情; 超管 authorization:manage。
  static const String adminAiUsage = '/admin/ai-usage';
  static const String adminAiUsagePersonRoute = '/admin/ai-usage/:userId';
  static String adminAiUsagePerson(String userId) =>
      '/admin/ai-usage/${Uri.encodeComponent(userId)}';

  // 财税部主数据别名入口（复用基础资料真实页面）
  static const String financeCustomers = '/finance/customers';
  static const String financeSuppliers = '/finance/suppliers';
  static const String financeAccounts = '/finance/accounts';

  // 统一履约任务工作台（仓库 / 采购 / 委外）。
  static const String operationsWarehouseWorkbench =
      '/operations/workbench/warehouse';
  static const String operationsPurchaseWorkbench =
      '/operations/workbench/purchase';
  static const String operationsSubcontractWorkbench =
      '/operations/workbench/subcontract';

  /// 委外领料页(ADR-143 §4.2)：委外任务中心子路由，?orderItemIds=a,b。
  static const String operationsSubcontractDrawRequest =
      '/operations/workbench/subcontract/draw-request';

  /// 委外领料页深链：带入要领料的委外订货明细(一次最多 50 个)。
  static String operationsSubcontractDrawRequestFor(
    Iterable<String> orderItemIds,
  ) => Uri(
    path: operationsSubcontractDrawRequest,
    queryParameters: {'orderItemIds': orderItemIds.join(',')},
  ).toString();

  /// 委外任务中心「领料」分段深链(可领料通知、进行中「可领料」跳转)：
  /// ?segment=draw，可按委外订货明细 [orderItemId] 或订货单 [orderId] 定位。
  static String operationsSubcontractDrawSegment({
    String? orderItemId,
    String? orderId,
  }) => Uri(
    path: operationsSubcontractWorkbench,
    queryParameters: {
      'segment': 'draw',
      if (orderItemId != null && orderItemId.isNotEmpty)
        'orderItemId': orderItemId,
      if (orderId != null && orderId.isNotEmpty) 'orderId': orderId,
    },
  ).toString();

  /// 委外任务中心「待处理」分段深链(ADR-156 可下单通知)：?segment=pending，
  /// 可带委外申请号 [keyword] 进页即按它搜索。
  static String operationsSubcontractPendingSegment({String? keyword}) => Uri(
    path: operationsSubcontractWorkbench,
    queryParameters: {
      'segment': 'pending',
      if (keyword != null && keyword.trim().isNotEmpty)
        'keyword': keyword.trim(),
    },
  ).toString();

  // 工程研发部任务中心（设计 / 打样 / 试产 / ECN 及历史任务）。
  static const String rdTaskCenter = '/rd/tasks';

  // 采购管理（PMC 运营部）：hub + 4 单据列表。
  // new/detail/edit 走 RoutePath.purchaseDoc*(doc,id) 带参；doc=requests|orders|receipts|returns。
  static const String purchase = '/purchase';
  static const String purchaseRequestList = '/purchase/requests';
  static const String purchaseOrderList = '/purchase/orders';
  static const String purchaseReceiptList = '/purchase/receipts';
  static const String purchaseReturnList = '/purchase/returns';
  static const String purchaseReport = '/purchase/report';

  // 库存查询（库存管理）：余额 + 出入库流水 + 即时库存。
  static const String stockBalance = '/stock/balance';
  static const String stockMovement = '/stock/movement';
  static const String stockInstantInventory = '/stock/instant-inventory';
  static const String stockInstantInventoryOverview =
      '/stock/instant-inventory/overview';

  /// 库存详情 (即时库存双击进入)：该货品各仓余额 + 出入库流水 + 单重学习。
  /// balance/movement 两页已并入 (旧路由重定向保深链)。
  /// [tab]：balance=库存余额(默认) / ledger=出入库流水 / weight=单重学习 (ADR-135)。
  static const String stockItemBase = '/stock/item';
  static String stockItemDetail(
    String goodsId, {
    String? tab,
    InstantInventoryScope? scope,
    String? returnTo,
  }) {
    final path = '$stockItemBase/${Uri.encodeComponent(goodsId.trim())}';
    final key = tab?.trim() ?? '';
    final query = {
      if (key.isNotEmpty) 'tab': key,
      ...?scope?.toQuery(),
      if (scope != null) 'inventoryOnly': '${scope.inventoryOnly}',
      'returnTo': ?returnTo,
    };
    return query.isEmpty
        ? path
        : Uri(path: path, queryParameters: query).toString();
  }

  // 仓库管理（8 单据 hub + 列表 + new/detail/edit + 报表）。
  static const String warehouse = '/warehouse';
  static const String warehouseReport = '/warehouse/report';
  static const String warehouseReportDetail = '/warehouse/report/detail';
  static const String warehouseReportSummary = '/warehouse/report/summary';
  static const String warehouseInboundExpectations =
      '/warehouse/inbound/expectations';

  static const String warehouseDocumentHistory = '/warehouse/history';
  static const String warehousePurchaseReceiptHistory =
      '/warehouse/history/purchase-receipts';
  static const String warehouseSubcontractReceiptHistory =
      '/warehouse/history/subcontract-receipts';
  static const String warehouseSubcontractOutboundHistory =
      '/warehouse/history/subcontract-material-issues';
  static const String warehouseSubcontractFinishedReturnHistory =
      '/warehouse/history/subcontract-returns';
  static const String warehouseSubcontractMaterialReturnHistory =
      '/warehouse/history/subcontract-material-returns';
  static const String warehouseSubcontractWasteHistory =
      '/warehouse/history/subcontract-wastes';
  static const String warehouseIqcReturns = '/warehouse/iqc-returns';
  static const String warehouseIqcStockIns = '/warehouse/iqc-stock-ins';

  /// 品质部检查结果（原 IQC 合格待入库 + IQC 不合格实物退回的合并任务中心）。
  static const String warehouseQualityResults = '/warehouse/quality-results';

  /// 待入库多选「批量入库」页（2026-09-12 弹窗改页；extra 带所选任务）。
  /// 静态段，须先于 :receiptType/:receiptId 声明。
  static const String warehouseQualityBatchStockIn =
      '$warehouseQualityResults/batch-stock-in';

  /// 先入库后质检(V596)：把等待检查结果的收货单逐行上架(实际叶仓 + 库位)。
  /// 静态前缀段，须先于 :receiptType/:receiptId 声明。
  static const String warehouseQualityPreStockInBase =
      '$warehouseQualityResults/pre-stock-in';

  static String warehouseQualityPreStockIn(
    String receiptType,
    String receiptId,
  ) =>
      '$warehouseQualityPreStockInBase/${Uri.encodeComponent(receiptType.trim().toUpperCase())}/'
      '${Uri.encodeComponent(receiptId.trim())}';

  /// 品质检查结果详情完整页（列表双击进入；旧 IQC 待入库详情深链重定向至此）。
  static String warehouseQualityResultDetail(
    String receiptType,
    String receiptId,
  ) =>
      '$warehouseQualityResults/${Uri.encodeComponent(receiptType.trim().toUpperCase())}/'
      '${Uri.encodeComponent(receiptId.trim())}';

  /// 登记实际到货页(ADR-151 §5 单批合一)：预计到货双击 = 1 个来源、多选 = N 个来源，同一个页面；
  /// 来源身份走 `?expectationIds=a,b`(刷新、草稿恢复都能重新读到)，路线走 `?preStock=1|0`。
  static const String warehouseArrivalRegistration =
      '/warehouse/inbound/arrivals/register';

  /// 采购/委外 IQC 待检处置任务中心（sidecar 前端入口）+ 单据处置页。
  static const String warehouseInspections = '/warehouse/inspections';

  /// 待检处置多选后的「批量审批」汇总页（extra 携带 QualityBatchApprovalSelection）。
  static const String warehouseInspectionBatchApproval =
      '/warehouse/inspections/batch-approval';

  /// 单张收货单的待检明细处置页（任务中心卡片点入；静态段，须先于 /warehouse/:code）。
  static String warehouseInspectionDetail(
    String receiptType,
    String receiptId,
  ) => '/warehouse/inspections/$receiptType/$receiptId';
  static const String warehouseArrivalExceptions =
      '/warehouse/inbound/arrival-exceptions';

  /// 生产报工生成、等待仓库逐行实收的 FINISHED_IN 权威任务队列。
  static const String warehouseProductionFinishedInboundTasks =
      '/warehouse/production-finished-in/tasks';

  /// 待点收多选「批量全量点收入库」页（2026-09-12 弹窗改页；extra 带所选任务）。
  static const String warehouseProductionFinishedBatchStockIn =
      '/warehouse/production-finished-in/batch-stock-in';

  /// 产成品登记实际入库页(ADR-151 §5 单批合一)：双击 = 1 张报工、多选 = N 张报工，同一个页面；
  /// 来源走 `?reportIds=a,b`，路线走 `?preStock=1|0`(不带 = 两条路线并排)。
  static const String warehouseProductionFinishedArrivalRegistrationBase =
      '/warehouse/production-finished-in/arrival-registrations';
  static const String warehouseProductionFinishedArrivalRegistration =
      warehouseProductionFinishedArrivalRegistrationBase;

  /// 品质管理部任务中心（待检处置等品质任务的统一入口）。
  static const String qualityTaskCenter = '/quality/task-center';
  static const String qualityInspectionRecords = '/quality/inspection-records';
  static const String productionFqcInspections =
      '/quality/production-inspections';

  /// FQC 检查单办理页 / 单任务办理页（2026-09-12 弹窗改页，对齐采购 IQC 处置页；
  /// 挂在待检处置前缀下复用其权限面）。
  static const String productionFqcSheetHandlingBase =
      '$warehouseInspections/fqc/sheets';
  static String productionFqcSheetHandling(String sheetId) =>
      '$productionFqcSheetHandlingBase/${Uri.encodeComponent(sheetId.trim())}';
  static const String productionFqcInspectionHandlingBase =
      '$warehouseInspections/fqc/inspections';
  static String productionFqcInspectionHandling(String inspectionId) =>
      '$productionFqcInspectionHandlingBase/'
      '${Uri.encodeComponent(inspectionId.trim())}';

  /// 货架目视化清单（库位号驱动的挂牌打印/导出；静态段，须先于 /warehouse/:code）。
  static const String warehouseShelfLabels = '/warehouse/shelf-labels';

  /// 库存分析 (ADR-135；呆滞与库龄 / 盘点建议 / 称重异常 / 单重学习；stock_report:view；
  /// 静态段，须先于 /warehouse/:code)。
  static const String warehouseInsights = '/warehouse/insights';

  /// 独立称重计数页 (ADR-135；手机放秤旁：选货品 → 称重折算件数，可保存抽样；
  /// stock:view，保存抽样另需称样权限；静态段，须先于 /warehouse/:code)。
  static const String warehouseWeighCount = '/warehouse/weigh-count';

  /// 委外出仓任务中心与拣货出仓页（仓库专属，静态段须先于 /warehouse/:code）。
  /// 一行 = 一张委外人员已提交、仓库未发出的领料出仓草稿(ADR-143 §4.3)。
  static const String warehouseSubcontractOutbound =
      '/warehouse/subcontract-outbound';

  /// 拣货出仓页：按领料出仓草稿(委外材料出仓单) id 打开。
  static String warehouseSubcontractOutboundDetail(String issueId) =>
      '/warehouse/subcontract-outbound/$issueId';

  /// 财务已放行的销售出货仓库作业工作台（静态段须先于 /warehouse/:code）。
  static const String warehouseSalesOutbound = '/warehouse/sales-outbound';

  // —— 仓库任务中心（2026-09-24 四卡合并页；静态段 tasks 须先于 /warehouse/:code）——
  /// 仓库任务中心：出库 / 入库 / 生产领料 / 品质检查结果 / 委外成品退货 /
  /// 委外损耗 六个大类的一站式入口（?group= 深链预设大类）。
  static const String warehouseTasks = '/warehouse/tasks';

  /// 出库任务中心：销售出库（待出库/已出库历史）+ 委外出仓（任务/出仓
  /// 历史）+ 其它出库 + 产成品出库（各自新建/历史）。
  static const String warehouseOutboundTasks = '/warehouse/tasks/outbound';

  /// 入库任务中心：采购入库（预计到货/到货异常/收货历史）+ 委外入库（预计到货/收货
  /// 历史）+ 产成品入库（待点收任务/进仓单据）+ 其它入库（新建/历史）。
  static const String warehouseInboundTasks = '/warehouse/tasks/inbound';

  /// 生产领料任务中心：待领任务（履约备料）+ 领料单（新建/历史/出库进度）+ 生产退料。
  /// 多选领料单完整详情，documentIds 查询参数承接跨页选择并支持刷新。
  static const String warehouseProductionDrawBatchIssue =
      '/warehouse/DRAW/batch-issue';

  static const String warehouseDrawTasks = '/warehouse/tasks/draw';

  // —— 车间内料仓 (ADR-131) ——
  /// 车间内料仓设置: 车间开启 / 机台与容器 / 上线准备 (静态段须先于 /warehouse/:code)。
  static const String workshopMaterialSetup =
      '/warehouse/workshop-material/setup';

  /// 车间内料仓页: 现存、申请领料 / 退回 / 其它耗用、盘点与结算状态 (?workshopId=)。
  static const String workshopMaterialBin = '/workshop-material/bin';

  /// 仓库发料页: 按申请发料、直接发料、收退回 (?requisitionId= 或 ?mode=direct)。
  static const String workshopMaterialIssue = '/workshop-material/issue';

  /// 盘点页 (手机优先; ?periodId=)。
  static const String workshopMaterialCount = '/workshop-material/count';

  /// 车间内料仓用量报表与结算页 (生产、钱流报表入口)。
  static const String workshopMaterialReports = '/reports/workshop-material';
  static const String stockCountRequests = '/stock/count-requests';
  static const String financeStockCountReview = '/finance/stock-count-review';
  static const String warehouseStockCountReview =
      '/warehouse/stock-count-review';

  static const String procurementArrivalExceptions =
      '/procurement/arrival-exceptions';
  static const String procurementIqcRejections = '/procurement/iqc-rejections';
  static const String financeArrivalExceptions =
      '/finance/procurement-arrival-exceptions';

  // 销售管理（综合营销部）：hub + 5 单据 + 报表。
  // new/detail/edit 走 RoutePath.salesDoc*；seg = quotes|orders|shipments|other-shipments|returns。
  static const String sales = '/sales';
  static const String salesScarcity = '/sales/scarcity';
  static const String salesOrderProgress = '/sales/progress';

  /// 销售任务中心（2026-09-24 三段式）：订货进度 + 出货/零星/退货/报价 +
  /// 历史其它出货的一站式查看入口（?group= 深链预设大类）。
  static const String salesTasks = '/sales/tasks';
  static const String salesReport = '/sales/report';
  static const String salesReportDetail = '/sales/report/detail';
  static const String salesReportSummary = '/sales/report/summary';

  // 委外管理（综合营销部）：hub + 8 单据 + 报表。
  // seg = inquiries|applications|orders|receipts|material-issues|returns|material-returns|wastes。
  static const String subcontract = '/subcontract';
  static const String subcontractReport = '/subcontract/report';

  /// 委外回厂短交判定页（ADR-098）：?caseId= 定位案件、?orderId= / ?supplierId= 过滤。
  static const String subcontractShortDeliveries =
      '/subcontract/short-deliveries';

  /// 判定页深链：只看某张订货单 / 某个委外商的案件（任务中心状态列、供应商详情用）。
  static String subcontractShortDeliveriesWith({
    String? orderId,
    String? supplierId,
    String? caseId,
  }) {
    final params = <String, String>{
      if (orderId != null && orderId.isNotEmpty) 'orderId': orderId,
      if (supplierId != null && supplierId.isNotEmpty) 'supplierId': supplierId,
      if (caseId != null && caseId.isNotEmpty) 'caseId': caseId,
    };
    if (params.isEmpty) return subcontractShortDeliveries;
    return Uri(
      path: subcontractShortDeliveries,
      queryParameters: params,
    ).toString();
  }

  // 生产管理（生产部）：hub + 调度 + 计划单 + 日报 + 4 报表入口。
  static const String production = '/production';
  static const String productionSchedule = '/production/schedule';
  static const String productionProgress = '/production/progress';
  static const String productionWorkshopTasks = '/production/workshop-tasks';
  static const String productionOverproductionRateRequests =
      '/production/overproduction-rate-requests';
  static const String productionMaterialIncrementRequests =
      '/production/material-increment-requests';
  static const String productionDrawRequest =
      '/production/workshop-tasks/draw-request';
  static const String productionBatchDraw =
      '/production/workshop-tasks/batch-draw';
  static const String productionMaterialAnalysis =
      '/production/material-analysis';
  static const String productionMaterialAnalysisHistory =
      '/production/material-analyses';
  static const String productionPlanList = '/production/plans';
  static const String productionDailyReportList = '/production/daily-reports';
  static const String productionWhereUsed = '/production/where-used';
  static const String productionChainHealth = '/production/chain-health';
  // /production/reports/{plan-detail|plan-summary} 用 RoutePath 助手（当前仅注册 2 段）。

  // 钱流管理（财税部）：hub + 5 单据 + AR/AP 台账 + 对账 + 支票 + 报表。
  // seg = receipts|payments|expenses|incomes|bank-transfers。
  static const String finance = '/finance';

  /// 业务审核中心：财务全部审核/审批队列的一站式分段工作台（原 hub 任务中心
  /// 6 张卡的合并入口；?segment= 深链到具体队列分段）。
  static const String financeAudits = '/finance/audits';

  /// 销售出货财务人工放行工作台。
  static const String financeSalesShipmentAudit =
      '/finance/sales-shipment-audits';

  /// 出货财务审核详情（财务专用审核视图，与销售端出货详情分离）。
  static const String financeSalesShipmentAuditReview =
      '/finance/sales-shipment-audits/:id';

  /// 销售报价财务核价(ADR-134)：待核价 / 已核价 / 已退回 三个分段。
  static const String financeQuoteReview = '/finance/quote-review';

  /// 报价核价详情：认领后可改价、退回销售、确认报价、撤销确认。
  static const String financeQuoteReviewDetail = '/finance/quote-review/:id';
  static const String financeArAp = '/finance/ar-ap';
  static const String financePayables = '/finance/payables';
  static const String financeReconciliations = '/finance/reconciliations';
  static const String financeChecks = '/finance/checks';
  static const String financeReport = '/finance/report';
  // 钱流报表 5 卡（镜像销售「明细+汇总+单独卡」）。
  static const String financeReportDetail = '/finance/report/detail';
  static const String financeReportSummary = '/finance/report/summary';
  static const String financeReportOverview = '/finance/report/overview';
  static const String financeReportStatement = '/finance/report/statement';
  static const String financeReportAccountFlow = '/finance/report/account-flow';
  static const String financeReportCustomerPrepayment =
      '/finance/report/customer-prepayment';
  // C2 对账单（委外加工/采购外放/供应商/其他应收/客户 5 chip）。
  static const String financeReportRecon = '/finance/report/recon';
  // C4 成本核算（产品成本/销售成本/铜柱加工费/酸洗明细/塑料耗用 8 chip）。
  static const String financeReportCost = '/finance/report/cost';
  // C3 总账报表（科目余额表+附 9~16 共 8 chip）。
  static const String financeReportGl = '/finance/report/gl';
  // C5 资产与待摊专业工作台（台账/审批/不可变月度批次；核心落账默认门禁关闭）。
  static const String financeAssets = '/finance/assets';
}

/// 路径拼接工具（带参数的路由）
abstract final class RoutePath {
  /// Entry page with an optional route preserved for portal selection.
  ///
  /// 入口选择页已退役(2026-09-25)：/entry 由 redirect 兼容重定向到 /login，
  /// 此助手仅供旧深链/测试沿用。
  static String entry({String? returnTo}) => _withReturnTo(
    RouteName.entry,
    returnTo: returnTo,
    scope: ReturnToScope.any,
  );

  /// Employee login page with an optional post-login route.
  static String login({String? returnTo}) => _withReturnTo(
    RouteName.login,
    returnTo: returnTo,
    scope: ReturnToScope.employee,
  );

  /// Visitor login page with an optional post-login route.
  static String visitorLogin({String? returnTo}) => _withReturnTo(
    RouteName.visitorLogin,
    returnTo: returnTo,
    scope: ReturnToScope.visitor,
  );

  /// Password-change page, preserving the employee route through forced mode.
  static String changePassword({bool forced = false, String? returnTo}) {
    final safe = sanitizeReturnTo(returnTo, scope: ReturnToScope.employee);
    final query = <String, String>{
      if (forced) 'forced': 'true',
      'returnTo': ?safe,
    };
    return query.isEmpty
        ? RouteName.changePassword
        : Uri(
            path: RouteName.changePassword,
            queryParameters: query,
          ).toString();
  }

  static String _withReturnTo(
    String path, {
    required String? returnTo,
    required ReturnToScope scope,
  }) {
    final safe = sanitizeReturnTo(returnTo, scope: scope);
    return safe == null
        ? path
        : Uri(path: path, queryParameters: {'returnTo': safe}).toString();
  }

  static String payrollSlipDetail(String id) => '/payroll/slip/$id';

  static String warehouseDocumentHistoryDetail(String segment, String id) =>
      '/warehouse/history/$segment/$id';

  static String warehouseSalesOutboundDetail(String id) =>
      '${RouteName.warehouseSalesOutbound}/$id';

  static String adminAuditSession(String sessionId, {int? snapshotAuditId}) {
    final path =
        '${RouteName.adminAuditLogs}/sessions/'
        '${Uri.encodeComponent(sessionId.trim())}';
    return snapshotAuditId == null || snapshotAuditId <= 0
        ? path
        : Uri(
            path: path,
            queryParameters: {'snapshotAuditId': snapshotAuditId.toString()},
          ).toString();
  }

  static String adminAuditInvestigation(String requestId) => Uri(
    path: RouteName.adminAuditLogs,
    queryParameters: {'requestId': requestId.trim()},
  ).toString();

  /// 货品资料：新增 / 详情整页。[tab] 为页签名 basic (基本信息, 默认) / bom (组装信息) /
  /// cost (成本预算) / files (图片和文件) / stock (库存与出入库)，路由原样透传 ?tab= (ADR-135；
  /// 详情页仍认旧深链的数字 0/1/2)。
  static String basicinfoGoodsNew(String categoryId) =>
      '/basicinfo/goods/new?categoryId=$categoryId';
  static String basicinfoGoodsDetail(String id, {String? tab}) {
    final path = '/basicinfo/goods/${Uri.encodeComponent(id.trim())}';
    final key = tab?.trim() ?? '';
    return key.isEmpty
        ? path
        : Uri(path: path, queryParameters: {'tab': key}).toString();
  }

  static String basicinfoAccountDetail(String id, {bool edit = false}) =>
      edit ? '/basicinfo/account/$id?edit=true' : '/basicinfo/account/$id';
  static String expenseDetail(String id) => '/expense/$id';
  static String expenseEdit(String id) => '/expense/$id/edit';
  static String noticeDetail(String id) => '/notice/$id';
  static String suggestionDetail(String id) => '/suggestion/$id';
  static String websiteInquiryDetail(String id) => '/webinquiry/$id';
  static String employeeDetail(String id) => '/employee/$id';
  static String basicinfoClientDetail(String id) => '/basicinfo/client/$id';
  static String basicinfoSupplierDetail(String id) => '/basicinfo/supplier/$id';
  static String employeeEdit(String id) => '/employee/$id/edit';

  /// 采购单据：新建 / 详情 / 编辑。[doc] = requests|orders|receipts|returns。
  static String purchaseDocNew(String doc) => '/purchase/$doc/new';
  static String purchaseDocDetail(String doc, String id) =>
      '/purchase/$doc/$id';
  static String purchaseDocEdit(String doc, String id) =>
      '/purchase/$doc/$id/edit';
  static String purchaseReportTable(String kind) => '/purchase/report/$kind';

  /// 仓库单据：列表 / 新建 / 详情 / 编辑。[code] = TRANSFER|OTHER_IN|...|CHECK。
  static String stockDocList(String code) => '/warehouse/$code';
  static String stockDocNew(String code) => '/warehouse/$code/new';
  static String stockDocDetail(String code, String id) =>
      '/warehouse/$code/$id';
  static String stockDocEdit(String code, String id) =>
      '/warehouse/$code/$id/edit';

  /// 员工资料核对更正页深链(ADR-160)：[employeeIds] = 证件核对多选的员工
  /// UUID(逗号拼接进 query)；[planId] = 核对记录回看。查询参数只放 UUID，绝不放证件号。
  static String hrReconcile({
    List<String>? employeeIds,
    String? planId,
    String? returnTo,
  }) {
    final ids = employeeIds
        ?.map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .join(',');
    final safeReturnTo = sanitizeReturnTo(
      returnTo,
      scope: ReturnToScope.employee,
    );
    final employeeParam = ids == null || ids.isEmpty ? null : ids;
    return Uri(
      path: RouteName.hrReconcile,
      queryParameters: {
        'employeeIds': ?employeeParam,
        'planId': ?planId,
        'returnTo': ?safeReturnTo,
      },
    ).toString();
  }

  /// 产成品登记页深链(单张 = 1 个来源、多选 = N 个来源)：reportIds 逗号拼接进 query(可恢复)；
  /// [stockInBeforeInspection] = 任务中心多选时点的路线(`preStock=1|0`)，双击进来为空(两条路线并排)。
  static String warehouseProductionFinishedArrivalRegistration(
    List<String> reportIds, {
    String? returnTo,
    bool? stockInBeforeInspection,
  }) {
    final ids = reportIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .join(',');
    final safeReturnTo = sanitizeReturnTo(
      returnTo,
      scope: ReturnToScope.employee,
    );
    return Uri(
      path: RouteName.warehouseProductionFinishedArrivalRegistration,
      queryParameters: {
        'reportIds': ids,
        if (stockInBeforeInspection != null)
          'preStock': stockInBeforeInspection ? '1' : '0',
        'returnTo': ?safeReturnTo,
      },
    ).toString();
  }

  /// 登记实际到货页深链(单张 = 1 个来源、多选 = N 个来源)：expectationIds 逗号拼接进 query。
  static String warehouseArrivalRegistration(
    List<String> expectationIds, {
    bool? stockInBeforeInspection,
  }) {
    final ids = expectationIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .join(',');
    return Uri(
      path: RouteName.warehouseArrivalRegistration,
      queryParameters: {
        'expectationIds': ids,
        if (stockInBeforeInspection != null)
          'preStock': stockInBeforeInspection ? '1' : '0',
      },
    ).toString();
  }

  static String procurementArrivalException(String id) =>
      '/procurement/arrival-exceptions/$id';
  static String procurementIqcRejections({String? source}) => Uri(
    path: RouteName.procurementIqcRejections,
    queryParameters: {
      if (source?.trim().isNotEmpty == true) 'from': source!.trim(),
    },
  ).toString();
  static String procurementIqcRejectionDetail(String id, {String? source}) =>
      Uri(
        path:
            '${RouteName.procurementIqcRejections}/${Uri.encodeComponent(id)}',
        queryParameters: {
          if (source?.trim().isNotEmpty == true) 'from': source!.trim(),
        },
      ).toString();
  static String financeArrivalException(String id) =>
      '/finance/procurement-arrival-exceptions/$id';

  /// 报价核价详情(ADR-134)。
  static String financeQuoteReview(String id) =>
      '/finance/quote-review/${Uri.encodeComponent(id)}';

  /// 车间内料仓页深链 (ADR-131): 指定车间时带 ?workshopId=。
  static String workshopMaterialBin({String? workshopId}) =>
      _withQuery(RouteName.workshopMaterialBin, {'workshopId': workshopId});

  /// 仓库按申请发料 / 收退回。
  static String workshopMaterialIssueForRequisition(String requisitionId) =>
      _withQuery(RouteName.workshopMaterialIssue, {
        'requisitionId': requisitionId,
      });

  /// 仓库直接发料 (不经车间申请)。
  static String workshopMaterialDirectIssue() =>
      _withQuery(RouteName.workshopMaterialIssue, {'mode': 'direct'});

  /// 某一期的盘点页。
  static String workshopMaterialCount(String periodId) =>
      _withQuery(RouteName.workshopMaterialCount, {'periodId': periodId});

  /// 只带非空参数; 一个参数都没有时不留问号。
  static String _withQuery(String path, Map<String, String?> params) {
    final query = <String, String>{
      for (final entry in params.entries)
        if (entry.value?.trim().isNotEmpty == true)
          entry.key: entry.value!.trim(),
    };
    return query.isEmpty
        ? path
        : Uri(path: path, queryParameters: query).toString();
  }

  /// 员工修改审批单批详情（HR 端）。
  static String hrProfileChangeDetail(String id) => '/hr/profile-changes/$id';

  /// 销售单据：列表 / 新建 / 详情 / 编辑。
  /// [seg] = quotes|orders|shipments|other-shipments|returns。
  static String salesDocList(String seg) => '/sales/$seg';
  static String salesDocNew(String seg) => '/sales/$seg/new';
  static String salesDocDetail(String seg, String id) => '/sales/$seg/$id';
  static String salesDocEdit(String seg, String id) => '/sales/$seg/$id/edit';

  /// 销售订单进度详情（快递式全链路追踪整页）。
  static String salesOrderProgressDetail(String orderId) =>
      '/sales/progress/$orderId';

  /// 委外单据：列表 / 新建 / 详情 / 编辑。
  /// [seg] = inquiries|applications|orders|receipts|material-issues|returns|material-returns|wastes。
  static String subcontractDocList(String seg) => '/subcontract/$seg';
  static String subcontractDocNew(String seg) => '/subcontract/$seg/new';
  static String subcontractDocDetail(String seg, String id) =>
      '/subcontract/$seg/$id';
  static String subcontractDocEdit(String seg, String id) =>
      '/subcontract/$seg/$id/edit';

  /// 生产计划单 / 日报表：新建 / 详情 / 编辑。
  static String productionMaterialAnalysisSummary(String analysisId) =>
      '/production/material-analyses/$analysisId/summary';

  /// 物料分析关联销售订货单的只读货品清单(ADR-088)。
  /// 专用只读页，**不是**销售订单详情：无价格、无任何编辑动作。
  static String productionAnalysisSalesOrder(
    String analysisId,
    String orderId,
  ) => '/production/material-analyses/$analysisId/sales-orders/$orderId';
  static String productionPlanNew() => '/production/plans/new';
  static String productionPlanDetail(String id) => '/production/plans/$id';
  static String productionOverproductionRateRequest(String id) =>
      '/production/overproduction-rate-requests/$id';
  static String productionMaterialIncrementRequest(String id) =>
      '/production/material-increment-requests/$id';
  static String productionMaterialIncrementForSegment(String id) =>
      '/production/material-increment-requests/new?segmentId=$id';
  static String productionActualOutputSupplement(String id) =>
      '/production/actual-output-supplements/$id';
  static String productionPlanEdit(String id) => '/production/plans/$id/edit';
  static String productionDailyReportNew() => '/production/daily-reports/new';
  static String productionDailyReportCreateRecovery(
    String draftId, {
    bool returnToEditor = false,
  }) => Uri(
    path: '/production/daily-reports/create-recovery',
    queryParameters: {
      'draftId': draftId,
      if (returnToEditor) 'returnToEditor': '1',
    },
  ).toString();
  static String productionDailyReportDetail(String id) =>
      '/production/daily-reports/$id';
  static String productionDailyReportEdit(String id) =>
      '/production/daily-reports/$id/edit';

  /// 生产报表（当前注册 2 入口）。
  /// [seg] = plan-detail|plan-summary。
  static String productionReport(String seg) => '/production/reports/$seg';

  /// 钱流单据：列表 / 新建 / 详情 / 编辑。
  /// [seg] = receipts|payments|expenses|incomes|bank-transfers。
  static String financeDocList(String seg) => '/finance/$seg';
  static String financeDocNew(String seg) => '/finance/$seg/new';
  static String financeDocDetail(String seg, String id) => '/finance/$seg/$id';
  static String financeDocEdit(String seg, String id) =>
      '/finance/$seg/$id/edit';
}

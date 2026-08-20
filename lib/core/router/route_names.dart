// 路由名称常量
// 文档：docs/05-架构/路由设计.md

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
  static const String basicinfoSupplier = '/basicinfo/supplier';
  static const String basicinfoColor = '/basicinfo/color';
  static const String basicinfoUnit = '/basicinfo/unit';
  static const String basicinfoCurrency = '/basicinfo/currency';
  static const String basicinfoWarehouse = '/basicinfo/warehouse';
  static const String basicinfoAccount = '/basicinfo/account';
  static const String basicinfoPaymentStyle = '/basicinfo/payment-style';

  // 工资条
  static const String payrollSlipList = '/payroll/slip';
  static const String payrollSlipDetail = '/payroll/slip/:id';

  // 报销
  static const String expense = '/expense';
  static const String expenseNew = '/expense/new';
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

  // 员工档案
  static const String employee = '/employee';
  static const String employeeDetail = '/employee/:id';

  // 个人信息修改
  static const String profileEdit = '/profile/edit';
  static const String profileMyChanges = '/profile/me/changes';
  static const String profileMyDepartment = '/profile/me/department';

  /// 我的车辆与备用手机号（ADR-021 员工自助，直改即时生效）。
  static const String profileMyVehicles = '/profile/me/vehicles';

  /// 我的文件（员工自服务：只读查看本人档案文件）。
  static const String profileMyDocuments = '/profile/me/documents';

  // HR 端：员工个人信息修改审批
  static const String hrProfileChanges = '/hr/profile-changes';
  static const String hrProfileChangeDetail = '/hr/profile-changes/:id';

  // HR 端：工作台（今日概览 + 事务办理子页，ADR-021）
  static const String hrTaskCenter = '/hr/tasks';
  static String hrTaskList(String type) => '/hr/tasks/$type';

  // 入口选择（登录前：内部人员 / 访客）
  static const String entry = '/entry';

  // 访客端（独立流程，不进 ShellRoute）
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

  // 账号支持 + 超级管理员授权管理
  static const String adminPermissions = '/admin/permissions';
  // 审计中心（独立 audit_log:view 只读核查；导出另需 audit_log:export）
  static const String adminAuditLogs = '/admin/audit-logs';
  // 系统设置（安全/业务策略阈值；超管 authorization:manage，改设置二次密码确认）
  static const String adminSystemSettings = '/admin/system-settings';

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

  // 工程研发部任务中心（BOM 缺失转发 / 设计 / 打样 / 试产 / ECN）。
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

  // 仓库管理（8 单据 hub + 列表 + new/detail/edit + 报表）。
  static const String warehouse = '/warehouse';
  static const String warehouseReport = '/warehouse/report';
  static const String warehouseReportDetail = '/warehouse/report/detail';
  static const String warehouseReportSummary = '/warehouse/report/summary';
  static const String warehouseInboundExpectations =
      '/warehouse/inbound/expectations';

  /// 仓库登记实际到货独立页（价格/币种对仓库不可见；extra 带 ProcurementReceiptPrefill）。
  static const String warehouseArrivalReceiptNew =
      '/warehouse/inbound/receipts/new';

  /// 采购/委外 IQC 待检处置工作台（sidecar 前端入口）。
  static const String warehouseInspections = '/warehouse/inspections';
  static const String warehouseArrivalExceptions =
      '/warehouse/inbound/arrival-exceptions';

  /// 品质管理部任务中心（待检处置等品质任务的统一入口）。
  static const String qualityTaskCenter = '/quality/task-center';

  /// 货架目视化清单（库位号驱动的挂牌打印/导出；静态段，须先于 /warehouse/:code）。
  static const String warehouseShelfLabels = '/warehouse/shelf-labels';

  /// 委外出仓任务中心与拣货出仓页（V304；仓库专属，静态段须先于 /warehouse/:code）。
  static const String warehouseSubcontractOutbound =
      '/warehouse/subcontract-outbound';
  static String warehouseSubcontractOutboundEdit(String planId) =>
      '/warehouse/subcontract-outbound/$planId';

  static const String procurementArrivalExceptions =
      '/procurement/arrival-exceptions';
  static const String financeArrivalExceptions =
      '/finance/procurement-arrival-exceptions';

  // 销售管理（综合营销部）：hub + 5 单据 + 报表。
  // new/detail/edit 走 RoutePath.salesDoc*；seg = quotes|orders|shipments|other-shipments|returns。
  static const String sales = '/sales';
  static const String salesScarcity = '/sales/scarcity';
  static const String salesOrderProgress = '/sales/progress';
  static const String salesReport = '/sales/report';
  static const String salesReportDetail = '/sales/report/detail';
  static const String salesReportSummary = '/sales/report/summary';

  // 委外管理（综合营销部）：hub + 8 单据 + 报表。
  // seg = inquiries|applications|orders|receipts|material-issues|returns|material-returns|wastes。
  static const String subcontract = '/subcontract';
  static const String subcontractReport = '/subcontract/report';

  // 生产管理（生产部）：hub + 调度 + 计划单 + 日报 + 4 报表入口。
  static const String production = '/production';
  static const String productionSchedule = '/production/schedule';
  static const String productionProgress = '/production/progress';
  static const String productionMaterialAnalysis =
      '/production/material-analysis';
  static const String productionMaterialAnalysisHistory =
      '/production/material-analyses';
  static const String productionPlanList = '/production/plans';
  static const String productionDailyReportList = '/production/daily-reports';
  static const String productionWhereUsed = '/production/where-used';
  static const String productionChainHealth = '/production/chain-health';
  // /production/reports/{plan-detail|plan-summary|daily-detail|daily-summary} 用 RoutePath 助手。

  // 钱流管理（财税部）：hub + 5 单据 + AR/AP 台账 + 对账 + 支票 + 报表。
  // seg = receipts|payments|expenses|incomes|bank-transfers。
  static const String finance = '/finance';
  static const String financeArAp = '/finance/ar-ap';
  static const String financeReconciliations = '/finance/reconciliations';
  static const String financeChecks = '/finance/checks';
  static const String financeReport = '/finance/report';
  // 钱流报表 5 卡（镜像销售「明细+汇总+单独卡」）。
  static const String financeReportDetail = '/finance/report/detail';
  static const String financeReportSummary = '/finance/report/summary';
  static const String financeReportOverview = '/finance/report/overview';
  static const String financeReportStatement = '/finance/report/statement';
  static const String financeReportAccountFlow = '/finance/report/account-flow';
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

  /// 货品资料：新增 / 详情整页。[tab]：0=基本信息，1=组装信息，2=成本预算。
  static String basicinfoGoodsNew(String categoryId) =>
      '/basicinfo/goods/new?categoryId=$categoryId';
  static String basicinfoGoodsDetail(String id, {int? tab}) =>
      tab == null ? '/basicinfo/goods/$id' : '/basicinfo/goods/$id?tab=$tab';
  static String expenseDetail(String id) => '/expense/$id';
  static String noticeDetail(String id) => '/notice/$id';
  static String suggestionDetail(String id) => '/suggestion/$id';
  static String websiteInquiryDetail(String id) => '/webinquiry/$id';
  static String employeeDetail(String id) => '/employee/$id';
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
  static String stockWdrawNewFromDraw(String drawId) =>
      '/warehouse/WDRAW/new?drawId=$drawId';

  static String procurementArrivalException(String id) =>
      '/procurement/arrival-exceptions/$id';
  static String financeArrivalException(String id) =>
      '/finance/procurement-arrival-exceptions/$id';

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
  static String productionPlanNew() => '/production/plans/new';
  static String productionPlanDetail(String id) => '/production/plans/$id';
  static String productionPlanEdit(String id) => '/production/plans/$id/edit';
  static String productionDailyReportNew() => '/production/daily-reports/new';
  static String productionDailyReportDetail(String id) =>
      '/production/daily-reports/$id';
  static String productionDailyReportEdit(String id) =>
      '/production/daily-reports/$id/edit';

  /// 生产报表（4 入口）。
  /// [seg] = plan-detail|plan-summary|daily-detail|daily-summary。
  static String productionReport(String seg) => '/production/reports/$seg';

  /// 钱流单据：列表 / 新建 / 详情 / 编辑。
  /// [seg] = receipts|payments|expenses|incomes|bank-transfers。
  static String financeDocList(String seg) => '/finance/$seg';
  static String financeDocNew(String seg) => '/finance/$seg/new';
  static String financeDocDetail(String seg, String id) => '/finance/$seg/$id';
  static String financeDocEdit(String seg, String id) =>
      '/finance/$seg/$id/edit';
}

// 路由名称常量
// 文档：docs/05-架构/路由设计.md

/// 路由路径常量
abstract final class RouteName {
  static const String login = '/login';
  static const String home = '/';
  static const String dashboard = '/dashboard';
  static const String profile = '/profile';
  static const String settings = '/settings';
  static const String changePassword = '/change-password';
  static const String department = '/department';

  // 基础资料（登录即可访问，不设路由守卫）
  // /basicinfo       = 资料入口 hub（货品资料 / 模具资料 / ...）
  // /basicinfo/goods = 货品资料（分类树 + 货品）
  // /basicinfo/mould = 模具资料（分类树 + 模具）
  static const String basicinfo = '/basicinfo';
  static const String basicinfoGoods = '/basicinfo/goods';
  static const String basicinfoMould = '/basicinfo/mould';
  static const String basicinfoClient = '/basicinfo/client';
  static const String basicinfoSupplier = '/basicinfo/supplier';
  static const String basicinfoColor = '/basicinfo/color';
  static const String basicinfoUnit = '/basicinfo/unit';
  static const String basicinfoCurrency = '/basicinfo/currency';
  static const String basicinfoWarehouse = '/basicinfo/warehouse';

  // 工资条
  static const String payrollSlipList = '/payroll/slip';
  static const String payrollSlipDetail = '/payroll/slip/:id';

  // 报销
  static const String expense = '/expense';
  static const String expenseNew = '/expense/new';
  static const String expenseDetail = '/expense/:id';

  // 通知
  static const String notice = '/notice';
  static const String noticeDetail = '/notice/:id';

  // 建议
  static const String suggestion = '/suggestion';
  static const String suggestionNew = '/suggestion/new';
  static const String suggestionDetail = '/suggestion/:id';

  // 员工档案（Phase 2）
  static const String employee = '/employee';
  static const String employeeDetail = '/employee/:id';

  // 个人信息修改（Phase 6）
  static const String profileEdit = '/profile/edit';
  static const String profileMyChanges = '/profile/me/changes';

  // HR 端：员工个人信息修改审批
  static const String hrProfileChanges = '/hr/profile-changes';
  static const String hrProfileChangeDetail = '/hr/profile-changes/:id';

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
  static const String securityCheck = '/security/check/:id';

  // 系统管理（超级管理员）
  static const String adminPermissions = '/admin/permissions';

  // 财税部新模块（页面未接入前由占位页承接，权限点已种子化）
  static const String financeCustomers = '/finance/customers';
  static const String financeSuppliers = '/finance/suppliers';
  static const String financeAccounts = '/finance/accounts';

  // 采购管理（PMC 运营部）：hub + 4 单据列表。
  // new/detail/edit 走 RoutePath.purchaseDoc*(doc,id) 带参；doc=requests|orders|receipts|returns。
  static const String purchase = '/purchase';
  static const String purchaseRequestList = '/purchase/requests';
  static const String purchaseOrderList = '/purchase/orders';
  static const String purchaseReceiptList = '/purchase/receipts';
  static const String purchaseReturnList = '/purchase/returns';
  static const String purchaseReport = '/purchase/report';

  // 库存查询（库存管理）：余额 + 出入库流水。
  static const String stockBalance = '/stock/balance';
  static const String stockMovement = '/stock/movement';

  // 仓库管理（8 单据 hub + 列表 + new/detail/edit + 报表）。
  static const String warehouse = '/warehouse';
  static const String warehouseReport = '/warehouse/report';
}

/// 路径拼接工具（带参数的路由）
abstract final class RoutePath {
  /// 登录页（可带 returnTo）
  static String login({String? returnTo}) {
    if (returnTo == null) return RouteName.login;
    return '${RouteName.login}?returnTo=$returnTo';
  }

  static String payrollSlipDetail(String id) => '/payroll/slip/$id';
  static String expenseDetail(String id) => '/expense/$id';
  static String noticeDetail(String id) => '/notice/$id';
  static String suggestionDetail(String id) => '/suggestion/$id';
  static String employeeDetail(String id) => '/employee/$id';
  static String employeeEdit(String id) => '/employee/$id/edit';

  /// 采购单据：新建 / 详情 / 编辑。[doc] = requests|orders|receipts|returns。
  static String purchaseDocNew(String doc) => '/purchase/$doc/new';
  static String purchaseDocDetail(String doc, String id) => '/purchase/$doc/$id';
  static String purchaseDocEdit(String doc, String id) => '/purchase/$doc/$id/edit';

  /// 仓库单据：列表 / 新建 / 详情 / 编辑。[code] = TRANSFER|OTHER_IN|...|CHECK。
  static String stockDocList(String code) => '/warehouse/$code';
  static String stockDocNew(String code) => '/warehouse/$code/new';
  static String stockDocDetail(String code, String id) => '/warehouse/$code/$id';
  static String stockDocEdit(String code, String id) => '/warehouse/$code/$id/edit';

  /// 员工修改审批单批详情（HR 端）。
  static String hrProfileChangeDetail(String id) => '/hr/profile-changes/$id';
}

// 接口路径常量（基址 /api）。后端见 server .../features/*/Controller。
abstract final class ApiEndpoints {
  // 鉴权
  static const authLogin = '/auth/login';
  static const authRefresh = '/auth/refresh';
  static const authLogout = '/auth/logout';
  static const authChangePassword = '/auth/change-password';
  static const authMe = '/auth/me';

  // 部门
  static const departmentsTree = '/org/departments/tree';
  static String departmentSubtree(String id) => '/org/departments/$id/subtree';
  static String department(String id) => '/org/departments/$id';
  static const departments = '/org/departments';

  // 货品资料分类（基础资料 / master-data）
  static const materialCategories = '/master/material-categories';
  static const materialCategoryTree = '$materialCategories/tree';
  static String materialCategorySubtree(String id) =>
      '$materialCategories/$id/subtree';
  static String materialCategory(String id) => '$materialCategories/$id';

  // 货品主档（基础资料 / master-data）—— 分类下货品分页 + 详情 + 字段 facet
  static const goods = '/master/goods';
  static const goodsFacets = '$goods/facets';
  static String good(String id) => '/master/goods/$id';

  // 模具资料分类（基础资料 / master-data）—— 与货品分类同构，独立端点
  static const mouldCategories = '/master/mould-categories';
  static const mouldCategoryTree = '$mouldCategories/tree';
  static String mouldCategorySubtree(String id) =>
      '$mouldCategories/$id/subtree';
  static String mouldCategory(String id) => '$mouldCategories/$id';

  // 模具主档（基础资料 / master-data）—— 分类下模具分页 + 详情 + 字段 facet
  static const moulds = '/master/moulds';
  static const mouldsFacets = '$moulds/facets';
  static String mould(String id) => '/master/moulds/$id';

  // 客户资料分类（基础资料 / master-data）—— 与货品/模具分类同构，独立端点
  static const clientCategories = '/master/client-categories';
  static const clientCategoryTree = '$clientCategories/tree';
  static String clientCategorySubtree(String id) =>
      '$clientCategories/$id/subtree';
  static String clientCategory(String id) => '$clientCategories/$id';

  // 客户主档（基础资料 / master-data）—— 分类下客户分页 + 详情 + 字段 facet
  static const clients = '/master/clients';
  static const clientsFacets = '$clients/facets';
  static String client(String id) => '/master/clients/$id';

  // 供应商资料分类（基础资料 / master-data）—— 与货品/模具分类同构，独立端点
  static const supplierCategories = '/master/supplier-categories';
  static const supplierCategoryTree = '$supplierCategories/tree';
  static String supplierCategorySubtree(String id) =>
      '$supplierCategories/$id/subtree';
  static String supplierCategory(String id) => '$supplierCategories/$id';

  // 供应商主档（基础资料 / master-data）—— 分类下供应商分页 + 详情 + 字段 facet
  static const suppliers = '/master/suppliers';
  static const suppliersFacets = '$suppliers/facets';
  static String supplier(String id) => '/master/suppliers/$id';

  // 颜色主档（基础资料 / master-data）—— 扁平结构，无分类：分页 + 详情 + 字段 facet + 字典
  static const colors = '/master/colors';
  static const colorsFacets = '$colors/facets';
  static const colorsDict = '$colors/dict';
  static String color(String id) => '/master/colors/$id';

  // 基本单位主档（基础资料 / master-data）—— 扁平结构，无分类：分页 + 详情 + 字段 facet + 字典
  static const units = '/master/units';
  static const unitsFacets = '$units/facets';
  static const unitsDict = '$units/dict';
  static String unit(String id) => '/master/units/$id';

  // 币种主档（基础资料 / master-data）—— 扁平结构，无分类：分页 + 详情 + 字段 facet + 字典
  static const currencies = '/master/currencies';
  static const currenciesFacets = '$currencies/facets';
  static const currenciesDict = '$currencies/dict';
  static String currency(String id) => '/master/currencies/$id';

  // 仓库主档（基础资料 / master-data）—— 扁平结构，无分类：分页 + 详情 + 字段 facet + 字典
  static const warehouses = '/master/warehouses';
  static const warehousesFacets = '$warehouses/facets';
  static const warehousesDict = '$warehouses/dict';
  static String warehouse(String id) => '/master/warehouses/$id';

  // 供应商字典（采购单据页按 id 解析供应商名用，全量约 386 条）
  static const suppliersDict = '/master/suppliers/dict';

  // 货品按 id 批量解析名（采购明细展示用；ids 经 repository 以 query 传入）
  static const goodsLookup = '/master/goods/lookup';

  // 采购单据（采购管理 / purchase）—— 4 单据 CRUD + 审核 + 红冲。
  // [doc] = requests | orders | receipts | returns（与后端 @RequestMapping 对齐）。
  static String purchaseBase(String doc) => '/purchase/$doc';
  static String purchaseDoc(String doc, String id) => '/purchase/$doc/$id';
  static String purchaseApprove(String doc, String id) => '/purchase/$doc/$id/approve';
  static String purchaseReverse(String doc, String id) => '/purchase/$doc/$id/reverse';

  // 采购报表（采购管理）：月度汇总（MV 上卷）+ 待交货订货汇总。明细报表复用 4 单据列表。
  static const purchaseReportMonthly = '/purchase/reports/monthly';
  static const purchaseReportPending = '/purchase/reports/pending';

  // 库存查询（库存管理）：当前余额 + 出入库流水。
  static const stockBalances = '/stock/balances';
  static const stockMovements = '/stock/movements';

  // 仓库管理单据（8 类统一，端点 /api/stock/docs，docType 区分）：CRUD + 审核 + 红冲。
  static const stockDocsBase = '/stock/docs';
  static String stockDoc(String id) => '/stock/docs/$id';
  static String stockDocApprove(String id) => '/stock/docs/$id/approve';
  static String stockDocReverse(String id) => '/stock/docs/$id/reverse';

  // 岗位（部门下）
  static String departmentPositions(String deptId) =>
      '/org/departments/$deptId/positions';
  static String position(String id) => '/org/positions/$id';

  // 员工
  static const employees = '/org/employees';
  static String employee(String id) => '/org/employees/$id';
  static String employeeHistory(String id) => '/org/employees/$id/history';
  static String employeeTransfer(String id) => '/org/employees/$id/transfer';
  static String employeeOffboard(String id) => '/org/employees/$id/offboard';
  static String employeeConfirm(String id) => '/org/employees/$id/confirm';

  // 账号管理（HR）
  static const adminUsers = '/admin/users';
  static String userLock(String id) => '/admin/users/$id/lock';
  static String userUnlock(String id) => '/admin/users/$id/unlock';
  static String userDisable(String id) => '/admin/users/$id/disable';
  static String userEnable(String id) => '/admin/users/$id/enable';
  static String userResetPassword(String id) =>
      '/admin/users/$id/reset-password';

  // 权限管理（超级管理员）
  /// 列全部权限点（GET /admin/permissions；与前端路由 /admin/permissions 同名，注意区分）
  static const adminPermissionList = '/admin/permissions';
  static String userPermOverrides(String id) =>
      '/admin/users/$id/permission-overrides';

  /// 完整权限目录（按 category 分组、已排序）
  static const adminPermissionCatalog = '/admin/permission-catalog';

  /// 部门已配置的权限点
  static String departmentPermissions(String id) =>
      '/admin/departments/$id/permissions';

  /// 员工有效权限（部门 ∪ 角色 ± 个人覆盖，后端计算）
  static String userEffectivePermissions(String id) =>
      '/admin/users/$id/effective-permissions';

  // 访客（visitor）
  static const visitorSendCode = '/visitor/auth/send-code';
  static const visitorLogin = '/visitor/auth/login';
  static const visitorRefresh = '/visitor/auth/refresh';
  static const visitorLogout = '/visitor/auth/logout';
  static const visitorDirectoryDepartments = '/visitor/directory/departments';
  static const visitorDirectoryEmployees = '/visitor/directory/employees';
  static const visitorApplicationsMine = '/visitor/applications/mine';
  static const visitorApplications = '/visitor/applications';
  static String visitorApplication(String id) => '/visitor/applications/$id';
  static const visitorApproval = '/visitor-approval';
  static const visitorApprovalAsHost = '/visitor-approval/as-host';
  static const visitorApprovalPendingCount =
      '/visitor-approval/pending-count';
  static const visitorApprovalHostPendingCount =
      '/visitor-approval/host-pending-count';
  static String visitorApprovalById(String id) => '/visitor-approval/$id';
  static String visitorApprovalAction(String id) =>
      '/visitor-approval/$id/action';
  static String visitorHostConfirm(String id) =>
      '/visitor-approval/$id/host-confirm';
  static const securityVerify = '/security/verify';
  static String securityCheckIn(String id) => '/security/check-in/$id';

  // 个人信息修改（Phase 6）
  static const authVerifyPassword = '/auth/verify-password';
  static const profileMyChanges = '/profile/me/changes';
  static const hrProfileChanges = '/hr/profile-changes';
  static const hrProfileChangesPendingCount =
      '/hr/profile-changes/pending-count';
  static String hrProfileChangesPendingCountFor(String employeeId) =>
      '/hr/profile-changes/pending-count/$employeeId';
  static String hrProfileChangeDetail(String id) => '/hr/profile-changes/$id';
  static String hrProfileChangeReview(String id) =>
      '/hr/profile-changes/$id/review';

  // 用户偏好（任意 key-value；工作台布局等）
  static const userPreferences = '/user/preferences';
  static String userPreference(String key) => '/user/preferences/$key';
}

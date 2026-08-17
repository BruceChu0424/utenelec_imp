// 接口路径常量（基址 /api）。后端见 server .../features/*/Controller。
abstract final class ApiEndpoints {
  // 鉴权
  static const authLogin = '/auth/login';
  static const authRefresh = '/auth/refresh';
  static const authLogout = '/auth/logout';
  static const authChangePassword = '/auth/change-password';
  static const authMe = '/auth/me';

  // 工作台权限化聚合读模型
  static const dashboardOverview = '/dashboard/overview';

  // 财务订货审批：服务端按当前 assigneeUserId 返回个人任务与数量。
  static const financeProcurementApprovalTasks =
      '/finance/procurement-approvals/tasks';
  static const financeProcurementApprovalCount =
      '/finance/procurement-approvals/count';
  static const financeProcurementApprovalTypeCounts =
      '/finance/procurement-approvals/type-counts';

  // 销售订货单财务确认（V294 闸门）：待确认列表 / 徽标计数 / 确认动作。
  static const salesOrderFinanceConfirmationPending =
      '/sales/orders/finance-confirmation/pending';
  static const salesOrderFinanceConfirmationCount =
      '/sales/orders/finance-confirmation/count';
  static String salesOrderFinanceConfirm(String orderId) =>
      '/sales/orders/$orderId/finance-confirmation';

  // 财务批准后形成的仓储预计到货，以及超量到货隔离任务。
  static const warehouseInboundExpectations = '/warehouse/inbound/expectations';
  static const warehouseInboundExpectationCount =
      '/warehouse/inbound/expectations/count';
  static const warehouseInboundExpectationTypeCounts =
      '/warehouse/inbound/expectations/type-counts';
  static const warehouseArrivalExceptions =
      '/warehouse/inbound/arrival-exceptions';
  static const warehouseArrivalExceptionCount =
      '/warehouse/inbound/arrival-exceptions/count';
  static String warehouseArrivalExceptionStockIn(String id) =>
      '/warehouse/inbound/arrival-exceptions/$id/stock-in';
  static const procurementInspectionPendingReceipts =
      '/procurement/inspection/pending-receipts';
  static const procurementInspectionPendingCount =
      '/procurement/inspection/pending-count';
  static String procurementInspectionItems(
    String receiptType,
    String receiptId,
  ) => '/procurement/inspection?receiptType=$receiptType&receiptId=$receiptId';
  static String procurementInspectionDispose(
    String receiptType,
    String receiptId,
    String inspectionItemId,
  ) =>
      '/procurement/inspection/$receiptType/$receiptId/$inspectionItemId/dispose';
  static const procurementArrivalExceptionTasks =
      '/procurement/arrival-exceptions/tasks';
  static const procurementArrivalExceptionTaskCount =
      '/procurement/arrival-exceptions/count';
  static const financeArrivalExceptionTasks =
      '/finance/procurement-arrival-exceptions/tasks';
  static const financeArrivalExceptionCount =
      '/finance/procurement-arrival-exceptions/count';
  static String procurementArrivalException(String id) =>
      '/procurement/arrival-exceptions/$id';
  static String financeArrivalException(String id) =>
      '/finance/procurement-arrival-exceptions/$id';
  static String financeArrivalExceptionDecision(String id) =>
      '/finance/procurement-arrival-exceptions/$id/decision';
  static String procurementArrivalReturnTaskComplete(String id) =>
      '/procurement/arrival-exceptions/return-tasks/$id/complete';

  // 部门
  static const departmentsTree = '/org/departments/tree';
  static const employeePickerDepartmentTree =
      '/org/departments/employee-picker-tree';
  static String departmentSubtree(String id) => '/org/departments/$id/subtree';
  static String department(String id) => '/org/departments/$id';
  static String departmentWorkforceOverview(String id) =>
      '/org/departments/$id/workforce-overview';
  static const departments = '/org/departments';

  // HR 任务中心（转正/生日/周年/新入职动态提醒 + 软认领 ADR-021）
  static const hrTaskSummary = '/org/hr-tasks/summary';
  static const hrTaskCount = '/org/hr-tasks/count';
  static const hrTaskClaims = '/org/hr-tasks/claims';
  static String hrTaskClaim(String taskType, String employeeId) =>
      '/org/hr-tasks/claims/$taskType/$employeeId';
  static String hrTaskClaimTakeover(String taskType, String employeeId) =>
      '/org/hr-tasks/claims/$taskType/$employeeId/takeover';

  // 统一任务软认领（ADR-023，show-as-locked；池化审批/分解防重复操作）
  static String taskClaims(String targetType) => '/task-claims/$targetType';
  static String taskClaim(String targetType, String targetKey) =>
      '/task-claims/$targetType/$targetKey';
  static String taskClaimClaim(String targetType, String targetKey) =>
      '/task-claims/$targetType/$targetKey/claim';
  static String taskClaimHeartbeat(String targetType, String targetKey) =>
      '/task-claims/$targetType/$targetKey/heartbeat';

  // 我的部门（工作台卡片，问题 #20；任意员工可用，不走 department:view/employee:view）
  static const myDepartmentTree = '/my-department/tree';
  static const myDepartmentRoster = '/my-department/roster';

  // 部门主管管理本部门员工权限（问题 #20）
  static const departmentStaffPermissionsManaged =
      '/department-staff-permissions/managed';
  static String departmentStaffPermissionOverride(
    String employeeId,
    String code,
  ) => '/department-staff-permissions/employees/$employeeId/overrides/$code';

  // 工程研发部任务中心（rd_tasks）
  static const rdTasks = '/rd-tasks';
  static const rdTaskCount = '$rdTasks/count';
  static String rdTaskResolve(String id) => '$rdTasks/$id/resolve';
  static String rdTaskAssign(String id) => '$rdTasks/$id/assign';
  // 生产待排产 BOM 缺失 → 转发工程研发部
  static const productionScheduleForwardRd = '/production/schedule/forward-rd';

  // 货品资料分类（基础资料 / master-data）
  static const materialCategories = '/master/material-categories';
  static const materialCategoryTree = '$materialCategories/tree';
  static String materialCategorySubtree(String id) =>
      '$materialCategories/$id/subtree';
  static String materialCategory(String id) => '$materialCategories/$id';
  static String materialCategoryPrefixPreview(String id) =>
      '$materialCategories/$id/prefix-preview';
  static String materialCategoryDeletePreview(String id) =>
      '$materialCategories/$id/delete-preview';

  // 货品主档（基础资料 / master-data）—— 分类下货品分页 + 详情 + 字段 facet
  static const goods = '/master/goods';
  static const goodsFacets = '$goods/facets';
  static const goodsSearchCategoryIds = '$goods/search-category-ids';
  static String good(String id) => '/master/goods/$id';

  // 货品组装信息（BOM）—— 详情「组装信息」页签 + 配件清单导出
  static String goodsBom(String id) => '/master/goods/$id/bom';
  static String goodsBomItem(String id, String itemId) =>
      '/master/goods/$id/bom/$itemId';
  static String goodsBomItemAudit(String id, String itemId) =>
      '/master/goods/$id/bom/$itemId/audit';
  static String goodsBomExport(String id) => '/master/goods/$id/bom/export';
  // 货品批量导入：detect 只读检测 / commit 原子导入 / latest 最近批次 / undo 撤回。
  static const goodsImportDetect = '/master/goods/import/detect';
  static const goodsImportCommit = '/master/goods/import/commit';
  static const goodsImportLatest = '/master/goods/import/latest';
  static String goodsImportUndo(String batchId) =>
      '/master/goods/import/$batchId';

  // 模具资料分类（基础资料 / master-data）—— 与货品分类同构，独立端点
  static const mouldCategories = '/master/mould-categories';
  static const mouldCategoryTree = '$mouldCategories/tree';
  static String mouldCategorySubtree(String id) =>
      '$mouldCategories/$id/subtree';
  static String mouldCategory(String id) => '$mouldCategories/$id';
  static String mouldCategoryPrefixPreview(String id) =>
      '$mouldCategories/$id/prefix-preview';
  static String mouldCategoryDeletePreview(String id) =>
      '$mouldCategories/$id/delete-preview';

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
  static String clientCategoryPrefixPreview(String id) =>
      '$clientCategories/$id/prefix-preview';

  // 客户主档（基础资料 / master-data）—— 分类下客户分页 + 详情 + 字段 facet
  static const clients = '/master/clients';
  static const clientsFacets = '$clients/facets';
  static const clientsDict = '$clients/dict';
  static String client(String id) => '/master/clients/$id';

  // 供应商资料分类（基础资料 / master-data）—— 与货品/模具分类同构，独立端点
  static const supplierCategories = '/master/supplier-categories';
  static const supplierCategoryTree = '$supplierCategories/tree';
  static String supplierCategorySubtree(String id) =>
      '$supplierCategories/$id/subtree';
  static String supplierCategory(String id) => '$supplierCategories/$id';
  static String supplierCategoryPrefixPreview(String id) =>
      '$supplierCategories/$id/prefix-preview';

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

  // Stable UUID dictionaries used by sales/purchase/subcontract settlement
  // terms and by finance receipt/payment instruments respectively.
  static const settlementMethods = '/master/reference-methods/settlement';
  static const financePaymentMethods = '/master/reference-methods/finance';

  // 仓库主档（基础资料 / master-data）—— 扁平结构，无分类：分页 + 详情 + 字段 facet + 字典
  static const warehouses = '/master/warehouses';
  static const warehousesFacets = '$warehouses/facets';
  static const warehousesDict = '$warehouses/dict';
  static const warehousesWorkshops = '$warehouses/workshops';
  static String warehouse(String id) => '/master/warehouses/$id';

  // 供应商字典（采购单据页按 id 解析供应商名用，全量约 386 条）
  static const suppliersDict = '/master/suppliers/dict';

  // 货品按 id 批量解析名（采购明细展示用；ids 经 repository 以 query 传入）
  static const goodsLookup = '/master/goods/lookup';

  // 采购单据（采购管理 / purchase）—— 4 单据 CRUD + 审核 + 红冲。
  // [doc] = requests | orders | receipts | returns（与后端 @RequestMapping 对齐）。
  static String purchaseBase(String doc) => '/purchase/$doc';
  static String purchaseDoc(String doc, String id) => '/purchase/$doc/$id';
  static String purchaseApprove(String doc, String id) =>
      '/purchase/$doc/$id/approve';
  static String purchaseReverse(String doc, String id) =>
      '/purchase/$doc/$id/reverse';

  // 采购报表（采购管理）：月度汇总（MV 上卷）+ 待交货订货汇总。明细报表复用 4 单据列表。
  static const purchaseReportMonthly = '/purchase/reports/monthly';
  static const purchaseReportPending = '/purchase/reports/pending';

  // 库存查询（库存管理）：当前余额 + 出入库流水。
  static const stockBalances = '/stock/balances';
  static const stockBalanceAdjust = '/stock/balances/adjust';
  static const stockMovements = '/stock/movements';
  // 即时库存（货品+颜色聚合余额 + 分类树/仓库过滤；仓库管理 hub 入口）。
  static const stockInstantInventory = '/stock/instant-inventory';
  static const stockInstantInventorySearchCategoryIds =
      '$stockInstantInventory/search-category-ids';
  // 货架目视化清单（货品主档库位号驱动，打印张贴/导出口径，与库存数量无关）。
  static const stockShelfLabels = '/stock/shelf-labels';
  static const stockShelfLabelRacks = '/stock/shelf-labels/racks';

  // 仓库管理单据（8 类统一，端点 /api/stock/docs，docType 区分）：CRUD + 审核 + 红冲。
  static const stockDocsBase = '/stock/docs';
  static String stockDoc(String id) => '/stock/docs/$id';
  static String stockDocApprove(String id) => '/stock/docs/$id/approve';
  static String stockDocReverse(String id) => '/stock/docs/$id/reverse';
  static String stockDocIssue(String id) => '/stock/docs/$id/issue';
  static String stockDocIssueReverse(String id) =>
      '/stock/docs/$id/issue/reverse';
  static const productionMaterialReturnableSources =
      '/stock/production-materials/returnable-sources';
  static String productionMaterialClearance(String planId) =>
      '/stock/production-materials/plans/$planId/clearance';
  static String productionMaterialSettlements(String planId) =>
      '/stock/production-materials/plans/$planId/settlements';
  static String productionMaterialSettlementReverse(String planId) =>
      '/stock/production-materials/plans/$planId/settlements/reverse';
  static String productionMaterialClose(String planId) =>
      '/stock/production-materials/plans/$planId/close';

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
  static String employeeRehire(String id) => '/org/employees/$id/rehire';
  static String employeeContracts(String id) => '/org/employees/$id/contracts';
  static String employeeAvatar(String id) => '/org/employees/$id/avatar';
  static String employeeAccount(String id) => '/org/employees/$id/account';

  /// 锁定 / 解锁员工登录账号（员工详情顶卡，account:support）。
  static String employeeAccountLock(String id) =>
      '/org/employees/$id/account/lock';
  static String employeeAccountUnlock(String id) =>
      '/org/employees/$id/account/unlock';
  // 更换手机号（同步登录账号 + 踢会话；employee:pii:edit）—— ADR-021
  static String employeeChangePhone(String id) =>
      '/org/employees/$id/change-phone';

  // 员工自助：本人车辆 / 备用手机号（ADR-021；profile:edit:self，仅本人）
  static const myVehicles = '/profile/me/vehicles';
  static const myPhones = '/profile/me/phones';

  // 账号管理（HR）
  static const adminUsers = '/admin/users';
  static String adminUserByEmployee(String employeeId) =>
      '/admin/users/by-employee/$employeeId';
  static String userLock(String id) => '/admin/users/$id/lock';
  static String userUnlock(String id) => '/admin/users/$id/unlock';
  static String userDisable(String id) => '/admin/users/$id/disable';
  static String userEnable(String id) => '/admin/users/$id/enable';
  static String userResetPassword(String id) =>
      '/admin/users/$id/reset-password';

  /// 开通账号候选（尚无登录账号的在册员工；account:support；最小信息集不含 PII）。
  static const adminProvisionCandidates = '/admin/users/provision-candidates';

  /// 设置/取消超级管理员（仅超管；允许多个超管）。
  static String userSuperAdmin(String id) => '/admin/users/$id/super-admin';

  /// 设置/取消云端(外网)访问授权（仅超管；变更即时失效旧 token，触发器 bump auth_version）。
  static String userRemoteAccess(String id) => '/admin/users/$id/remote-access';

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

  /// 数据范围授权（用户 × 范围 × 可见归属人）
  static String userDataScopes(String id, String scope) =>
      '/admin/users/$id/data-scopes?scope=$scope';

  /// 授权归属人候选（范围内实际有归属数据的员工）
  static String dataScopeOwners(String scope) =>
      '/admin/data-scope-owners?scope=$scope';

  /// 审计中心（独立 audit_log:view 只读核查；导出另需 audit_log:export）
  static const adminAuditLogs = '/admin/audit-logs';

  /// 联网授权并审计一次本机操作回执核查。
  static String adminAuditLocalReceiptVerification(String operationId) =>
      '$adminAuditLogs/local-receipt-verifications/$operationId';

  /// 系统设置（安全/业务策略阈值；超管 authorization:manage，改设置二次密码确认）
  static const adminSystemSettings = '/admin/system-settings';

  /// 管理员「切换人 / 模拟身份」：enter(验密码发 modeToken) / start(签发目标 token) / end(审计)。
  /// 仅 superAdmin；start 由 admin token 调，end 由模拟 token 调（主体=目标）。
  static const adminImpersonationEnter = '/admin/impersonation/enter';
  static const adminImpersonationStart = '/admin/impersonation/start';
  static const adminImpersonationEnd = '/admin/impersonation/end';
  static const adminImpersonationTargets = '/admin/impersonation/targets';

  /// 公共运行时设置（仅需登录，前端读会话空闲超时阈值等）
  static const publicSettings = '/settings/public';

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
  static const visitorApprovalPendingCount = '/visitor-approval/pending-count';
  static const visitorApprovalHostPendingCount =
      '/visitor-approval/host-pending-count';
  static String visitorApprovalById(String id) => '/visitor-approval/$id';
  static String visitorApprovalAction(String id) =>
      '/visitor-approval/$id/action';
  static String visitorHostConfirm(String id) =>
      '/visitor-approval/$id/host-confirm';
  static const securityVerify = '/security/verify';
  static String securityCheckIn(String id) => '/security/check-in/$id';

  // 个人信息修改
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

  // 通知（广播 + 每用户已读/删除状态；后端 features/notice/NoticeController）
  static const notices = '/notices';
  static String notice(String id) => '/notices/$id';
  static const noticesUnreadCount = '/notices/unread-count';
  static const noticesReadAll = '/notices/read-all';
  static const noticesUnreadCountBySource = '/notices/unread-count-by-source';
  static const noticesReadBySource = '/notices/read-by-source';
  static const noticesBatchDelete = '/notices/batch-delete';
  static const noticesAudiencePreview = '/notices/audience/preview';
  static const noticesAudienceEmployees = '/notices/audience/employees';
  static const noticesTodos = '/notices/todos';
  static String noticeRead(String id) => '/notices/$id/read';
  static String noticeComplete(String id) => '/notices/$id/complete';
  static String noticeAcknowledge(String id) => '/notices/$id/acknowledge';
  static String noticeBlessing(String id) => '/notices/$id/blessing';
  static String noticeBlessings(String id) => '/notices/$id/blessings';
  static String noticeAcknowledgers(String id) => '/notices/$id/acknowledgers';
  static const noticeCelebrationPreview = '/notices/celebration/preview';
  static const noticeCelebrationSettings = '/notices/celebration/settings';

  /// 当前用户今日庆典（登录弹窗 / 今日卡片；notice:read，PII 安全）。
  static const noticeCelebrationMyToday = '/notices/celebration/my-today';

  /// 一键批量发布庆典祝福（notice:publish）。
  static const noticeCelebrationBatch = '/notices/celebration/batch';

  // 建议箱（广场/我的/提交/点赞/官方回复；后端 features/suggestion/SuggestionController）
  static const suggestions = '/suggestions';
  static String suggestion(String id) => '/suggestions/$id';
  static String suggestionLike(String id) => '/suggestions/$id/like';
  static String suggestionReplies(String id) => '/suggestions/$id/replies';

  // 官网询盘（统一收件箱；后端 features/webinquiry/WebsiteInquiryController）
  static const websiteInquiries = '/website-inquiries';
  static String websiteInquiry(String id) => '/website-inquiries/$id';
  static String websiteInquiryStatus(String id) =>
      '/website-inquiries/$id/status';
  static String websiteInquiryConvert(String id) =>
      '/website-inquiries/$id/convert';

  // 单据号预览（新建页占位显示；不消耗序列，并发时可能差1以保存后为准）
  static const docNumberPeek = '/doc-number/peek';
}

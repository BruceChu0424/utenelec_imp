// 接口路径常量（基址 /api）。后端见 server .../features/*/Controller。
abstract final class ApiEndpoints {
  // 鉴权
  static const authLogin = '/auth/login';
  static const authRefresh = '/auth/refresh';
  static const authLogout = '/auth/logout';
  static const authChangePassword = '/auth/change-password';

  /// 当前用户资料 + 会话快照(可委派页面 / 单据范围写能力 / 用户偏好, ADR-108)。
  static const authMe = '/auth/me';

  /// 工作台徽章汇总: 全站红黄徽章、通知未读数与页内分段细数一次带回(ADR-108)。
  static const workbenchBadges = '/workbench/badges';

  /// 敏感操作再认证：输入登录密码换一次性凭证 (ADR-110)。
  static const authStepUp = '/auth/step-up';

  // 工作台权限化聚合读模型
  static const dashboardOverview = '/dashboard/overview';

  // 财务订货审批：服务端返回共享审核组任务；动作按 allowedActions 分权，
  // 批量决定由 caseId + expectedVersion 精确绑定并整批原子提交。
  static const financeProcurementApprovalTasks =
      '/finance/procurement-approvals/tasks';
  static const financeProcurementApprovalFacets =
      '$financeProcurementApprovalTasks/facets'; // 2026-09-25 单号列统一
  static const financeProcurementApprovalTypeCounts =
      '/finance/procurement-approvals/type-counts';
  static const financeProcurementApprovalBatchApprove =
      '/finance/procurement-approvals/tasks/batch-approve';
  static const financeProcurementApprovalBatchReject =
      '/finance/procurement-approvals/tasks/batch-reject';
  static String financeProcurementApprovalReview(String caseId) =>
      '/finance/procurement-approvals/tasks/$caseId/review';

  // 销售订货单财务确认（V294 闸门）：待确认列表 / 徽标计数 / 确认动作。
  static const salesOrderFinanceConfirmationPending =
      '/sales/orders/finance-confirmation/pending';
  static const salesOrderFinanceConfirmationFacets =
      '$salesOrderFinanceConfirmationPending/facets'; // 2026-09-25 单号列统一
  static const salesOrderFinanceConfirmationCount =
      '/sales/orders/finance-confirmation/count';
  static const salesOrderFinanceConfirmationBatch =
      '/sales/orders/finance-confirmation/batch';
  static String salesOrderFinanceConfirm(String orderId) =>
      '/sales/orders/$orderId/finance-confirmation';
  static String salesOrderFinanceReview(String orderId) =>
      '/sales/orders/$orderId/finance-confirmation/review';
  static String salesOrderFinanceReject(String orderId) =>
      '/sales/orders/$orderId/finance-confirmation/reject';

  // 销售报价财务核价(ADR-134)：队列(state=pending|confirmed|returned) / 核价详情 /
  // 改价保存 / 退回销售 / 确认报价 / 撤销确认。动作都带 expectedRevision + expectedClaimId。
  static const salesQuoteFinanceReviewList = '/sales/quotes/finance-review';
  static String salesQuoteFinanceReview(String quoteId) =>
      '/sales/quotes/${Uri.encodeComponent(quoteId)}/finance-review';
  static String salesQuoteFinanceEdit(String quoteId) =>
      '/sales/quotes/${Uri.encodeComponent(quoteId)}/finance';
  static String salesQuoteFinanceReturn(String quoteId) =>
      '/sales/quotes/${Uri.encodeComponent(quoteId)}/finance-return';
  static String salesQuoteFinanceConfirm(String quoteId) =>
      '/sales/quotes/${Uri.encodeComponent(quoteId)}/finance-confirm';
  static String salesQuoteFinanceReopen(String quoteId) =>
      '/sales/quotes/${Uri.encodeComponent(quoteId)}/finance-reopen';

  // 财务批准后形成的仓储预计到货，以及超量到货隔离任务。
  static const warehouseInboundExpectations = '/warehouse/inbound/expectations';
  static const warehouseInboundExpectationFacets =
      '$warehouseInboundExpectations/facets'; // 2026-09-25 单号列统一
  // ADR-151 §5：登记页按来源身份读取预计到货。
  static const warehouseInboundExpectationsByIds =
      '$warehouseInboundExpectations/by-ids';
  static const warehouseArrivalExceptions =
      '/warehouse/inbound/arrival-exceptions';
  static const warehouseArrivalExceptionFacets =
      '$warehouseArrivalExceptions/facets'; // 2026-09-25 单号列统一
  static const warehouseArrivalExceptionBatchStockIn =
      '/warehouse/inbound/arrival-exceptions/batch-stock-in';
  static const warehouseIqcStockIns = '/warehouse/iqc-stock-ins';
  static const warehouseIqcStockInBatchConfirm =
      '$warehouseIqcStockIns/batch-confirm';
  static String warehouseIqcStockInDetail(
    String receiptType,
    String receiptId,
  ) =>
      '$warehouseIqcStockIns/${Uri.encodeComponent(receiptType.trim().toUpperCase())}/'
      '${Uri.encodeComponent(receiptId.trim())}';
  static String warehouseIqcStockInConfirm(
    String receiptType,
    String receiptId,
  ) => '${warehouseIqcStockInDetail(receiptType, receiptId)}/confirm';

  /// 先入库后质检(V596)：把等待检查结果的待检明细逐行上架到实际叶仓与库位。
  static String warehouseIqcStockInPreStockIn(
    String receiptType,
    String receiptId,
  ) => '${warehouseIqcStockInDetail(receiptType, receiptId)}/pre-stock-in';

  // 品质部检查结果合并页（原 IQC 合格待入库 + IQC 不合格实物退回）：
  // 按收货单聚合 等待检查结果/全部合格待入库/部分合格/全部不合格需退回/已完结。
  static const warehouseQualityResults = '/warehouse/quality-results';
  static const warehouseQualityResultFacets =
      '$warehouseQualityResults/facets'; // 2026-09-25 单号列统一
  static const warehouseQualityResultStatusCounts =
      '$warehouseQualityResults/status-counts';
  static String warehouseQualityResultDetail(
    String receiptType,
    String receiptId,
  ) =>
      '$warehouseQualityResults/${Uri.encodeComponent(receiptType.trim().toUpperCase())}/'
      '${Uri.encodeComponent(receiptId.trim())}';
  static const productionFinishedInboundTasks =
      '/warehouse/production-finished-in/tasks';
  static const productionFinishedInboundTaskFacets =
      '$productionFinishedInboundTasks/facets'; // 2026-09-25 单号列统一
  static const productionFinishedInboundBatchConfirm =
      '/stock/docs/finished-in/confirm-batch';
  static const productionFinishedArrivalBatchBase =
      '/warehouse/production-finished-in/arrival-registrations/batch';

  /// V548 登记撤回（仅品质未处理）：路径参数是登记批次 UUID，不是报工单 UUID。
  static String productionFinishedArrivalReverse(String registrationId) =>
      '/warehouse/production-finished-in/arrival-registrations/$registrationId/reverse';
  static const productionQualityInspections = '/production/quality-inspections';
  static const productionQualityInspectionCapability =
      '/production/quality-inspections/capability';
  static const productionQualityInspectionPassAll =
      '/production/quality-inspections/decisions/pass-all';

  /// ADR-148 整批判定：同一批实物(需求份 / 计划公共 / 实际超产)一次判定。
  static String productionQualityInspectionLotDecisions(String lotId) =>
      '/production/quality-inspections/lots/$lotId/decisions';

  /// V547 品质检查单（待检处置一行一张单）。
  static const productionQualityInspectionSheets =
      '/production/quality-inspections/sheets';
  static String productionQualityInspectionSheet(String sheetId) =>
      '$productionQualityInspectionSheets/$sheetId';
  static const productionQualityInspectionRecords =
      '/production/quality-inspections/records';
  static String productionQualityInspectionRecord(String recordId) =>
      '$productionQualityInspectionRecords/$recordId';
  static const productionQualityReplenishments =
      '/production/quality-replenishments';
  static const productionQualityReplenishmentMaterialTasks =
      '/production/quality-replenishments/material-tasks';
  static const productionQualityReplenishmentMaterialTaskCount =
      '/production/quality-replenishments/material-tasks/count';
  static String warehouseArrivalExceptionStockIn(String id) =>
      '/warehouse/inbound/arrival-exceptions/$id/stock-in';
  // 入库登记库位建议(采购/委外到货与产成品登记共用)：所选仓 × 货品 × 颜色记忆 → 货品资料通用库位。
  static const warehousePlaceSuggestions = '/warehouse/place-suggestions';
  // 货品资料「学习」回写：登记到货保存后回写库位号/系列/编码（对仓库端开放）。
  static const warehouseInboundGoodsProfileHints =
      '/warehouse/inbound/goods-profile-hints';
  // 到货登记一步完成（登记 + 送检审核）：仓库只登记数量/库位，币族服务端权威回填。
  static const warehouseInboundArrivals = '/warehouse/inbound/arrivals';
  // ADR-151 §5：登记实际到货的唯一页面命令(单张 = 1 组，多选 = N 组，一个事务)。
  static const warehouseInboundArrivalsBatch =
      '$warehouseInboundArrivals/batch';
  // 完成中断的到货登记（断点恢复）：草稿收货单一键继续送检，不进采购/委外单据页。
  static String warehouseInboundArrivalComplete(String receiptId) =>
      '/warehouse/inbound/arrivals/$receiptId/complete';
  // 预计到货「批量继续送检」：一个事务逐张草稿收货单完成送检步骤。
  static const warehouseInboundArrivalBatchComplete =
      '/warehouse/inbound/arrivals/batch-complete';

  // 委外出仓工作台（V304）：财务批准委外订货后按 BOM 展开发料计划并自动生出仓草稿；
  // 仓库在此看任务、拣货、审核出仓（编辑/审核走既有 /subcontract/material-issues 端点）。
  static const warehouseSubcontractOutboundTasks =
      '/warehouse/subcontract-outbound/tasks';
  static String warehouseSubcontractOutboundTask(String planId) =>
      '/warehouse/subcontract-outbound/tasks/$planId';
  static String warehouseSubcontractOutboundDraft(String planId) =>
      '/warehouse/subcontract-outbound/tasks/$planId/draft';
  static String warehouseSubcontractOutboundClose(String planId) =>
      '/warehouse/subcontract-outbound/tasks/$planId/close';
  static const procurementInspectionPendingReceipts =
      '/procurement/inspection/pending-receipts';
  static const procurementInspectionRecords = '/procurement/inspection/records';
  static String procurementInspectionRecord(String recordId) =>
      '$procurementInspectionRecords/$recordId';
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
  static String procurementInspectionPassBatch(
    String receiptType,
    String receiptId,
  ) => '/procurement/inspection/$receiptType/$receiptId/pass-batch';
  static String procurementInspectionDecideBatch(
    String receiptType,
    String receiptId,
  ) => '/procurement/inspection/$receiptType/$receiptId/decide-batch';
  static const procurementArrivalExceptionTasks =
      '/procurement/arrival-exceptions/tasks';
  static const financeArrivalExceptionTasks =
      '/finance/procurement-arrival-exceptions/tasks';
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
  static const departmentStaffPermissionManagedDepartments =
      '/department-staff-permissions/managed-departments';
  static const departmentStaffPermissionStaff =
      '/department-staff-permissions/staff';
  static String departmentStaffEmployeePermissions(String employeeId) =>
      '/department-staff-permissions/employees/'
      '${Uri.encodeComponent(employeeId)}/permissions';

  // 工程研发部任务中心（rd_tasks）
  static const rdTasks = '/rd-tasks';
  static String rdTaskResolve(String id) => '$rdTasks/$id/resolve';

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

  /// Goods English name only (ADR-134): goods:name_en:edit or goods:edit;
  /// body {nameEn, version}, the server marks the value as manually maintained.
  static String goodNameEn(String id) => '${good(id)}/name-en';

  // 货品组装信息（BOM）—— 详情「组装信息」页签 + 配件清单导出
  static String goodsBom(String id) => '/master/goods/$id/bom';
  static String goodsBomItem(String id, String itemId) =>
      '/master/goods/$id/bom/$itemId';
  static String goodsBomItemAudit(String id, String itemId) =>
      '/master/goods/$id/bom/$itemId/audit';

  /// 批量删除组装行：一次提交同一父货品下的多条关系 id。
  /// 用 POST 而非 DELETE —— 删除清单要走请求体，带 body 的 DELETE 在网关/代理
  /// 上并不可靠(部分中间件会直接丢掉 DELETE 的 body)。
  static String goodsBomBatchDelete(String id) =>
      '/master/goods/$id/bom/batch-delete';
  static String goodsBomExport(String id) => '/master/goods/$id/bom/export';

  /// BOM 学习记录(ADR-129)：逐组件的设计/真实使用数量与累计；relearn 把某组件
  /// 的当前累计记为基线、从现在起重新学习(goods:bom:edit)，返回同一份汇总。
  static String goodsBomLearning(String id) => '/master/goods/$id/bom-learning';
  static String goodsBomRelearn(String id) =>
      '/master/goods/$id/bom-learning/relearn';
  // 货品批量导入：detect 只读检测 / commit 原子导入 / latest 最近批次 / undo 撤回。
  // 组装信息导入（2026-09-25）：格式 = 配件清单导出 13 列，序号级联段表达层级。
  static String goodsBomImportDetect(String goodsId) =>
      '/master/goods/$goodsId/bom/import/detect';
  static String goodsBomImportCommit(String goodsId) =>
      '/master/goods/$goodsId/bom/import/commit';
  static const goodsImportDetect = '/master/goods/import/detect';
  static const goodsImportCommit = '/master/goods/import/commit';
  static const goodsImportLatest = '/master/goods/import/latest';
  static String goodsImportUndo(String batchId) =>
      '/master/goods/import/$batchId';

  // 发料方式 (按工单领料 / 整批领到车间内料仓) 与分摊方式切换, ADR-131: 先预览受影响项, 再原子批量切换。
  static String goodsIssueMethodPreview(String goodsId) =>
      '/master/goods/$goodsId/issue-method/preview';
  static const goodsIssueMethodBatch = '/master/goods/issue-method/batch';

  // 车间内料仓上线准备: 产品的塑料单个重量 (期间边) 与认料批量填写。
  static const goodsPeriodicBomPreparation =
      '/master/goods/periodic-bom/preparation';
  static const goodsPeriodicBomBatch = '/master/goods/periodic-bom/batch';

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

  /// 客户列表 (手机/电话/银行账号筛选值走请求体，不进 URL)。
  static const clientsSearch = '$clients/search';
  static const clientsFacets = '$clients/facets';
  static const clientsDict = '$clients/dict';
  static const clientsAccessCandidates = '$clients/access-candidates';
  static String client(String id) => '/master/clients/$id';
  static String clientAccess(String id) => '${client(id)}/access';

  /// Learned customer goods cross reference (ADR-134): GET paged list
  /// (?page&size&keyword), DELETE one row.
  static String clientGoodsAliases(String id) => '${client(id)}/goods-aliases';
  static String clientGoodsAlias(String id, String aliasId) =>
      '${clientGoodsAliases(id)}/$aliasId';

  /// 多选客户批量设负责人/可见人（字面段 access 与 UUID 路径参数不冲突）。
  static const clientsAccessBatch = '$clients/access/batch';

  /// 销售识别客户文件: 用文件信息新建客户(服务端先跨范围查重, ADR-134)。
  static const clientFromDocument = '$clients/from-document';

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

  /// 供应商列表 (手机/电话/银行账号筛选值走请求体，不进 URL)。
  static const suppliersSearch = '$suppliers/search';
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

  // 结算方式管理页（V453）：全量含禁用行与账期策略；表头筛选 facets；账期维护。
  static const settlementMethodsAdmin =
      '/master/reference-methods/settlement-admin';
  static const settlementMethodsAdminFacets = '$settlementMethodsAdmin/facets';
  static String settlementMethodTerms(String id) =>
      '/master/reference-methods/settlement/$id/terms';

  // 仓库主档（基础资料 / master-data）—— 扁平结构，无分类：分页 + 详情 + 字段 facet + 字典
  static const warehouses = '/master/warehouses';
  static const warehousesFacets = '$warehouses/facets';
  static const warehousesDict = '$warehouses/dict';
  static const warehousesWorkshops = '$warehouses/workshops';
  static String warehouse(String id) => '/master/warehouses/$id';

  // 仓库负责人(仓管员, ADR-115)：列表列 / 候选员工 / 本人仓库数据范围(ADR-149) / 某仓整组替换
  static const warehouseKeeperAssignments = '$warehouses/keepers';
  static const warehouseKeeperCandidates = '$warehouses/keeper-candidates';
  static const myWarehouseScope = '$warehouses/my-scope';
  static String warehouseKeepers(String id) => '/master/warehouses/$id/keepers';

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

  // 库存查询 (库存管理): 当前余额 + 授权余额调整 (出入库流水见下方 stockGoodsLedger)。
  static const stockBalances = '/stock/balances';

  /// ADR-146 不良品专门通道：当前用户能办的通道 / 一次建单并过账。
  static const stockDefectiveMoveOptions =
      '/stock/docs/defective-moves/options';
  static const stockDefectiveMoves = '/stock/docs/defective-moves';
  static const stockBalanceAdjust = '/stock/balances/adjust';
  // 即时库存（货品+颜色聚合余额 + 分类树/仓库过滤；仓库管理 hub 入口）。
  static const stockInstantInventory = '/stock/instant-inventory';
  static const stockInstantInventorySearchCategoryIds =
      '$stockInstantInventory/search-category-ids';
  // 货架目视化清单（货品主档库位号驱动，打印张贴/导出口径，与库存数量无关）。
  static const stockShelfLabels = '/stock/shelf-labels';
  static const stockShelfLabelRacks = '/stock/shelf-labels/racks';
  static const stockShelfLabelLayout = '/stock/shelf-labels/layout';

  // 单货品出入库流水 (库存明细账：流水行 + 重量调整行，服务端算结存/期初期末，ADR-135 §7.1)。
  static String stockGoodsLedger(String goodsId) =>
      '/stock/goods/${Uri.encodeComponent(goodsId)}/ledger';

  // 仓库重量账与单重学习 (ADR-135 §7.2)：单重参数批量取 (一页一次，客户端自算件数/偏差)、
  // 单货品单重详情/称重记录、称样校准、单重设置、排除/恢复记录、重新学习、核重。
  static const stockWeightParams = '/stock/weight/params';
  static String stockWeightGoods(String goodsId) =>
      '/stock/weight/goods/${Uri.encodeComponent(goodsId)}';
  static String stockWeightGoodsObservations(String goodsId) =>
      '${stockWeightGoods(goodsId)}/observations';
  static String stockWeightGoodsSamples(String goodsId) =>
      '${stockWeightGoods(goodsId)}/samples';
  static String stockWeightGoodsProfile(String goodsId) =>
      '${stockWeightGoods(goodsId)}/profile';
  static String stockWeightGoodsResetRegime(String goodsId) =>
      '${stockWeightGoods(goodsId)}/reset-regime';
  static String stockWeightObservationExclude(String observationId) =>
      '/stock/weight/observations/${Uri.encodeComponent(observationId)}/exclude';
  static String stockWeightObservationInclude(String observationId) =>
      '/stock/weight/observations/${Uri.encodeComponent(observationId)}/include';
  static const stockWeightBalanceSet = '/stock/weight/balances/set';

  // 库存分析 (ADR-135 §7.4，stock_report:view；单货品 KPI 条为 stock:view)：
  // 呆滞与库龄 / 盘点建议 / 称重异常 / 单重学习。
  static const stockInsightsHealth = '/stock/insights/health';
  static const stockInsightsCycleCount = '/stock/insights/cycle-count';
  static const stockInsightsWeightAlerts = '/stock/insights/weight-alerts';
  static const stockInsightsLearning = '/stock/insights/learning';
  static String stockInsightsGoods(String goodsId) =>
      '/stock/insights/goods/${Uri.encodeComponent(goodsId)}';

  // 仓库管理单据（8 类统一，端点 /api/stock/docs，docType 区分）：CRUD + 审核 + 红冲。
  static const stockDocsBase = '/stock/docs';
  static String stockDoc(String id) => '/stock/docs/$id';
  static String stockDocApprove(String id) => '/stock/docs/$id/approve';
  static String stockDocReverse(String id) => '/stock/docs/$id/reverse';
  static String stockDocIssue(String id) => '/stock/docs/$id/issue';
  static String stockDocApproveAndIssue(String id) =>
      '/stock/docs/$id/approve-and-issue';
  static String stockDocIssueReverse(String id) =>
      '/stock/docs/$id/issue/reverse';
  static String productionMaterialClearance(String planId) =>
      '/stock/production-materials/plans/$planId/clearance';
  static String productionMaterialCapabilities(String planId) =>
      '/stock/production-materials/plans/$planId/capabilities';
  static String productionMaterialSettlements(String planId) =>
      '/stock/production-materials/plans/$planId/settlements';
  static String productionMaterialSettlementReverse(String planId) =>
      '/stock/production-materials/plans/$planId/settlements/reverse';
  static String productionMaterialClose(String planId) =>
      '/stock/production-materials/plans/$planId/close';

  // 车间内料仓 (ADR-131; 后端 features/warehouse/materialbin): 设置、机台与容器、
  // 领料 / 退回 / 其它耗用、盘点与期间、自动结算状态、认料与换料、用量报表。
  // 写接口都带 idempotencyKey 与 expectedVersion; 页面按钮只看响应里的 allowedActions。
  static const workshopMaterialBase = '/workshop-material';

  /// 工作台徽章来源: 待发料 / 待收退回 / 盘点中。
  static const workshopMaterialBadgeCounts =
      '$workshopMaterialBase/badge-counts';
  static const workshopMaterialSettings = '$workshopMaterialBase/settings';
  static String workshopMaterialSetting(String workshopId) =>
      '$workshopMaterialSettings/$workshopId';

  /// 开启整批领料前, 所选车间在产、需认料的产品 (按产品去重, 含预填; ADR-147)。
  static const workshopMaterialSettingsInProgressPending =
      '$workshopMaterialSettings/in-progress-pending';

  /// 发料来源仓滑窗的仓库层级 (只有元数据; ADR-147)。
  static const workshopMaterialSourceWarehouses =
      '$workshopMaterialSettings/source-warehouses';

  /// 批量开通 / 开启整批领料 / 改来源仓 (全成全败; ADR-147)。
  static const workshopMaterialSettingsBatchEnable =
      '$workshopMaterialSettings/batch-enable';

  /// 批量撤销一步 (全成全败; ADR-147)。
  static const workshopMaterialSettingsBatchDisable =
      '$workshopMaterialSettings/batch-disable';
  static const workshopMaterialMachines = '$workshopMaterialBase/machines';
  static const workshopMaterialMachinesBatch =
      '$workshopMaterialBase/machines/batch';
  static String workshopMaterialMachine(String machineId) =>
      '$workshopMaterialMachines/$machineId';
  static const workshopMaterialContainersBatch =
      '$workshopMaterialBase/containers/batch';
  static String workshopMaterialContainer(String containerId) =>
      '$workshopMaterialBase/containers/$containerId';
  static String workshopMaterialBinPosition(String binId) =>
      '$workshopMaterialBase/bins/$binId/position';
  static const workshopMaterialRequisitions =
      '$workshopMaterialBase/requisitions';
  static String workshopMaterialRequisition(String id) =>
      '$workshopMaterialRequisitions/$id';
  static String workshopMaterialRequisitionFulfil(String id) =>
      '$workshopMaterialRequisitions/$id/fulfil';
  static String workshopMaterialRequisitionCancel(String id) =>
      '$workshopMaterialRequisitions/$id/cancel';
  static const workshopMaterialDirectIssues =
      '$workshopMaterialBase/direct-issues';

  /// 直接发料默认值 (该车间上一次的领料人)。
  static const workshopMaterialDirectIssueDefaults =
      '$workshopMaterialDirectIssues/defaults';
  static const workshopMaterialOtherIssues =
      '$workshopMaterialBase/other-issues';
  static const workshopMaterialPeriods = '$workshopMaterialBase/periods';
  static String workshopMaterialPeriod(String periodId) =>
      '$workshopMaterialPeriods/$periodId';
  static String workshopMaterialStartCount(String periodId) =>
      '$workshopMaterialPeriods/$periodId/start-count';
  static String workshopMaterialWithdrawCount(String periodId) =>
      '$workshopMaterialPeriods/$periodId/withdraw-count';
  static String workshopMaterialCorrectCount(String periodId) =>
      '$workshopMaterialPeriods/$periodId/correct-count';
  static String workshopMaterialCloseStatus(String periodId) =>
      '$workshopMaterialPeriods/$periodId/close-status';
  static String workshopMaterialCloseRetry(String periodId) =>
      '$workshopMaterialPeriods/$periodId/close-retry';

  /// 撤销结算 (需再认证)。
  static String workshopMaterialReopen(String periodId) =>
      '$workshopMaterialPeriods/$periodId/reopen';
  static String workshopMaterialCount(String countId) =>
      '$workshopMaterialBase/counts/$countId';

  /// 盘点单一行 (逐行保存 / 删除); key 是客户端生成的行键。
  static String workshopMaterialCountLine(String countId, String key) =>
      '$workshopMaterialBase/counts/$countId/lines/${Uri.encodeComponent(key)}';
  static String workshopMaterialZeroRest(String countId) =>
      '$workshopMaterialBase/counts/$countId/zero-rest';
  static String workshopMaterialSubmitCount(String countId) =>
      '$workshopMaterialBase/counts/$countId/submit';

  /// 整批领料的料清单 (申请/发料下拉、出库仓下拉、上线准备颗粒下拉), ?workshopId=。
  static const workshopMaterialMaterials = '$workshopMaterialBase/materials';
  static const workshopMaterialRequestMaterials =
      '$workshopMaterialBase/request-materials';
  static const workshopMaterialChoicesPending =
      '$workshopMaterialBase/choices/pending';
  static const workshopMaterialChoices = '$workshopMaterialBase/choices';

  /// 某张工单 (任务段) 改用别的料。
  static String workshopMaterialSegmentChange(String segmentId) =>
      '$workshopMaterialBase/segments/$segmentId/material-changes';

  /// 用量报表: [kind] = bin-usage | product-usage | waste-trend | missing-weights | ledger。
  static String workshopMaterialReport(String kind) =>
      '$workshopMaterialBase/reports/$kind';

  // 岗位（部门下）
  static String departmentPositions(String deptId) =>
      '/org/departments/$deptId/positions';
  static String position(String id) => '/org/positions/$id';

  // 员工
  static const employees = '/org/employees';
  static String employee(String id) => '/org/employees/$id';
  static String employeeHistory(String id) => '/org/employees/$id/history';
  static String employeeSecondaryDepartments(String id) =>
      '/org/employees/$id/secondary-departments';
  static String employeeTransfer(String id) => '/org/employees/$id/transfer';
  static String employeeOffboard(String id) => '/org/employees/$id/offboard';
  static String employeeHandoverPreview(String id) =>
      '/org/employees/$id/handover-preview';
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
  static const myProfile = '/profile/me';
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
  static String userPermOverrides(String id) =>
      '/admin/users/$id/permission-overrides';

  /// 个人「全部授权 / 本模块 / 本组」：服务端按授权策略补齐(ADR-109)。
  static String userPermGrantAll(String id) =>
      '/admin/users/$id/permission-overrides/grant-all';

  /// 全员基础包(每个在职员工都隐式持有的码)。
  static const adminPermissionBaseline = '/admin/permission-baseline';

  /// 完整权限目录（按 category 分组、已排序）
  static const adminPermissionCatalog = '/admin/permission-catalog';

  /// 部门已配置的权限点
  static String departmentPermissions(String id) =>
      '/admin/departments/$id/permissions';

  /// 部门「全部授权 / 本模块 / 本组」：服务端按授权策略补齐(ADR-109)。
  static String departmentPermGrantAll(String id) =>
      '/admin/departments/$id/permissions/grant-all';

  /// 员工有效权限(全员基础 ∪ 部门 ± 个人覆盖 ∪ 负责人委派，后端计算)
  static String userEffectivePermissions(String id) =>
      '/admin/users/$id/effective-permissions';

  /// 数据范围授权（用户 × 范围 × 可见归属人）
  static String userDataScopes(String id, String scope) =>
      '/admin/users/$id/data-scopes?scope=$scope';

  /// 授权归属人候选（范围内实际有归属数据的员工）
  static String dataScopeOwners(String scope) =>
      '/admin/data-scope-owners?scope=$scope';

  /// 数据范围动态目录（启用状态、全量覆盖权限和业务分组）。
  static const adminDataScopeCatalog = '/admin/data-scope-catalog';

  static const adminDataHandovers = '/admin/data-handovers';
  static const adminDataHandoverPreview = '$adminDataHandovers/preview';
  static const adminDataHandoverCandidates = '$adminDataHandovers/candidates';

  /// 审计中心（独立 audit_log:view 只读核查；导出另需 audit_log:export）
  static const adminAuditLogs = '/admin/audit-logs';

  /// 联网授权并审计一次本机操作回执核查。
  static String adminAuditLocalReceiptVerification(String operationId) =>
      '$adminAuditLogs/local-receipt-verifications/$operationId';

  /// 系统设置（安全/业务策略阈值；超管 authorization:manage，改设置二次密码确认）
  static const adminSystemSettings = '/admin/system-settings';

  /// AI 服务设置(ADR-133，超管 authorization:manage + superAdmin)。
  /// 增删改、设默认、启停、用已存密钥测试/取模型要再认证；用本次新填密钥测试免再认证。
  static const adminAiProviders = '/admin/ai/providers';
  static String adminAiProvider(String id) => '$adminAiProviders/$id';
  static String adminAiProviderDefault(String id) =>
      '$adminAiProviders/$id/default';
  static String adminAiProviderEnabled(String id) =>
      '$adminAiProviders/$id/enabled';
  static String adminAiProviderTest(String id) => '$adminAiProviders/$id/test';
  static String adminAiProviderModels(String id) =>
      '$adminAiProviders/$id/models';
  static const adminAiProvidersTest = '$adminAiProviders/test';
  static const adminAiProvidersModels = '$adminAiProviders/models';
  static const adminAiPresets = '/admin/ai/presets';
  static const adminAiUsage = '/admin/ai/usage';

  /// 公共 AI 作业(ADR-133): 提交原始文件(octet-stream) / 轮询 / 取消；员工账号本人可用。
  static const aiJobs = '/ai/jobs';
  static String aiJob(String id) => '$aiJobs/$id';
  static String aiJobCancel(String id) => '$aiJobs/$id/cancel';

  /// 当前账号能否用 AI(不含服务商/模型细节)。
  static const aiStatus = '/ai/status';

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

  /// 冷启动会话校验（访客主体；401 时拦截器自动走刷新流程）。
  static const visitorMe = '/visitor/me';
  static const visitorDirectoryEmployees = '/visitor/directory/employees';
  static const visitorApplicationsMine = '/visitor/applications/mine';
  static const visitorApplications = '/visitor/applications';
  static String visitorApplication(String id) => '/visitor/applications/$id';
  static const visitorApproval = '/visitor-approval';

  /// HR 审批列表表头筛选桶（状态/接待人部门，2026-09-10）。
  static const visitorApprovalFacets = '/visitor-approval/facets';
  static const visitorApprovalAsHost = '/visitor-approval/as-host';
  static String visitorApprovalById(String id) => '/visitor-approval/$id';
  static String visitorApprovalAction(String id) =>
      '/visitor-approval/$id/action';
  static String visitorHostConfirm(String id) =>
      '/visitor-approval/$id/host-confirm';
  static const securityVerify = '/security/verify';
  static String securityCheckIn(String id) => '/security/check-in/$id';

  /// 访客黑名单（visitor:blacklist）：列表分页 / 拉黑（原因必填）/ 解除。
  static const securityBlacklist = '/security/blacklist';
  static String securityBlacklistById(String id) => '/security/blacklist/$id';

  // 个人信息修改
  static const profileMyChanges = '/profile/me/changes';
  static const hrProfileChanges = '/hr/profile-changes';

  /// HR 队列表头筛选桶（部门），status 与列表分段同口径（2026-09-10）。
  static const hrProfileChangesFacets = '/hr/profile-changes/facets';
  static String hrProfileChangeDetail(String id) => '/hr/profile-changes/$id';
  static String hrProfileChangeReview(String id) =>
      '/hr/profile-changes/$id/review';

  // 用户偏好(任意 key-value；工作台布局等)。读取整表随会话快照 /auth/me 带回，
  // 这里只剩单键写入(ADR-108)。
  static String userPreference(String key) => '/user/preferences/$key';

  // 通知（广播 + 每用户已读/删除状态；后端 features/notice/NoticeController）
  static const notices = '/notices';
  static const noticeArrivals = '/notices/arrivals';
  static String notice(String id) => '/notices/$id';
  static const noticesReadAll = '/notices/read-all';

  /// 未读索引(判定用轻量列 + 摘要): 摘要随徽章汇总带回, 对不上时才拉(ADR-108)。
  static const noticesUnreadIndex = '/notices/unread-index';
  static const noticesReadBySource = '/notices/read-by-source';

  /// 按站内办理路由批量已读（业务动作完成/打开单据后清对应通知）。
  static const noticesReadByRoute = '/notices/read-by-route';

  /// V459「稍后再看」（query: minutes，默认 15）。
  static String noticeSnooze(String id) => '/notices/$id/snooze';

  /// V459 弹卡真态校验（query: ids 逗号分隔）。
  static const noticesPendingReviewStatus = '/notices/pending-review-status';

  /// V459 居中审核弹窗（登录检查）：我名下未办结且未稍后的待审通知。
  static const noticesPendingReviews = '/notices/pending-reviews';

  /// 人工通知登录弹窗（2026-09-10，ADR-063 §8）：人事手动发布、对我可见且仍待
  /// 打卡（acknowledge）/ 未读未确认（none，14 天内）的通知。
  static const noticesPendingPopups = '/notices/pending-popups';
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

  /// 翻转「庆典自动发送」开关（notice:publish，HR 任务中心页面开关；V600）。
  static const noticeCelebrationAuto = '/notices/celebration/auto';

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

  // 单据列表页分段计数(2026-09-21; 前端 lib/shared/providers/document_status_counts_provider.dart)。
  // 跨模块草稿数与三类「财务已退回」张数随徽章汇总带回(ADR-108)。
  static const documentStatusCounts = '/documents/status-counts';

  // 系统测试（工作台「系统测试」区，仅超管+本地/内网测试环境可用；
  // 后端 features/admin/systemtest/SystemTestController）
  static const systemTestBusinessDataReset = '/system-test/business-data/reset';
  static const systemTestBusinessDataLastResult =
      '/system-test/business-data/last-result';
}

// 路由 → 所需权限点映射（路由守卫用）。仅未列出的已知自助路径按登录访问。
// 文档：docs/05-架构/全局机制.md §1.4
//
// 路由使用 requiredAnyPermFor() 表达任一权限，使用 requiredAllPermsFor() 表达全部权限。
import '../../shared/auth/document_permission_set.dart';
import '../../shared/auth/permissions.dart';
import 'route_names.dart';

String? _documentRouteAuthority(
  String location,
  String module,
  Map<String, DocumentPermissionSet> catalog,
) {
  final path = Uri.tryParse(location)?.path ?? location.split('?').first;
  final segments = path.split('/');
  if (segments.length < 3 || segments[1] != module) return null;
  final permissions = catalog[segments[2]];
  if (permissions == null) return null;
  if (path.endsWith('/new')) return permissions.create;
  if (path.endsWith('/edit')) return permissions.edit;
  return permissions.view;
}

String? _documentRouteViewDependency(
  String location,
  String module,
  Map<String, DocumentPermissionSet> catalog,
) {
  final path = Uri.tryParse(location)?.path ?? location.split('?').first;
  final segments = path.split('/');
  if (segments.length < 3 || segments[1] != module) return null;
  final permissions = catalog[segments[2]];
  if (permissions == null) return null;
  if (path.endsWith('/new')) {
    return permissions.create == null ? null : permissions.view;
  }
  if (path.endsWith('/edit')) {
    return permissions.edit == null ? null : permissions.view;
  }
  return null;
}

bool _isOrderDetailPath(String location, String module) {
  final path = Uri.tryParse(location)?.path ?? location.split('?').first;
  final segments = path.split('/');
  return segments.length == 4 &&
      segments[1] == module &&
      segments[2] == 'orders' &&
      segments[3].isNotEmpty &&
      segments[3] != 'new' &&
      segments[3] != 'edit';
}

/// 返回某路径所需的权限点列表（任一满足即可）；不需要权限返回 null。
///
/// 这是路由守卫与工作台显隐共用的唯一数据源。
List<String>? requiredAnyPermFor(String location) {
  final routePath = Uri.tryParse(location)?.path ?? location.split('?').first;
  // 账号支持可进入员工账号列表；只有超级管理员能看到并修改授权部分。
  if (location == RouteName.adminPermissions) {
    return const [Perm.accountSupport, Perm.authorizationManage];
  }
  // 审计中心与本机回执核查共享独立的只读权限；导出仍另需 audit_log:export。
  if (routePath == RouteName.adminAuditLogs ||
      routePath.startsWith('${RouteName.adminAuditLogs}/') ||
      location == RouteName.deviceAuditReceipts) {
    return const [Perm.auditLogView];
  }
  // 其余系统管理页面仍由授权管理权限保护。
  if (location == RouteName.adminSystemSettings ||
      location.startsWith('/admin/')) {
    return const [Perm.authorizationManage];
  }
  // 员工档案
  if (location == '/employee' || location.startsWith('/employee/')) {
    if (location == '/employee/onboarding') {
      return const [Perm.employeeCreate];
    }
    if (location.endsWith('/offboarding')) {
      return const [Perm.employeeOffboard];
    }
    if (location.endsWith('/edit')) {
      return const [Perm.employeeEdit];
    }
    return const [Perm.employeeView];
  }
  // 部门
  if (location == '/department' || location.startsWith('/department/')) {
    return const [Perm.departmentView];
  }
  // 财务
  if (location == '/expense/approval' ||
      location.startsWith('/expense/approval/')) {
    return const [Perm.expenseApprove, Perm.expensePay];
  }
  if (location == '/expense' ||
      location == '/expense/new' ||
      location.startsWith('/expense/')) {
    return const [Perm.expenseApply];
  }
  if (location == '/payroll/review') {
    return const [Perm.payrollReview, Perm.payrollPublish];
  }
  if (location == '/payroll/generate') return const [Perm.payrollGenerate];
  if (location == '/payroll/slip' || location.startsWith('/payroll/slip/')) {
    return const [Perm.payrollViewSelf, Perm.payrollViewAll];
  }
  if (location == '/finance/procurement-approvals') {
    return const [Perm.financeOrderApprovalView];
  }
  if (location == '/finance/sales-order-confirmations' ||
      location.startsWith('/finance/sales-order-confirmations/')) {
    return const [Perm.salesOrderFinanceView];
  }
  if (routePath == RouteName.financeSalesShipmentAudit) {
    return const [Perm.financeShipmentAudit];
  }
  if (location == RouteName.financeArrivalExceptions ||
      location.startsWith('${RouteName.financeArrivalExceptions}/')) {
    return const [Perm.financeOrderApprovalView];
  }
  if (location == RouteName.financeAssets ||
      location.startsWith('${RouteName.financeAssets}/')) {
    return const [Perm.financeAssetView];
  }
  if (location == RouteName.financePayables) {
    return const [
      Perm.arApLedgerView,
      Perm.subcontractLossClaimView,
      Perm.supplierSettlementView,
    ];
  }
  if (location == RouteName.financeReport ||
      location.startsWith('${RouteName.financeReport}/')) {
    return const [Perm.financeReportView];
  }
  // 客户主档入口统一要求 client:view；本人/授权/全部范围由后端 OwnerVisibility 强制裁剪。
  if (location.startsWith('/finance/customers')) {
    return const [Perm.clientView];
  }
  if (location.startsWith('/finance/suppliers')) {
    return const [Perm.supplierView];
  }
  if (location.startsWith('/finance/accounts')) {
    return const [Perm.accountView];
  }
  // 统一履约工作台：沿用各部门现有单据查看权限，列表本身不授予写权限。
  if (location == RouteName.operationsWarehouseWorkbench) {
    return const [Perm.stockDocView];
  }
  if (location == RouteName.operationsPurchaseWorkbench) {
    return const [
      Perm.purchaseRequestView,
      Perm.purchaseOrderView,
      Perm.purchaseReceiptView,
      Perm.purchaseReturnView,
    ];
  }
  if (location == RouteName.operationsSubcontractWorkbench) {
    // 委外分解页的首屏权威是计划下达的只读申请；
    // create/decompose 只是页内动作，不能反向授予申请阅读。
    return const [Perm.subcontractApplicationView];
  }
  // 工程研发部任务中心。
  if (location == RouteName.rdTaskCenter) {
    return const [Perm.rdTaskView];
  }
  // HR 任务中心（转正/生日/周年/新入职提醒；权限与员工档案查看一致）。
  if (location == RouteName.hrTaskCenter) {
    return const [Perm.employeeView];
  }
  // 采购管理（PMC 运营部；view 全员、edit 归 PMC）
  if (location == RouteName.purchase) {
    // hub：任一采购单据 view 即可见
    return const [
      Perm.purchaseRequestView,
      Perm.purchaseOrderView,
      Perm.purchaseReceiptView,
      Perm.purchaseReturnView,
    ];
  }
  if (location == RouteName.purchaseReport ||
      location.startsWith('${RouteName.purchaseReport}/')) {
    return const [Perm.purchaseReportView];
  }
  // 库存查询（余额 + 流水）
  if (location.startsWith('/stock/')) return const [Perm.stockView];
  // 仓库管理（8 单据，stock_doc:view 全员 / edit 归 PMC）
  if (location == RouteName.warehouse) {
    return const [
      Perm.stockDocView,
      Perm.warehouseInboundView,
      Perm.salesShipmentWarehouseWork,
      Perm.warehousePurchaseReceiptHistoryView,
      Perm.warehouseSubcontractReceiptHistoryView,
      Perm.warehouseSubcontractOutboundHistoryView,
      Perm.subcontractOutboundView,
      Perm.warehouseSubcontractFinishedReturnHistoryView,
      Perm.warehouseSubcontractMaterialReturnHistoryView,
      Perm.warehouseSubcontractWasteHistoryView,
      Perm.warehouseIqcReturnView,
      Perm.warehouseIqcStockInView,
    ];
  }
  if (routePath == RouteName.warehousePurchaseReceiptHistory ||
      routePath.startsWith('${RouteName.warehousePurchaseReceiptHistory}/')) {
    return const [Perm.warehousePurchaseReceiptHistoryView];
  }
  if (routePath == RouteName.warehouseSubcontractReceiptHistory ||
      routePath.startsWith(
        '${RouteName.warehouseSubcontractReceiptHistory}/',
      )) {
    return const [Perm.warehouseSubcontractReceiptHistoryView];
  }
  if (routePath == RouteName.warehouseSubcontractOutboundHistory ||
      routePath.startsWith(
        '${RouteName.warehouseSubcontractOutboundHistory}/',
      )) {
    return const [Perm.warehouseSubcontractOutboundHistoryView];
  }
  if (routePath == RouteName.warehouseSubcontractFinishedReturnHistory ||
      routePath.startsWith(
        '${RouteName.warehouseSubcontractFinishedReturnHistory}/',
      )) {
    return const [Perm.warehouseSubcontractFinishedReturnHistoryView];
  }
  if (routePath == RouteName.warehouseSubcontractMaterialReturnHistory ||
      routePath.startsWith(
        '${RouteName.warehouseSubcontractMaterialReturnHistory}/',
      )) {
    return const [Perm.warehouseSubcontractMaterialReturnHistoryView];
  }
  if (routePath == RouteName.warehouseSubcontractWasteHistory ||
      routePath.startsWith('${RouteName.warehouseSubcontractWasteHistory}/')) {
    return const [Perm.warehouseSubcontractWasteHistoryView];
  }
  if (routePath == RouteName.warehouseIqcReturns ||
      routePath.startsWith('${RouteName.warehouseIqcReturns}/')) {
    return const [Perm.warehouseIqcReturnView];
  }
  if (routePath == RouteName.warehouseIqcStockIns ||
      routePath.startsWith('${RouteName.warehouseIqcStockIns}/')) {
    return const [Perm.warehouseIqcStockInView];
  }
  if (routePath == RouteName.warehouseSalesOutbound ||
      routePath.startsWith('${RouteName.warehouseSalesOutbound}/')) {
    return const [Perm.salesShipmentWarehouseWork];
  }
  // 待检处置任务中心 + 单据处置页：同查看权限（处置动作由页面内 handle 权限把关）。
  if (location == RouteName.warehouseInspections ||
      location.startsWith('${RouteName.warehouseInspections}/')) {
    return const [Perm.procurementInspectionView];
  }
  // 品质任务中心：与待检处置同权限（查看检验任务）。
  if (location == RouteName.qualityTaskCenter) {
    return const [
      Perm.procurementInspectionView,
      Perm.productionQualityInspectionView,
    ];
  }
  // 检测记录按事件只读；IQC/FQC 分支仍由各自后端权限与对象范围裁剪。
  if (routePath == RouteName.qualityInspectionRecords) {
    return const [
      Perm.procurementInspectionView,
      Perm.productionQualityInspectionView,
    ];
  }
  if (location == RouteName.productionFqcInspections) {
    return const [Perm.productionQualityInspectionView];
  }
  if (location == RouteName.warehouseInboundExpectations ||
      location == RouteName.warehouseArrivalExceptions) {
    return const [Perm.warehouseInboundView];
  }
  if (location == RouteName.warehouseProductionFinishedInboundTasks ||
      location.startsWith(
        '${RouteName.warehouseProductionFinishedArrivalRegistrationBase}/',
      )) {
    return const [Perm.stockDocView];
  }
  // 到货异常确认入库是独立高影响动作，不再借用收货单编辑权限。
  if (location == RouteName.warehouseArrivalReceiptNew) {
    return const [Perm.warehouseInboundStockIn];
  }
  if (location == RouteName.warehouseReport ||
      location.startsWith('${RouteName.warehouseReport}/')) {
    return const [Perm.stockReportView];
  }
  // 货架目视化清单：货品主档库位号查询，与库存查询同权（stock:view 全员）。
  if (location == RouteName.warehouseShelfLabels) {
    return const [Perm.stockView];
  }
  // 委外目标件出仓工作台（V436；LEGACY_BOM_COMPONENT 历史兼容）：独立权限点，
  // 权限管理授权后才可见/可操作。
  if (location == RouteName.warehouseSubcontractOutbound ||
      location.startsWith('${RouteName.warehouseSubcontractOutbound}/')) {
    // 首屏任务/详情查询要求 view；handle 只是页面内动作，不能替代查看权限。
    return const [Perm.subcontractOutboundView];
  }
  if (routePath == RouteName.procurementIqcRejections ||
      routePath.startsWith('${RouteName.procurementIqcRejections}/')) {
    // 查看是页面硬门槛；退回、抵扣、无贷项关闭和红冲都不能替代查看权限。
    return const [Perm.procurementIqcRejectionView];
  }
  if (location == RouteName.procurementArrivalExceptions ||
      location.startsWith('${RouteName.procurementArrivalExceptions}/')) {
    return const [Perm.supplierReturnTaskView];
  }
  if (location.startsWith('/warehouse/')) {
    final authority = _documentRouteAuthority(
      location,
      'warehouse',
      DocumentPermissionCatalog.stockBySegment,
    );
    return authority == null ? const [] : [authority];
  }
  if (location.startsWith('/purchase/')) {
    if (_isOrderDetailPath(location, 'purchase')) {
      return const [Perm.purchaseOrderView, Perm.financeOrderApprovalView];
    }
    final authority = _documentRouteAuthority(
      location,
      'purchase',
      DocumentPermissionCatalog.purchaseBySegment,
    );
    return authority == null ? const [] : [authority];
  }
  // 通知与建议箱：与后端 employee 基础权限包保持一致；仍允许管理员单独回收。
  if (location == '/notice/publish') return const [Perm.noticePublish];
  if (location == RouteName.notice || location.startsWith('/notice/')) {
    return const [Perm.noticeRead];
  }
  if (location == RouteName.suggestion || location.startsWith('/suggestion/')) {
    return const [Perm.suggestionSubmit];
  }
  // 官网询盘：按权限点收口（部门授权，非全员基础包）。
  if (location == RouteName.websiteInquiry ||
      location.startsWith('/webinquiry/')) {
    return const [Perm.webinquiryView];
  }
  // 基础资料：hub 按任一主档查看权限放行；详情页使用对应主档权限。
  if (location == RouteName.basicinfo) {
    return const [
      Perm.goodsView,
      Perm.mouldView,
      Perm.clientView,
      Perm.supplierView,
      Perm.colorView,
      Perm.unitView,
      Perm.currencyView,
      Perm.warehouseView,
      Perm.accountView,
      Perm.paymentStyleView,
    ];
  }
  if (location == '${RouteName.basicinfoGoods}/new') {
    return const [Perm.goodsCreate];
  }
  if (location == RouteName.basicinfoGoods ||
      location.startsWith('${RouteName.basicinfoGoods}/')) {
    // 货品列表与详情整页；新增深链在上方独立要求 goods:create。
    return const [Perm.goodsView];
  }
  if (location == RouteName.basicinfoMould) return const [Perm.mouldView];
  if (location == RouteName.basicinfoClient) return const [Perm.clientView];
  if (location == RouteName.basicinfoSupplier) {
    return const [Perm.supplierView];
  }
  if (location == RouteName.basicinfoColor) return const [Perm.colorView];
  if (location == RouteName.basicinfoUnit) return const [Perm.unitView];
  if (location == RouteName.basicinfoCurrency) {
    return const [Perm.currencyView];
  }
  if (location == RouteName.basicinfoWarehouse) {
    return const [Perm.warehouseView];
  }
  if (location == RouteName.basicinfoAccount ||
      location.startsWith('${RouteName.basicinfoAccount}/')) {
    return const [Perm.accountView];
  }
  if (location == RouteName.basicinfoPaymentStyle) {
    return const [Perm.paymentStyleView];
  }

  // 出货财务审核复用只读出货列表/详情：finance_shipment_audit 可查看并审核，
  // 但绝不放开 /new 或 /edit；这些路径仍走下方单据 create/edit 权限。
  final salesSegments = routePath.split('/');
  final isShipmentList = routePath == '/sales/shipments';
  final isShipmentDetail =
      salesSegments.length == 4 &&
      salesSegments[1] == 'sales' &&
      salesSegments[2] == 'shipments' &&
      salesSegments[3].isNotEmpty &&
      salesSegments[3] != 'new' &&
      salesSegments[3] != 'edit';
  if (isShipmentList || isShipmentDetail) {
    return const [
      Perm.salesShipmentView,
      Perm.financeShipmentAudit,
      Perm.salesShipmentWarehouseWork,
    ];
  }

  // ===== 销售管理（综合营销部；sales_<quote|order|shipment|other_shipment|return>:view/edit）=====
  if (location == RouteName.sales) {
    // hub：任一销售单据 view 即可见
    return const [
      Perm.salesQuoteView,
      Perm.salesOrderView,
      Perm.salesShipmentView,
      Perm.salesOtherShipmentView,
      Perm.salesReturnView,
    ];
  }
  if (location == RouteName.salesReport ||
      location.startsWith('${RouteName.salesReport}/')) {
    return const [Perm.salesReportView];
  }
  if (location == RouteName.salesScarcity) {
    return const [Perm.salesOrderReallocate];
  }
  if (location == RouteName.salesOrderProgress ||
      location.startsWith('${RouteName.salesOrderProgress}/')) {
    return const [Perm.salesOrderView];
  }
  if (location.startsWith('/sales/')) {
    final authority = _documentRouteAuthority(
      location,
      'sales',
      DocumentPermissionCatalog.salesBySegment,
    );
    return authority == null ? const [] : [authority];
  }

  // ===== 委外管理（综合营销部；subcontract_<...>:view/edit）=====
  if (location == RouteName.subcontract) {
    return const [
      Perm.subcontractInquiryView,
      Perm.subcontractApplicationView,
      Perm.subcontractOrderView,
      Perm.subcontractReceiptView,
      Perm.subcontractMaterialIssueView,
      Perm.subcontractReturnView,
      Perm.subcontractMaterialReturnView,
      Perm.subcontractWasteView,
    ];
  }
  if (location == RouteName.subcontractReport ||
      location.startsWith('${RouteName.subcontractReport}/')) {
    return const [Perm.subcontractReportView];
  }
  if (routePath == RouteName.subcontractPreparations) {
    return const [Perm.subcontractPreparationView];
  }
  if (location.startsWith('/subcontract/')) {
    // V436 新出仓流不允许从历史发料页空白新建。
    if (routePath == '/subcontract/material-issues/new') {
      return const [Perm.subcontractMaterialIssueView];
    }
    if (_isOrderDetailPath(location, 'subcontract')) {
      return const [Perm.subcontractOrderView, Perm.financeOrderApprovalView];
    }
    final authority = _documentRouteAuthority(
      location,
      'subcontract',
      DocumentPermissionCatalog.subcontractBySegment,
    );
    return authority == null ? const [] : [authority];
  }

  // ===== 生产管理（生产部）=====
  if (location == RouteName.production) {
    // hub：任一生产 view 即可见
    return const [
      Perm.productionPlanView,
      Perm.productionDailyReportView,
      Perm.productionReportView,
      Perm.productionWhereUsedView,
      Perm.productionMaterialAnalysisView,
      Perm.productionMaterialAnalysisCreate,
      Perm.productionMaterialAnalysisRefresh,
      Perm.productionPlanEdit,
    ];
  }
  if (location.startsWith('/production/reports')) {
    return const [Perm.productionReportView];
  }
  // 生产调度工作台（业务链 · 排产段）：view 可见列表，页面内按 edit 权限显隐合并排产面板
  if (location == RouteName.productionSchedule) {
    return const [Perm.productionPlanView];
  }
  if (location == RouteName.productionProgress) {
    return const [Perm.productionPlanView];
  }
  if (location == RouteName.productionMaterialAnalysis) {
    return const [
      Perm.productionMaterialAnalysisView,
      Perm.productionMaterialAnalysisCreate,
      Perm.productionMaterialAnalysisRefresh,
      Perm.productionMaterialAnalysisCancel,
      Perm.productionMaterialAnalysisRoute,
      Perm.productionMaterialAnalysisNotify,
      Perm.productionMaterialAnalysisGenerate,
      Perm.productionMaterialAnalysisReallocate,
      Perm.productionMaterialAnalysisCrossReallocate,
    ];
  }
  if (location == RouteName.productionMaterialAnalysisHistory) {
    return const [Perm.productionMaterialAnalysisView];
  }
  if (location.startsWith('/production/material-analyses/') &&
      location.endsWith('/summary')) {
    return const [Perm.productionMaterialAnalysisView];
  }
  // 生产链路健康初筛：与物料分析查看同权（只读扫描）
  if (location == RouteName.productionChainHealth) {
    return const [Perm.productionMaterialAnalysisView];
  }
  // 物料反查产成品（BOM where-used）：工程研发部 + 生产部共用入口
  if (location == RouteName.productionWhereUsed) {
    return const [Perm.productionWhereUsedView];
  }
  if (location == RoutePath.productionPlanNew()) {
    return const [Perm.productionMaterialAnalysisCreate];
  }
  if (location.startsWith('/production/plans')) {
    if (location.endsWith('/edit')) return const [Perm.productionPlanEdit];
    return const [Perm.productionPlanView];
  }
  if (location.startsWith('/production/daily-reports')) {
    final authority = _documentRouteAuthority(
      location,
      'production',
      DocumentPermissionCatalog.productionBySegment,
    );
    return authority == null ? const [] : [authority];
  }

  // ===== 钱流管理（财税部；finance_<...>:view/edit + ar_ap_ledger/finance_reconciliation）=====
  if (location == RouteName.finance) {
    // hub：任一钱流单据 view 即可见
    return const [
      Perm.financeReceiptView,
      Perm.financePaymentView,
      Perm.financeExpenseView,
      Perm.financeOtherIncomeView,
      Perm.financeBankTransferView,
      Perm.financeReportView,
      Perm.financeAssetView,
      Perm.arApLedgerView,
      Perm.financeReconciliationView,
      Perm.accountView,
      Perm.financeOrderApprovalView,
      Perm.salesOrderFinanceView,
      Perm.financeShipmentAudit,
    ];
  }
  if (location == RouteName.financeArAp) {
    return const [Perm.arApLedgerView];
  }
  if (location == RouteName.financeReconciliations) {
    return const [Perm.accountFlowView];
  }
  if (location == RouteName.financeChecks) {
    return const [Perm.accountView];
  }
  if (location.startsWith('/finance/')) {
    final authority = _documentRouteAuthority(
      location,
      'finance',
      DocumentPermissionCatalog.financeBySegment,
    );
    return authority == null ? const [] : [authority];
  }

  // 访客审批 / 被访人 / 保安
  if (location == '/visitor-approval' ||
      location.startsWith('/visitor-approval/')) {
    return const [Perm.visitorApprove];
  }
  if (location == '/my-visitors') return const [Perm.visitorHostConfirm];
  if (location == '/security/scan' || location.startsWith('/security/')) {
    return const [Perm.visitorVerify];
  }
  // 个人信息自助修改（员工侧）：全员入口——任何登录员工都能查看/修改自己的信息。
  // 能改什么由编辑页 + 后端 ProfileFieldPolicy 的字段策略（直改即时生效 / 需审核走 HR /
  // HR 专属只读）控制，不在这里挂权限点守卫。后端用当前用户 employeeId 落库，无越权风险。
  // HR 端：员工修改审批
  if (location == '/hr/profile-changes' ||
      location.startsWith('/hr/profile-changes/')) {
    return const [Perm.profileReview];
  }
  // 基础资料（/profile）不在此映射 = 登录即可访问
  return null;
}

/// Returns permissions that must all be present for a route.
///
/// Most routes use [requiredAnyPermFor]. This second contract is reserved for
/// compound operations where one permission must not imply another.
List<String> requiredAllPermsFor(String location) {
  if (location == '/employee/onboarding') {
    return const [
      Perm.employeeCreate,
      Perm.employeePiiEdit,
      Perm.departmentView,
    ];
  }
  if (location.startsWith('/employee/') &&
      (location.endsWith('/edit') || location.endsWith('/offboarding'))) {
    return const [Perm.employeeView];
  }
  if (location == RouteName.department) {
    // 部门页首屏会加载直属员工花名册，不能只有 department:view。
    return const [Perm.employeeView];
  }

  if (location == RouteName.financeReportCustomerPrepayment) {
    return const [
      Perm.financeReportView,
      Perm.customerPrepaymentView,
      Perm.financeViewAll,
    ];
  }

  if (location == RouteName.financeReconciliations) {
    return const [
      Perm.accountView,
      Perm.accountBalanceView,
      Perm.accountFlowView,
    ];
  }

  // 分类树与右侧主档是一个页面：两侧读取权限必须同时成立。
  if (location.startsWith('/finance/customers')) {
    return const [Perm.clientCategoryView];
  }
  if (location.startsWith('/finance/suppliers')) {
    return const [Perm.supplierCategoryView];
  }
  if (location == '${RouteName.basicinfoGoods}/new') {
    return const [Perm.goodsView, Perm.materialCategoryView];
  }
  if (location == RouteName.basicinfoGoods ||
      location.startsWith('${RouteName.basicinfoGoods}/')) {
    return const [Perm.materialCategoryView];
  }
  if (location == RouteName.basicinfoMould) {
    return const [Perm.mouldCategoryView];
  }
  if (location == RouteName.basicinfoClient) {
    return const [Perm.clientCategoryView];
  }
  if (location == RouteName.basicinfoSupplier) {
    return const [Perm.supplierCategoryView];
  }

  // 物料分析所有首屏查询都要求 view；manage/route 等只是附加动作。
  if (location == RouteName.productionMaterialAnalysis ||
      location.startsWith('/production/material-analyses/') &&
          location.endsWith('/summary')) {
    return const [Perm.productionMaterialAnalysisView];
  }

  final stockView = _documentRouteViewDependency(
    location,
    'warehouse',
    DocumentPermissionCatalog.stockBySegment,
  );
  if (stockView != null) return [stockView];

  final purchaseView = _documentRouteViewDependency(
    location,
    'purchase',
    DocumentPermissionCatalog.purchaseBySegment,
  );
  if (purchaseView != null) return [purchaseView];

  final salesView = _documentRouteViewDependency(
    location,
    'sales',
    DocumentPermissionCatalog.salesBySegment,
  );
  if (salesView != null) return [salesView];

  final uri = Uri.tryParse(location);
  if (uri?.path == '/subcontract/orders/new' &&
      uri!.queryParameters.containsKey('applicationItemIds')) {
    return const [
      Perm.subcontractOrderView,
      Perm.subcontractApplicationView,
      Perm.subcontractOrderDecompose,
    ];
  }

  final subcontractView = _documentRouteViewDependency(
    location,
    'subcontract',
    DocumentPermissionCatalog.subcontractBySegment,
  );
  if (subcontractView != null) return [subcontractView];

  final financeView = _documentRouteViewDependency(
    location,
    'finance',
    DocumentPermissionCatalog.financeBySegment,
  );
  if (financeView != null) return [financeView];

  final productionView = _documentRouteViewDependency(
    location,
    'production',
    DocumentPermissionCatalog.productionBySegment,
  );
  if (productionView != null) return [productionView];

  return const [];
}

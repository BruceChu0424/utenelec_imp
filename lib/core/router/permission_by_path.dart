// 路由 → 所需权限点映射（路由守卫用）。仅未列出的已知自助路径按登录访问。
// 文档：docs/05-架构/全局机制.md §1.4
//
// 路由使用 requiredAnyPermFor() 表达任一权限，使用 requiredAllPermsFor() 表达全部权限。
import '../../shared/auth/permissions.dart';
import 'route_names.dart';

/// 返回某路径所需的权限点列表（任一满足即可）；不需要权限返回 null。
///
/// 这是路由守卫与工作台显隐共用的唯一数据源。
List<String>? requiredAnyPermFor(String location) {
  // 账号支持可进入员工账号列表；只有超级管理员能看到并修改授权部分。
  if (location == RouteName.adminPermissions) {
    return const [Perm.accountSupport, Perm.authorizationManage];
  }
  // 审计中心与本机回执核查共享独立的只读权限；导出仍另需 audit_log:export。
  if (location == RouteName.adminAuditLogs ||
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
    if (location.endsWith('/edit') || location.endsWith('/offboarding')) {
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
  if (location == '/finance/sales-order-confirmations') {
    return const [Perm.salesOrderFinanceView];
  }
  if (location == RouteName.financeArrivalExceptions ||
      location.startsWith('${RouteName.financeArrivalExceptions}/')) {
    return const [Perm.financeOrderApprovalView];
  }
  if (location == RouteName.financeAssets ||
      location.startsWith('${RouteName.financeAssets}/')) {
    return const [Perm.financeAssetView];
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
    return const [Perm.stockDocView, Perm.warehouseInboundView];
  }
  if (location == RouteName.warehouseInspections) {
    return const [Perm.procurementInspectionView];
  }
  if (location == RouteName.warehouseInboundExpectations ||
      location == RouteName.warehouseArrivalExceptions) {
    return const [Perm.warehouseInboundView];
  }
  if (location == RouteName.warehouseReport ||
      location.startsWith('${RouteName.warehouseReport}/')) {
    return const [Perm.stockReportView];
  }
  // 货架目视化清单：货品主档库位号查询，与库存查询同权（stock:view 全员）。
  if (location == RouteName.warehouseShelfLabels) {
    return const [Perm.stockView];
  }
  if (location == RouteName.procurementArrivalExceptions ||
      location.startsWith('${RouteName.procurementArrivalExceptions}/')) {
    return const [Perm.procurementArrivalExceptionHandle];
  }
  if (location.startsWith('/warehouse/')) {
    final segments = location.split('/');
    final code = segments.length > 2 ? segments[2] : '';
    const knownCodes = {
      'TRANSFER',
      'OTHER_IN',
      'OTHER_OUT',
      'DRAW',
      'WDRAW',
      'FINISHED_IN',
      'FINISHED_OUT',
      'CHECK',
    };
    if (!knownCodes.contains(code)) return const [];
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    return [isEdit ? Perm.stockDocEdit : Perm.stockDocView];
  }
  if (location.startsWith('/purchase/')) {
    final seg = location.split('/'); // ['', 'purchase', doc, ...]
    final doc = seg.length > 2 ? seg[2] : '';
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    switch (doc) {
      case 'requests':
        return [isEdit ? Perm.purchaseRequestEdit : Perm.purchaseRequestView];
      case 'orders':
        return [isEdit ? Perm.purchaseOrderEdit : Perm.purchaseOrderView];
      case 'receipts':
        return [isEdit ? Perm.purchaseReceiptEdit : Perm.purchaseReceiptView];
      case 'returns':
        return [isEdit ? Perm.purchaseReturnEdit : Perm.purchaseReturnView];
    }
    return const [];
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
  if (location == RouteName.basicinfoGoods ||
      location.startsWith('${RouteName.basicinfoGoods}/')) {
    // 货品列表 + 新增/详情整页（/basicinfo/goods/new、/basicinfo/goods/:id）。
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
  if (location == RouteName.basicinfoAccount) return const [Perm.accountView];
  if (location == RouteName.basicinfoPaymentStyle) {
    return const [Perm.paymentStyleView];
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
  if (location == RouteName.salesOrderProgress) {
    return const [Perm.salesOrderView];
  }
  if (location.startsWith('/sales/')) {
    final seg = location.split('/'); // ['', 'sales', seg, ...]
    final doc = seg.length > 2 ? seg[2] : '';
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    switch (doc) {
      case 'quotes':
        return [isEdit ? Perm.salesQuoteEdit : Perm.salesQuoteView];
      case 'orders':
        return [isEdit ? Perm.salesOrderEdit : Perm.salesOrderView];
      case 'shipments':
        return [isEdit ? Perm.salesShipmentEdit : Perm.salesShipmentView];
      case 'other-shipments':
        return [
          isEdit ? Perm.salesOtherShipmentEdit : Perm.salesOtherShipmentView,
        ];
      case 'returns':
        return [isEdit ? Perm.salesReturnEdit : Perm.salesReturnView];
    }
    return const [];
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
  if (location.startsWith('/subcontract/')) {
    final seg = location.split('/');
    final doc = seg.length > 2 ? seg[2] : '';
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    switch (doc) {
      case 'inquiries':
        return [
          isEdit ? Perm.subcontractInquiryEdit : Perm.subcontractInquiryView,
        ];
      case 'applications':
        return [
          isEdit
              ? Perm.subcontractApplicationEdit
              : Perm.subcontractApplicationView,
        ];
      case 'orders':
        return [isEdit ? Perm.subcontractOrderEdit : Perm.subcontractOrderView];
      case 'receipts':
        return [
          isEdit ? Perm.subcontractReceiptEdit : Perm.subcontractReceiptView,
        ];
      case 'material-issues':
        return [
          isEdit
              ? Perm.subcontractMaterialIssueEdit
              : Perm.subcontractMaterialIssueView,
        ];
      case 'returns':
        return [
          isEdit ? Perm.subcontractReturnEdit : Perm.subcontractReturnView,
        ];
      case 'material-returns':
        return [
          isEdit
              ? Perm.subcontractMaterialReturnEdit
              : Perm.subcontractMaterialReturnView,
        ];
      case 'wastes':
        return [isEdit ? Perm.subcontractWasteEdit : Perm.subcontractWasteView];
    }
    return const [];
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
      Perm.productionMaterialAnalysisManage,
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
      Perm.productionMaterialAnalysisManage,
      Perm.productionMaterialAnalysisRoute,
      Perm.productionMaterialAnalysisNotify,
      Perm.productionMaterialAnalysisGenerate,
      Perm.productionMaterialAnalysisReallocate,
    ];
  }
  if (location == RouteName.productionMaterialAnalysisHistory) {
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
    return const [Perm.productionMaterialAnalysisManage];
  }
  if (location.startsWith('/production/plans')) {
    if (location.endsWith('/edit')) return const [Perm.productionPlanEdit];
    return const [Perm.productionPlanView];
  }
  if (location.startsWith('/production/daily-reports')) {
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    return [
      isEdit ? Perm.productionDailyReportEdit : Perm.productionDailyReportView,
    ];
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
    ];
  }
  if (location == RouteName.financeArAp) {
    return const [Perm.arApLedgerView];
  }
  if (location == RouteName.financeReconciliations) {
    return const [Perm.financeReconciliationView];
  }
  if (location == RouteName.financeChecks) {
    return const [Perm.accountView];
  }
  if (location.startsWith('/finance/')) {
    final seg = location.split('/');
    final doc = seg.length > 2 ? seg[2] : '';
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    switch (doc) {
      case 'receipts':
        return [isEdit ? Perm.financeReceiptEdit : Perm.financeReceiptView];
      case 'payments':
        return [isEdit ? Perm.financePaymentEdit : Perm.financePaymentView];
      case 'expenses':
        return [isEdit ? Perm.financeExpenseEdit : Perm.financeExpenseView];
      case 'incomes':
        return [
          isEdit ? Perm.financeOtherIncomeEdit : Perm.financeOtherIncomeView,
        ];
      case 'bank-transfers':
        return [
          isEdit ? Perm.financeBankTransferEdit : Perm.financeBankTransferView,
        ];
    }
    // 未知动态段不允许任何权限命中；合法静态段已在上方显式处理。
    return const [];
  }

  // 访客审批 / 被访人 / 保安
  if (location == '/visitor-approval' ||
      location.startsWith('/visitor-approval/')) {
    return const [Perm.visitorApprove];
  }
  if (location == '/my-visitors') return const [Perm.visitorHostConfirm];
  if (location == '/security/scan' || location.startsWith('/security/')) {
    return const [Perm.visitorCheckIn];
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
    return const [Perm.employeeCreate, Perm.employeePiiEdit];
  }
  return const [];
}

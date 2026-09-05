// 页面内权限入口使用的权限范围。
//
// 此文件只负责把当前员工业务路由映射到稳定的页面 surfaceKey 与标题。
// 页面包含哪些权限由后端 PermissionSurfaceRegistry 和动态权限目录权威决定；
// Flutter 不保存权限 code/prefix 副本，避免两端目录漂移。

/// 一个业务页面对应的稳定权限设置入口。
final class PagePermissionScope {
  const PagePermissionScope({required this.surfaceKey, required this.title})
    : assert(surfaceKey != '');

  /// 与后端 PermissionSurfaceRegistry 对齐的稳定业务页面键。
  final String surfaceKey;
  final String title;
}

/// 返回员工业务页的“本页权限”范围。
///
/// 未登记路径返回 null（fail closed）。登录/访客端、四个主 Tab、个人自助、设置、
/// 全局权限页、审计页和系统设置均不在这里登记，因此不会出现页面内转授入口。
PagePermissionScope? pagePermissionScopeFor(String location) {
  final path = _normalizedPath(location);
  if (path == null) return null;

  // 人事与组织。
  if (path == '/employee' || _isDescendant(path, '/employee')) {
    return _employeeScope;
  }
  if (path == '/department') return _departmentScope;
  if (path == '/payroll/generate' || path == '/payroll/review') {
    return _payrollScope;
  }
  if (path == '/expense/approval' || _isDescendant(path, '/expense/approval')) {
    return _expenseApprovalScope;
  }
  if (path == '/hr/tasks' || _isDescendant(path, '/hr/tasks')) {
    return _hrTaskScope;
  }
  if (path == '/hr/profile-changes' ||
      _isDescendant(path, '/hr/profile-changes')) {
    return _profileReviewScope;
  }

  // 通知列表属于主 Tab/全员自助；仅发布页有可委派业务动作。
  if (path == '/notice/publish') return _noticePublishScope;
  if (path == '/suggestion' || _isDescendant(path, '/suggestion')) {
    return _suggestionScope;
  }
  if (path == '/webinquiry' || _isDescendant(path, '/webinquiry')) {
    return _websiteInquiryScope;
  }

  // 基础资料及财务别名入口。
  if (path == '/finance/customers') return _clientScope;
  if (path == '/finance/suppliers') return _supplierScope;
  if (path == '/finance/accounts') return _accountScope;
  if (path == '/basicinfo') return _basicDataHubScope;
  if (path == '/basicinfo/goods' || _isDescendant(path, '/basicinfo/goods')) {
    return _goodsScope;
  }
  if (path == '/basicinfo/mould') return _mouldScope;
  if (path == '/basicinfo/client') return _clientScope;
  if (path == '/basicinfo/supplier') return _supplierScope;
  if (path == '/basicinfo/color') return _colorScope;
  if (path == '/basicinfo/unit') return _unitScope;
  if (path == '/basicinfo/currency') return _currencyScope;
  if (path == '/basicinfo/warehouse') return _warehouseMasterScope;
  if (path == '/basicinfo/account' ||
      _isDescendant(path, '/basicinfo/account')) {
    return _accountScope;
  }
  if (path == '/basicinfo/payment-style') return _paymentStyleScope;
  if (path == '/basicinfo/settlement-methods') return _settlementMethodScope;

  // 跨部门履约工作台与工程任务。
  if (path == '/operations/workbench/warehouse') {
    return _warehouseWorkbenchScope;
  }
  if (path == '/operations/workbench/purchase') {
    return _operationsPurchaseScope;
  }
  if (path == '/operations/workbench/subcontract') {
    return _operationsSubcontractScope;
  }
  if (path == '/rd/tasks') return _rdTaskScope;
  if (path == '/procurement/iqc-rejections' ||
      _isDescendant(path, '/procurement/iqc-rejections')) {
    return _procurementIqcRejectionScope;
  }
  if (path == '/procurement/arrival-exceptions' ||
      _isDescendant(path, '/procurement/arrival-exceptions')) {
    return _procurementExceptionScope;
  }

  final segments = _segments(path);
  if (segments.isEmpty) return null;

  if (segments.first == 'purchase') return _purchaseScopeFor(segments);
  if (segments.first == 'stock') return _stockScopeFor(segments);
  if (segments.first == 'warehouse') return _warehouseScopeFor(path, segments);
  if (path == '/quality/task-center') return _qualityInspectionScope;
  if (path == '/quality/production-inspections') {
    return _productionFqcInspectionsScope;
  }
  if (path == '/quality/inspection-records') {
    return _qualityInspectionRecordsScope;
  }
  if (segments.first == 'sales') return _salesScopeFor(segments);
  if (segments.first == 'subcontract') return _subcontractScopeFor(segments);
  if (segments.first == 'production') return _productionScopeFor(segments);
  if (segments.first == 'finance') return _financeScopeFor(path, segments);

  // 员工侧访客管理；访客 portal（/visitor/**）不会命中。
  if (path == '/visitor-approval' || _isDescendant(path, '/visitor-approval')) {
    return _visitorApprovalScope;
  }
  if (path == '/security/scan' || _isDescendant(path, '/security')) {
    return _securityScope;
  }

  return null;
}

/// 独立权限设置路由按稳定 surfaceKey 反查页面定义。
///
/// 这里列的是唯一业务 surface，不包含路由别名；前后端注册表测试负责防漂移。
PagePermissionScope? pagePermissionScopeBySurfaceKey(String surfaceKey) {
  final normalized = surfaceKey.trim();
  if (normalized.isEmpty) return null;
  for (final scope in _registeredPagePermissionScopes) {
    if (scope.surfaceKey == normalized) return scope;
  }
  return null;
}

const _registeredPagePermissionScopes = <PagePermissionScope>[
  _employeeScope,
  _departmentScope,
  _payrollScope,
  _expenseApprovalScope,
  _hrTaskScope,
  _profileReviewScope,
  _noticePublishScope,
  _suggestionScope,
  _websiteInquiryScope,
  _goodsScope,
  _mouldScope,
  _clientScope,
  _supplierScope,
  _colorScope,
  _unitScope,
  _currencyScope,
  _warehouseMasterScope,
  _accountScope,
  _paymentStyleScope,
  _settlementMethodScope,
  _productionWorkshopTasksScope,
  _basicDataHubScope,
  _warehouseWorkbenchScope,
  _operationsPurchaseScope,
  _operationsSubcontractScope,
  _purchaseHubScope,
  _purchaseReportScope,
  _purchaseRequestScope,
  _purchaseOrderScope,
  _purchaseReceiptScope,
  _purchaseReturnScope,
  _rdTaskScope,
  _stockBalanceScope,
  _stockMovementScope,
  _instantInventoryScope,
  _warehouseHubScope,
  _inspectionScope,
  _qualityInspectionScope,
  _productionFqcInspectionsScope,
  _qualityInspectionRecordsScope,
  _warehouseInboundScope,
  _warehousePurchaseReceiptHistoryScope,
  _warehouseSubcontractReceiptHistoryScope,
  _warehouseSubcontractOutboundHistoryScope,
  _warehouseSubcontractFinishedReturnHistoryScope,
  _warehouseSubcontractMaterialReturnHistoryScope,
  _warehouseSubcontractWasteHistoryScope,
  _warehouseIqcReturnScope,
  _warehouseIqcStockInScope,
  _warehouseQualityResultsScope,
  _warehouseReportScope,
  _shelfLabelScope,
  _subcontractOutboundScope,
  _warehouseSalesOutboundScope,
  _stockDocumentScope,
  _warehouseOutboundTasksScope,
  _warehouseInboundTasksScope,
  _warehouseDrawTasksScope,
  _stockItemScope,
  _procurementIqcRejectionScope,
  _procurementExceptionScope,
  _salesHubScope,
  _salesReportScope,
  _salesScarcityScope,
  _salesProgressScope,
  _salesQuoteScope,
  _salesOrderScope,
  _salesShipmentScope,
  _salesOtherShipmentScope,
  _salesReturnScope,
  _subcontractHubScope,
  _subcontractPreparationScope,
  _subcontractReportScope,
  _subcontractInquiryScope,
  _subcontractApplicationScope,
  _subcontractOrderScope,
  _subcontractReceiptScope,
  _subcontractMaterialIssueScope,
  _subcontractReturnScope,
  _subcontractMaterialReturnScope,
  _subcontractWasteScope,
  _productionHubScope,
  _productionPlanScope,
  _productionScheduleScope,
  _productionProgressScope,
  _materialAnalysisScope,
  _materialAnalysisHistoryScope,
  _productionDailyReportScope,
  _productionReportScope,
  _whereUsedScope,
  _financeHubScope,
  _financeOrderApprovalScope,
  _salesFinanceScope,
  _financeShipmentAuditScope,
  _financeReportScope,
  _arApScope,
  _financePayablesScope,
  _reconciliationScope,
  _financeAssetScope,
  _financeChecksScope,
  _financeReceiptScope,
  _financePaymentScope,
  _financeExpenseScope,
  _financeIncomeScope,
  _financeBankTransferScope,
  _visitorApprovalScope,
  _securityScope,
];

PagePermissionScope? _purchaseScopeFor(List<String> segments) {
  if (segments.length == 1) return _purchaseHubScope;
  if (segments[1] == 'report') {
    return segments.length <= 3 ? _purchaseReportScope : null;
  }
  final scope = _purchaseDocumentScopes[segments[1]];
  if (scope == null || !_isDocumentPath(segments)) return null;
  return scope;
}

PagePermissionScope? _stockScopeFor(List<String> segments) {
  if (segments.length == 2) {
    return switch (segments[1]) {
      'balance' => _stockBalanceScope,
      'movement' => _stockMovementScope,
      'instant-inventory' => _instantInventoryScope,
      _ => null,
    };
  }
  // 库存详情（即时库存双击进入）：/stock/item/:goodsId。
  if (segments.length == 3 && segments[1] == 'item') return _stockItemScope;
  return null;
}

PagePermissionScope? _warehouseScopeFor(String path, List<String> segments) {
  if (segments.length == 1) return _warehouseHubScope;
  if (segments.length >= 3 && segments[1] == 'history') {
    return _warehouseHistoryScopes[segments[2]];
  }
  if (path == '/warehouse/quality-results' ||
      _isDescendant(path, '/warehouse/quality-results')) {
    // 合并页专属面：IQC 入库查看+确认与退回登记查看都在本页；旧深链
    // /warehouse/iqc-stock-ins、/warehouse/iqc-returns 仍各挂原面（重定向可达）。
    return _warehouseQualityResultsScope;
  }
  if (path == '/warehouse/iqc-returns' ||
      _isDescendant(path, '/warehouse/iqc-returns')) {
    return _warehouseIqcReturnScope;
  }
  if (path == '/warehouse/iqc-stock-ins' ||
      _isDescendant(path, '/warehouse/iqc-stock-ins')) {
    return _warehouseIqcStockInScope;
  }
  if (path == '/warehouse/inspections' ||
      _isDescendant(path, '/warehouse/inspections')) {
    return _inspectionScope;
  }
  if (path == '/warehouse/inbound/expectations' ||
      path == '/warehouse/inbound/arrival-exceptions' ||
      path == '/warehouse/inbound/receipts/new') {
    return _warehouseInboundScope;
  }
  if (path == '/warehouse/report' || _isDescendant(path, '/warehouse/report')) {
    return _warehouseReportScope;
  }
  if (path == '/warehouse/shelf-labels') return _shelfLabelScope;
  if (path == '/warehouse/subcontract-outbound' ||
      _isDescendant(path, '/warehouse/subcontract-outbound')) {
    return _subcontractOutboundScope;
  }
  if (path == '/warehouse/sales-outbound' ||
      _isDescendant(path, '/warehouse/sales-outbound')) {
    return _warehouseSalesOutboundScope;
  }
  // 仓库任务中心三页（2026-09-01 重组；静态段 tasks 须先于库存单据 :code 段）。
  if (path == '/warehouse/tasks/outbound' ||
      _isDescendant(path, '/warehouse/tasks/outbound')) {
    return _warehouseOutboundTasksScope;
  }
  if (path == '/warehouse/tasks/inbound' ||
      _isDescendant(path, '/warehouse/tasks/inbound')) {
    return _warehouseInboundTasksScope;
  }
  if (path == '/warehouse/tasks/draw' ||
      _isDescendant(path, '/warehouse/tasks/draw')) {
    return _warehouseDrawTasksScope;
  }
  if (!_stockDocumentCodes.contains(segments[1])) return null;
  return _isDocumentPath(segments) ? _stockDocumentScope : null;
}

PagePermissionScope? _salesScopeFor(List<String> segments) {
  if (segments.length == 1) return _salesHubScope;
  if (segments[1] == 'report') {
    return segments.length <= 3 ? _salesReportScope : null;
  }
  if (segments[1] == 'scarcity') {
    return segments.length == 2 ? _salesScarcityScope : null;
  }
  if (segments[1] == 'progress') {
    return segments.length <= 3 ? _salesProgressScope : null;
  }
  final scope = _salesDocumentScopes[segments[1]];
  if (scope == null || !_isDocumentPath(segments)) return null;
  return scope;
}

PagePermissionScope? _subcontractScopeFor(List<String> segments) {
  if (segments.length == 1) return _subcontractHubScope;
  if (segments[1] == 'preparations') {
    return segments.length == 2 ? _subcontractPreparationScope : null;
  }
  if (segments[1] == 'report') {
    return segments.length <= 3 ? _subcontractReportScope : null;
  }
  final scope = _subcontractDocumentScopes[segments[1]];
  if (scope == null || !_isDocumentPath(segments)) return null;
  return scope;
}

PagePermissionScope? _productionScopeFor(List<String> segments) {
  if (segments.length == 1) return _productionHubScope;
  switch (segments[1]) {
    case 'schedule':
      return segments.length == 2 ? _productionScheduleScope : null;
    case 'progress':
      return segments.length == 2 ? _productionProgressScope : null;
    case 'material-analysis':
      return segments.length == 2 ? _materialAnalysisScope : null;
    case 'workshop-tasks':
      return segments.length == 2 ? _productionWorkshopTasksScope : null;
    case 'material-analyses':
      if (segments.length == 2) return _materialAnalysisHistoryScope;
      return segments.length == 4 && segments[3] == 'summary'
          ? _materialAnalysisScope
          : null;
    case 'plans':
      return _isDocumentPath(segments) ? _productionPlanScope : null;
    case 'daily-reports':
      return _isDocumentPath(segments) ? _productionDailyReportScope : null;
    case 'reports':
      return segments.length == 3 &&
              _productionReportKinds.contains(segments[2])
          ? _productionReportScope
          : null;
    case 'where-used':
      return segments.length == 2 ? _whereUsedScope : null;
    case 'chain-health':
      // 当前仍是未套对象范围的全局 SQL 初筛；对象级授权完成前不开放负责人委派。
      return null;
  }
  return null;
}

PagePermissionScope? _financeScopeFor(String path, List<String> segments) {
  if (segments.length == 1) return _financeHubScope;
  if (path == '/finance/procurement-approvals' ||
      _isDescendant(path, '/finance/procurement-approvals')) {
    return _financeOrderApprovalScope;
  }
  if (path == '/finance/sales-order-confirmations' ||
      _isDescendant(path, '/finance/sales-order-confirmations')) {
    return _salesFinanceScope;
  }
  if (path == '/finance/sales-shipment-audits') {
    return _financeShipmentAuditScope;
  }
  if (path == '/finance/procurement-arrival-exceptions' ||
      _isDescendant(path, '/finance/procurement-arrival-exceptions')) {
    return _financeOrderApprovalScope;
  }
  if (path == '/finance/report' || _isDescendant(path, '/finance/report')) {
    return _financeReportScope;
  }
  if (path == '/finance/ar-ap') return _arApScope;
  if (path == '/finance/payables') return _financePayablesScope;
  if (path == '/finance/reconciliations') return _reconciliationScope;
  if (path == '/finance/checks') return _financeChecksScope;
  if (path == '/finance/assets') return _financeAssetScope;

  final scope = _financeDocumentScopes[segments[1]];
  if (scope == null || !_isDocumentPath(segments)) return null;
  return scope;
}

bool _isDocumentPath(List<String> segments) {
  if (segments.length == 2) return true; // list
  if (segments.length == 3) return true; // new or detail
  return segments.length == 4 && segments.last == 'edit';
}

String? _normalizedPath(String location) {
  final uri = Uri.tryParse(location.trim());
  if (uri == null || !uri.path.startsWith('/')) return null;
  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

List<String> _segments(String path) =>
    path.split('/').where((segment) => segment.isNotEmpty).toList();

bool _isDescendant(String path, String root) => path.startsWith('$root/');

const _employeeScope = PagePermissionScope(
  surfaceKey: 'org.employee',
  title: '员工档案',
);

const _departmentScope = PagePermissionScope(
  surfaceKey: 'org.department',
  title: '部门与岗位',
);

const _payrollScope = PagePermissionScope(
  surfaceKey: 'hr.payroll',
  title: '工资管理',
);

const _expenseApprovalScope = PagePermissionScope(
  surfaceKey: 'hr.expense',
  title: '报销审批',
);

const _hrTaskScope = PagePermissionScope(surfaceKey: 'hr.task', title: '人事任务');

const _profileReviewScope = PagePermissionScope(
  surfaceKey: 'hr.profile',
  title: '信息变更审核',
);

const _noticePublishScope = PagePermissionScope(
  surfaceKey: 'hr.notice',
  title: '通知发布',
);

const _suggestionScope = PagePermissionScope(
  surfaceKey: 'hr.suggestion',
  title: '建议箱',
);

const _websiteInquiryScope = PagePermissionScope(
  surfaceKey: 'website.inquiry',
  title: '官网询盘',
);

const _goodsScope = PagePermissionScope(
  surfaceKey: 'basic.goods',
  title: '货品资料',
);

const _mouldScope = PagePermissionScope(
  surfaceKey: 'basic.mould',
  title: '模具资料',
);

const _clientScope = PagePermissionScope(
  surfaceKey: 'basic.client',
  title: '客户资料',
);

const _supplierScope = PagePermissionScope(
  surfaceKey: 'basic.supplier',
  title: '供应商资料',
);

const _colorScope = PagePermissionScope(surfaceKey: 'basic.color', title: '颜色');
const _unitScope = PagePermissionScope(surfaceKey: 'basic.unit', title: '基本单位');
const _currencyScope = PagePermissionScope(
  surfaceKey: 'basic.currency',
  title: '币种',
);
const _warehouseMasterScope = PagePermissionScope(
  surfaceKey: 'basic.warehouse',
  title: '仓库资料',
);
const _accountScope = PagePermissionScope(
  surfaceKey: 'basic.account',
  title: '账户',
);
const _paymentStyleScope = PagePermissionScope(
  surfaceKey: 'basic.payment-style',
  title: '收付款类别',
);
const _settlementMethodScope = PagePermissionScope(
  surfaceKey: 'basic.settlement-method',
  title: '结算方式',
);

const _basicDataHubScope = PagePermissionScope(
  surfaceKey: 'basic.hub',
  title: '基础资料',
);

const _warehouseWorkbenchScope = PagePermissionScope(
  surfaceKey: 'operations.warehouse',
  title: '仓库履约工作台',
);

const _operationsPurchaseScope = PagePermissionScope(
  surfaceKey: 'operations.purchase',
  title: '采购履约工作台',
);

const _operationsSubcontractScope = PagePermissionScope(
  surfaceKey: 'operations.subcontract',
  title: '委外履约工作台',
);

const _purchaseHubScope = PagePermissionScope(
  surfaceKey: 'purchase.hub',
  title: '采购管理',
);

const _purchaseReportScope = PagePermissionScope(
  surfaceKey: 'purchase.report',
  title: '采购报表',
);

const _purchaseRequestScope = PagePermissionScope(
  surfaceKey: 'purchase.request',
  title: '采购申请',
);
const _purchaseOrderScope = PagePermissionScope(
  surfaceKey: 'purchase.order',
  title: '采购订货',
);
const _purchaseReceiptScope = PagePermissionScope(
  surfaceKey: 'purchase.receipt',
  title: '采购收货',
);
const _purchaseReturnScope = PagePermissionScope(
  surfaceKey: 'purchase.return',
  title: '采购退货',
);
const _purchaseDocumentScopes = <String, PagePermissionScope>{
  'requests': _purchaseRequestScope,
  'orders': _purchaseOrderScope,
  'receipts': _purchaseReceiptScope,
  'returns': _purchaseReturnScope,
};

const _rdTaskScope = PagePermissionScope(
  surfaceKey: 'hr.rd-task',
  title: '工程研发任务',
);

const _stockBalanceScope = PagePermissionScope(
  surfaceKey: 'warehouse.stock-balance',
  title: '库存余额',
);
const _stockMovementScope = PagePermissionScope(
  surfaceKey: 'warehouse.stock-movement',
  title: '出入库流水',
);
const _instantInventoryScope = PagePermissionScope(
  surfaceKey: 'warehouse.instant-inventory',
  title: '即时库存',
);

const _warehouseHubScope = PagePermissionScope(
  surfaceKey: 'warehouse.hub',
  title: '仓库管理',
);
const _inspectionScope = PagePermissionScope(
  surfaceKey: 'purchase.inspection',
  title: '待检处置',
);
const _qualityInspectionScope = PagePermissionScope(
  // V456：改挂品质任务中心专属面（IQC/FQC 两域 view + 本页两个决定动作）。
  surfaceKey: 'quality.task-center',
  title: '品质任务中心',
);
const _productionFqcInspectionsScope = PagePermissionScope(
  surfaceKey: 'quality.production-fqc',
  title: '生产成品质检',
);
const _qualityInspectionRecordsScope = PagePermissionScope(
  // V475：品质检测记录页补挂专属面（V455 全量收口的漏网，2 码只读）。
  surfaceKey: 'quality.inspection-records',
  title: '品质检测记录',
);
const _warehouseInboundScope = PagePermissionScope(
  surfaceKey: 'warehouse.inbound',
  title: '到货与入库',
);
const _warehousePurchaseReceiptHistoryScope = PagePermissionScope(
  surfaceKey: 'warehouse.purchase-receipt-history',
  title: '仓库采购收货历史',
);
const _warehouseSubcontractReceiptHistoryScope = PagePermissionScope(
  surfaceKey: 'warehouse.subcontract-receipt-history',
  title: '仓库委外进仓历史',
);
const _warehouseSubcontractOutboundHistoryScope = PagePermissionScope(
  surfaceKey: 'warehouse.subcontract-outbound-history',
  title: '仓库委外出仓历史',
);
const _warehouseSubcontractFinishedReturnHistoryScope = PagePermissionScope(
  surfaceKey: 'warehouse.subcontract-finished-return-history',
  title: '仓库委外成品退货历史',
);
const _warehouseSubcontractMaterialReturnHistoryScope = PagePermissionScope(
  surfaceKey: 'warehouse.subcontract-material-return-history',
  title: '仓库委外材料退回历史',
);
const _warehouseSubcontractWasteHistoryScope = PagePermissionScope(
  surfaceKey: 'warehouse.subcontract-waste-history',
  title: '仓库委外损耗历史',
);
const _warehouseIqcReturnScope = PagePermissionScope(
  surfaceKey: 'warehouse.iqc-return',
  title: 'IQC 不合格实物退回',
);
const _warehouseIqcStockInScope = PagePermissionScope(
  surfaceKey: 'warehouse.iqc-stock-in',
  // 旧「IQC 合格待入库」深链重定向进合并页；合并页本体 V456 起挂专属面。
  title: 'IQC 入库',
);
const _warehouseQualityResultsScope = PagePermissionScope(
  surfaceKey: 'warehouse.quality-results',
  title: '品质部检查结果',
);
const _warehouseHistoryScopes = <String, PagePermissionScope>{
  'purchase-receipts': _warehousePurchaseReceiptHistoryScope,
  'subcontract-receipts': _warehouseSubcontractReceiptHistoryScope,
  'subcontract-material-issues': _warehouseSubcontractOutboundHistoryScope,
  'subcontract-returns': _warehouseSubcontractFinishedReturnHistoryScope,
  'subcontract-material-returns':
      _warehouseSubcontractMaterialReturnHistoryScope,
  'subcontract-wastes': _warehouseSubcontractWasteHistoryScope,
};
const _warehouseReportScope = PagePermissionScope(
  surfaceKey: 'warehouse.report',
  title: '仓库报表',
);
const _shelfLabelScope = PagePermissionScope(
  surfaceKey: 'warehouse.shelf-label',
  title: '货架目视化',
);
const _subcontractOutboundScope = PagePermissionScope(
  surfaceKey: 'warehouse.subcontract-outbound',
  title: '委外出仓',
);
const _warehouseSalesOutboundScope = PagePermissionScope(
  surfaceKey: 'warehouse.sales-outbound',
  title: '仓库销售出库',
);
const _stockDocumentScope = PagePermissionScope(
  surfaceKey: 'warehouse.stock-document',
  title: '库存单据',
);
const _warehouseOutboundTasksScope = PagePermissionScope(
  surfaceKey: 'warehouse.outbound-tasks',
  title: '出库任务中心',
);
const _warehouseInboundTasksScope = PagePermissionScope(
  surfaceKey: 'warehouse.inbound-tasks',
  title: '入库任务中心',
);
const _warehouseDrawTasksScope = PagePermissionScope(
  surfaceKey: 'warehouse.draw-tasks',
  title: '生产领料任务中心',
);
const _stockItemScope = PagePermissionScope(
  surfaceKey: 'warehouse.stock-item',
  title: '库存详情',
);
const _procurementIqcRejectionScope = PagePermissionScope(
  surfaceKey: 'procurement.iqc-rejection',
  title: '采购与委外 IQC 拒收闭环',
);
const _procurementExceptionScope = PagePermissionScope(
  surfaceKey: 'purchase.arrival-exception',
  title: '供应商退回任务',
);
const _stockDocumentCodes = <String>{
  'TRANSFER',
  'OTHER_IN',
  'OTHER_OUT',
  'DRAW',
  'WDRAW',
  'FINISHED_IN',
  'FINISHED_OUT',
  'CHECK',
};

const _salesHubScope = PagePermissionScope(
  surfaceKey: 'sales.hub',
  title: '销售管理',
);
const _salesReportScope = PagePermissionScope(
  surfaceKey: 'sales.report',
  title: '销售报表',
);
const _salesScarcityScope = PagePermissionScope(
  surfaceKey: 'sales.scarcity',
  title: '销售稀缺分配',
);
const _salesProgressScope = PagePermissionScope(
  surfaceKey: 'sales.progress',
  title: '销售订单进度',
);
const _salesQuoteScope = PagePermissionScope(
  surfaceKey: 'sales.quote',
  title: '销售报价',
);
const _salesOrderScope = PagePermissionScope(
  surfaceKey: 'sales.order',
  title: '销售订货',
);
const _salesShipmentScope = PagePermissionScope(
  surfaceKey: 'sales.shipment',
  title: '销售出货',
);
const _salesOtherShipmentScope = PagePermissionScope(
  surfaceKey: 'sales.other-shipment',
  title: '其他出货',
);
const _salesReturnScope = PagePermissionScope(
  surfaceKey: 'sales.return',
  title: '销售退货',
);
const _salesDocumentScopes = <String, PagePermissionScope>{
  'quotes': _salesQuoteScope,
  'orders': _salesOrderScope,
  'shipments': _salesShipmentScope,
  'other-shipments': _salesOtherShipmentScope,
  'returns': _salesReturnScope,
};

const _subcontractHubScope = PagePermissionScope(
  surfaceKey: 'subcontract.hub',
  title: '委外管理',
);
const _subcontractPreparationScope = PagePermissionScope(
  surfaceKey: 'subcontract.preparation',
  title: '委外前置自制',
);
const _subcontractReportScope = PagePermissionScope(
  surfaceKey: 'subcontract.report',
  title: '委外报表',
);
const _subcontractInquiryScope = PagePermissionScope(
  surfaceKey: 'subcontract.inquiry',
  title: '委外询价',
);
const _subcontractApplicationScope = PagePermissionScope(
  surfaceKey: 'subcontract.application',
  title: '委外申请',
);
const _subcontractOrderScope = PagePermissionScope(
  surfaceKey: 'subcontract.order',
  title: '委外订货',
);
const _subcontractReceiptScope = PagePermissionScope(
  surfaceKey: 'subcontract.receipt',
  title: '委外进仓',
);
const _subcontractMaterialIssueScope = PagePermissionScope(
  surfaceKey: 'subcontract.material-issue',
  title: '委外发料',
);
const _subcontractReturnScope = PagePermissionScope(
  surfaceKey: 'subcontract.return',
  title: '委外退货',
);
const _subcontractMaterialReturnScope = PagePermissionScope(
  surfaceKey: 'subcontract.material-return',
  title: '委外退料',
);
const _subcontractWasteScope = PagePermissionScope(
  surfaceKey: 'subcontract.waste',
  title: '委外损耗',
);
const _subcontractDocumentScopes = <String, PagePermissionScope>{
  'inquiries': _subcontractInquiryScope,
  'applications': _subcontractApplicationScope,
  'orders': _subcontractOrderScope,
  'receipts': _subcontractReceiptScope,
  'material-issues': _subcontractMaterialIssueScope,
  'returns': _subcontractReturnScope,
  'material-returns': _subcontractMaterialReturnScope,
  'wastes': _subcontractWasteScope,
};

const _productionHubScope = PagePermissionScope(
  surfaceKey: 'production.hub',
  title: '生产管理',
);
const _productionPlanScope = PagePermissionScope(
  surfaceKey: 'production.plan',
  title: '生产计划',
);
// V456：调度看板/进度页挂 view-only 专属面；完整生产动作仍在 /production/plans
// 的 production.plan 面授予（安全收紧：不再随看板委派全套生产权限）。
const _productionScheduleScope = PagePermissionScope(
  surfaceKey: 'production.schedule',
  title: '生产调度',
);
const _productionProgressScope = PagePermissionScope(
  surfaceKey: 'production.progress',
  title: '生产进度',
);
const _materialAnalysisScope = PagePermissionScope(
  surfaceKey: 'production.material-analysis',
  title: '物料分析',
);
const _productionWorkshopTasksScope = PagePermissionScope(
  surfaceKey: 'production.workshop-tasks',
  title: '我的车间任务',
);
const _materialAnalysisHistoryScope = PagePermissionScope(
  surfaceKey: 'production.material-analysis-history',
  title: '物料分析记录',
);
const _productionDailyReportScope = PagePermissionScope(
  surfaceKey: 'production.daily-report',
  title: '生产日报',
);
const _productionReportScope = PagePermissionScope(
  surfaceKey: 'production.report',
  title: '生产报表',
);
const _whereUsedScope = PagePermissionScope(
  surfaceKey: 'production.where-used',
  title: '物料反查',
);
// 生产报表 surface 只登记已接路由的两段（plan-detail/plan-summary）；
// 日报明细/汇总报表尚未接线，登记即误导，接线时再加。
const _productionReportKinds = <String>{'plan-detail', 'plan-summary'};

const _financeHubScope = PagePermissionScope(
  surfaceKey: 'finance.hub',
  title: '钱流管理',
);
const _financeOrderApprovalScope = PagePermissionScope(
  surfaceKey: 'finance.order-approval',
  title: '采购与委外财务审批',
);
const _salesFinanceScope = PagePermissionScope(
  surfaceKey: 'finance.sales-order-confirmation',
  title: '销售订单财务确认',
);
const _financeShipmentAuditScope = PagePermissionScope(
  surfaceKey: 'finance.sales-shipment-audit',
  title: '出货财务审核',
);
const _financeReportScope = PagePermissionScope(
  surfaceKey: 'finance.report',
  title: '财务报表',
);
const _arApScope = PagePermissionScope(
  surfaceKey: 'finance.ar-ap',
  title: '应收应付台账',
);
const _financePayablesScope = PagePermissionScope(
  // V475：应付结算工作台补挂专属面（V455 全量收口的漏网）。
  surfaceKey: 'finance.payables',
  title: '采购委外应付结算工作台',
);
const _reconciliationScope = PagePermissionScope(
  surfaceKey: 'finance.reconciliation',
  title: '财务对账',
);
const _financeAssetScope = PagePermissionScope(
  surfaceKey: 'finance.asset',
  title: '资产与待摊',
);
const _financeChecksScope = PagePermissionScope(
  surfaceKey: 'finance.checks',
  title: '账户与支票',
);
const _financeReceiptScope = PagePermissionScope(
  surfaceKey: 'finance.receipt',
  title: '收款单',
);
const _financePaymentScope = PagePermissionScope(
  surfaceKey: 'finance.payment',
  title: '付款单',
);
const _financeExpenseScope = PagePermissionScope(
  surfaceKey: 'finance.expense',
  title: '费用单',
);
const _financeIncomeScope = PagePermissionScope(
  surfaceKey: 'finance.other-income',
  title: '其他收入',
);
const _financeBankTransferScope = PagePermissionScope(
  surfaceKey: 'finance.bank-transfer',
  title: '银行转账',
);
const _financeDocumentScopes = <String, PagePermissionScope>{
  'receipts': _financeReceiptScope,
  'payments': _financePaymentScope,
  'expenses': _financeExpenseScope,
  'incomes': _financeIncomeScope,
  'bank-transfers': _financeBankTransferScope,
};

const _visitorApprovalScope = PagePermissionScope(
  surfaceKey: 'hr.visitor-approval',
  title: '访客审批',
);
const _securityScope = PagePermissionScope(
  surfaceKey: 'hr.visitor-security',
  title: '访客核验',
);

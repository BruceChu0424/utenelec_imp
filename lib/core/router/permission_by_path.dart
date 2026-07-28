// 路由 → 所需权限点映射（路由守卫用）。未列出的路径 = 登录即可访问。
// 文档：docs/05-架构/全局机制.md §1.4
//
// 单一权限点的路径直接用 requiredPermFor()；
// "多级权限任一满足即可"的路径（如客户资料 self/department/all）
// 用 requiredAnyPermFor() 返回列表，任一命中即放行。
import '../../shared/auth/permissions.dart';
import 'route_names.dart';

/// 返回某路径所需的权限点列表（任一满足即可）；不需要权限返回 null。
///
/// 这是路由守卫与工作台显隐共用的唯一数据源。
List<String>? requiredAnyPermFor(String location) {
  // 系统管理（超管：员工角色/权限分配）
  if (location == '/admin/permissions' || location.startsWith('/admin/')) {
    return const [Perm.userManage];
  }
  // 员工档案
  if (location == '/employee' || location.startsWith('/employee/')) {
    if (location == '/employee/onboarding') return const [Perm.employeeCreate];
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
    return const [Perm.expenseApprove];
  }
  if (location == '/payroll/review') return const [Perm.payrollReview];
  if (location == '/payroll/generate') return const [Perm.payrollGenerate];
  if (location == '/finance/report') return const [Perm.financeReportView];
  // 客户资料：self/department/all 三级数据范围，任一即达最低门槛
  if (location.startsWith('/finance/customers')) {
    return const [
      Perm.customerViewSelf,
      Perm.customerViewDepartment,
      Perm.customerViewAll,
    ];
  }
  if (location.startsWith('/finance/suppliers')) {
    return const [Perm.supplierView];
  }
  if (location.startsWith('/finance/accounts')) {
    return const [Perm.accountView];
  }
  // 采购管理（PMC 运营部；V44 细粒度：view 全员、edit 归 PMC）
  if (location == RouteName.purchase) {
    // hub：任一采购单据 view 即可见
    return const [
      Perm.purchaseRequestView,
      Perm.purchaseOrderView,
      Perm.purchaseReceiptView,
      Perm.purchaseReturnView,
    ];
  }
  if (location == '/purchase/report') return const [Perm.purchaseReportView];
  // 库存查询（余额 + 流水）
  if (location.startsWith('/stock/')) return const [Perm.stockView];
  // 仓库管理（8 单据，stock_doc:view 全员 / edit 归 PMC）
  if (location == RouteName.warehouse) return const [Perm.stockDocView];
  if (location.startsWith('/warehouse/')) {
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
    return const [
      Perm.purchaseRequestView,
      Perm.purchaseOrderView,
      Perm.purchaseReceiptView,
      Perm.purchaseReturnView,
    ];
  }
  // 通知发布
  if (location == '/notice/publish') return const ['notice:publish'];
  // 实验室
  if (location.startsWith('/lab/')) return const ['lab:test:view'];

  // ===== 销售管理（综合营销部；V51 seed：sales_<quote|order|shipment|other_shipment|return>:view/edit）=====
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
  if (location == RouteName.salesReport) return const [Perm.salesReportView];
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
          isEdit ? Perm.salesOtherShipmentEdit : Perm.salesOtherShipmentView
        ];
      case 'returns':
        return [isEdit ? Perm.salesReturnEdit : Perm.salesReturnView];
    }
    return const [Perm.salesReportView];
  }

  // ===== 委外管理（综合营销部；V53 seed：subcontract_<...>:view/edit）=====
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
  if (location == RouteName.subcontractReport) {
    return const [Perm.subcontractReportView];
  }
  if (location.startsWith('/subcontract/')) {
    final seg = location.split('/');
    final doc = seg.length > 2 ? seg[2] : '';
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    switch (doc) {
      case 'inquiries':
        return [
          isEdit ? Perm.subcontractInquiryEdit : Perm.subcontractInquiryView
        ];
      case 'applications':
        return [
          isEdit
              ? Perm.subcontractApplicationEdit
              : Perm.subcontractApplicationView
        ];
      case 'orders':
        return [
          isEdit ? Perm.subcontractOrderEdit : Perm.subcontractOrderView
        ];
      case 'receipts':
        return [
          isEdit ? Perm.subcontractReceiptEdit : Perm.subcontractReceiptView
        ];
      case 'material-issues':
        return [
          isEdit
              ? Perm.subcontractMaterialIssueEdit
              : Perm.subcontractMaterialIssueView
        ];
      case 'returns':
        return [
          isEdit ? Perm.subcontractReturnEdit : Perm.subcontractReturnView
        ];
      case 'material-returns':
        return [
          isEdit
              ? Perm.subcontractMaterialReturnEdit
              : Perm.subcontractMaterialReturnView
        ];
      case 'wastes':
        return [isEdit ? Perm.subcontractWasteEdit : Perm.subcontractWasteView];
    }
    return const [Perm.subcontractReportView];
  }

  // ===== 生产管理（生产部；V55 seed 细粒度）=====
  if (location == RouteName.production) {
    // hub：任一生产 view 即可见
    return const [
      Perm.productionPlanView,
      Perm.productionDailyReportView,
      Perm.productionReportView,
    ];
  }
  if (location.startsWith('/production/reports')) {
    return const [Perm.productionReportView];
  }
  // 物料反查产成品（BOM where-used）：工程研发部 + 生产部共用入口
  if (location == RouteName.productionWhereUsed) {
    return const [Perm.productionWhereUsedView];
  }
  if (location.startsWith('/production/plans')) {
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    return [isEdit ? Perm.productionPlanEdit : Perm.productionPlanView];
  }
  if (location.startsWith('/production/daily-reports')) {
    final isEdit = location.endsWith('/new') || location.endsWith('/edit');
    return [
      isEdit ? Perm.productionDailyReportEdit : Perm.productionDailyReportView
    ];
  }

  // ===== 钱流管理（财税部；V57 seed：finance_<...>:view/edit + ar_ap_ledger/finance_reconciliation）=====
  if (location == RouteName.finance) {
    // hub：任一钱流单据 view 即可见
    return const [
      Perm.financeReceiptView,
      Perm.financePaymentView,
      Perm.financeExpenseView,
      Perm.financeOtherIncomeView,
      Perm.financeBankTransferView,
    ];
  }
  if (location == RouteName.financeReport) return const [Perm.financeReportView];
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
          isEdit ? Perm.financeOtherIncomeEdit : Perm.financeOtherIncomeView
        ];
      case 'bank-transfers':
        return [
          isEdit ? Perm.financeBankTransferEdit : Perm.financeBankTransferView
        ];
    }
    // 其它已上面的字面量段处理；兜底放行（占位页：客户/供应商资料走 self/department/all）
    return null;
  }

  // 生产辅助：库存 / 空调（保留旧 broad 守卫）
  if (location.startsWith('/inventory') || location.startsWith('/hvac')) {
    return const ['production:view'];
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

/// 返回某路径所需权限点；不需要权限返回 null。
///
/// 兼容旧签名：对"任一满足"的多权限路径只返回第一个（最低门槛）。
/// 新代码请直接用 [requiredAnyPermFor]。
String? requiredPermFor(String location) =>
    requiredAnyPermFor(location)?.first;

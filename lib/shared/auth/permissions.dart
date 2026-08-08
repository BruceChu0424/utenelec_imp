// 权限点常量（与后端 permissions 表 code 对齐）+ 当前用户权限/角色 Provider。
// 文档：docs/05-架构/全局机制.md §1
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/role.dart';
import '../providers/session_provider.dart';

abstract final class Perm {
  static const employeeView = 'employee:view';
  static const employeeCreate = 'employee:create';
  static const employeeEdit = 'employee:edit';
  static const employeeDelete = 'employee:delete';
  static const departmentView = 'department:view';
  static const departmentEdit = 'department:edit';

  /// 锁定、启停账号以及重置一次性临时密码。
  static const accountSupport = 'account:support';

  /// 权限、数据范围和系统设置管理；后端同时要求超级管理员身份。
  static const authorizationManage = 'authorization:manage';

  /// 查看审计中心及核查本机操作回执。
  static const auditLogView = 'audit_log:view';

  /// 审计日志加密导出；独立于查看权限，只授予明确指定的导出人员。
  static const auditLogExport = 'audit_log:export';
  static const payrollViewSelf = 'payroll:view:self';
  static const payrollViewAll = 'payroll:view:all';
  static const payrollGenerate = 'payroll:generate';
  static const payrollReview = 'payroll:review';
  static const payrollPublish = 'payroll:publish';
  static const payrollExport = 'payroll:export';
  static const expenseApply = 'expense:apply';
  static const expenseApprove = 'expense:approve';
  static const expensePay = 'expense:pay';
  static const visitorView = 'visitor:view';
  static const visitorApply = 'visitor:apply';
  static const visitorApprove = 'visitor:approve';
  static const visitorHostConfirm = 'visitor:host-confirm';
  static const visitorCheckIn = 'visitor:check-in';
  static const visitorBlacklist = 'visitor:blacklist';

  // 个人信息自助修改（Phase 6）
  static const profileEditSelf = 'profile:edit:self';
  static const profileReview = 'profile:review';

  /// 查看员工薪资/补偿字段（HR/finance/admin）；
  /// 渐进替代 DataAccessPolicy 里按角色名硬编码的判断。
  static const employeePiiView = 'employee:pii:view';
  static const employeePiiEdit = 'employee:pii:edit';
  static const employeeCompensationView = 'employee:compensation:view';
  static const employeeCompensationEdit = 'employee:compensation:edit';

  /// 员工资料打印与导出（花名册/部门架构图等文档下载）—— ADR-021，独立于查看权限。
  static const employeeExport = 'employee:export';

  // ===== 采购管理（PMC 运营部；后端 V44 细粒度种子化）=====
  /// 采购申请单
  static const purchaseRequestView = 'purchase_request:view';
  static const purchaseRequestEdit = 'purchase_request:edit';

  /// 采购订货单
  static const purchaseOrderView = 'purchase_order:view';
  static const purchaseOrderEdit = 'purchase_order:edit';

  /// 采购收货单
  static const purchaseReceiptView = 'purchase_receipt:view';
  static const purchaseReceiptEdit = 'purchase_receipt:edit';

  /// 采购退货单
  static const purchaseReturnView = 'purchase_return:view';
  static const purchaseReturnEdit = 'purchase_return:edit';

  /// 采购报表
  static const purchaseReportView = 'purchase_report:view';

  /// 查看全部采购单据（对象级授权 V233；按制单人 maker_id 隔离，持此权限看全部）。
  static const purchaseViewAll = 'purchase:view:all';

  // ===== 财税部主数据入口（复用基础资料真实页面）=====
  /// 供应商资料
  static const supplierView = 'supplier:view';
  static const supplierEdit = 'supplier:edit';

  /// 账户资料
  static const accountView = 'account:view';
  static const accountEdit = 'account:edit';
  static const accountExport = 'account:export';

  /// 货品资料分类（基础资料）
  static const materialCategoryView = 'material_category:view';
  static const materialCategoryEdit = 'material_category:edit';

  /// 货品主档（基础资料；V32 已将 goods:view 授予全部部门）
  static const goodsView = 'goods:view';
  static const goodsEdit = 'goods:edit';
  static const goodsExport = 'goods:export';
  static const goodsViewAll = 'goods:view:all';
  /// 编辑货品售价/折扣（V226；默认仅财务部，可在权限管理页授权他人）。
  static const goodsPriceEdit = 'goods:price:edit';
  /// 查看货品成本（V226；默认仅财务部，未授权时详情隐藏「成本预算」Tab）。
  static const goodsCostView = 'goods:cost:view';
  /// 查看货品折扣（V227；默认仅销售部+财务部，未授权时详情/列表隐藏折扣字段）。
  static const goodsDiscountView = 'goods:discount:view';

  /// 模具资料分类（基础资料）
  static const mouldCategoryView = 'mould_category:view';
  static const mouldCategoryEdit = 'mould_category:edit';

  /// 模具主档（基础资料；V34 已将 mould:view 授予全部部门）
  static const mouldView = 'mould:view';
  static const mouldEdit = 'mould:edit';

  /// 客户资料分类（基础资料）
  static const clientCategoryView = 'client_category:view';
  static const clientCategoryEdit = 'client_category:edit';

  /// 客户主档（基础资料；V36 已将 client:view 授予全部部门）
  static const clientView = 'client:view';
  static const clientEdit = 'client:edit';
  static const clientExport = 'client:export';
  static const clientViewAll = 'client:view:all';

  /// 供应商资料分类（基础资料）
  static const supplierCategoryView = 'supplier_category:view';
  static const supplierCategoryEdit = 'supplier_category:edit';
  static const supplierExport = 'supplier:export';

  /// 颜色主档（基础资料；扁平结构，无分类树）
  static const colorView = 'color:view';
  static const colorEdit = 'color:edit';

  /// 基本单位主档（基础资料；扁平结构，无分类树）
  static const unitView = 'unit:view';
  static const unitEdit = 'unit:edit';

  /// 币种主档（基础资料；扁平结构，V42 种子化，view 全员 / edit 归 PMC）
  static const currencyView = 'currency:view';
  static const currencyEdit = 'currency:edit';
  static const currencyExport = 'currency:export';

  /// 仓库主档（基础资料；扁平结构，V43 种子化，view 全员 / edit 归 PMC）
  static const warehouseView = 'warehouse:view';
  static const warehouseEdit = 'warehouse:edit';

  /// 库存查看（V45 种子化，全员；本轮采购审核联动库存，库存页未接入）
  static const stockView = 'stock:view';

  /// 领导或库存负责人明确授权后，可直接把库存余额修正为目标值。
  static const stockBalanceAdjust = 'stock:balance:adjust';

  /// 仓库管理单据（V48 种子化，view 全员 / edit 归 PMC）
  static const stockDocView = 'stock_doc:view';
  static const stockDocEdit = 'stock_doc:edit';

  /// 查看全部仓库单据（对象级授权 V233；按制单人 maker_id 隔离，持此权限看全部）。
  static const stockDocViewAll = 'stock_doc:view:all';

  /// 仓库报表（V67 种子化）
  static const stockReportView = 'stock_report:view';
  static const stockReportExport = 'stock_report:export';

  /// 财务批准后的预计到货及仓储异常只读任务。
  static const warehouseInboundView = 'warehouse_inbound:view';

  /// 未批准超量仅允许服务端认定的原下单人完成供应商退回。
  static const procurementArrivalExceptionHandle =
      'supplier_return_task:handle';

  // ===== 实验室（V06 种子化）=====
  static const labTestView = 'lab:test:view';
  static const labTestUpload = 'lab:test:upload';

  // ===== 销售管理（综合营销部；V51 seed）=====
  static const salesQuoteView = 'sales_quote:view';
  static const salesQuoteEdit = 'sales_quote:edit';
  static const salesOrderView = 'sales_order:view';
  static const salesOrderEdit = 'sales_order:edit';
  static const salesOrderPriceView = 'sales_order:price:view';
  static const salesOrderChangePlanned = 'sales_order:change_planned';
  static const salesOrderConfirmPartialShipment =
      'sales_order:confirm_partial_shipment';

  /// V178 订单行设优先级（急单/普通/现货）：稀缺让单决策用。
  static const salesOrderPriority = 'sales_order:priority';

  /// V178 稀缺库存让单（释放低优先级订单行的现货预留）：主管仲裁用。
  static const salesOrderReallocate = 'sales_order:reallocate';
  static const salesShipmentView = 'sales_shipment:view';
  static const salesShipmentEdit = 'sales_shipment:edit';
  static const salesShipmentReject = 'sales_shipment:reject';
  static const salesShipmentWarehouseWork = 'sales_shipment:warehouse-work';
  static const salesOtherShipmentView = 'sales_other_shipment:view';
  static const salesOtherShipmentEdit = 'sales_other_shipment:edit';
  static const salesReturnView = 'sales_return:view';
  static const salesReturnEdit = 'sales_return:edit';
  static const salesReturnQualityView = 'sales_return_quality:view';
  static const salesReturnQualityHandle = 'sales_return_quality:handle';
  static const salesReportView = 'sales_report:view';
  static const salesReportExport = 'sales_report:export';
  static const salesViewAll = 'sales:view:all';

  // ===== 委外管理（综合营销部；V53 seed）=====
  static const subcontractInquiryView = 'subcontract_inquiry:view';
  static const subcontractInquiryEdit = 'subcontract_inquiry:edit';
  static const subcontractApplicationView = 'subcontract_application:view';
  static const subcontractApplicationEdit = 'subcontract_application:edit';
  static const subcontractOrderView = 'subcontract_order:view';
  static const subcontractOrderEdit = 'subcontract_order:edit';
  static const subcontractReceiptView = 'subcontract_receipt:view';
  static const subcontractReceiptEdit = 'subcontract_receipt:edit';
  static const subcontractMaterialIssueView = 'subcontract_material_issue:view';
  static const subcontractMaterialIssueEdit = 'subcontract_material_issue:edit';
  static const subcontractReturnView = 'subcontract_return:view';
  static const subcontractReturnEdit = 'subcontract_return:edit';
  static const subcontractMaterialReturnView =
      'subcontract_material_return:view';
  static const subcontractMaterialReturnEdit =
      'subcontract_material_return:edit';
  static const subcontractWasteView = 'subcontract_waste:view';
  static const subcontractWasteEdit = 'subcontract_waste:edit';
  static const subcontractReportView = 'subcontract_report:view';
  static const subcontractReportExport = 'subcontract_report:export';

  /// 查看全部委外单据（对象级授权 V233；按制单人 maker_id 隔离，持此权限看全部）。
  static const subcontractViewAll = 'subcontract:view:all';

  // ===== 生产管理（生产部；V55 seed 细粒度）=====
  static const productionPlanView = 'production_plan:view';
  static const productionPlanEdit = 'production_plan:edit';
  static const productionDailyReportView = 'production_daily_report:view';
  static const productionDailyReportEdit = 'production_daily_report:edit';
  static const productionReportView = 'production_report:view';
  static const productionReportExport = 'production_report:export';
  static const productionWhereUsedView = 'production_where_used:view';

  /// 查看全部生产单据（对象级授权 V233；生产计划/日报按制单人 maker_id 隔离，持此权限看全部）。
  static const productionPlanViewAll = 'production_plan:view:all';

  // ===== 钱流管理（财税部；V57 seed）=====
  static const financeReceiptView = 'finance_receipt:view';
  static const financeReceiptEdit = 'finance_receipt:edit';
  static const financePaymentView = 'finance_payment:view';
  static const financePaymentEdit = 'finance_payment:edit';
  static const financeExpenseView = 'finance_expense:view';
  static const financeExpenseEdit = 'finance_expense:edit';
  static const financeOtherIncomeView = 'finance_other_income:view';
  static const financeOtherIncomeEdit = 'finance_other_income:edit';
  static const financeBankTransferView = 'finance_bank_transfer:view';
  static const financeBankTransferEdit = 'finance_bank_transfer:edit';
  static const financeReportView = 'finance_report:view';
  static const financeReportExport = 'finance_report:export';
  static const financeAssetView = 'finance_asset:view';
  static const financeAssetEdit = 'finance_asset:edit';
  static const financeAssetApprove = 'finance_asset:approve';
  static const financeAssetPost = 'finance_asset:post';
  static const financeAssetDispose = 'finance_asset:dispose';
  static const financeAssetExport = 'finance_asset:export';
  static const financeAssetPeriodManage = 'finance_asset_period:manage';
  static const financePostExecute = 'finance_post:execute';
  static const financeShipmentAudit = 'finance_shipment_audit';

  /// 采购/委外订货单财务审批任务（V229/ADR-027：财务部门持 review 权限的审核组均可审）。
  static const financeOrderApprovalView = 'finance_order_approval:view';
  static const financeOrderApprovalReview = 'finance_order_approval:review';

  static const arApLedgerView = 'ar_ap_ledger:view';
  static const financeReconciliationView = 'finance_reconciliation:view';

  // ===== 收付款类别（基础资料）=====
  /// 收付款类别：view 全员可见（路由不挂守卫），edit 归财务。
  static const paymentStyleView = 'payment_style:view';
  static const paymentStyleEdit = 'payment_style:edit';

  // ===== 通知、建议与报表导出 =====
  static const noticeRead = 'notice:read';
  static const noticePublish = 'notice:publish';
  static const suggestionSubmit = 'suggestion:submit';
  static const suggestionReply = 'suggestion:reply';
  static const purchaseReportExport = 'purchase_report:export';

  // 注：supplierView/supplierEdit（'supplier:view'/'supplier:edit'）见上方财税部段——
  // 后端 V38 以「主数据」category 种子化同一 code，基础资料与财税业务视图共用，故不重复定义。

  // ===== 工程研发部任务中心 =====
  static const rdTaskView = 'rd_task:view';
  static const rdTaskEdit = 'rd_task:edit';
  static const rdTaskResolve = 'rd_task:resolve';
  /// 生产待排产 BOM 缺失转发工程研发部（独立权限点，不复用 production_plan:edit）。
  static const productionPlanForwardRd = 'production_plan:forward_rd';
}

/// 当前用户的功能权限集合。
///
/// 超级管理员（[UserProfile.superAdmin] == true）后端已经把全量 permissions 推过来，
/// 因此这里的 Set 已包含所有权限点。如果未来后端没推全，前端也会再 union 一个
/// "所有已知 Perm" 兜底——但主路径以后端为准。
final currentPermissionsProvider = Provider<Set<String>>((ref) {
  final user = ref.watch(sessionProvider).user;
  if (user == null) return const <String>{};
  if (user.superAdmin) {
    // 兜底：union 所有已知 Perm 常量。即便后端漏推某个新增权限也能 work。
    return <String>{
      Perm.employeeView,
      Perm.employeeCreate,
      Perm.employeeEdit,
      Perm.employeeDelete,
      Perm.departmentView,
      Perm.departmentEdit,
      Perm.accountSupport,
      Perm.authorizationManage,
      Perm.auditLogView,
      Perm.auditLogExport,
      Perm.payrollViewSelf,
      Perm.payrollViewAll,
      Perm.payrollGenerate,
      Perm.payrollReview,
      Perm.payrollPublish,
      Perm.payrollExport,
      Perm.expenseApply,
      Perm.expenseApprove,
      Perm.expensePay,
      Perm.visitorView,
      Perm.visitorApply,
      Perm.visitorApprove,
      Perm.visitorHostConfirm,
      Perm.visitorCheckIn,
      Perm.visitorBlacklist,
      Perm.profileEditSelf,
      Perm.profileReview,
      Perm.employeePiiView,
      Perm.employeePiiEdit,
      Perm.employeeCompensationView,
      Perm.employeeCompensationEdit,
      // 财税部新模块（超管兜底，后端漏推也能 work）
      // 采购管理细分（V44 种子化）
      Perm.purchaseRequestView,
      Perm.purchaseRequestEdit,
      Perm.purchaseOrderView,
      Perm.purchaseOrderEdit,
      Perm.purchaseReceiptView,
      Perm.purchaseReceiptEdit,
      Perm.purchaseReturnView,
      Perm.purchaseReturnEdit,
      Perm.purchaseReportView,
      Perm.purchaseReportExport,
      Perm.purchaseViewAll,
      Perm.currencyView,
      Perm.currencyEdit,
      Perm.currencyExport,
      Perm.warehouseView,
      Perm.warehouseEdit,
      Perm.stockView,
      Perm.stockBalanceAdjust,
      Perm.stockDocView,
      Perm.stockDocEdit,
      Perm.stockDocViewAll,
      Perm.stockReportView,
      Perm.stockReportExport,
      Perm.warehouseInboundView,
      Perm.procurementArrivalExceptionHandle,
      Perm.labTestView,
      Perm.labTestUpload,
      Perm.supplierView,
      Perm.supplierEdit,
      Perm.supplierExport,
      Perm.accountView,
      Perm.accountEdit,
      Perm.accountExport,
      Perm.materialCategoryView,
      Perm.materialCategoryEdit,
      Perm.goodsView,
      Perm.goodsEdit,
      Perm.goodsExport,
      Perm.goodsViewAll,
      Perm.mouldCategoryView,
      Perm.mouldCategoryEdit,
      Perm.mouldView,
      Perm.mouldEdit,
      Perm.clientCategoryView,
      Perm.clientCategoryEdit,
      Perm.clientView,
      Perm.clientEdit,
      Perm.clientExport,
      Perm.clientViewAll,
      Perm.supplierCategoryView,
      Perm.supplierCategoryEdit,
      Perm.colorView,
      Perm.colorEdit,
      Perm.unitView,
      Perm.unitEdit,
      // 销售管理（V51）
      Perm.salesQuoteView, Perm.salesQuoteEdit,
      Perm.salesOrderView, Perm.salesOrderEdit,
      Perm.salesOrderPriceView, Perm.salesOrderChangePlanned,
      Perm.salesOrderConfirmPartialShipment,
      Perm.salesOrderPriority, Perm.salesOrderReallocate,
      Perm.salesShipmentView, Perm.salesShipmentEdit,
      Perm.salesShipmentReject, Perm.salesShipmentWarehouseWork,
      Perm.salesOtherShipmentView, Perm.salesOtherShipmentEdit,
      Perm.salesReturnView, Perm.salesReturnEdit,
      Perm.salesReturnQualityView, Perm.salesReturnQualityHandle,
      Perm.salesReportView, Perm.salesReportExport,
      Perm.salesViewAll,
      // 委外管理（V53）
      Perm.subcontractInquiryView, Perm.subcontractInquiryEdit,
      Perm.subcontractApplicationView, Perm.subcontractApplicationEdit,
      Perm.subcontractOrderView, Perm.subcontractOrderEdit,
      Perm.subcontractReceiptView, Perm.subcontractReceiptEdit,
      Perm.subcontractMaterialIssueView, Perm.subcontractMaterialIssueEdit,
      Perm.subcontractReturnView, Perm.subcontractReturnEdit,
      Perm.subcontractMaterialReturnView, Perm.subcontractMaterialReturnEdit,
      Perm.subcontractWasteView, Perm.subcontractWasteEdit,
      Perm.subcontractReportView, Perm.subcontractReportExport,
      Perm.subcontractViewAll,
      // 生产管理（V55）
      Perm.productionPlanView, Perm.productionPlanEdit,
      Perm.productionDailyReportView, Perm.productionDailyReportEdit,
      Perm.productionReportView, Perm.productionReportExport,
      Perm.productionWhereUsedView,
      Perm.productionPlanViewAll,
      Perm.productionPlanForwardRd,
      // 工程研发部任务中心
      Perm.rdTaskView, Perm.rdTaskEdit, Perm.rdTaskResolve,
      // 钱流管理（V57）
      Perm.financeReceiptView, Perm.financeReceiptEdit,
      Perm.financePaymentView, Perm.financePaymentEdit,
      Perm.financeExpenseView, Perm.financeExpenseEdit,
      Perm.financeOtherIncomeView, Perm.financeOtherIncomeEdit,
      Perm.financeBankTransferView, Perm.financeBankTransferEdit,
      Perm.financeReportView, Perm.financeReportExport,
      Perm.financeAssetView,
      Perm.financeAssetEdit,
      Perm.financeAssetApprove,
      Perm.financeAssetPost,
      Perm.financeAssetDispose,
      Perm.financeAssetExport,
      Perm.financeAssetPeriodManage,
      Perm.financePostExecute,
      Perm.financeShipmentAudit,
      Perm.financeOrderApprovalView,
      Perm.financeOrderApprovalReview,
      Perm.arApLedgerView,
      Perm.financeReconciliationView,
      Perm.paymentStyleView,
      Perm.noticeRead,
      Perm.noticePublish,
      Perm.suggestionSubmit,
      Perm.suggestionReply,
      // 收付款类别
      Perm.paymentStyleEdit,
      ...user.permissions,
    };
  }
  return user.permissions.toSet();
});

/// 当前用户是否为超级管理员（专一字段，便于 UI 短路判定）。
final isSuperAdminProvider = Provider<bool>((ref) {
  final user = ref.watch(sessionProvider).user;
  return user?.superAdmin ?? false;
});

/// 当前用户的角色名集合（如 {'hr','manager'}）。
final currentRolesProvider = Provider<Set<String>>((ref) {
  final user = ref.watch(sessionProvider).user;
  if (user == null) return const <String>{};
  return user.roles.map((Role r) => r.name).toSet();
});

/// 通用权限判定快捷函数。super admin 一律短路放行，其他按权限字符串匹配。
bool hasPerm(Ref ref, String code) {
  if (ref.read(isSuperAdminProvider)) return true;
  return ref.read(currentPermissionsProvider).contains(code);
}

/// 仅判断当前用户角色——不引入权限集。
bool hasRole(Ref ref, String code) {
  return ref.read(currentRolesProvider).contains(code);
}

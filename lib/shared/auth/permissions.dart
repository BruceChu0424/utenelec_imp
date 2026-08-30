// 权限点常量（与后端 permissions 表 code 对齐）+ 当前用户权限/角色 Provider。
// 文档：docs/05-架构/全局机制.md §1
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/role.dart';
import '../providers/session_provider.dart';

abstract final class Perm {
  static const employeeView = 'employee:view';
  static const employeeCreate = 'employee:create';
  static const employeeEdit = 'employee:edit';
  static const departmentView = 'department:view';
  static const departmentEdit = 'department:edit';

  /// 锁定、启停账号以及重置一次性临时密码。
  static const accountSupport = 'account:support';

  /// 财务敏感驾驶舱字段查看。
  static const dashboardFinanceSensitiveView =
      'dashboard:finance-sensitive:view';

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

  // 个人信息自助修改
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

  // ===== 附件（通用附件系统；权限目录归「人事行政/附件」）=====
  /// 查看/下载附件（通用层门槛；员工档案再叠加对象级策略：本人或 employee:view）。
  /// V280 已授予全部在职部门（员工"我的文件"自服务）；可在权限管理页按部门收回。
  static const attachmentView = 'attachment:view';

  // ===== 采购管理（PMC 运营部）=====
  /// 采购申请单
  static const purchaseRequestView = 'purchase_request:view';

  /// 采购订货单
  static const purchaseOrderView = 'purchase_order:view';
  static const purchaseOrderEdit = 'purchase_order:edit';
  static const purchaseOrderSubmitFinance = 'purchase_order:submit_finance';

  /// 采购收货单
  static const purchaseReceiptView = 'purchase_receipt:view';
  static const purchaseReceiptEdit = 'purchase_receipt:edit';
  static const purchaseReceiptPriceView = 'purchase_receipt:price:view';

  /// 采购退货单
  static const purchaseReturnView = 'purchase_return:view';
  static const purchaseReturnEdit = 'purchase_return:edit';

  /// 采购报表
  static const purchaseReportView = 'purchase_report:view';

  /// 查看全部采购单据（对象级授权；按制单人 maker_id 隔离，持此权限看全部）。
  static const purchaseViewAll = 'purchase:view:all';

  // ===== 财税部主数据入口（复用基础资料真实页面）=====
  /// 供应商资料
  static const supplierView = 'supplier:view';
  static const supplierEdit = 'supplier:edit';

  /// 账户资料
  static const accountView = 'account:view';
  static const accountEdit = 'account:edit';
  static const accountExport = 'account:export';
  static const accountBalanceView = 'account:balance:view';
  static const accountFlowView = 'account:flow:view';
  static const accountBalanceAdjust = 'account:balance:adjust';
  static const accountWarningManage = 'account:warning:manage';

  /// 货品资料分类（基础资料）
  static const materialCategoryView = 'material_category:view';
  static const materialCategoryEdit = 'material_category:edit';

  /// 货品主档（基础资料；已将 goods:view 授予全部部门）
  static const goodsView = 'goods:view';
  static const goodsEdit = 'goods:edit';
  static const goodsExport = 'goods:export';

  /// 导入货品（独立权限点，跟随 goods:edit 授予）。
  static const goodsImport = 'goods:import';
  static const goodsViewAll = 'goods:view:all';

  /// 编辑货品售价/折扣（默认仅财务部，可在权限管理页授权他人）。
  static const goodsPriceEdit = 'goods:price:edit';

  /// 查看货品成本（默认仅财务部，未授权时详情隐藏「成本预算」Tab）。
  static const goodsCostView = 'goods:cost:view';

  /// 查看货品折扣（默认仅销售部+财务部，未授权时详情/列表隐藏折扣字段）。
  static const goodsDiscountView = 'goods:discount:view';

  /// 审计组装信息（默认跟随 goods:edit 授予，可单独授权质检；
  /// 无授权时组装信息页签不显示「审计模式」按钮）。
  static const goodsBomAudit = 'goods:bom:audit';

  /// 模具资料分类（基础资料）
  static const mouldCategoryView = 'mould_category:view';
  static const mouldCategoryEdit = 'mould_category:edit';

  /// 模具主档（基础资料；已将 mould:view 授予全部部门）
  static const mouldView = 'mould:view';
  static const mouldEdit = 'mould:edit';

  /// 客户资料分类（基础资料）
  static const clientCategoryView = 'client_category:view';
  static const clientCategoryEdit = 'client_category:edit';

  /// 客户主档（基础资料；已将 client:view 授予全部部门）
  static const clientView = 'client:view';
  static const clientEdit = 'client:edit';
  static const clientExport = 'client:export';
  static const clientViewAll = 'client:view:all';
  static const clientAssign = 'client:assign';

  /// 客户收货地址簿删除（V300）：查看/新增沿用 client:view / 开单权限，删除须单独授权。
  static const clientAddressDelete = 'client_address:delete';

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

  /// 币种主档（基础资料；扁平结构，view 全员 / edit 归 PMC）
  static const currencyView = 'currency:view';
  static const currencyEdit = 'currency:edit';
  static const currencyExport = 'currency:export';

  /// 仓库主档（基础资料；扁平结构，view 全员 / edit 归 PMC）
  static const warehouseView = 'warehouse:view';
  static const warehouseEdit = 'warehouse:edit';

  /// 库存查看（全员；本轮采购审核联动库存，库存页未接入）
  static const stockView = 'stock:view';

  /// 领导或库存负责人明确授权后，可直接把库存余额修正为目标值。
  static const stockBalanceAdjust = 'stock:balance:adjust';

  /// 仓库管理单据（view 全员 / edit 归 PMC）
  static const stockDocView = 'stock_doc:view';
  static const stockDocEdit = 'stock_doc:edit';

  /// 查看全部仓库单据（对象级授权；按制单人 maker_id 隔离，持此权限看全部）。
  static const stockDocViewAll = 'stock_doc:view:all';

  static const stockReportView = 'stock_report:view';
  static const stockReportExport = 'stock_report:export';

  /// 财务批准后的预计到货及仓储异常只读任务。
  static const warehouseInboundView = 'warehouse_inbound:view';

  /// 采购/委外收货 IQC 待检查看与处置（处置还需 :handle）。
  static const procurementInspectionView = 'procurement_inspection:view';
  static const procurementInspectionHandle = 'procurement_inspection:handle';
  // ===== 实验室 =====
  static const labTestView = 'lab:test:view';
  static const labTestUpload = 'lab:test:upload';

  // ===== 销售管理（综合营销部）=====
  static const salesQuoteView = 'sales_quote:view';
  static const salesQuoteEdit = 'sales_quote:edit';
  static const salesOrderView = 'sales_order:view';
  static const salesOrderEdit = 'sales_order:edit';
  static const salesOrderPriceView = 'sales_order:price:view';
  static const salesOrderChangePlanned = 'sales_order:change_planned';
  static const salesOrderConfirmPartialShipment =
      'sales_order:confirm_partial_shipment';

  /// 订单行设优先级（急单/普通/现货）：稀缺让单决策用。
  static const salesOrderPriority = 'sales_order:priority';

  /// 稀缺库存让单（释放低优先级订单行的现货预留）：主管仲裁用。
  static const salesOrderReallocate = 'sales_order:reallocate';
  static const salesShipmentView = 'sales_shipment:view';
  static const salesShipmentEdit = 'sales_shipment:edit';
  static const salesShipmentReject = 'sales_shipment:reject';
  static const salesShipmentWarehouseWork = 'sales_shipment:warehouse-work';
  static const salesOtherShipmentView = 'sales_other_shipment:view';
  static const salesOtherShipmentEdit = 'sales_other_shipment:edit';
  static const salesReturnView = 'sales_return:view';
  static const salesReturnEdit = 'sales_return:edit';
  static const salesReturnDisposition = 'sales_return:disposition';
  static const salesReturnQualityView = 'sales_return_quality:view';
  static const salesReportView = 'sales_report:view';
  static const salesReportExport = 'sales_report:export';
  static const salesViewAll = 'sales:view:all';

  // ===== 委外管理（综合营销部）=====
  static const subcontractInquiryView = 'subcontract_inquiry:view';
  static const subcontractInquiryEdit = 'subcontract_inquiry:edit';
  static const subcontractApplicationView = 'subcontract_application:view';
  static const subcontractOrderView = 'subcontract_order:view';
  static const subcontractOrderEdit = 'subcontract_order:edit';
  static const subcontractOrderSubmitFinance =
      'subcontract_order:submit_finance';
  static const subcontractReceiptView = 'subcontract_receipt:view';
  static const subcontractReceiptEdit = 'subcontract_receipt:edit';
  static const subcontractReceiptPriceView = 'subcontract_receipt:price:view';
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
  // 委外出仓工作台（V305）：仓库 hub「委外出仓」任务中心显隐与拣货/审核操作。
  static const subcontractOutboundView = 'subcontract_outbound:view';
  static const subcontractOutboundHandle = 'subcontract_outbound:handle';

  /// 查看全部委外单据（对象级授权；按制单人 maker_id 隔离，持此权限看全部）。
  static const subcontractViewAll = 'subcontract:view:all';

  // ===== 生产管理（生产部）=====
  static const productionPlanView = 'production_plan:view';
  static const productionPlanEdit = 'production_plan:edit';
  static const productionPlanCostView = 'production_plan_cost:view';
  static const planningSupplyRequestView = 'planning_supply_request:view';
  static const productionPlanApprove = 'production_plan:approve';
  static const productionPlanBatchApprove = 'production_plan:batchApprove';
  static const productionPlanBatchDelete = 'production_plan:batchDelete';
  static const productionMaterialAnalysisView =
      'production_material_analysis:view';
  static const productionMaterialAnalysisRoute =
      'production_material_analysis:route';
  static const productionMaterialAnalysisNotify =
      'production_material_analysis:notify';
  static const productionMaterialAnalysisGenerate =
      'production_material_analysis:generate';
  static const productionMaterialAnalysisReallocate =
      'production_material_analysis:reallocate';
  static const productionMaterialAnalysisCrossReallocate =
      'production_material_analysis:cross_reallocate';
  static const productionDailyReportView = 'production_daily_report:view';
  static const productionDailyReportEdit = 'production_daily_report:edit';
  static const productionQualityInspectionView =
      'production_quality_inspection:view';
  static const productionQualityInspectionApprove =
      'production_quality_inspection:approve';
  static const productionFqcReplenishmentView =
      'production_fqc_replenishment:view';
  static const productionFqcReplenishmentConfirm =
      'production_fqc_replenishment:confirm';
  static const productionReportView = 'production_report:view';
  static const productionReportExport = 'production_report:export';
  static const productionWhereUsedView = 'production_where_used:view';

  /// 查看全部生产单据（对象级授权；生产计划/日报按制单人 maker_id 隔离，持此权限看全部）。
  static const productionPlanViewAll = 'production_plan:view:all';

  // ===== 钱流管理（财税部）=====
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

  /// 采购/委外订货单财务审批任务（ADR-027：财务部门持 review 权限的审核组均可审）。
  static const financeOrderApprovalView = 'finance_order_approval:view';
  static const financeOrderApprovalReview = 'finance_order_approval:review';

  /// 销售订货单财务确认（V294 闸门：确认后计划部才可见/可排产）。
  static const salesOrderFinanceView = 'sales_order_finance:view';
  static const salesOrderFinanceConfirm = 'sales_order_finance:confirm';

  static const arApLedgerView = 'ar_ap_ledger:view';
  static const customerPrepaymentView = 'customer_prepayment:view';
  static const customerPrepaymentApply = 'customer_prepayment:apply';
  static const customerPrepaymentReverse = 'customer_prepayment:reverse';
  static const subcontractLossClaimView = 'subcontract_loss_claim:view';
  static const subcontractLossClaimReview = 'subcontract_loss_claim:review';
  static const subcontractLossClaimFulfill = 'subcontract_loss_claim:fulfill';
  static const subcontractLossClaimReverse = 'subcontract_loss_claim:reverse';
  static const supplierOpenItemOffsetApply = 'supplier_open_item_offset:apply';
  static const supplierSettlementView = 'supplier_settlement:view';
  static const supplierSettlementCreate = 'supplier_settlement:create';
  static const supplierSettlementConfirm = 'supplier_settlement:confirm';
  static const supplierSettlementDispute = 'supplier_settlement:dispute';
  static const supplierSettlementReverse = 'supplier_settlement:reverse';
  static const financeReconciliationView = 'finance_reconciliation:view';

  /// 公司级财务对象范围；不能由普通页面入口推导或替代。
  static const financeViewAll = 'finance:view:all';

  // ===== 收付款类别（基础资料）=====
  /// 收付款类别：view 全员可见（路由不挂守卫），edit 归财务。
  static const paymentStyleView = 'payment_style:view';
  static const paymentStyleEdit = 'payment_style:edit';

  // ===== 通知、建议与报表导出 =====
  static const noticeRead = 'notice:read';
  static const noticePublish = 'notice:publish';
  static const suggestionSubmit = 'suggestion:submit';
  static const suggestionReply = 'suggestion:reply';
  // 官网询盘（综合营销统一收件箱；部门授权非全员基础包）
  static const webinquiryView = 'webinquiry:view';
  static const purchaseReportExport = 'purchase_report:export';

  // 注：supplierView/supplierEdit（'supplier:view'/'supplier:edit'）见上方财税部段——
  // 后端以「主数据」category 种子化同一 code，基础资料与财税业务视图共用，故不重复定义。

  // ===== 工程研发部任务中心 =====
  static const rdTaskView = 'rd_task:view';
  static const rdTaskResolve = 'rd_task:resolve';

  // ===== V328：按钮级动作权限（与后端迁移 code 一一对应） =====
  static const materialCategoryCreate = 'material_category:create';
  static const materialCategoryDelete = 'material_category:delete';
  static const materialCategoryMove = 'material_category:move';
  static const materialCategoryReorder = 'material_category:reorder';
  static const mouldCategoryCreate = 'mould_category:create';
  static const mouldCategoryDelete = 'mould_category:delete';
  static const mouldCategoryMove = 'mould_category:move';
  static const mouldCategoryReorder = 'mould_category:reorder';
  static const clientCategoryCreate = 'client_category:create';
  static const clientCategoryDelete = 'client_category:delete';
  static const clientCategoryMove = 'client_category:move';
  static const clientCategoryReorder = 'client_category:reorder';
  static const supplierCategoryCreate = 'supplier_category:create';
  static const supplierCategoryDelete = 'supplier_category:delete';
  static const supplierCategoryMove = 'supplier_category:move';
  static const supplierCategoryReorder = 'supplier_category:reorder';
  static const goodsCreate = 'goods:create';
  static const goodsDelete = 'goods:delete';
  static const goodsStatus = 'goods:status';
  static const goodsBomCreate = 'goods:bom:create';
  static const goodsBomEdit = 'goods:bom:edit';
  static const goodsBomDelete = 'goods:bom:delete';
  static const mouldCreate = 'mould:create';
  static const mouldDelete = 'mould:delete';
  static const mouldStatus = 'mould:status';
  static const clientCreate = 'client:create';
  static const clientDelete = 'client:delete';
  static const clientStatus = 'client:status';
  static const clientAddressCreate = 'client_address:create';
  static const supplierCreate = 'supplier:create';
  static const supplierDelete = 'supplier:delete';
  static const supplierStatus = 'supplier:status';
  static const colorCreate = 'color:create';
  static const colorDelete = 'color:delete';
  static const colorStatus = 'color:status';
  static const unitCreate = 'unit:create';
  static const unitDelete = 'unit:delete';
  static const unitStatus = 'unit:status';
  static const currencyCreate = 'currency:create';
  static const currencyDelete = 'currency:delete';
  static const currencyStatus = 'currency:status';
  static const warehouseCreate = 'warehouse:create';
  static const warehouseDelete = 'warehouse:delete';
  static const warehouseStatus = 'warehouse:status';
  static const accountCreate = 'account:create';
  static const accountDelete = 'account:delete';
  static const accountStatus = 'account:status';
  static const paymentStyleCreate = 'payment_style:create';
  static const paymentStyleStatus = 'payment_style:status';
  static const paymentStyleMove = 'payment_style:move';
  static const paymentStyleReorder = 'payment_style:reorder';
  static const settlementMethodCreate = 'settlement_method:create';
  static const salesQuoteCreate = 'sales_quote:create';
  static const salesQuoteDelete = 'sales_quote:delete';
  static const salesQuoteApprove = 'sales_quote:approve';
  static const salesQuoteReverse = 'sales_quote:reverse';
  static const salesQuoteConvert = 'sales_quote:convert';
  static const salesOrderCreate = 'sales_order:create';
  static const salesOrderDelete = 'sales_order:delete';
  static const salesOrderApprove = 'sales_order:approve';
  static const salesOrderReverse = 'sales_order:reverse';
  static const salesOrderStop = 'sales_order:stop';
  static const salesOrderChangeQty = 'sales_order:change_qty';
  static const salesOrderCancel = 'sales_order:cancel';
  static const salesShipmentCreate = 'sales_shipment:create';
  static const salesShipmentDelete = 'sales_shipment:delete';
  static const salesShipmentApprove = 'sales_shipment:approve';
  static const salesShipmentReverse = 'sales_shipment:reverse';
  static const salesOtherShipmentCreate = 'sales_other_shipment:create';
  static const salesOtherShipmentDelete = 'sales_other_shipment:delete';
  static const salesOtherShipmentApprove = 'sales_other_shipment:approve';
  static const salesOtherShipmentReverse = 'sales_other_shipment:reverse';
  static const salesReturnCreate = 'sales_return:create';
  static const salesReturnDelete = 'sales_return:delete';
  static const salesReturnApprove = 'sales_return:approve';
  static const salesReturnReverse = 'sales_return:reverse';
  static const purchaseOrderCreate = 'purchase_order:create';
  static const purchaseOrderDelete = 'purchase_order:delete';
  static const purchaseOrderReverse = 'purchase_order:reverse';
  static const purchaseOrderDecompose = 'purchase_order:decompose';
  static const purchaseReceiptCreate = 'purchase_receipt:create';
  static const purchaseReceiptDelete = 'purchase_receipt:delete';
  static const purchaseReceiptApprove = 'purchase_receipt:approve';
  static const purchaseReceiptReverse = 'purchase_receipt:reverse';
  static const purchaseReturnCreate = 'purchase_return:create';
  static const purchaseReturnDelete = 'purchase_return:delete';
  static const purchaseReturnApprove = 'purchase_return:approve';
  static const purchaseReturnReverse = 'purchase_return:reverse';
  static const financeOrderApprovalApprove = 'finance_order_approval:approve';
  static const financeOrderApprovalReject = 'finance_order_approval:reject';
  static const stockDocCreate = 'stock_doc:create';
  static const stockDocDelete = 'stock_doc:delete';
  static const stockDocApprove = 'stock_doc:approve';
  static const stockDocReverse = 'stock_doc:reverse';
  static const stockDocIssue = 'stock_doc:issue';
  static const stockDocReverseIssue = 'stock_doc:reverse_issue';
  static const productionDailyReportCreate = 'production_daily_report:create';
  static const productionDailyReportDelete = 'production_daily_report:delete';
  static const productionDailyReportApprove = 'production_daily_report:approve';
  static const productionDailyReportReverse = 'production_daily_report:reverse';
  static const productionPlanDelete = 'production_plan:delete';
  static const productionPlanReverse = 'production_plan:reverse';
  static const productionPlanFlags = 'production_plan:flags';
  static const productionExecutionAssign = 'production_execution:assign';
  static const productionExecutionReleaseDefer =
      'production_execution:release_defer';
  static const productionExecutionDispatch = 'production_execution:dispatch';
  static const productionExecutionStart = 'production_execution:start';
  static const productionPlanningPackageGenerate =
      'production_planning_package:generate';
  static const productionPlanningPackageDraftEdit =
      'production_planning_package:draft_edit';
  static const productionPlanningPackageCancel =
      'production_planning_package:cancel';
  static const productionPlanningPackageReverse =
      'production_planning_package:reverse';
  static const productionMaterialSettle = 'production_material:settle';
  static const productionMaterialReverse = 'production_material:reverse';
  static const productionMaterialClose = 'production_material:close';
  static const goodsImportUndo = 'goods:import:undo';
  static const subcontractInquiryCreate = 'subcontract_inquiry:create';
  static const subcontractInquiryDelete = 'subcontract_inquiry:delete';
  static const subcontractInquiryApprove = 'subcontract_inquiry:approve';
  static const subcontractInquiryReverse = 'subcontract_inquiry:reverse';
  static const subcontractOrderCreate = 'subcontract_order:create';
  static const subcontractOrderDelete = 'subcontract_order:delete';
  static const subcontractOrderReverse = 'subcontract_order:reverse';
  static const subcontractOrderDecompose = 'subcontract_order:decompose';
  static const subcontractReceiptCreate = 'subcontract_receipt:create';
  static const subcontractReceiptDelete = 'subcontract_receipt:delete';
  static const subcontractReceiptApprove = 'subcontract_receipt:approve';
  static const subcontractReceiptReverse = 'subcontract_receipt:reverse';
  static const subcontractMaterialIssueCreate =
      'subcontract_material_issue:create';
  static const subcontractMaterialIssueDelete =
      'subcontract_material_issue:delete';
  static const subcontractMaterialIssueApprove =
      'subcontract_material_issue:approve';
  static const subcontractMaterialIssueReverse =
      'subcontract_material_issue:reverse';
  static const subcontractReturnCreate = 'subcontract_return:create';
  static const subcontractReturnDelete = 'subcontract_return:delete';
  static const subcontractReturnApprove = 'subcontract_return:approve';
  static const subcontractReturnReverse = 'subcontract_return:reverse';
  static const subcontractMaterialReturnCreate =
      'subcontract_material_return:create';
  static const subcontractMaterialReturnDelete =
      'subcontract_material_return:delete';
  static const subcontractMaterialReturnApprove =
      'subcontract_material_return:approve';
  static const subcontractMaterialReturnReverse =
      'subcontract_material_return:reverse';
  static const subcontractWasteCreate = 'subcontract_waste:create';
  static const subcontractWasteDelete = 'subcontract_waste:delete';
  static const subcontractWasteApprove = 'subcontract_waste:approve';
  static const subcontractWasteReverse = 'subcontract_waste:reverse';
  static const financeReceiptCreate = 'finance_receipt:create';
  static const financeReceiptDelete = 'finance_receipt:delete';
  static const financeReceiptApprove = 'finance_receipt:approve';
  static const financeReceiptReverse = 'finance_receipt:reverse';
  static const financePaymentCreate = 'finance_payment:create';
  static const financePaymentDelete = 'finance_payment:delete';
  static const financePaymentApprove = 'finance_payment:approve';
  static const financePaymentReverse = 'finance_payment:reverse';
  static const financeExpenseCreate = 'finance_expense:create';
  static const financeExpenseDelete = 'finance_expense:delete';
  static const financeExpenseApprove = 'finance_expense:approve';
  static const financeExpenseReverse = 'finance_expense:reverse';
  static const financeExpenseGlConfirm = 'finance_expense:gl_confirm';
  static const financeOtherIncomeCreate = 'finance_other_income:create';
  static const financeOtherIncomeDelete = 'finance_other_income:delete';
  static const financeOtherIncomeApprove = 'finance_other_income:approve';
  static const financeOtherIncomeReverse = 'finance_other_income:reverse';
  static const financeBankTransferCreate = 'finance_bank_transfer:create';
  static const financeBankTransferDelete = 'finance_bank_transfer:delete';
  static const financeBankTransferApprove = 'finance_bank_transfer:approve';
  static const financeBankTransferReverse = 'finance_bank_transfer:reverse';

  static const departmentCreate = 'department:create';
  static const departmentDelete = 'department:delete';
  static const departmentMove = 'department:move';
  static const departmentManagerAssign = 'department:manager_assign';
  static const positionCreate = 'position:create';
  static const positionEdit = 'position:edit';
  static const positionDelete = 'position:delete';
  static const employeeTransfer = 'employee:transfer';
  static const employeeHandover = 'employee:handover';
  static const employeeOffboard = 'employee:offboard';
  static const employeeConfirm = 'employee:confirm';
  static const employeeRehire = 'employee:rehire';
  static const employeeContractRenew = 'employee:contract_renew';
  static const employeeAvatarEdit = 'employee:avatar_edit';
  static const employeeTaskTakeover = 'employee:task_takeover';
  static const attachmentDownload = 'attachment:download';
  static const attachmentUpload = 'attachment:upload';
  static const attachmentDelete = 'attachment:delete';
  static const attachmentReconcileView = 'attachment:reconcile:view';
  static const attachmentReconcileApproveDelete =
      'attachment:reconcile:approve_delete';
  static const productionMaterialAnalysisCreate =
      'production_material_analysis:create';
  static const productionMaterialAnalysisRefresh =
      'production_material_analysis:refresh';
  static const productionMaterialAnalysisCancel =
      'production_material_analysis:cancel';
  static const webinquiryClaim = 'webinquiry:claim';
  static const webinquiryClose = 'webinquiry:close';
  static const webinquiryConvertClient = 'webinquiry:convert_client';
  static const salesReturnQualityCorrect = 'sales_return_quality:correct';
  static const salesReturnQualityDispose = 'sales_return_quality:dispose';
  static const supplierReturnTaskView = 'supplier_return_task:view';
  static const supplierReturnTaskComplete = 'supplier_return_task:complete';
  static const visitorVerify = 'visitor:verify';
  static const subcontractOutboundExecute = 'subcontract_outbound:execute';
  static const subcontractOutboundClose = 'subcontract_outbound:close';
  static const warehouseInboundStockIn = 'warehouse_inbound:stock_in';

  /// 超级管理员在后端目录短暂漏项时的按钮级权限兜底。
  static const buttonActionCodes = <String>{
    materialCategoryCreate,
    materialCategoryDelete,
    materialCategoryMove,
    materialCategoryReorder,
    mouldCategoryCreate,
    mouldCategoryDelete,
    mouldCategoryMove,
    mouldCategoryReorder,
    clientCategoryCreate,
    clientCategoryDelete,
    clientCategoryMove,
    clientCategoryReorder,
    supplierCategoryCreate,
    supplierCategoryDelete,
    supplierCategoryMove,
    supplierCategoryReorder,
    goodsCreate,
    goodsDelete,
    goodsStatus,
    goodsBomCreate,
    goodsBomEdit,
    goodsBomDelete,
    mouldCreate,
    mouldDelete,
    mouldStatus,
    clientCreate,
    clientDelete,
    clientStatus,
    clientAssign,
    clientAddressCreate,
    supplierCreate,
    supplierDelete,
    supplierStatus,
    colorCreate,
    colorDelete,
    colorStatus,
    unitCreate,
    unitDelete,
    unitStatus,
    currencyCreate,
    currencyDelete,
    currencyStatus,
    warehouseCreate,
    warehouseDelete,
    warehouseStatus,
    accountCreate,
    accountDelete,
    accountStatus,
    accountBalanceAdjust,
    accountWarningManage,
    paymentStyleCreate,
    paymentStyleStatus,
    paymentStyleMove,
    paymentStyleReorder,
    settlementMethodCreate,
    salesQuoteCreate,
    salesQuoteDelete,
    salesQuoteApprove,
    salesQuoteReverse,
    salesQuoteConvert,
    salesOrderCreate,
    salesOrderDelete,
    salesOrderApprove,
    salesOrderReverse,
    salesOrderStop,
    salesOrderChangeQty,
    salesOrderCancel,
    salesShipmentCreate,
    salesShipmentDelete,
    salesShipmentApprove,
    salesShipmentReverse,
    salesOtherShipmentCreate,
    salesOtherShipmentDelete,
    salesOtherShipmentApprove,
    salesOtherShipmentReverse,
    salesReturnCreate,
    salesReturnDelete,
    salesReturnApprove,
    salesReturnReverse,
    purchaseOrderCreate,
    purchaseOrderDelete,
    purchaseOrderReverse,
    purchaseOrderDecompose,
    purchaseReceiptCreate,
    purchaseReceiptDelete,
    purchaseReceiptApprove,
    purchaseReceiptReverse,
    purchaseReturnCreate,
    purchaseReturnDelete,
    purchaseReturnApprove,
    purchaseReturnReverse,
    financeOrderApprovalApprove,
    financeOrderApprovalReject,
    stockDocCreate,
    stockDocDelete,
    stockDocApprove,
    stockDocReverse,
    stockDocIssue,
    stockDocReverseIssue,
    productionDailyReportCreate,
    productionDailyReportDelete,
    productionDailyReportApprove,
    productionDailyReportReverse,
    productionQualityInspectionView,
    productionQualityInspectionApprove,
    productionFqcReplenishmentConfirm,
    productionPlanDelete,
    productionPlanReverse,
    productionPlanFlags,
    productionExecutionAssign,
    productionExecutionReleaseDefer,
    productionExecutionDispatch,
    productionExecutionStart,
    productionPlanningPackageGenerate,
    productionPlanningPackageDraftEdit,
    productionPlanningPackageCancel,
    productionPlanningPackageReverse,
    productionMaterialSettle,
    productionMaterialReverse,
    productionMaterialClose,
    goodsImportUndo,
    subcontractInquiryCreate,
    subcontractInquiryDelete,
    subcontractInquiryApprove,
    subcontractInquiryReverse,
    subcontractOrderCreate,
    subcontractOrderDelete,
    subcontractOrderReverse,
    subcontractOrderDecompose,
    subcontractReceiptCreate,
    subcontractReceiptDelete,
    subcontractReceiptApprove,
    subcontractReceiptReverse,
    subcontractMaterialIssueCreate,
    subcontractMaterialIssueDelete,
    subcontractMaterialIssueApprove,
    subcontractMaterialIssueReverse,
    subcontractReturnCreate,
    subcontractReturnDelete,
    subcontractReturnApprove,
    subcontractReturnReverse,
    subcontractMaterialReturnCreate,
    subcontractMaterialReturnDelete,
    subcontractMaterialReturnApprove,
    subcontractMaterialReturnReverse,
    subcontractWasteCreate,
    subcontractWasteDelete,
    subcontractWasteApprove,
    subcontractWasteReverse,
    customerPrepaymentApply,
    customerPrepaymentReverse,
    subcontractLossClaimReview,
    subcontractLossClaimFulfill,
    subcontractLossClaimReverse,
    supplierOpenItemOffsetApply,
    supplierSettlementCreate,
    supplierSettlementConfirm,
    supplierSettlementDispute,
    supplierSettlementReverse,
    financeReceiptCreate,
    financeReceiptDelete,
    financeReceiptApprove,
    financeReceiptReverse,
    financePaymentCreate,
    financePaymentDelete,
    financePaymentApprove,
    financePaymentReverse,
    financeExpenseCreate,
    financeExpenseDelete,
    financeExpenseApprove,
    financeExpenseReverse,
    financeExpenseGlConfirm,
    financeOtherIncomeCreate,
    financeOtherIncomeDelete,
    financeOtherIncomeApprove,
    financeOtherIncomeReverse,
    financeBankTransferCreate,
    financeBankTransferDelete,
    financeBankTransferApprove,
    financeBankTransferReverse,
    departmentCreate,
    departmentDelete,
    departmentMove,
    departmentManagerAssign,
    positionCreate,
    positionEdit,
    positionDelete,
    employeeTransfer,
    employeeHandover,
    employeeOffboard,
    employeeConfirm,
    employeeRehire,
    employeeContractRenew,
    employeeAvatarEdit,
    employeeTaskTakeover,
    attachmentDownload,
    attachmentUpload,
    attachmentDelete,
    attachmentReconcileView,
    attachmentReconcileApproveDelete,
    productionMaterialAnalysisCreate,
    productionMaterialAnalysisRefresh,
    productionMaterialAnalysisCancel,
    webinquiryClaim,
    webinquiryClose,
    webinquiryConvertClient,
    salesReturnQualityCorrect,
    salesReturnQualityDispose,
    supplierReturnTaskView,
    supplierReturnTaskComplete,
    visitorVerify,
    visitorCheckIn,
    subcontractOutboundExecute,
    subcontractOutboundClose,
    warehouseInboundStockIn,
  };
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
      Perm.employeeExport,
      Perm.departmentView,
      Perm.departmentEdit,
      Perm.accountSupport,
      Perm.dashboardFinanceSensitiveView,
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
      Perm.attachmentView,
      // 财税部新模块（超管兜底，后端漏推也能 work）
      // 采购管理细分
      Perm.purchaseRequestView,
      Perm.purchaseOrderView,
      Perm.purchaseOrderEdit,
      Perm.purchaseOrderSubmitFinance,
      Perm.purchaseReceiptView,
      Perm.purchaseReceiptEdit,
      Perm.purchaseReceiptPriceView,
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
      Perm.procurementInspectionView,
      Perm.procurementInspectionHandle,
      Perm.supplierReturnTaskView,
      Perm.supplierReturnTaskComplete,
      Perm.labTestView,
      Perm.labTestUpload,
      Perm.supplierView,
      Perm.supplierEdit,
      Perm.supplierExport,
      Perm.accountView,
      Perm.accountEdit,
      Perm.accountExport,
      Perm.accountBalanceView,
      Perm.accountFlowView,
      Perm.materialCategoryView,
      Perm.materialCategoryEdit,
      Perm.goodsView,
      Perm.goodsEdit,
      Perm.goodsExport,
      Perm.goodsImport,
      Perm.goodsViewAll,
      Perm.goodsPriceEdit,
      Perm.goodsCostView,
      Perm.goodsDiscountView,
      Perm.goodsBomAudit,
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
      Perm.clientAssign,
      Perm.clientAddressDelete,
      Perm.supplierCategoryView,
      Perm.supplierCategoryEdit,
      Perm.colorView,
      Perm.colorEdit,
      Perm.unitView,
      Perm.unitEdit,
      // 销售管理
      Perm.salesQuoteView, Perm.salesQuoteEdit,
      Perm.salesOrderView, Perm.salesOrderEdit,
      Perm.salesOrderPriceView, Perm.salesOrderChangePlanned,
      Perm.salesOrderConfirmPartialShipment,
      Perm.salesOrderPriority, Perm.salesOrderReallocate,
      Perm.salesShipmentView, Perm.salesShipmentEdit,
      Perm.salesShipmentReject, Perm.salesShipmentWarehouseWork,
      Perm.salesOtherShipmentView, Perm.salesOtherShipmentEdit,
      Perm.salesReturnView, Perm.salesReturnEdit,
      Perm.salesReturnDisposition,
      Perm.salesReturnQualityView,
      Perm.salesReportView, Perm.salesReportExport,
      Perm.salesViewAll,
      // 委外管理
      Perm.subcontractInquiryView, Perm.subcontractInquiryEdit,
      Perm.subcontractApplicationView,
      Perm.subcontractOrderView, Perm.subcontractOrderEdit,
      Perm.subcontractOrderSubmitFinance,
      Perm.subcontractReceiptView, Perm.subcontractReceiptEdit,
      Perm.subcontractReceiptPriceView,
      Perm.subcontractMaterialIssueView, Perm.subcontractMaterialIssueEdit,
      Perm.subcontractReturnView, Perm.subcontractReturnEdit,
      Perm.subcontractMaterialReturnView, Perm.subcontractMaterialReturnEdit,
      Perm.subcontractWasteView, Perm.subcontractWasteEdit,
      Perm.subcontractReportView, Perm.subcontractReportExport,
      Perm.subcontractOutboundView, Perm.subcontractOutboundHandle,
      Perm.subcontractViewAll,
      // 生产管理
      Perm.productionPlanView, Perm.productionPlanEdit,
      Perm.productionPlanCostView,
      Perm.planningSupplyRequestView,
      Perm.productionPlanApprove,
      Perm.productionPlanBatchApprove, Perm.productionPlanBatchDelete,
      Perm.productionMaterialAnalysisView,
      Perm.productionMaterialAnalysisRoute,
      Perm.productionMaterialAnalysisNotify,
      Perm.productionMaterialAnalysisGenerate,
      Perm.productionMaterialAnalysisReallocate,
      Perm.productionMaterialAnalysisCrossReallocate,
      Perm.productionDailyReportView, Perm.productionDailyReportEdit,
      Perm.productionQualityInspectionView,
      Perm.productionQualityInspectionApprove,
      Perm.productionFqcReplenishmentView,
      Perm.productionFqcReplenishmentConfirm,
      Perm.productionReportView, Perm.productionReportExport,
      Perm.productionWhereUsedView,
      Perm.productionPlanViewAll,
      // 工程研发部任务中心
      Perm.rdTaskView, Perm.rdTaskResolve,
      // 钱流管理
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
      Perm.salesOrderFinanceView,
      Perm.salesOrderFinanceConfirm,
      Perm.arApLedgerView,
      Perm.customerPrepaymentView,
      Perm.financeReconciliationView,
      Perm.financeViewAll,
      Perm.paymentStyleView,
      Perm.noticeRead,
      Perm.noticePublish,
      Perm.suggestionSubmit,
      Perm.suggestionReply,
      Perm.webinquiryView,
      // 收付款类别
      Perm.paymentStyleEdit,
      ...Perm.buttonActionCodes,
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

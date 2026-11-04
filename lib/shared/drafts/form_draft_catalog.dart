import '../../features/finance/config/finance_requirement_names.dart';
import '../auth/permissions.dart';
import '../../core/router/route_names.dart';
import 'form_draft.dart';

export 'form_draft.dart';

/// Registered editor identity: its resume destination, ownership module and
/// required business authority travel together. Pages supply input/context,
/// never an independently chosen draft access rule.
class FormDraftDescriptor {
  const FormDraftDescriptor({
    required this.title,
    required this.module,
    required this.route,
    required this.permission,
    this.dialogKind,
    this.draftKind,
  });

  final String title;
  final BadgeModule module;
  final String route;
  final String permission;
  final String? dialogKind;
  final String? draftKind;

  /// Presentation grouping only; actual restoration still validates the full
  /// active editor contract and current permissions.
  bool groups(FormDraft draft) =>
      draft.permission == permission && matchesDestination(draft);

  /// Stable editor identity for counting across permission-name changes.
  /// Restore and write authorization still require [groups] and live grants.
  bool matchesDestination(FormDraft draft) =>
      draft.module == module &&
      _matchesRouteTemplate(draft.route) &&
      Uri.parse(draft.route).queryParameters['draftForm'] == dialogKind;

  FormDraftSpec spec({
    String? title,
    String? route,
    String? categoryId,
    String? parentId,
    String? draftKind,
    Map<String, String> routeParameters = const {},
  }) {
    final destination = route ?? this.route;
    if (!formDraftRouteIsLocal(destination) ||
        !_matchesRouteTemplate(destination)) {
      throw ArgumentError('草稿恢复路径不属于当前表单');
    }
    final uri = Uri.parse(destination);
    final parameters = <String, String>{
      ...uri.queryParameters,
      'draftForm': ?dialogKind,
      'categoryId': ?categoryId,
      'parentId': ?parentId,
      ...routeParameters,
    };
    if (parameters['draftForm'] != dialogKind) {
      throw ArgumentError('草稿恢复类型不属于当前表单');
    }
    return FormDraftSpec(
      title: title ?? this.title,
      module: module,
      route: parameters.isEmpty
          ? uri.toString()
          : uri.replace(queryParameters: parameters).toString(),
      permission: permission,
      draftKind: draftKind ?? this.draftKind,
    );
  }

  bool _matchesRouteTemplate(String destination) {
    final expected = Uri.parse(route).pathSegments;
    final actual = Uri.parse(destination).pathSegments;
    if (actual.length != expected.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (expected[index].startsWith(':')) {
        final value = actual[index];
        if (value.isEmpty ||
            value.startsWith(':') ||
            value.contains('/') ||
            value.contains('\\')) {
          return false;
        }
      } else if (actual[index] != expected[index]) {
        return false;
      }
    }
    return true;
  }
}

/// New-document drafts use their create/approve authority. Existing-task
/// drafts may use the task's view authority when that GET already exposes the
/// same values, so an owner can inspect an unresolved result after losing an
/// action grant. Restoring local input never grants a business write: pages
/// still require current action permissions, live claims and server capabilities.
/// Accounting policy creation remains an approval operation.
abstract final class FormDraftCatalog {
  static const salesManagerOrderBatch = FormDraftDescriptor(
    title: '负责人批量审核订货',
    module: BadgeModule.salesReview,
    route: '/sales/manager-review?kind=order',
    permission: Perm.salesOrderManagerView,
    draftKind: 'sales_manager_order_batch',
  );
  static const salesManagerQuoteReview = FormDraftDescriptor(
    title: '销售负责人报价审核',
    module: BadgeModule.salesReview,
    route: '/sales/manager-review/quotes/:id',
    permission: Perm.salesQuoteManagerView,
    draftKind: 'sales_manager_quote_review',
  );
  static const salesManagerOrderReview = FormDraftDescriptor(
    title: '销售负责人订货审核',
    module: BadgeModule.salesReview,
    route: '/sales/manager-review/orders/:id',
    permission: Perm.salesOrderManagerView,
    draftKind: 'sales_manager_order_review',
  );
  static const financeSalesOrderReview = FormDraftDescriptor(
    title: '销售订单财务审核',
    module: BadgeModule.finance,
    route: '/finance/sales-order-confirmations/:id',
    permission: Perm.salesOrderFinanceView,
    draftKind: 'finance_sales_order_review',
  );
  static const financeProcurementReview = FormDraftDescriptor(
    title: '订货财务审批',
    module: BadgeModule.finance,
    route: '/finance/procurement-approvals/:caseId',
    permission: Perm.financeOrderApprovalView,
    draftKind: 'finance_procurement_review',
  );
  static const financeQuoteReview = FormDraftDescriptor(
    title: '报价财务核价',
    module: BadgeModule.finance,
    route: '/finance/quote-review/:id',
    permission: Perm.salesQuoteFinanceView,
    draftKind: 'finance_quote_review',
  );
  static const financeShipmentReview = FormDraftDescriptor(
    title: FinanceRequirementNames.customerShipmentReview,
    module: BadgeModule.finance,
    route: '/finance/sales-shipment-audits/:id',
    permission: Perm.salesShipmentFinanceView,
    draftKind: 'finance_shipment_review',
  );
  static const goodsCost = FormDraftDescriptor(
    title: '货品成本',
    module: BadgeModule.finance,
    route: '/basicinfo/goods/:id?tab=cost',
    permission: Perm.goodsCostView,
    draftKind: 'goods_cost',
  );
  static const client = FormDraftDescriptor(
    title: '新增客户',
    module: BadgeModule.sales,
    route: '/basicinfo/client',
    permission: Perm.clientCreate,
    dialogKind: 'master',
  );
  static const supplier = FormDraftDescriptor(
    title: '新增供应商',
    module: BadgeModule.purchase,
    route: '/basicinfo/supplier',
    permission: Perm.supplierCreate,
    dialogKind: 'master',
  );
  static const supplierQuick = FormDraftDescriptor(
    title: '添加供应商',
    module: BadgeModule.purchase,
    route: '/basicinfo/supplier',
    permission: Perm.supplierCreate,
    dialogKind: 'supplierQuick',
  );
  static const mould = FormDraftDescriptor(
    title: '新增模具',
    module: BadgeModule.rd,
    route: '/basicinfo/mould',
    permission: Perm.mouldCreate,
    dialogKind: 'master',
  );
  static const color = FormDraftDescriptor(
    title: '新增颜色',
    module: BadgeModule.rd,
    route: '/basicinfo/color',
    permission: Perm.colorCreate,
    dialogKind: 'master',
  );
  static const unit = FormDraftDescriptor(
    title: '新增单位',
    module: BadgeModule.rd,
    route: '/basicinfo/unit',
    permission: Perm.unitCreate,
    dialogKind: 'master',
  );
  static const currency = FormDraftDescriptor(
    title: '新增币种',
    module: BadgeModule.finance,
    route: '/basicinfo/currency',
    permission: Perm.currencyCreate,
    dialogKind: 'master',
  );
  static const warehouse = FormDraftDescriptor(
    title: '新增仓库',
    module: BadgeModule.warehouse,
    route: '/basicinfo/warehouse',
    permission: Perm.warehouseCreate,
    dialogKind: 'master',
  );
  static const account = FormDraftDescriptor(
    title: '新增账户',
    module: BadgeModule.finance,
    route: '/basicinfo/account',
    permission: Perm.accountCreate,
    dialogKind: 'master',
  );
  static const settlement = FormDraftDescriptor(
    title: '新增结算方式',
    module: BadgeModule.finance,
    route: '/basicinfo/settlement-methods',
    permission: Perm.settlementMethodCreate,
    dialogKind: 'master',
  );
  static const goodsCategory = FormDraftDescriptor(
    title: '新增货品分类',
    module: BadgeModule.rd,
    route: '/basicinfo/goods',
    permission: Perm.materialCategoryCreate,
    dialogKind: 'category',
  );
  static const mouldCategory = FormDraftDescriptor(
    title: '新增模具分类',
    module: BadgeModule.rd,
    route: '/basicinfo/mould',
    permission: Perm.mouldCategoryCreate,
    dialogKind: 'category',
  );
  static const clientCategory = FormDraftDescriptor(
    title: '新增客户分类',
    module: BadgeModule.sales,
    route: '/basicinfo/client',
    permission: Perm.clientCategoryCreate,
    dialogKind: 'category',
  );
  static const supplierCategory = FormDraftDescriptor(
    title: '新增供应商分类',
    module: BadgeModule.purchase,
    route: '/basicinfo/supplier',
    permission: Perm.supplierCategoryCreate,
    dialogKind: 'category',
  );
  static const department = FormDraftDescriptor(
    title: '新增部门',
    module: BadgeModule.people,
    route: '/department',
    permission: Perm.departmentCreate,
    dialogKind: 'department',
  );
  static const position = FormDraftDescriptor(
    title: '添加岗位',
    module: BadgeModule.people,
    route: '/department',
    permission: Perm.positionCreate,
    dialogKind: 'position',
  );
  static const paymentStyle = FormDraftDescriptor(
    title: '新增收付款类别',
    module: BadgeModule.finance,
    route: '/basicinfo/payment-style',
    permission: Perm.paymentStyleCreate,
    dialogKind: 'paymentStyle',
  );
  static const clientAddress = FormDraftDescriptor(
    title: '新增收货地址',
    module: BadgeModule.sales,
    route: '/basicinfo/client',
    permission: Perm.clientAddressCreate,
    dialogKind: 'clientAddress',
  );
  static const assetPolicy = FormDraftDescriptor(
    title: '新增资产会计政策',
    module: BadgeModule.finance,
    route: '/finance/assets',
    permission: Perm.financeAssetApprove,
    dialogKind: 'assetPolicy',
  );
  static const financeCostTemplateInput = FormDraftDescriptor(
    title: '财务原表资料',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.paymentStyleEdit,
    dialogKind: 'financeCostTemplateInput',
  );
  static const financeAssetTemplateInput = FormDraftDescriptor(
    title: '资产原表资料',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeAssetEdit,
    dialogKind: 'financeAssetTemplateInput',
  );
  static const financeAssetOpeningGroup = FormDraftDescriptor(
    title: '资产原表接续',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeAssetView,
    dialogKind: 'financeAssetOpeningGroup',
  );
  static const financeMaterialStatement = FormDraftDescriptor(
    title: FinanceRequirementNames.otherReceivableStatement,
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeReportView,
    dialogKind: 'financeMaterialStatement',
  );
  static const financeSubcontractLossPolicy = FormDraftDescriptor(
    title: '允许损耗率',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeReportView,
    dialogKind: 'financeSubcontractLossPolicy',
  );
  static const financeSubcontractQuantityEvidence = FormDraftDescriptor(
    title: '原表数量对应/期初与尾料核对',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeReportView,
    dialogKind: 'financeSubcontractQuantityEvidence',
  );
  static const financeProcurementConfirmation = FormDraftDescriptor(
    title: '提交对账确认',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeReportView,
    dialogKind: 'financeProcurementConfirmation',
  );
  static const financeAuxiliaryImport = FormDraftDescriptor(
    title: '原辅助明细导入',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeReportView,
    dialogKind: 'financeAuxiliaryImport',
  );
  static const financeStatementComparison = FormDraftDescriptor(
    title: '原表导入比对',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeReportView,
    dialogKind: 'financeStatementComparison',
  );
  static const financeNativeLegacyOpening = FormDraftDescriptor(
    title: '旧未结接续',
    module: BadgeModule.finance,
    route: RouteName.financeArAp,
    permission: Perm.financeReportView,
    dialogKind: 'financeNativeLegacyOpening',
  );
  static const financeClassificationCorrection = FormDraftDescriptor(
    title: '往来分类整图更正',
    module: BadgeModule.finance,
    route: RouteName.financeArAp,
    permission: Perm.financeReportView,
    dialogKind: 'financeClassificationCorrection',
  );
  static const financePayableStatementAdjustment = FormDraftDescriptor(
    title: '对账手续费及尾数处理',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.supplierSettlementConfirm,
    dialogKind: 'financePayableStatementAdjustment',
  );
  static const financeAccountingImport = FormDraftDescriptor(
    title: '原账套接续',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financePostExecute,
    dialogKind: 'financeAccountingImport',
  );
  static const financeExpenseAnalysisInput = FormDraftDescriptor(
    title: '费用原表资料',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.paymentStyleEdit,
    dialogKind: 'financeExpenseAnalysisInput',
  );
  static const financeStatementProfile = FormDraftDescriptor(
    title: '对账打印资料',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.paymentStyleEdit,
    dialogKind: 'financeStatementProfile',
  );
  static const financeStatementProfileReview = FormDraftDescriptor(
    title: '对账打印资料审核',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financePostExecute,
    dialogKind: 'financeStatementProfileReview',
  );
  static const financeStatementReview = FormDraftDescriptor(
    title: '对账原件处理',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.supplierSettlementConfirm,
    dialogKind: 'financeStatementReview',
  );
  static const financeStatementClientReview = FormDraftDescriptor(
    title: '对账原件处理',
    module: BadgeModule.finance,
    route: '/finance',
    permission: Perm.financeReceiptApprove,
    dialogKind: 'financeStatementClientReview',
  );
  static const financeApplication = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/new',
    permission: Perm.financeApplicationApply,
  );
  static const financeApplicationExpense = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/new',
    permission: Perm.expenseApply,
  );
  static const financeApplicationPayroll = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/new',
    permission: Perm.payrollGenerate,
  );
  static const financeApplicationReview = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id',
    permission: Perm.financeApplicationReview,
    dialogKind: 'financeApplicationReview',
  );
  static const financeApplicationOwner = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id',
    permission: Perm.financeApplicationApply,
    dialogKind: 'financeApplicationOwner',
  );
  static const financeApplicationExpenseOwner = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id',
    permission: Perm.expenseApply,
    dialogKind: 'financeApplicationExpenseOwner',
  );
  static const financeApplicationPayrollOwner = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id',
    permission: Perm.payrollGenerate,
    dialogKind: 'financeApplicationPayrollOwner',
  );
  static const financeApplicationAssignment = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id',
    permission: Perm.expenseSettings,
    dialogKind: 'financeApplicationAssignment',
  );
  static const financeApplicationContinuation = FormDraftDescriptor(
    title: '原申请接续',
    module: BadgeModule.finance,
    route: '/finance/applications/:id/continue',
    permission: Perm.financeApplicationApply,
  );
  static const financeApplicationExpenseContinuation = FormDraftDescriptor(
    title: '原申请接续',
    module: BadgeModule.finance,
    route: '/finance/applications/:id/continue',
    permission: Perm.expenseApply,
  );
  static const financeApplicationEditing = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id/edit',
    permission: Perm.financeApplicationApply,
  );
  static const financeApplicationExpenseEditing = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id/edit',
    permission: Perm.expenseApply,
  );
  static const financeApplicationPayrollEditing = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id/edit',
    permission: Perm.payrollGenerate,
  );
  static const financeApplicationExecute = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id',
    permission: Perm.financeApplicationExecute,
    dialogKind: 'financeApplicationExecute',
  );
  static const financeApplicationConfirm = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id',
    permission: Perm.financeApplicationConfirm,
    dialogKind: 'financeApplicationConfirm',
  );
  static const financeApplicationReverse = FormDraftDescriptor(
    title: FinanceRequirementNames.financeApplications,
    module: BadgeModule.finance,
    route: '/finance/applications/:id',
    permission: Perm.financeApplicationReverse,
    dialogKind: 'financeApplicationReverse',
  );

  static const goods = FormDraftDescriptor(
    title: '新增货品',
    module: BadgeModule.rd,
    route: '/basicinfo/goods/new',
    permission: Perm.goodsCreate,
  );

  static const employeeOnboarding = FormDraftDescriptor(
    title: '员工入职',
    module: BadgeModule.people,
    route: '/employee/onboarding',
    permission: Perm.employeeCreate,
  );

  static const employeeOffboarding = FormDraftDescriptor(
    title: '员工离职办理',
    module: BadgeModule.people,
    route: '/employee/:id/offboarding',
    permission: 'employee:offboard',
  );
  static const employeeReconcile = FormDraftDescriptor(
    title: '员工证件核对',
    module: BadgeModule.people,
    route: RouteName.hrReconcile,
    permission: Perm.employeePiiEdit,
    draftKind: 'employee_reconcile',
  );

  static const expense = FormDraftDescriptor(
    title: '新建报销',
    module: BadgeModule.people,
    route: '/expense/new',
    permission: Perm.expenseApply,
    draftKind: 'expense',
  );

  static const businessApplication = FormDraftDescriptor(
    title: '新建申请',
    module: BadgeModule.people,
    route: '/applications/new',
    permission: Perm.applicationApply,
    draftKind: 'business_application',
  );
  static const businessApplicationPayment = FormDraftDescriptor(
    title: '申请付款登记',
    module: BadgeModule.finance,
    route: '/applications/:id',
    permission: Perm.applicationPay,
    dialogKind: 'applicationPayment',
    draftKind: 'business_application_payment',
  );
  static const businessApplicationPrepaymentFinance = FormDraftDescriptor(
    title: '预付账务关联',
    module: BadgeModule.finance,
    route: '/applications/:id',
    permission: Perm.applicationPrepaymentLinkFinance,
    dialogKind: 'applicationPrepaymentFinance',
    draftKind: 'business_application_prepayment_finance',
  );
  static const travelApplication = FormDraftDescriptor(
    title: '出差申请',
    module: BadgeModule.people,
    route: '/applications/new?kind=TRAVEL',
    permission: Perm.applicationApplyTravel,
    draftKind: 'business_application',
  );
  static const paymentApplication = FormDraftDescriptor(
    title: '付款申请',
    module: BadgeModule.people,
    route: '/applications/new?kind=PAYMENT',
    permission: Perm.applicationApplyPayment,
    draftKind: 'business_application',
  );
  static const prepaymentApplication = FormDraftDescriptor(
    title: '预付申请',
    module: BadgeModule.people,
    route: '/applications/new?kind=PREPAYMENT',
    permission: Perm.applicationApplyPrepayment,
    draftKind: 'business_application',
  );
  static const supplierPaymentApplication = FormDraftDescriptor(
    title: '供应商付款申请',
    module: BadgeModule.people,
    route: '/applications/new?kind=SUPPLIER_PAYMENT',
    permission: Perm.applicationApplySupplierPayment,
    draftKind: 'business_application',
  );
  static const applicationKinds = {
    'TRAVEL': travelApplication,
    'PAYMENT': paymentApplication,
    'PREPAYMENT': prepaymentApplication,
    'SUPPLIER_PAYMENT': supplierPaymentApplication,
  };

  static const asset = FormDraftDescriptor(
    title: '新建资产',
    module: BadgeModule.finance,
    route: '/finance/assets/new',
    permission: Perm.financeAssetEdit,
  );

  static const weightSampleInbound = FormDraftDescriptor(
    title: '称样校准',
    module: BadgeModule.warehouse,
    route: '/measurement/weight-sample',
    permission: Perm.warehouseInboundStockIn,
    dialogKind: 'weightSample',
    draftKind: 'weight_sample',
  );
  static const weightSampleDocument = FormDraftDescriptor(
    title: '称样校准',
    module: BadgeModule.warehouse,
    route: '/measurement/weight-sample',
    permission: Perm.stockDocEdit,
    dialogKind: 'weightSample',
    draftKind: 'weight_sample',
  );
  static const weightSampleManage = FormDraftDescriptor(
    title: '称样校准',
    module: BadgeModule.warehouse,
    route: '/measurement/weight-sample',
    permission: Perm.stockWeightManage,
    dialogKind: 'weightSample',
    draftKind: 'weight_sample',
  );

  static const weighCountInbound = FormDraftDescriptor(
    title: '称重算数量',
    module: BadgeModule.warehouse,
    route: '/measurement/weigh-count-recovery',
    permission: Perm.warehouseInboundStockIn,
    dialogKind: 'weighCount',
    draftKind: 'weigh_count',
  );
  static const weighCountDocument = FormDraftDescriptor(
    title: '称重算数量',
    module: BadgeModule.warehouse,
    route: '/measurement/weigh-count-recovery',
    permission: Perm.stockDocEdit,
    dialogKind: 'weighCount',
    draftKind: 'weigh_count',
  );
  static const weighCountManage = FormDraftDescriptor(
    title: '称重算数量',
    module: BadgeModule.warehouse,
    route: '/measurement/weigh-count-recovery',
    permission: Perm.stockWeightManage,
    dialogKind: 'weighCount',
    draftKind: 'weigh_count',
  );
  static const weighCountRead = FormDraftDescriptor(
    title: '称重算数量',
    module: BadgeModule.warehouse,
    route: '/measurement/weigh-count-recovery',
    permission: Perm.stockView,
    dialogKind: 'weighCount',
    draftKind: 'weigh_count',
  );

  static const workshopMaterialCount = FormDraftDescriptor(
    title: '车间内料仓盘点',
    module: BadgeModule.warehouse,
    route: RouteName.workshopMaterialCount,
    permission: Perm.workshopMaterialCount,
    draftKind: 'workshop_material_count',
  );

  static const workshopMaterialCloseRetry = FormDraftDescriptor(
    title: '车间物料结算',
    module: BadgeModule.warehouse,
    route: '/workshop-material/close-retry',
    permission: Perm.workshopMaterialCount,
    draftKind: 'workshop_material_close_retry',
  );

  static const materialPreparation = FormDraftDescriptor(
    title: '物料备料操作草稿',
    module: BadgeModule.production,
    route: RouteName.productionMaterialAnalysis,
    permission: Perm.productionMaterialAnalysisView,
    draftKind: 'material_preparation',
  );

  static const dailyReport = FormDraftDescriptor(
    title: '新建生产日报',
    module: BadgeModule.workshop,
    route: '/production/daily-reports/new',
    permission: Perm.productionDailyReportCreate,
    draftKind: 'productionDailyReport',
  );

  static const productionDraw = FormDraftDescriptor(
    title: '新建车间领料申请',
    module: BadgeModule.workshop,
    route: RouteName.productionDrawRequest,
    permission: Perm.productionExecutionStart,
  );

  static const productionDiscovery = FormDraftDescriptor(
    title: '新建车间材料领料申请',
    module: BadgeModule.workshop,
    route: '/production/material-discovery-request',
    permission: Perm.productionExecutionStart,
  );

  static const productionReturn = FormDraftDescriptor(
    title: '生产余料退仓申请',
    module: BadgeModule.workshop,
    route: '/production/material-return/new',
    permission: Perm.productionMaterialSettle,
  );

  static const productionRate = FormDraftDescriptor(
    title: '申请调整允许超产比例',
    module: BadgeModule.workshop,
    route: '/production/overproduction-rate-requests/new',
    permission: Perm.productionExecutionRequestOverproductionRate,
  );

  static const iqcReport = FormDraftDescriptor(
    title: '来料检验报告',
    module: BadgeModule.quality,
    route: '${RouteName.warehouseInspections}/:receiptType/:receiptId',
    permission: Perm.procurementInspectionHandle,
  );

  static const fqcSheet = FormDraftDescriptor(
    title: '自制产成品质检报告',
    module: BadgeModule.quality,
    route: '${RouteName.productionFqcSheetHandlingBase}/:sheetId',
    permission: Perm.productionQualityInspectionApprove,
  );

  static const fqcInspection = FormDraftDescriptor(
    title: '自制产成品质检报告',
    module: BadgeModule.quality,
    route: '${RouteName.productionFqcInspectionHandlingBase}/:inspectionId',
    permission: Perm.productionQualityInspectionApprove,
  );

  static const finishedArrival = FormDraftDescriptor(
    title: '登记实际入库',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseProductionFinishedArrivalRegistration,
    permission: Perm.stockDocApprove,
  );

  static const warehouseDraw = FormDraftDescriptor(
    title: '批量领料出库填写',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseProductionDrawBatchIssue,
    permission: Perm.stockDocIssue,
  );

  static const workshopMaterialIssue = FormDraftDescriptor(
    title: '生产领退料办理',
    module: BadgeModule.warehouse,
    route: RouteName.workshopMaterialIssue,
    permission: Perm.workshopMaterialIssue,
    draftKind: 'workshop_material_issue',
  );
  static const workshopMaterialBatchIssue = FormDraftDescriptor(
    title: '生产领退料批量办理',
    module: BadgeModule.warehouse,
    route: '${RouteName.workshopMaterialIssue}/batch',
    permission: Perm.workshopMaterialIssue,
    draftKind: 'workshop_material_batch_issue',
  );
  static const warehouseDiscovery = FormDraftDescriptor(
    title: '填写领料材料',
    module: BadgeModule.warehouse,
    route: '/warehouse/material-discovery/:requestId',
    permission: Perm.stockDocIssue,
  );

  static const stockDocument = FormDraftDescriptor(
    title: '新建单据',
    module: BadgeModule.warehouse,
    route: '/warehouse/:code/new',
    permission: Perm.stockDocCreate,
    draftKind: 'stockDocument',
  );

  static const stockCount = FormDraftDescriptor(
    title: '盘点模式',
    module: BadgeModule.warehouse,
    route: RouteName.stockCountSession,
    permission: Perm.stockCountSubmit,
    draftKind: 'stockCount',
  );

  static const arrival = FormDraftDescriptor(
    title: '登记实际到货',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseArrivalRegistration,
    permission: Perm.warehouseInboundStockIn,
  );

  static const subcontractOutbound = FormDraftDescriptor(
    title: '委外领料拣货出仓填写',
    module: BadgeModule.warehouse,
    route: '/warehouse/subcontract-outbound/:issueId',
    permission: Perm.subcontractMaterialIssueEdit,
  );

  static const warehouseSalesOutbound = FormDraftDescriptor(
    title: '销售出库核对',
    module: BadgeModule.warehouse,
    route: '/warehouse/sales-outbound/:id',
    permission: Perm.warehouseSalesOutboundExecute,
  );

  static const subcontractOutboundBatch = FormDraftDescriptor(
    title: '批量委外领料拣货出仓填写',
    module: BadgeModule.warehouse,
    route: '/warehouse/subcontract-outbound/batch',
    permission: Perm.subcontractMaterialIssueEdit,
  );

  static const warehouseSalesOutboundBatch = FormDraftDescriptor(
    title: '批量销售出库核对',
    module: BadgeModule.warehouse,
    route: '/warehouse/sales-outbound/batch',
    permission: Perm.warehouseSalesOutboundExecute,
  );

  static const warehouseQualityStockIn = FormDraftDescriptor(
    title: '合格来料入库填写',
    module: BadgeModule.warehouse,
    route: '${RouteName.warehouseQualityResults}/:receiptType/:receiptId',
    permission: Perm.warehouseIqcStockInConfirm,
  );
  static const warehouseQualityBatchStockIn = FormDraftDescriptor(
    title: '批量合格来料入库填写',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseQualityBatchStockIn,
    permission: Perm.warehouseIqcStockInConfirm,
  );
  static const warehouseQualityPreStockIn = FormDraftDescriptor(
    title: '待检来料上架填写',
    module: BadgeModule.warehouse,
    route:
        '${RouteName.warehouseQualityPreStockInBase}/:receiptType/:receiptId',
    permission: Perm.warehouseIqcStockInBeforeInspection,
  );
  static const productionFinishedBatchStockIn = FormDraftDescriptor(
    title: '批量产成品点收填写',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseProductionFinishedBatchStockIn,
    permission: Perm.stockDocApprove,
  );
  static const materialReturnBatchReceive = FormDraftDescriptor(
    title: '批量生产退料收仓填写',
    module: BadgeModule.warehouse,
    route: '/warehouse/material-returns/batch-receive',
    permission: Perm.stockDocApprove,
  );

  static const suggestion = FormDraftDescriptor(
    title: '新建建议',
    module: BadgeModule.people,
    route: '/suggestion/new',
    permission: Perm.suggestionSubmit,
  );

  static const notice = FormDraftDescriptor(
    title: '发布通知',
    module: BadgeModule.system,
    route: '/notice/publish',
    permission: 'notice:publish',
  );

  static const payroll = FormDraftDescriptor(
    title: '生成工资',
    module: BadgeModule.people,
    route: '/payroll/generate',
    permission: 'payroll:generate',
  );
  static const iqcBatchReport = FormDraftDescriptor(
    title: '品质批量检验报告',
    module: BadgeModule.quality,
    route: RouteName.warehouseInspectionBatchApproval,
    permission: Perm.procurementInspectionHandle,
  );
  static const fqcBatchReport = FormDraftDescriptor(
    title: '品质批量检验报告',
    module: BadgeModule.quality,
    route: RouteName.warehouseInspectionBatchApproval,
    permission: Perm.productionQualityInspectionApprove,
  );

  /// Completeness index for the single reviewed descriptor catalog.
  static const all = <String, FormDraftDescriptor>{
    'salesManagerOrderBatch': salesManagerOrderBatch,
    'salesManagerQuoteReview': salesManagerQuoteReview,
    'salesManagerOrderReview': salesManagerOrderReview,
    'financeSalesOrderReview': financeSalesOrderReview,
    'financeProcurementReview': financeProcurementReview,
    'financeQuoteReview': financeQuoteReview,
    'financeShipmentReview': financeShipmentReview,
    'goodsCost': goodsCost,
    'client': client,
    'supplier': supplier,
    'supplierQuick': supplierQuick,
    'mould': mould,
    'color': color,
    'unit': unit,
    'currency': currency,
    'warehouse': warehouse,
    'account': account,
    'settlement': settlement,
    'goodsCategory': goodsCategory,
    'mouldCategory': mouldCategory,
    'clientCategory': clientCategory,
    'supplierCategory': supplierCategory,
    'department': department,
    'position': position,
    'paymentStyle': paymentStyle,
    'clientAddress': clientAddress,
    'assetPolicy': assetPolicy,
    'financeCostTemplateInput': financeCostTemplateInput,
    'financeAssetTemplateInput': financeAssetTemplateInput,
    'financeAssetOpeningGroup': financeAssetOpeningGroup,
    'financeMaterialStatement': financeMaterialStatement,
    'financeSubcontractLossPolicy': financeSubcontractLossPolicy,
    'financeSubcontractQuantityEvidence': financeSubcontractQuantityEvidence,
    'financeProcurementConfirmation': financeProcurementConfirmation,
    'financeAuxiliaryImport': financeAuxiliaryImport,
    'financeStatementComparison': financeStatementComparison,
    'financeNativeLegacyOpening': financeNativeLegacyOpening,
    'financeClassificationCorrection': financeClassificationCorrection,
    'financePayableStatementAdjustment': financePayableStatementAdjustment,
    'financeAccountingImport': financeAccountingImport,
    'financeExpenseAnalysisInput': financeExpenseAnalysisInput,
    'financeStatementProfile': financeStatementProfile,
    'financeStatementProfileReview': financeStatementProfileReview,
    'financeStatementReview': financeStatementReview,
    'financeStatementClientReview': financeStatementClientReview,
    'financeApplication': financeApplication,
    'financeApplicationExpense': financeApplicationExpense,
    'financeApplicationPayroll': financeApplicationPayroll,
    'financeApplicationReview': financeApplicationReview,
    'financeApplicationExecute': financeApplicationExecute,
    'financeApplicationConfirm': financeApplicationConfirm,
    'financeApplicationReverse': financeApplicationReverse,
    'financeApplicationOwner': financeApplicationOwner,
    'financeApplicationExpenseOwner': financeApplicationExpenseOwner,
    'financeApplicationPayrollOwner': financeApplicationPayrollOwner,
    'financeApplicationAssignment': financeApplicationAssignment,
    'financeApplicationContinuation': financeApplicationContinuation,
    'financeApplicationExpenseContinuation':
        financeApplicationExpenseContinuation,
    'financeApplicationEditing': financeApplicationEditing,
    'financeApplicationExpenseEditing': financeApplicationExpenseEditing,
    'financeApplicationPayrollEditing': financeApplicationPayrollEditing,
    'goods': goods,
    'employeeOnboarding': employeeOnboarding,
    'employeeOffboarding': employeeOffboarding,
    'employeeReconcile': employeeReconcile,
    'expense': expense,
    'businessApplication': businessApplication,
    'businessApplicationPayment': businessApplicationPayment,
    'businessApplicationPrepaymentFinance':
        businessApplicationPrepaymentFinance,
    'travelApplication': travelApplication,
    'paymentApplication': paymentApplication,
    'prepaymentApplication': prepaymentApplication,
    'supplierPaymentApplication': supplierPaymentApplication,
    'asset': asset,
    'dailyReport': dailyReport,
    'materialPreparation': materialPreparation,
    'workshopMaterialCount': workshopMaterialCount,
    'workshopMaterialCloseRetry': workshopMaterialCloseRetry,
    'weightSampleInbound': weightSampleInbound,
    'weightSampleDocument': weightSampleDocument,
    'weightSampleManage': weightSampleManage,
    'weighCountInbound': weighCountInbound,
    'weighCountDocument': weighCountDocument,
    'weighCountManage': weighCountManage,
    'weighCountRead': weighCountRead,
    'productionDraw': productionDraw,
    'productionDiscovery': productionDiscovery,
    'productionReturn': productionReturn,
    'productionRate': productionRate,
    'iqcReport': iqcReport,
    'fqcSheet': fqcSheet,
    'fqcInspection': fqcInspection,
    'finishedArrival': finishedArrival,
    'warehouseDraw': warehouseDraw,
    'workshopMaterialIssue': workshopMaterialIssue,
    'workshopMaterialBatchIssue': workshopMaterialBatchIssue,
    'warehouseDiscovery': warehouseDiscovery,
    'stockDocument': stockDocument,
    'stockCount': stockCount,
    'arrival': arrival,
    'subcontractOutbound': subcontractOutbound,
    'warehouseSalesOutbound': warehouseSalesOutbound,
    'warehouseSalesOutboundBatch': warehouseSalesOutboundBatch,
    'subcontractOutboundBatch': subcontractOutboundBatch,
    'warehouseQualityStockIn': warehouseQualityStockIn,
    'warehouseQualityBatchStockIn': warehouseQualityBatchStockIn,
    'warehouseQualityPreStockIn': warehouseQualityPreStockIn,
    'productionFinishedBatchStockIn': productionFinishedBatchStockIn,
    'materialReturnBatchReceive': materialReturnBatchReceive,
    'suggestion': suggestion,
    'notice': notice,
    'payroll': payroll,
    'iqcBatchReport': iqcBatchReport,
    'fqcBatchReport': fqcBatchReport,
  };
}

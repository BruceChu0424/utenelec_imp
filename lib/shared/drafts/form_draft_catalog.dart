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
      draft.module == module &&
      draft.permission == permission &&
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

/// Draft policy uses the same create/approve authority as its domain command.
/// Accounting policy creation is an approval operation, unlike asset entry.
abstract final class FormDraftCatalog {
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

  static const expense = FormDraftDescriptor(
    title: '新建报销',
    module: BadgeModule.people,
    route: '/expense/new',
    permission: Perm.expenseApply,
    draftKind: 'expense',
  );

  static const asset = FormDraftDescriptor(
    title: '新建资产',
    module: BadgeModule.finance,
    route: '/finance/assets/new',
    permission: Perm.financeAssetEdit,
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

  static const finishedArrivalBatch = FormDraftDescriptor(
    title: '批量登记实际入库',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseProductionFinishedArrivalBatchRegistration,
    permission: Perm.stockDocApprove,
  );

  static const warehouseDraw = FormDraftDescriptor(
    title: '批量领料出库填写',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseProductionDrawBatchIssue,
    permission: Perm.stockDocIssue,
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

  static const arrival = FormDraftDescriptor(
    title: '登记实际到货',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseArrivalReceiptNew,
    permission: Perm.warehouseInboundStockIn,
  );

  static const arrivalBatch = FormDraftDescriptor(
    title: '批量登记实际到货',
    module: BadgeModule.warehouse,
    route: RouteName.warehouseArrivalReceiptBatch,
    permission: Perm.warehouseInboundStockIn,
  );

  static const subcontractOutbound = FormDraftDescriptor(
    title: '委外领料拣货出仓填写',
    module: BadgeModule.warehouse,
    route: '/warehouse/subcontract-outbound/:issueId',
    permission: Perm.subcontractMaterialIssueEdit,
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
    'goods': goods,
    'employeeOnboarding': employeeOnboarding,
    'employeeOffboarding': employeeOffboarding,
    'expense': expense,
    'asset': asset,
    'dailyReport': dailyReport,
    'productionDraw': productionDraw,
    'productionDiscovery': productionDiscovery,
    'productionReturn': productionReturn,
    'productionRate': productionRate,
    'iqcReport': iqcReport,
    'fqcSheet': fqcSheet,
    'fqcInspection': fqcInspection,
    'finishedArrival': finishedArrival,
    'finishedArrivalBatch': finishedArrivalBatch,
    'warehouseDraw': warehouseDraw,
    'warehouseDiscovery': warehouseDiscovery,
    'stockDocument': stockDocument,
    'arrival': arrival,
    'arrivalBatch': arrivalBatch,
    'subcontractOutbound': subcontractOutbound,
    'suggestion': suggestion,
    'notice': notice,
    'payroll': payroll,
    'iqcBatchReport': iqcBatchReport,
    'fqcBatchReport': fqcBatchReport,
  };
}

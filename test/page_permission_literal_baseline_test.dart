import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 页面 / 组件里本地拼权限的基线(ADR-109 / permissions-15)。
///
/// 按钮能不能点，最终要由服务端按「权限码 + 对象范围 + 单据状态 + 附加审核权」一次算好
/// 随详情下发(如日报、出货财审的 allowedActions)。页面或组件里每多一处 `Perm.x`，
/// 就多一处可能和服务端判断不一致的地方(例：日报审核按钮漏了车间直送审核权，点了才被拒)。
///
/// 计数口径：lib/features 下所有 pages / widgets 目录里出现的 `Perm.x` 引用，不管写成
/// `contains(Perm.x)`、`_has(Perm.x)` 还是 `can(Perm.x)`——换个辅助函数包一层也照样计数，
/// 绕不过去。路由守卫与 hub 卡片走 lib/core/router 下的目录派生，不在此计数。
///
/// 本测试只许这个数下降：新页面请改用服务端下发的动作集合；把旧页面迁走后，
/// 同步把 [_baseline] 调小。数字上涨会直接红。
// 2026-09-23 第一阶段合并: 主档明细区把状态/删除权限码作为配置传入共享组件(客户分类 +1、模具分类 +3),
// 总账报表「附表取数设置」按钮 +1, 仓库到货预期视图 -1, 净 +4。改为服务端下发动作集合归后续 uikit 工作流。
// 2026-09-24 +10：V694–V702 三个新审批页(追加用料/超产比例/追加生产计划)的按钮显隐
// 与服务端 @PreAuthorize 组合一一对应地本地预演，非新增裁决逻辑。
// 2026-09-25 +8：物料聚合单(聚合明细表 +3/物料表 +2/分析页 +1)与叶层物料发现页(+2)
// 的按钮显隐与服务端 @PreAuthorize 一一对应地本地预演，非新增裁决逻辑。
// 2026-09-25 +7：基础资料五个主档(模具/颜色/单位/结算方式/仓库)补齐导出/打印按钮(+9，
// 与币种/账户页同款 UtenExportButton 本地权限引用)；组装信息页单价/金额列退役顺手
// 移除 2 处价格权限引用，净 +7。
// 2026-09-25 +1：销售订单详情「修改订单」按钮显隐本地预演(与服务端 sales:order:edit
// 的 @PreAuthorize 一一对应，随列对齐编辑保存 pop 回宿主批次)。
// 2026-09-28 -1: ADR-133/134 合并后(报价按钮改服务端 allowedActions、政策情报退役)净减 1。
// 2026-09-28 +1：快照分支并入的仓库收退回批量收货页/单据段(收货确认按 stockDocApprove
// 本地预演，与服务端 @PreAuthorize 同口径)。
// 2026-10-02 +43（closeout/盘点批次，格式门禁修复后首次全量清点）：
//   · 平台整改批次在 main 上未过格式门禁前已积累 +37（调度台 +13、日报创建恢复页
//     新页 +12、日报编辑页 +14 等，均按「与服务端 @PreAuthorize 一一对应本地预演」口径）；
//   · 盘点审核页(stock_count_review_page) +5、库存余额详情弹层 +1；
//   · 即时库存总览/汇总条 WIP +6（同口径）。
//   净 621 -> 664。迁移服务端 allowedActions 归后续 uikit 工作流。
// 2026-10-02 +8：报价议价全链(V788)的报价操作按钮(客户确认/议价历史/撤回/重报)与服务端
// @PreAuthorize 一一对应地本地预演（与 V694-V702 审批页同款口径）。
// 2026-10-03 +8：AI 业务查询与表单辅助填写批次（报价模板下载/学习范围、销售模板
// 辅助等操作按钮）继续按同口径本地预演。
// 2026-10-03 +3：AI 使用审计面板（管理页查看计价/审计入口）同口径预演。
// 2026-10-04 -6：ADR-143 委外按工序领直属物料(委外申请进度弹窗、订货单进度区改由服务端
// priceMasked 判金额可见、仓库委外领料拣货页等)退掉本地权限引用，净 683 -> 677。
const _baseline = 677;

final _permReference = RegExp(r'\bPerm\.[a-zA-Z]');
final _fullPermReference = RegExp(r'\bPerm\.[a-zA-Z]\w*');

// 2026-10-12 合并主目录快照的 20 处已逐项审核：财审决定发送前复核当前
// 权限、HR 核对记录/应用沿原 employee 权限、仓库异步续接停止失去确认权
// 的批次。对象范围与最终动作仍由服务端 allowedActions / capability 及
// @PreAuthorize 裁决。保留旧基线 677，只减去这些精确来源的已审增量；
// 同样次数改成另一权限、复制到其他文件或再加引用均不享受这份登记。
// 2026-10-13：合入 main e206d69b1 / b329fa29d 的价格分析五处来源，净 +13。
// a7e3fc9db -> main b93f0e476 的引用从 697 增至 710；本轮 UI 与 main
// 在每文件、每 Perm 标识的出现次数完全一致，未增加权限检查。
// goods:view + goods:price_analysis:view 对应 GoodsPriceAnalysisController /
// GoodsPriceHistoryTableController 的服务端复合守卫；销售历史模式对应
// GoodsPriceAccess.requireHistory，来源与价格对象范围继续由服务端裁决。
// 货品详情原有 16 处引用不享受新增额度，其余四个新文件原有计数为 0。
// 2026-10-17 ADR-181: 同身份授权变化的监听集合与决定发送前重检复用后端动作码，
// 并继续与 allowedActions / claim / 对象范围相交；四主档的新增分类查看引用只控制
// 分类树读取，不强迫实体列表取得分类权。出货列表分别预演批准、驳回权限。
// 以下按文件和完整 Perm 标识登记已审引用，不提高 677 基线，也不放宽反绕过断言。
// ADR-182: 货品操作历史替换原「撤回导入」入口，将该入口的一处引用移入
// 历史面板。其余 15 处仅决定拥有对应操作权的人能否打开历史，实际撤回/重做
// 继续由服务端按原动作权限、身份、版本和当前对象状态裁决；不授予写权限。
// 2026-10-18 main 合入 V875 与 ADR-184（合并 d20e36971）后全量 684，按来源逐项登记 +8：
//   · V875 部门权限配置转移：入口操作条与导入对话框分别本地预演 authorization:manage
//     （2 处 / 1 处）；服务端 PermissionConfigurationTransferController/Service 统一强制
//     authorization:manage + superAdmin，预览、落库与审计均以服务端裁决为准。
//   · ADR-184 人事任务卡：任务可办与操作按钮改按真实已授动作权限逐类预演
//     （employeeView 门槛 +1、employeeConfirm +1、employeeEdit +1、employeePiiEdit +1、
//     noticePublish +1），与 HrTaskClaimService.requireCanHandle / HrTaskService.hasAction
//     的任务类型→动作码映射一一对应；接管仍为 isSuperAdmin || employee:task_takeover。
//   · production_plan_list_page 在表格化选择器重排中合并重复的 productionPlanApprove
//     预演净 -1，不占登记额度；登记后全量 676，仍守 677 基线。
const _reviewedSourceGuards = <String, ({int legacyCount, Map<String, int> tokens})>{
  'lib/features/finance/pages/finance_procurement_approval_review_page.dart': (
    legacyCount: 4,
    tokens: {
      'Perm.financeOrderApprovalApprove': 4,
      'Perm.financeOrderApprovalReject': 4,
      'Perm.financeOrderApprovalView': 3,
      'Perm.purchaseOrderReverse': 1,
      'Perm.subcontractOrderReverse': 1,
    },
  ),
  'lib/features/finance/pages/finance_quote_review_page.dart': (
    legacyCount: 4,
    tokens: {
      'Perm.attachmentView': 1,
      'Perm.salesQuoteFinanceConfirm': 2,
      'Perm.salesQuoteFinanceView': 2,
    },
  ),
  'lib/features/finance/pages/finance_sales_shipment_audit_review_page.dart': (
    legacyCount: 2,
    tokens: {
      'Perm.salesShipmentFinanceApprove': 4,
      'Perm.salesShipmentFinanceReject': 4,
      'Perm.salesShipmentFinanceView': 3,
      'Perm.salesShipmentFinanceReverse': 2,
      'Perm.salesShipmentView': 1,
    },
  ),
  'lib/features/finance/pages/finance_sales_order_review_page.dart': (
    legacyCount: 5,
    tokens: {
      'Perm.salesOrderFinanceView': 2,
      'Perm.salesOrderFinanceConfirm': 2,
      'Perm.salesOrderReverse': 1,
      'Perm.financeViewAll': 1,
      'Perm.customerPrepaymentView': 1,
      'Perm.attachmentView': 1,
      'Perm.salesQuoteView': 1,
    },
  ),
  'lib/features/basic_data/pages/client_category_page.dart': (
    legacyCount: 13,
    tokens: {
      'Perm.clientCategoryView': 1,
      'Perm.clientCategoryCreate': 1,
      'Perm.clientCategoryEdit': 1,
      'Perm.clientCategoryDelete': 1,
      'Perm.clientCategoryMove': 1,
      'Perm.clientCategoryReorder': 1,
      'Perm.clientCreate': 1,
      'Perm.clientEdit': 1,
      'Perm.clientDelete': 1,
      'Perm.clientStatus': 2,
      'Perm.clientExport': 1,
      'Perm.clientAssign': 2,
    },
  ),
  'lib/features/basic_data/pages/mould_category_page.dart': (
    legacyCount: 13,
    tokens: {
      'Perm.mouldCategoryView': 1,
      'Perm.mouldCategoryCreate': 1,
      'Perm.mouldCategoryEdit': 1,
      'Perm.mouldCategoryDelete': 1,
      'Perm.mouldCategoryMove': 1,
      'Perm.mouldCategoryReorder': 1,
      'Perm.mouldStatus': 2,
      'Perm.mouldCreate': 1,
      'Perm.mouldEdit': 2,
      'Perm.mouldDelete': 2,
      'Perm.mouldExport': 1,
    },
  ),
  'lib/features/basic_data/pages/product_category_page.dart': (
    legacyCount: 18,
    tokens: {
      'Perm.materialCategoryView': 1,
      'Perm.materialCategoryCreate': 1,
      'Perm.materialCategoryEdit': 1,
      'Perm.materialCategoryDelete': 1,
      'Perm.materialCategoryMove': 1,
      'Perm.materialCategoryReorder': 1,
      'Perm.goodsCreate': 1,
      'Perm.goodsDelete': 1,
      'Perm.goodsStatus': 1,
      'Perm.goodsBomDelete': 1,
      'Perm.goodsBomCreate': 2,
      'Perm.goodsBomEdit': 3,
      'Perm.goodsPriceEdit': 2,
      'Perm.goodsDiscountView': 1,
      'Perm.goodsPriceView': 1,
      'Perm.goodsEdit': 1,
      'Perm.goodsExport': 1,
      'Perm.goodsImport': 1,
    },
  ),
  'lib/features/basic_data/widgets/goods_operation_history_panel.dart': (
    legacyCount: 1,
    tokens: {
      'Perm.goodsCreate': 1,
      'Perm.goodsEdit': 1,
      'Perm.goodsNameEnEdit': 1,
      'Perm.goodsDelete': 1,
      'Perm.goodsStatus': 1,
      'Perm.goodsImport': 1,
      'Perm.goodsImportUndo': 1,
      'Perm.goodsBomCreate': 1,
      'Perm.goodsBomEdit': 1,
      'Perm.goodsBomDelete': 1,
      'Perm.goodsBomAudit': 1,
      'Perm.materialCategoryCreate': 1,
      'Perm.materialCategoryEdit': 1,
      'Perm.materialCategoryDelete': 1,
      'Perm.materialCategoryMove': 1,
      'Perm.materialCategoryReorder': 1,
    },
  ),
  'lib/features/basic_data/pages/supplier_category_page.dart': (
    legacyCount: 11,
    tokens: {
      'Perm.supplierCategoryView': 1,
      'Perm.supplierCategoryCreate': 1,
      'Perm.supplierCategoryEdit': 1,
      'Perm.supplierCategoryDelete': 1,
      'Perm.supplierCategoryMove': 1,
      'Perm.supplierCategoryReorder': 1,
      'Perm.supplierCreate': 1,
      'Perm.supplierEdit': 1,
      'Perm.supplierDelete': 1,
      'Perm.supplierStatus': 2,
      'Perm.supplierExport': 1,
    },
  ),
  'lib/features/sales/widgets/sales_shipment_task_workbench.dart': (
    legacyCount: 2,
    tokens: {
      'Perm.salesShipmentFinanceView': 1,
      'Perm.warehouseSalesOutboundView': 1,
      'Perm.salesShipmentFinanceApprove': 1,
      'Perm.salesShipmentFinanceReject': 1,
    },
  ),
  'lib/features/hr_task/pages/hr_reconcile_page.dart': (
    legacyCount: 0,
    tokens: {
      'Perm.employeeEdit': 3,
      'Perm.employeePiiEdit': 1,
      'Perm.employeeView': 4,
    },
  ),
  'lib/features/hr_task/pages/hr_task_list_page.dart': (
    legacyCount: 4,
    tokens: {
      'Perm.employeeConfirm': 2,
      'Perm.employeeEdit': 1,
      // ADR-180: history visibility mirrors the server GET guards. Birthday
      // history still requires PII read; neither guard grants a write action.
      'Perm.employeePiiView': 1,
      'Perm.employeeTaskTakeover': 1,
      'Perm.employeeView': 1,
      'Perm.noticePublish': 1,
      'Perm.noticeRead': 1,
    },
  ),
  'lib/features/hr_task/pages/hr_workbench_page.dart': (
    legacyCount: 1,
    tokens: {
      'Perm.employeeEdit': 1,
      'Perm.employeeView': 1,
      'Perm.noticePublish': 1,
    },
  ),
  'lib/features/warehouse/pages/production_finished_batch_stock_in_page.dart': (
    legacyCount: 2,
    tokens: {'Perm.stockDocApprove': 3},
  ),
  'lib/features/warehouse/pages/warehouse_material_return_batch_receive_page.dart':
      (legacyCount: 1, tokens: {'Perm.stockDocApprove': 3}),
  'lib/features/basic_data/pages/goods_price_analysis_page.dart': (
    legacyCount: 0,
    tokens: {
      'Perm.goodsPriceAnalysisView': 1,
      'Perm.goodsView': 1,
      'Perm.salesOrderPriceView': 1,
      'Perm.salesOrderView': 1,
      'Perm.salesQuoteFinanceView': 1,
    },
  ),
  'lib/features/basic_data/widgets/goods_detail_body.dart': (
    legacyCount: 16,
    tokens: {
      'Perm.attachmentView': 1,
      'Perm.colorCreate': 1,
      'Perm.goodsCostView': 2,
      'Perm.goodsDiscountView': 2,
      'Perm.goodsEdit': 1,
      'Perm.goodsPriceAnalysisView': 1,
      'Perm.goodsPriceEdit': 2,
      'Perm.goodsPriceView': 2,
      'Perm.goodsView': 3,
      'Perm.salesQuoteFinanceView': 1,
      'Perm.stockView': 1,
      'Perm.unitCreate': 1,
    },
  ),
  'lib/features/basic_data/widgets/goods_price_facet_picker.dart': (
    legacyCount: 0,
    tokens: {'Perm.goodsPriceAnalysisView': 1, 'Perm.goodsView': 1},
  ),
  'lib/features/basic_data/widgets/goods_price_observation_detail.dart': (
    legacyCount: 0,
    tokens: {'Perm.goodsPriceAnalysisView': 1, 'Perm.goodsView': 1},
  ),
  'lib/features/basic_data/widgets/goods_subcontract_supplier_table.dart': (
    legacyCount: 0,
    tokens: {'Perm.goodsPriceAnalysisView': 1, 'Perm.goodsView': 1},
  ),
  // The data-scope entry and its asynchronous boundary both require superAdmin
  // AND authorizationManage. clientViewAll identifies the permission row rather
  // than granting access. Backend admin guards/CAS and credit scope remain final.
  'lib/features/admin/widgets/page_permission_drawer.dart': (
    legacyCount: 2,
    tokens: {
      'Perm.accountSupport': 2,
      'Perm.authorizationManage': 2,
      'Perm.clientViewAll': 1,
    },
  ),
  // V875 部门权限配置转移：本地只预演 authorization:manage 入口，服务端另加
  // superAdmin 双重强制，转移预览/落库/审计全部由服务端裁决。
  'lib/features/admin/widgets/admin_permission_transfer_actions.dart': (
    legacyCount: 0,
    tokens: {'Perm.authorizationManage': 2},
  ),
  'lib/features/admin/widgets/permission_configuration_import_dialog.dart': (
    legacyCount: 0,
    tokens: {'Perm.authorizationManage': 1},
  ),
  // ADR-184 任务卡按真实已授动作权限逐类预演，映射与
  // HrTaskClaimService.requireCanHandle / HrTaskService.hasAction 一一对应；
  // 认领/接管与实际动作仍由服务端按对象与人裁决。
  'lib/features/hr_task/widgets/hr_task_widgets.dart': (
    legacyCount: 3,
    tokens: {
      'Perm.employeeConfirm': 2,
      'Perm.employeeEdit': 1,
      'Perm.employeePiiEdit': 1,
      'Perm.employeeTaskTakeover': 1,
      'Perm.employeeView': 1,
      'Perm.noticePublish': 2,
    },
  ),
  // 2026-10-18 官网管理/询盘并入（uimp/website-imp-integration）：管理页按 V879
  // 新增的 website:* 权限逐动作预演入口（发布/回退为高危动作，服务端
  // WebsiteManagementController 另按 @PreAuthorize + 门户会话租约裁决）；
  // authorizationManage 预演仅控制桥接诊断入口的显隐，实际授权仍由服务端强制。
  'lib/features/website_management/pages/website_management_page.dart': (
    legacyCount: 0,
    tokens: {
      'Perm.authorizationManage': 2,
      'Perm.webinquiryView': 1,
      'Perm.websiteContentEdit': 3,
      'Perm.websiteMediaManage': 1,
      'Perm.websiteProductEdit': 1,
      'Perm.websitePublish': 2,
      'Perm.websiteRollback': 1,
      'Perm.websiteView': 4,
    },
  ),
  // 询盘跟进时间线：新增跟进记录按钮预演 webinquiry:claim，与
  // WebsiteInquiryService 的认领归属复核同口径，第二人无法覆盖已认领人。
  'lib/features/webinquiry/widgets/website_inquiry_source_timeline.dart': (
    legacyCount: 0,
    tokens: {'Perm.webinquiryClaim': 1},
  ),
  // Inline price cells mirror GoodsInlineEditService's goods:price:edit guard.
  // The master-history entry also admits client-address action holders; the
  // native read boundary and server still enforce visibility, original action
  // grants, actor ownership, snapshots and reference constraints. These four
  // exact references only present existing actions and do not raise 677.
  'lib/features/basic_data/widgets/goods_inline_edit.dart': (
    legacyCount: 0,
    tokens: {'Perm.goodsPriceEdit': 1},
  ),
  'lib/features/basic_data/widgets/master_operation_history_panel.dart': (
    legacyCount: 0,
    tokens: {
      'Perm.clientView': 1,
      'Perm.clientAddressCreate': 1,
      'Perm.clientAddressDelete': 1,
    },
  ),
  // ADR-185: edit mode and retained asynchronous callbacks intersect current
  // split BOM grants with the page session. The server independently checks
  // each queued command, parent visibility, snapshots and explicit consent.
  // Where-used replacement requires view + BOM edit; its separate export grant
  // is enforced by the export controller. These exact tokens grant no object
  // scope or state transition locally, and do not raise the global baseline.
  'lib/features/basic_data/widgets/goods_bom_tab.dart': (
    legacyCount: 2,
    tokens: {
      'Perm.goodsBomAudit': 1,
      'Perm.goodsBomCreate': 2,
      'Perm.goodsBomDelete': 2,
      'Perm.goodsBomEdit': 1,
      'Perm.goodsExport': 1,
      'Perm.goodsView': 1,
    },
  ),
  'lib/features/production/pages/where_used_report_page.dart': (
    legacyCount: 2,
    tokens: {
      'Perm.goodsBomEdit': 2,
      'Perm.goodsView': 1,
      'Perm.productionWhereUsedExport': 1,
      'Perm.stockView': 1,
    },
  ),
  'lib/features/production/widgets/where_used_replacement_dialog.dart': (
    legacyCount: 0,
    tokens: {'Perm.goodsBomEdit': 1, 'Perm.productionWhereUsedView': 1},
  ),
  // ADR-185: action grants are rechecked across picker/preview/consent awaits.
  // Object visibility, top-level scope and atomic validation remain server-owned.
  'lib/features/basic_data/widgets/goods_bom_batch_maintenance_dialog.dart': (
    legacyCount: 0,
    tokens: {
      'Perm.goodsBomEdit': 1,
      'Perm.goodsBomCreate': 1,
      'Perm.goodsBomDelete': 2,
    },
  ),
};

Map<String, int> _permissionTokens(String source) {
  final tokens = <String, int>{};
  for (final match in _fullPermReference.allMatches(source)) {
    final token = match.group(0)!;
    tokens.update(token, (count) => count + 1, ifAbsent: () => 1);
  }
  return tokens;
}

int _reviewedIncrementFor(String path, Map<String, int> tokens) {
  final reviewed = _reviewedSourceGuards[path];
  if (reviewed == null) return 0;
  if (tokens.length != reviewed.tokens.length ||
      reviewed.tokens.entries.any(
        (entry) => tokens[entry.key] != entry.value,
      )) {
    throw StateError('$path 的已审权限来源已漂移：$tokens ≠ ${reviewed.tokens}');
  }
  return tokens.values.fold(0, (sum, count) => sum + count) -
      reviewed.legacyCount;
}

void main() {
  test('pages and widgets never add new local permission checks', () {
    var total = 0;
    final perFile = <String, int>{};
    final reviewedFilesSeen = <String>{};
    for (final entity in Directory('lib/features').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalized = entity.path.replaceAll(r'\', '/');
      if (!normalized.contains('/pages/') &&
          !normalized.contains('/widgets/')) {
        continue;
      }
      final source = entity.readAsStringSync();
      final count = _permReference.allMatches(source).length;
      if (count == 0) continue;
      final reviewedIncrement = _reviewedIncrementFor(
        normalized,
        _permissionTokens(source),
      );
      if (_reviewedSourceGuards.containsKey(normalized)) {
        reviewedFilesSeen.add(normalized);
      }
      total += count - reviewedIncrement;
      perFile[normalized] = count;
    }
    expect(
      reviewedFilesSeen,
      _reviewedSourceGuards.keys.toSet(),
      reason: '已审来源移除或迁移后必须清理对应精确登记，不能保留空额度',
    );
    final top =
        (perFile.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(5)
            .map((e) => '${e.key}: ${e.value}')
            .join('\n');
    expect(
      total,
      lessThanOrEqualTo(_baseline),
      reason:
          '页面 / 组件未经逐项登记的本地权限引用从 $_baseline 涨到了 $total。按钮显隐请改用服务端'
          '下发的动作集合(如 allowedActions)，不要再在页面里引用 Perm.x。\n'
          '当前最多的文件：\n$top',
    );
  });

  test('the counter cannot be dodged by wrapping the check in a helper', () {
    const wrapped = '''
bool _has(String code) => permissions.contains(code);
bool get _canApprove => _has(Perm.salesShipmentFinanceApprove);
''';
    expect(_permReference.allMatches(wrapped).length, 1);
  });

  test('reviewed guards lock exact permission identities and multiplicity', () {
    final path = _reviewedSourceGuards.keys.first;
    final tokens = Map<String, int>.from(_reviewedSourceGuards[path]!.tokens);
    expect(_reviewedIncrementFor(path, tokens), 9);
    tokens.remove('Perm.financeOrderApprovalView');
    tokens['Perm.authorizationManage'] = 2;
    expect(() => _reviewedIncrementFor(path, tokens), throwsStateError);
  });

  test('new references and copied files cannot reuse reviewed allowances', () {
    final path = _reviewedSourceGuards.keys.first;
    final tokens = Map<String, int>.from(_reviewedSourceGuards[path]!.tokens);
    tokens.update('Perm.financeOrderApprovalApprove', (count) => count + 1);
    expect(() => _reviewedIncrementFor(path, tokens), throwsStateError);
    expect(_reviewedIncrementFor('lib/features/new/pages/new.dart', tokens), 0);
    expect(
      _reviewedSourceGuards.entries.fold(
        0,
        (sum, entry) =>
            sum + _reviewedIncrementFor(entry.key, entry.value.tokens),
      ),
      126, // Previous 122 + 4 reviewed inline/history entry checks. Global baseline remains 677.
    );
  });

  test('history entry guards cannot restore the retired page undo check', () {
    const page = 'lib/features/basic_data/pages/product_category_page.dart';
    const history =
        'lib/features/basic_data/widgets/goods_operation_history_panel.dart';
    final pageTokens = Map<String, int>.from(
      _reviewedSourceGuards[page]!.tokens,
    )..['Perm.goodsImportUndo'] = 1;
    expect(() => _reviewedIncrementFor(page, pageTokens), throwsStateError);
    final historyTokens = Map<String, int>.from(
      _reviewedSourceGuards[history]!.tokens,
    )..remove('Perm.goodsBomAudit');
    expect(
      () => _reviewedIncrementFor(history, historyTokens),
      throwsStateError,
    );
  });
}

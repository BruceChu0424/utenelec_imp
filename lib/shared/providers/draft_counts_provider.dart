// 跨模块草稿（status=0）计数：hub 单据卡红色徽章 [UtenDraftBadge] 与新建页
// 「草稿」入口按钮 [UtenDraftsButton] 的唯一数据源。
//
// 后端 GET /api/documents/drafts/count 一次返回 21 类单据的草稿数，每类都已按
// 当前用户的 *:view 权限 + 该模块的对象级归属范围收敛；无权限的类型固定返回 0。
// 口径「草稿 = 待自审的新建/修订草稿」：销售订货单额外排除财务驳回单
//（驳回件已在销售关注徽章的 REJECTED 桶计数，不双计）。
//
// 【呈现形态 · 2026-09-11 口径反转】草稿改走**红底白字徽章**（[UtenDraftBadge]）
// 并**逐级累加**到 hub 卡与工作台模块卡。此前按「浏览型计数」渲染中性括号且不累加，
// 当日用户明确推翻：草稿是必须由本人处理完的活，看不见就会忘。累加实现唯一入口仍是
// todo_badge_registry.dart（模块级 `TodoEntry.*Drafts`）。见
// docs/00-项目准则/14-徽章与计数口径.md §草稿。
//
// 60s 自轮询 + 权限自卫（一个 *:view 都没有就不发请求），范式同
// sales_completion_count_provider.dart；refreshGlobalBadges 里 invalidate 即时刷新。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../auth/permissions.dart';

const _pollInterval = Duration(seconds: 60);

/// 深链预选草稿段的约定：`<列表路径>?status=draft`。
///
/// 由 `UtenDraftsButton` 写、各模块列表页读（`initialStatus`）。两端共用本常量，
/// 避免字符串在十来个页面里各写一份走样。
const String kDraftStatusQuery = 'draft';

/// 路由 query 是否要求预选草稿段。
bool isDraftStatusQuery(String? status) => status == kDraftStatusQuery;

/// 草稿按钮/括号数字的单据类型（与后端 DraftCountsResponse 字段一一对应）。
enum DraftDocKind {
  salesOrder(Perm.salesOrderView),
  salesShipment(Perm.salesShipmentView),
  salesReturn(Perm.salesReturnView),
  salesQuote(Perm.salesQuoteView),
  purchaseOrder(Perm.purchaseOrderView),
  subcontractOrder(Perm.subcontractOrderView),
  stockDocument(Perm.stockDocView),
  productionPlan(Perm.productionPlanView),
  productionDailyReport(Perm.productionDailyReportView),
  financeReceipt(Perm.financeReceiptView),
  financePayment(Perm.financePaymentView),
  financeExpense(Perm.financeExpenseView),
  financeOtherIncome(Perm.financeOtherIncomeView),
  financeBankTransfer(Perm.financeBankTransferView),
  // 2026-09-11 补齐：此前这 7 张 hub 卡一个数字都没有。
  purchaseReceipt(Perm.purchaseReceiptView),
  purchaseReturn(Perm.purchaseReturnView),
  subcontractReturn(Perm.subcontractReturnView),
  subcontractMaterialReturn(Perm.subcontractMaterialReturnView),
  subcontractWaste(Perm.subcontractWasteView),
  // stock_documents 的 doc_type 切片；与 [stockDocument] 合计重叠，调用方择一。
  stockTransfer(Perm.stockDocView),
  stockCheck(Perm.stockDocView);

  const DraftDocKind(this.viewPerm);

  /// 该类型的查看权限点：无此权限则按钮/徽章隐藏，后端计数也固定为 0。
  final String viewPerm;
}

/// 21 类单据的草稿数快照。
///
/// [stockDocument] 是 8 类仓库单据的合计，[stockTransfer]/[stockCheck] 是其中两类的
/// 切片；三者可同时非零，**同一个界面只能用其中一种**（仓库 hub 用两个切片，新建页
/// 的「草稿(N)」按钮用合计并在 tooltip 标注口径），否则会把同一张单数两遍。
class DraftCounts {
  const DraftCounts({
    this.salesOrder = 0,
    this.salesShipment = 0,
    this.salesReturn = 0,
    this.salesQuote = 0,
    this.purchaseOrder = 0,
    this.subcontractOrder = 0,
    this.stockDocument = 0,
    this.productionPlan = 0,
    this.productionDailyReport = 0,
    this.financeReceipt = 0,
    this.financePayment = 0,
    this.financeExpense = 0,
    this.financeOtherIncome = 0,
    this.financeBankTransfer = 0,
    this.purchaseReceipt = 0,
    this.purchaseReturn = 0,
    this.subcontractReturn = 0,
    this.subcontractMaterialReturn = 0,
    this.subcontractWaste = 0,
    this.stockTransfer = 0,
    this.stockCheck = 0,
  });

  /// 全零（未登录/无权限/加载中的安全默认，不放大成异常态）。
  static const empty = DraftCounts();

  factory DraftCounts.fromJson(Map<String, dynamic> json) {
    int read(String key) => (json[key] as num?)?.toInt() ?? 0;
    return DraftCounts(
      salesOrder: read('salesOrder'),
      salesShipment: read('salesShipment'),
      salesReturn: read('salesReturn'),
      salesQuote: read('salesQuote'),
      purchaseOrder: read('purchaseOrder'),
      subcontractOrder: read('subcontractOrder'),
      stockDocument: read('stockDocument'),
      productionPlan: read('productionPlan'),
      productionDailyReport: read('productionDailyReport'),
      financeReceipt: read('financeReceipt'),
      financePayment: read('financePayment'),
      financeExpense: read('financeExpense'),
      financeOtherIncome: read('financeOtherIncome'),
      financeBankTransfer: read('financeBankTransfer'),
      purchaseReceipt: read('purchaseReceipt'),
      purchaseReturn: read('purchaseReturn'),
      subcontractReturn: read('subcontractReturn'),
      subcontractMaterialReturn: read('subcontractMaterialReturn'),
      subcontractWaste: read('subcontractWaste'),
      stockTransfer: read('stockTransfer'),
      stockCheck: read('stockCheck'),
    );
  }

  final int salesOrder;
  final int salesShipment;
  final int salesReturn;
  final int salesQuote;
  final int purchaseOrder;
  final int subcontractOrder;
  final int stockDocument;
  final int productionPlan;
  final int productionDailyReport;
  final int financeReceipt;
  final int financePayment;
  final int financeExpense;
  final int financeOtherIncome;
  final int financeBankTransfer;
  final int purchaseReceipt;
  final int purchaseReturn;
  final int subcontractReturn;
  final int subcontractMaterialReturn;
  final int subcontractWaste;
  final int stockTransfer;
  final int stockCheck;

  /// 按类型取数（按钮/徽章/模块聚合共用，避免各处再写一遍 switch）。
  int of(DraftDocKind kind) => switch (kind) {
    DraftDocKind.salesOrder => salesOrder,
    DraftDocKind.salesShipment => salesShipment,
    DraftDocKind.salesReturn => salesReturn,
    DraftDocKind.salesQuote => salesQuote,
    DraftDocKind.purchaseOrder => purchaseOrder,
    DraftDocKind.subcontractOrder => subcontractOrder,
    DraftDocKind.stockDocument => stockDocument,
    DraftDocKind.productionPlan => productionPlan,
    DraftDocKind.productionDailyReport => productionDailyReport,
    DraftDocKind.financeReceipt => financeReceipt,
    DraftDocKind.financePayment => financePayment,
    DraftDocKind.financeExpense => financeExpense,
    DraftDocKind.financeOtherIncome => financeOtherIncome,
    DraftDocKind.financeBankTransfer => financeBankTransfer,
    DraftDocKind.purchaseReceipt => purchaseReceipt,
    DraftDocKind.purchaseReturn => purchaseReturn,
    DraftDocKind.subcontractReturn => subcontractReturn,
    DraftDocKind.subcontractMaterialReturn => subcontractMaterialReturn,
    DraftDocKind.subcontractWaste => subcontractWaste,
    DraftDocKind.stockTransfer => stockTransfer,
    DraftDocKind.stockCheck => stockCheck,
  };

  /// 某模块的草稿合计（2026-09-11 起草稿计入待办累加）。
  ///
  /// **不含 [DraftDocKind.stockTransfer] / [DraftDocKind.stockCheck]**：它们是
  /// [DraftDocKind.stockDocument] 的切片，一起加会把同一张单数两遍。
  int sumOf(Iterable<DraftDocKind> kinds) {
    var total = 0;
    for (final kind in kinds) {
      assert(
        kind != DraftDocKind.stockTransfer && kind != DraftDocKind.stockCheck,
        '仓库单据切片不参与合计：它们已含在 stockDocument 里，合计会双计',
      );
      total += of(kind);
    }
    return total;
  }

  /// 2026-09-11 重建风暴收口：60s 轮询每次都 new 一个快照，没有值相等时
  /// `AsyncData(新快照) != AsyncData(旧快照)`，于是每个 hub 卡徽章、每个新建页
  /// AppBar 的草稿按钮、以及在 build 里读本 provider 的列表页（如销售单据列表）
  /// 每分钟都要整体重建一次——哪怕 21 个计数一个都没变。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftCounts &&
          other.salesOrder == salesOrder &&
          other.salesShipment == salesShipment &&
          other.salesReturn == salesReturn &&
          other.salesQuote == salesQuote &&
          other.purchaseOrder == purchaseOrder &&
          other.subcontractOrder == subcontractOrder &&
          other.stockDocument == stockDocument &&
          other.productionPlan == productionPlan &&
          other.productionDailyReport == productionDailyReport &&
          other.financeReceipt == financeReceipt &&
          other.financePayment == financePayment &&
          other.financeExpense == financeExpense &&
          other.financeOtherIncome == financeOtherIncome &&
          other.financeBankTransfer == financeBankTransfer &&
          other.purchaseReceipt == purchaseReceipt &&
          other.purchaseReturn == purchaseReturn &&
          other.subcontractReturn == subcontractReturn &&
          other.subcontractMaterialReturn == subcontractMaterialReturn &&
          other.subcontractWaste == subcontractWaste &&
          other.stockTransfer == stockTransfer &&
          other.stockCheck == stockCheck;

  @override
  int get hashCode => Object.hashAll([
    salesOrder,
    salesShipment,
    salesReturn,
    salesQuote,
    purchaseOrder,
    subcontractOrder,
    stockDocument,
    productionPlan,
    productionDailyReport,
    financeReceipt,
    financePayment,
    financeExpense,
    financeOtherIncome,
    financeBankTransfer,
    purchaseReceipt,
    purchaseReturn,
    subcontractReturn,
    subcontractMaterialReturn,
    subcontractWaste,
    stockTransfer,
    stockCheck,
  ]);
}

/// 跨模块草稿计数（60s 轮询 + 权限自卫）。
// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
final draftCountsProvider = FutureProvider<DraftCounts>((ref) async {
  final permissions = ref.watch(currentPermissionsProvider);
  final superAdmin = ref.watch(isSuperAdminProvider);
  // 一个单据查看权限都没有的账号（如纯访客/仅 HR）不发请求。
  final anyVisible =
      superAdmin ||
      DraftDocKind.values.any((kind) => permissions.contains(kind.viewPerm));
  if (!anyVisible) return DraftCounts.empty;

  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final json = await ref
      .watch(apiClientProvider)
      .get(ApiEndpoints.documentDraftCounts);
  return DraftCounts.fromJson(json);
});

/// 当前草稿计数快照；加载中/失败按全零（与 module_badge_sum 的降级口径一致）。
DraftCounts watchDraftCounts(WidgetRef ref) =>
    ref.watch(draftCountsProvider).valueOrNull ?? DraftCounts.empty;

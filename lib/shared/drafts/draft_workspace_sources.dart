import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../features/finance/config/finance_doc_config.dart';
import '../../features/finance/models/finance_doc.dart';
import '../../features/finance/providers/finance_name_provider.dart';
import '../../features/finance/repositories/finance_repository.dart';
import '../../features/production/repositories/production_repository.dart';
import '../../features/purchase/config/purchase_doc_config.dart';
import '../../features/purchase/models/purchase_doc.dart';
import '../../features/purchase/repositories/purchase_repository.dart';
import '../../features/sales/config/sales_doc_config.dart';
import '../../features/sales/models/sales_doc.dart';
import '../../features/sales/providers/master_name_provider.dart';
import '../../features/sales/repositories/sales_repository.dart';
import '../../features/sales/services/sales_draft_delete.dart';
import '../../features/subcontract/config/subcontract_doc_config.dart';
import '../../features/subcontract/models/subcontract_doc.dart';
import '../../features/subcontract/repositories/subcontract_repository.dart';
import '../../features/warehouse/models/stock_doc.dart';
import '../../features/warehouse/providers/stock_draft_delete.dart';
import '../../features/warehouse/repositories/stock_doc_repository.dart';
import '../auth/document_scope_capability.dart';
import '../auth/permissions.dart';
import '../models/paged_result.dart';
import '../providers/authenticated_scope_provider.dart';
import '../providers/draft_counts_provider.dart';
import '../providers/master_name_provider.dart';
import 'form_draft_category.dart';
import 'form_draft_catalog.dart';

/// A display projection; the original repositories remain authoritative for
/// ownership, draft eligibility and writes. IDs always include their source.
class DraftWorkspaceRow {
  const DraftWorkspaceRow({
    required this.kind,
    required this.id,
    required this.category,
    required this.location,
    this.billNo,
    this.billDate,
    this.party,
    this.amount,
    this.deletable = false,
    this.stockType,
    this.local,
    this.expectedRevision,
  });
  final DraftDocKind? kind;
  final String id;
  final String category;
  final String location;
  final String? billNo;
  final String? billDate;
  final String? party;
  final String? amount;
  final bool deletable;
  final StockDocType? stockType;
  final FormDraft? local;
  final int? expectedRevision;
  String get key => kind == null ? 'local:$id' : '${kind!.name}:$id';

  DraftWorkspaceRow withRecovery(FormDraft draft) => DraftWorkspaceRow(
    kind: kind,
    id: id,
    category: category,
    location: draft.resumeLocation,
    billNo: billNo,
    billDate: billDate,
    party: party,
    amount: amount,
    deletable: deletable && !draft.hasUnknownSubmission,
    stockType: stockType,
    local: draft,
    expectedRevision: expectedRevision,
  );
}

String draftWorkspaceKindLabel(DraftDocKind kind) => switch (kind) {
  DraftDocKind.purchaseOrder => '采购订货单',
  DraftDocKind.purchaseReceipt => '采购收货单',
  DraftDocKind.purchaseReturn => '采购退货单',
  DraftDocKind.subcontractOrder => '委外订货单',
  DraftDocKind.subcontractReturn => '委外成品退回',
  DraftDocKind.subcontractMaterialReturn => '委外余料退回',
  DraftDocKind.subcontractWaste => '委外损耗',
  DraftDocKind.productionPlan => '生产计划单',
  DraftDocKind.productionDailyReport => '生产日报',
  DraftDocKind.financeReceipt => '销售收款单',
  DraftDocKind.financePayment => '采购付款单',
  DraftDocKind.financeExpense => '一般费用单',
  DraftDocKind.financeOtherIncome => '其它收入单',
  DraftDocKind.financeBankTransfer => '银行存取款',
  DraftDocKind.salesOrder => '销售订货单',
  DraftDocKind.salesShipment => '销售出货单',
  DraftDocKind.salesReturn => '销售退货单',
  DraftDocKind.salesQuote => '销售报价单',
  DraftDocKind.stockDocument => '仓库单据',
  DraftDocKind.stockTransfer => '仓库调拨',
  DraftDocKind.stockCheck => '盘点',
};

String formDraftCategoryLabel(FormDraft draft) {
  final kind = formDraftBusinessKind(draft);
  if (kind == DraftDocKind.stockDocument.name) {
    final code = Uri.parse(draft.route).pathSegments.elementAtOrNull(1);
    final type = code == null ? null : StockDocType.tryByCode(code);
    if (type != null) return type.label;
  }
  for (final candidate in DraftDocKind.values) {
    if (candidate.name == kind) return draftWorkspaceKindLabel(candidate);
  }
  for (final entry in FormDraftCatalog.all.values) {
    if (entry.groups(draft)) return _categoryTitle(entry.title);
  }
  return _categoryTitle(draft.title);
}

String _categoryTitle(String title) =>
    title.replaceFirst(RegExp(r'^(新建|新增|添加)'), '');

/// Exhaust every server page. An inconsistent/short page is an error, never a
/// silently complete subset which would make category filters misleading.
Future<List<T>> loadAllDraftPages<T>(
  Future<PagedResult<T>> Function(int page) fetch,
) async {
  final result = <T>[];
  var page = 1;
  while (true) {
    final response = await fetch(page);
    if (response.page != page ||
        (response.items.isEmpty && result.length < response.total)) {
      throw ApiException('INCOMPLETE_DRAFT_LIST', '草稿列表未完整返回，请刷新重试');
    }
    result.addAll(response.items);
    if (page >= response.totalPages && result.length >= response.total) break;
    if (response.items.isEmpty) {
      throw ApiException('INCOMPLETE_DRAFT_LIST', '草稿列表分页不完整，请刷新重试');
    }
    page++;
  }
  return result;
}

PurchaseDocType? _purchaseType(DraftDocKind kind) => switch (kind) {
  DraftDocKind.purchaseOrder => PurchaseDocType.order,
  DraftDocKind.purchaseReceipt => PurchaseDocType.receipt,
  DraftDocKind.purchaseReturn => PurchaseDocType.returnDoc,
  _ => null,
};
SubcontractDocType? _subcontractType(DraftDocKind kind) => switch (kind) {
  DraftDocKind.subcontractOrder => SubcontractDocType.order,
  DraftDocKind.subcontractReturn => SubcontractDocType.returnDoc,
  DraftDocKind.subcontractMaterialReturn => SubcontractDocType.materialReturn,
  DraftDocKind.subcontractWaste => SubcontractDocType.waste,
  _ => null,
};
FinanceDocType? _financeType(DraftDocKind kind) => switch (kind) {
  DraftDocKind.financeReceipt => FinanceDocType.receipt,
  DraftDocKind.financePayment => FinanceDocType.payment,
  DraftDocKind.financeExpense => FinanceDocType.expense,
  DraftDocKind.financeOtherIncome => FinanceDocType.otherIncome,
  DraftDocKind.financeBankTransfer => FinanceDocType.bankTransfer,
  _ => null,
};
SalesDocType? _salesType(DraftDocKind kind) => switch (kind) {
  DraftDocKind.salesOrder => SalesDocType.order,
  DraftDocKind.salesShipment => SalesDocType.shipment,
  DraftDocKind.salesReturn => SalesDocType.returnDoc,
  DraftDocKind.salesQuote => SalesDocType.quote,
  _ => null,
};

String? draftWorkspaceDeletePermission(DraftDocKind kind) {
  final purchase = _purchaseType(kind);
  if (purchase != null) return PurchaseDocConfig.by(purchase).deletePerm;
  final subcontract = _subcontractType(kind);
  if (subcontract != null) {
    return SubcontractDocConfig.by(subcontract).deletePerm;
  }
  final finance = _financeType(kind);
  if (finance != null) return FinanceDocConfig.by(finance).deletePerm;
  final sales = _salesType(kind);
  if (sales != null) return SalesDocConfig.by(sales).deletePerm;
  return switch (kind) {
    DraftDocKind.productionPlan => Perm.productionPlanDelete,
    DraftDocKind.productionDailyReport => Perm.productionDailyReportDelete,
    DraftDocKind.stockDocument ||
    DraftDocKind.stockTransfer ||
    DraftDocKind.stockCheck => Perm.stockDocDelete,
    _ => null,
  };
}

final draftWorkspaceRowsProvider = FutureProvider.autoDispose
    .family<List<DraftWorkspaceRow>, DraftDocKind>((ref, kind) async {
      final scope = ref.watch(authenticatedScopeProvider);
      final permissions = ref.watch(currentPermissionsProvider);
      final superAdmin = ref.watch(isSuperAdminProvider);
      if (scope == null ||
          (!superAdmin && !permissions.contains(kind.viewPerm))) {
        return const [];
      }
      final names = ref.watch(masterNameServiceProvider);
      final label = draftWorkspaceKindLabel(kind);
      String? money(double? amount, [bool masked = false]) =>
          masked ? '***' : amount?.toStringAsFixed(2);
      final purchase = _purchaseType(kind);
      if (purchase != null) {
        final repo = ref.watch(purchaseRepositoryProvider(purchase));
        final rows = await loadAllDraftPages(
          (page) => repo.list(
            page: page,
            size: 200,
            filter: PurchaseDocFilter(
              status: 0,
              financeApproval: purchase == PurchaseDocType.order
                  ? 'NONE'
                  : null,
            ),
          ),
        );
        await names.ensureLoaded();
        return [
          for (final row in rows)
            DraftWorkspaceRow(
              kind: kind,
              id: row.id,
              category: label,
              location: '/purchase/${purchase.pathSegment}/${row.id}',
              billNo: row.billNo,
              billDate: row.billDate,
              party: names.supplier(row.supplierId),
              amount: money(
                row.totalLocal,
                row.priceMasked ||
                    !PurchaseDocConfig.by(
                      purchase,
                    ).canViewCommercial(permissions),
              ),
              deletable:
                  row.status == 0 &&
                  !row.closed &&
                  !row.legacyImported &&
                  (purchase != PurchaseDocType.order ||
                      row.financeApproval == null ||
                      row.financeApproval!.status == 'DRAFT'),
            ),
        ];
      }
      final subcontract = _subcontractType(kind);
      if (subcontract != null) {
        final repo = ref.watch(subcontractRepositoryProvider(subcontract));
        final rows = await loadAllDraftPages(
          (page) => repo.list(
            page: page,
            size: 200,
            filter: SubcontractDocFilter(
              status: 0,
              financeApproval: subcontract == SubcontractDocType.order
                  ? 'NONE'
                  : null,
            ),
          ),
        );
        await names.ensureLoaded();
        return [
          for (final row in rows)
            DraftWorkspaceRow(
              kind: kind,
              id: row.id,
              category: label,
              location: '/subcontract/${subcontract.pathSegment}/${row.id}',
              billNo: row.billNo,
              billDate: row.billDate,
              party: names.supplier(row.supplierId),
              amount: money(
                row.totalLocal,
                row.priceMasked ||
                    !(superAdmin ||
                        SubcontractDocConfig.by(
                          subcontract,
                        ).canViewCommercial(permissions)),
              ),
              deletable:
                  row.status == 0 &&
                  !row.closed &&
                  !row.legacyImported &&
                  (subcontract != SubcontractDocType.order ||
                      row.financeApproval == null ||
                      row.financeApproval!.status == 'DRAFT'),
            ),
        ];
      }
      final finance = _financeType(kind);
      if (finance != null) {
        final repo = ref.watch(financeRepositoryProvider(finance));
        final financeNames = ref.read(financeNameServiceProvider);
        final rows = await loadAllDraftPages(
          (page) => repo.list(
            page: page,
            size: 200,
            filter: const FinanceDocFilter(status: 0),
          ),
        );
        await financeNames.ensureLoaded();
        return [
          for (final row in rows)
            DraftWorkspaceRow(
              kind: kind,
              id: row.id,
              category: label,
              location: '/finance/${finance.pathSegment}/${row.id}',
              billNo: row.billNo,
              billDate: row.billDate,
              party: switch (finance) {
                FinanceDocType.receipt => financeNames.client(row.partyId),
                FinanceDocType.payment => financeNames.supplier(row.partyId),
                _ => financeNames.account(row.accountId ?? row.outAccountId),
              },
              amount: row.amountLocalText ?? money(row.amountLocal),
              deletable: row.status == 0 && !row.legacyImported,
            ),
        ];
      }
      if (kind == DraftDocKind.productionPlan) {
        final repo = ref.watch(productionPlanRepositoryProvider);
        final rows = await loadAllDraftPages(
          (page) => repo.list(
            page: page,
            size: 200,
            filter: const ProductionPlanFilter(status: 0),
          ),
        );
        await names.ensureLoaded();
        return [
          for (final row in rows)
            DraftWorkspaceRow(
              kind: kind,
              id: row.id,
              category: label,
              location: '/production/plans/${row.id}',
              billNo: row.billNo,
              billDate: row.billDate,
              party: row.workshopName ?? names.department(row.departmentId),
              deletable:
                  row.status == 0 &&
                  !row.closed &&
                  !row.canceled &&
                  !row.stopped &&
                  row.legacyId == null,
            ),
        ];
      }
      if (kind == DraftDocKind.productionDailyReport) {
        final repo = ref.watch(productionDailyReportRepositoryProvider);
        final rows = await loadAllDraftPages(
          (page) => repo.list(
            page: page,
            size: 200,
            filter: const ProductionDailyReportFilter(status: 0),
          ),
        );
        await names.ensureLoaded();
        return [
          for (final row in rows)
            DraftWorkspaceRow(
              kind: kind,
              id: row.id,
              category: label,
              location: '/production/daily-reports/${row.id}',
              billNo: row.billNo,
              billDate: row.billDate,
              party: row.workshopName ?? names.department(row.departmentId),
              deletable:
                  row.status == 0 &&
                  !row.closed &&
                  !row.canceled &&
                  row.legacyId == null,
            ),
        ];
      }
      final sales = _salesType(kind);
      if (sales != null) {
        final repo = ref.watch(salesRepositoryProvider(sales));
        final salesNames = ref.watch(salesMasterNameServiceProvider);
        final rows = await loadAllDraftPages(
          (page) => repo.list(
            page: page,
            size: 200,
            filter: SalesDocFilter(
              status: 0,
              financeRejected: sales == SalesDocType.order ? false : null,
              stage: sales == SalesDocType.shipment
                  ? SalesShipmentStage.draft
                  : null,
              bucket: sales == SalesDocType.quote
                  ? SalesQuoteStage.draft
                  : null,
            ),
          ),
        );
        await salesNames.ensureLoaded();
        return [
          for (final row in rows)
            if (!row.financeRejected &&
                !row.rejected &&
                (sales != SalesDocType.shipment ||
                    salesShipmentStageOf(row) == SalesShipmentStage.draft))
              DraftWorkspaceRow(
                kind: kind,
                id: row.id,
                category: label,
                location: '/sales/${sales.pathSegment}/${row.id}',
                billNo: row.billNo,
                billDate: row.billDate,
                party: salesNames.client(row.clientId),
                amount: money(row.totalLocal, row.priceMasked),
                deletable: isDeletableSalesDraftRow(row, sales),
                expectedRevision: sales == SalesDocType.quote
                    ? row.quoteWorkflow.reviewRevision
                    : null,
              ),
        ];
      }
      final stockTypes = switch (kind) {
        DraftDocKind.stockTransfer => [StockDocType.transfer],
        DraftDocKind.stockCheck => [StockDocType.check],
        _ => StockDocType.values,
      };
      final repositories = {
        for (final type in stockTypes)
          type: ref.watch(stockDocRepositoryProvider(type)),
      };
      await names.ensureLoaded();
      return [
        for (final entry in repositories.entries)
          for (final row in await loadAllDraftPages(
            (page) => entry.value.list(
              page: page,
              size: 200,
              filter: const StockDocFilter(status: 0),
            ),
          ))
            DraftWorkspaceRow(
              kind: kind,
              id: row.id,
              category: entry.key.label,
              location: '/warehouse/${entry.key.code}/${row.id}',
              billNo: row.billNo,
              billDate: row.billDate,
              party: names.warehouse(row.warehouseId),
              amount: money(row.totalLocal),
              stockType: entry.key,
              deletable: row.status == 0 && !row.closed && row.legacyId == null,
            ),
      ];
    });

Future<void> deleteDraftWorkspaceRow(
  WidgetRef ref,
  DraftWorkspaceRow row, {
  required bool Function() stillCurrent,
  Future<void> Function()? beforeDelete,
}) async {
  final kind = row.kind!;
  final scope = ref.read(authenticatedScopeProvider);
  bool current() =>
      stillCurrent() &&
      scope != null &&
      !scope.readOnly &&
      ref.read(authenticatedScopeProvider) == scope &&
      ref
          .read(currentPermissionsProvider)
          .contains(draftWorkspaceDeletePermission(kind));
  void verify(bool eligible) {
    if (!current()) throw ApiException('FORBIDDEN', '当前身份、选择范围或删除权限已变化');
    if (!eligible) throw ApiException('CONFLICT', '单据已不是可删除草稿，请刷新后重试');
  }

  Future<void> beforeDispatch() async {
    await beforeDelete?.call();
    verify(true);
  }

  Future<void> owner(DocumentDataScope dataScope, String? makerId) async {
    if (!await loadDocumentOwnerCanWrite(ref, dataScope, makerId)) {
      throw ApiException('FORBIDDEN', documentScopeReadOnlyMessage);
    }
    verify(true);
  }

  verify(row.deletable);
  final purchase = _purchaseType(kind);
  if (purchase != null) {
    final repo = ref.read(purchaseRepositoryProvider(purchase));
    final detail = await repo.detail(row.id);
    verify(
      detail.status == 0 &&
          !detail.closed &&
          !detail.legacyImported &&
          (purchase != PurchaseDocType.order ||
              detail.financeApproval == null ||
              detail.financeApproval!.status == 'DRAFT'),
    );
    await owner(DocumentDataScope.purchase, detail.makerId);
    await beforeDispatch();
    return repo.delete(row.id);
  }
  final subcontract = _subcontractType(kind);
  if (subcontract != null) {
    final repo = ref.read(subcontractRepositoryProvider(subcontract));
    final detail = await repo.detail(row.id);
    verify(
      detail.status == 0 &&
          !detail.closed &&
          !detail.legacyImported &&
          (subcontract != SubcontractDocType.order ||
              detail.financeApproval == null ||
              detail.financeApproval!.status == 'DRAFT'),
    );
    await owner(DocumentDataScope.subcontract, detail.makerId);
    await beforeDispatch();
    return repo.delete(row.id);
  }
  final finance = _financeType(kind);
  if (finance != null) {
    final repo = ref.read(financeRepositoryProvider(finance));
    final detail = await repo.detail(row.id);
    verify(detail.status == 0 && !detail.legacyImported);
    await owner(DocumentDataScope.finance, detail.makerId);
    await beforeDispatch();
    return repo.delete(row.id);
  }
  final sales = _salesType(kind);
  if (sales != null) {
    return deleteSalesDraft(
      ref.read(salesRepositoryProvider(sales)),
      sales,
      row.id,
      expectedRevision: row.expectedRevision,
      stillCurrent: current,
      beforeDelete: beforeDispatch,
    );
  }
  if (kind == DraftDocKind.productionPlan) {
    final repo = ref.read(productionPlanRepositoryProvider);
    final detail = await repo.detail(row.id);
    verify(
      detail.status == 0 &&
          !detail.closed &&
          !detail.canceled &&
          !detail.stopped &&
          detail.legacyId == null,
    );
    await owner(DocumentDataScope.productionPlan, detail.makerId);
    await beforeDispatch();
    return repo.delete(row.id);
  }
  if (kind == DraftDocKind.productionDailyReport) {
    final repo = ref.read(productionDailyReportRepositoryProvider);
    final detail = await repo.detail(row.id);
    verify(
      detail.status == 0 &&
          !detail.closed &&
          !detail.canceled &&
          detail.legacyId == null,
    );
    await owner(DocumentDataScope.productionPlan, detail.makerId);
    await beforeDispatch();
    return repo.delete(row.id);
  }
  return deleteStockDraft(
    ref,
    type: row.stockType!,
    id: row.id,
    isMounted: stillCurrent,
    stillCurrent: current,
    beforeDelete: beforeDispatch,
  );
}

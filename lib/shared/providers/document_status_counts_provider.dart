// 单据列表页分段计数(GET /documents/status-counts?kind=...) + 三类单据「财务已退回」张数
// (随工作台徽章汇总带回, ADR-108)。
//
// 2026-09-21 用户口径: 「父分类有红色通知徽章, 子分类也要有数字」——hub 单据卡挂了红徽章
// (草稿 / 财务已退回)的列表页, 状态分段一律带数: 草稿与财务已退回是红徽章(等本人动手),
// 等待财务审核 / 已审 / 已出库 / 红冲是中性括号数(供掂量); 「财务退回」不再混在草稿里,
// 有自己的分段与徽章(后端草稿口径同步收紧, 见 DocumentDraftCountQueryService)。
//
// 计数与列表同一对象级读范围, 一次请求带回该类型全部桶; 分桶键见 [DocumentStatusBucket]。
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/data_write_revision.dart';
import '../../core/network/api_exception.dart';
import '../auth/permissions.dart';
import '../badges/badge_registry.dart';
import '../drafts/form_draft_category.dart';
import 'draft_counts_provider.dart';
import 'export_context_epoch_provider.dart';
import 'retain_read_snapshot.dart';
import '../paging/shared_read_provider_owner.dart';

/// 分桶键(与后端 DocumentStatusCountQueryService 逐字一致)。
abstract final class DocumentStatusBucket {
  static const pendingGlConfirmation = 'PENDING_GL_CONFIRMATION';
  static const draft = 'DRAFT';
  static const pendingManager = 'PENDING_MANAGER';
  static const managerRejected = 'MANAGER_REJECTED';
  static const pendingFinance = 'PENDING_FINANCE';
  static const financeRejected = 'FINANCE_REJECTED';

  /// 通用单据 = 已审(status 1); 销售出货 = 财务已放行待出库(status 0 + finance_audit 1)。
  static const approved = 'APPROVED';

  /// 委外订货已审且未结案；不包含历史已结案订货单。
  static const executing = 'EXECUTING';
  static const shipped = 'SHIPPED';
  static const reversed = 'REVERSED';
}

/// 一次分段计数的范围: 单据类型 + 出货类型切片(仅 salesShipment, 客户零星发货列表传
/// DIRECT_CUSTOMER) + 仓库单据类型(仅 stockDocument) + 任务中心挑的仓(仅仓库单据,
/// ADR-149: 与旁边列表同一个 scopeWarehouseId, 计数与列表同一谓词)。作 family 键, 值相等即同一份计数。
class DocumentStatusScope {
  const DocumentStatusScope(
    this.kind, {
    this.shipmentKind,
    this.docType,
    this.scopeWarehouseId,
  });

  final DraftDocKind kind;
  final String? shipmentKind;
  final String? docType;

  /// 仓库任务中心选择器挑的仓(含下级); null = 本人默认范围(服务端照样按本人范围计数)。
  final String? scopeWarehouseId;

  @override
  bool operator ==(Object other) =>
      other is DocumentStatusScope &&
      other.kind == kind &&
      other.shipmentKind == shipmentKind &&
      other.docType == docType &&
      other.scopeWarehouseId == scopeWarehouseId;

  @override
  int get hashCode =>
      Object.hash(kind, shipmentKind, docType, scopeWarehouseId);
}

/// 同一业务分类内的本机填写草稿范围，供列表与分类徽章共用。
FormDraftCategoryScope formDraftScopeForDocumentStatus(
  DocumentStatusScope scope,
) {
  final docType = scope.docType;
  if (scope.kind == DraftDocKind.stockDocument && docType != null) {
    return FormDraftCategoryScope(
      kind: switch (docType) {
        'TRANSFER' => DraftDocKind.stockTransfer.name,
        'CHECK' => DraftDocKind.stockCheck.name,
        _ => DraftDocKind.stockDocument.name,
      },
      routePath: '/warehouse/$docType/new',
    );
  }
  return FormDraftCategoryScope(
    kind: scope.kind.name,
    routePath: scope.shipmentKind == 'DIRECT_CUSTOMER'
        ? '/sales/customer-shipments/new'
        : null,
  );
}

/// 原始服务端桶保持不变；分类列表已合并本机草稿，因此草稿红数也采用同一投影。
final effectiveDocumentStatusCountsProvider = Provider.autoDispose
    .family<AsyncValue<Map<String, int>>, DocumentStatusScope>(
      (ref, scope) {
        final server = ref.watch(documentStatusCountsProvider(scope));
        final epoch = ref.watch(exportContextEpochProvider);
        final local = ref.watch(
          formDraftCategoryCountProvider(
            formDraftScopeForDocumentStatus(scope),
          ),
        );
        if (!server.hasValue && local == 0) return server;
        final previous = server.value;
        final denied =
            server.error is ApiException &&
            ({401, 403}.contains((server.error as ApiException).httpStatus) ||
                const {
                  'READ_SCOPE_CHANGED',
                  'SESSION_CHANGED',
                  'SESSION_STATE_UNAVAILABLE',
                }.contains((server.error as ApiException).code));
        // Riverpod may carry a previous value while rebuilding after an owner
        // change. Never project that old account/permission/warehouse proof.
        final counts =
            denied ||
                (previous is _DocumentStatusSnapshot &&
                    previous.readerEpoch != epoch)
            ? null
            : previous;
        if (counts == null && local == 0) return const AsyncLoading();
        return AsyncData({
          ...?counts,
          for (final bucket in const [
            DocumentStatusBucket.draft,
            DocumentStatusBucket.managerRejected,
            DocumentStatusBucket.financeRejected,
            DocumentStatusBucket.pendingGlConfirmation,
          ])
            if (counts?.containsKey(bucket) ?? false)
              bucket: counts?['ACTIONABLE_$bucket'] ?? 0,
          for (final bucket in const [
            DocumentStatusBucket.pendingManager,
            DocumentStatusBucket.pendingFinance,
            'FINANCE_APPROVED',
            DocumentStatusBucket.executing,
          ])
            if (counts?.containsKey(bucket) ?? false)
              bucket: counts?['RESPONSIBLE_$bucket'] ?? 0,
          DocumentStatusBucket.draft:
              (counts?['ACTIONABLE_DRAFT'] ?? 0) + local,
        });
      },
      dependencies: [documentStatusCountsProvider, exportContextEpochProvider],
    );

/// Exact-scope counts survive a brief page departure. Local writes and the
/// monotonic reader boundary retire them automatically; explicit refresh stays
/// fresh. Pagination/filtering within this scope need not restart the aggregate.
final documentStatusCountsProvider = FutureProvider.autoDispose
    .family<Map<String, int>, DocumentStatusScope>((ref, scope) async {
      final epoch = ref.watch(exportContextEpochProvider);
      final write = ref.watch(dataWriteRevisionProvider);
      retainReadSnapshot(ref);
      final permissions = ref.watch(currentPermissionsProvider);
      final viewPermission =
          scope.kind == DraftDocKind.salesShipment &&
              scope.shipmentKind == 'DIRECT_CUSTOMER'
          ? Perm.salesOtherShipmentView
          : scope.kind.viewPerm;
      if (!ref.watch(isSuperAdminProvider) &&
          !permissions.contains(viewPermission)) {
        return const {};
      }
      final api = ref.watch(apiClientProvider);
      final json = await runSharedProviderRead(
        ref,
        () => api.get(
          ApiEndpoints.documentStatusCounts,
          query: {
            'kind': scope.kind.name,
            if (scope.shipmentKind != null) 'shipmentKind': scope.shipmentKind,
            if (scope.docType != null) 'docType': scope.docType,
            if (scope.scopeWarehouseId != null)
              'scopeWarehouseId': scope.scopeWarehouseId,
          },
        ),
        isCurrent: () =>
            epoch == ref.read(exportContextEpochProvider) &&
            write == ref.read(dataWriteRevisionProvider),
      );
      return _DocumentStatusSnapshot({
        for (final entry in json.entries)
          if (entry.value is num) entry.key: (entry.value as num).toInt(),
      }, epoch);
    }, dependencies: [exportContextEpochProvider]);

/// Coalesce page-entry/category/pagination reads for the same exact scope.
/// Counts do not depend on the chosen status, row sort or page number. A short
/// freshness window only avoids redundant reads; explicit refresh and writes
/// always revalidate, and no values are inferred from the parent badge.
void refreshDocumentStatusCounts(
  WidgetRef ref,
  DocumentStatusScope scope, {
  bool force = false,
}) {
  final provider = documentStatusCountsProvider(scope);
  final state = ref.read(provider);
  if (state.isLoading && !force) return;
  final value = state.value;
  if (!force &&
      !state.hasError &&
      value is _DocumentStatusSnapshot &&
      value.readerEpoch == ref.read(exportContextEpochProvider) &&
      value.age.elapsed < const Duration(seconds: 15)) {
    return;
  }
  ref.invalidate(provider);
}

class _DocumentStatusSnapshot extends MapBase<String, int> {
  _DocumentStatusSnapshot(Map<String, int> values, this.readerEpoch)
    : _values = Map.unmodifiable(values);
  final Map<String, int> _values;
  final int readerEpoch;
  final age = Stopwatch()..start();
  @override
  int? operator [](Object? key) => _values[key];
  @override
  Iterable<String> get keys => _values.keys;
  @override
  void operator []=(String key, int value) =>
      throw UnsupportedError('snapshot');
  @override
  void clear() => throw UnsupportedError('snapshot');
  @override
  int? remove(Object? key) => throw UnsupportedError('snapshot');
}

/// 三类单据的「财务已退回」张数快照。
class FinanceRejectedCounts {
  const FinanceRejectedCounts({
    this.salesShipment = 0,
    this.purchaseOrder = 0,
    this.subcontractOrder = 0,
  });

  static const empty = FinanceRejectedCounts();

  final int salesShipment;
  final int purchaseOrder;
  final int subcontractOrder;

  /// 该类型的财务已退回张数; 没有退回桶的类型恒 0。
  int of(DraftDocKind kind) => switch (kind) {
    DraftDocKind.salesShipment => salesShipment,
    DraftDocKind.purchaseOrder => purchaseOrder,
    DraftDocKind.subcontractOrder => subcontractOrder,
    _ => 0,
  };

  /// 有「财务已退回」桶、hub 卡徽章要算「草稿 + 财务已退回」的三类单据。
  static const kinds = {
    DraftDocKind.salesShipment,
    DraftDocKind.purchaseOrder,
    DraftDocKind.subcontractOrder,
  };

  // 值相等: 汇总每分钟换一份新对象, 数没变时不让 hub 卡徽章重建。
  @override
  bool operator ==(Object other) =>
      other is FinanceRejectedCounts &&
      other.salesShipment == salesShipment &&
      other.purchaseOrder == purchaseOrder &&
      other.subcontractOrder == subcontractOrder;

  @override
  int get hashCode =>
      Object.hash(salesShipment, purchaseOrder, subcontractOrder);
}

/// 三类单据的「财务已退回」张数(hub 单据卡徽章 = 草稿 + 财务已退回)。
///
/// 取自工作台徽章汇总(事实数键 `financeRejected.<类型>`, ADR-108), 不单独请求;
/// 销售出货退回件已由服务端目录登记进销售待办(salesShipmentFinanceRejected 入口)。
final financeRejectedCountsProvider = Provider<FinanceRejectedCounts>((ref) {
  final facts = ref.watch(badgeSummaryProvider.select((s) => s.facts));
  return FinanceRejectedCounts(
    salesShipment: facts[BadgeFact.financeRejected('salesShipment')] ?? 0,
    purchaseOrder: facts[BadgeFact.financeRejected('purchaseOrder')] ?? 0,
    subcontractOrder: facts[BadgeFact.financeRejected('subcontractOrder')] ?? 0,
  );
});

import '../../../core/network/api_exception.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/paging/paged_read_intent.dart';
import '../models/production_daily_report.dart';
import '../models/production_exact_quantity.dart';
import 'production_repository.dart';

/// Read-side draft associations. Approved quantities and all commands retain
/// their existing server authority; actual-surplus lines claim no plan quota.
class ProductionDailyReportDraftSnapshot {
  const ProductionDailyReportDraftSnapshot(this.quantities, this.reports);
  final Map<String, String> quantities;
  final Map<String, List<ProductionDailyReportListItem>> reports;
}

Future<ProductionDailyReportDraftSnapshot>
loadProductionDailyReportDraftSnapshot({
  required ProductionDailyReportRepository repository,
  required Iterable<String> executionSegmentIds,
  required bool Function() isCurrent,
}) async {
  final activity = PagedReadIntent.currentActivity;
  bool current() => isCurrent() && (activity?.call() ?? true);
  final work = UiWorkBudget(isCurrent: current);
  work.ensureCurrent();
  final ids = <String>[];
  final seen = <String>{};
  for (final id in executionSegmentIds) {
    work.ensureCurrent();
    if (id.isEmpty || id.trim() != id) {
      throw const FormatException('当前任务身份不完整，请刷新后重新核对');
    }
    if (seen.add(id)) ids.add(id);
    await work.checkpoint();
  }
  final quantities = <String, BigInt>{};
  final reports = <String, List<ProductionDailyReportListItem>>{};
  final accepted = <String, (int, String, String)>{};
  for (var start = 0; start < ids.length; start += 100) {
    work.ensureCurrent();
    final scope = List<String>.unmodifiable(ids.skip(start).take(100));
    final page = await loadCompletePagedResult<ProductionDailyReportListItem>(
      isCurrent: isCurrent,
      idOf: (draft) => draft.id,
      loadPage: (page, size) => repository.draftClaimsBySegments(
        executionSegmentIds: scope,
        page: page,
        size: size,
      ),
    );
    for (final draft in page.items) {
      work.ensureCurrent();
      final version = draft.rowVersion;
      final fingerprint = draft.draftClaimsFingerprint;
      if (draft.status != 0 ||
          draft.draftClaimsVersion != 1 ||
          draft.draftClaims == null ||
          version == null ||
          !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(version) ||
          fingerprint == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
        throw ApiException(
          'INCOMPLETE_DRAFT_CLAIMS',
          '报工草稿范围或版本尚未核对，请更新服务端后重新读取',
        );
      }
      final proof = (draft.draftClaimsVersion!, version, fingerprint);
      final previous = accepted[draft.id];
      if (previous != null) {
        if (previous != proof) {
          throw ApiException('SNAPSHOT_CHANGED', '报工草稿在读取期间已变化，请刷新后重新核对');
        }
        continue; // One multi-task report appears in several bounded ID groups.
      }
      accepted[draft.id] = proof;
      final linked = <String>{};
      for (final claim in draft.draftClaims!) {
        final segment = claim.executionSegmentId;
        final qty = productionExactQuantityUnits(claim.qtyExact);
        if (claim.qtyExact != null && qty == null) {
          throw const FormatException('报工草稿数量缺少精确原文');
        }
        if (segment != null && segment.isNotEmpty) linked.add(segment);
        if (segment != null &&
            segment.isNotEmpty &&
            qty != null &&
            !claim.actualSurplus) {
          quantities[segment] = (quantities[segment] ?? BigInt.zero) + qty;
        }
        await work.checkpoint();
      }
      for (final segment in linked) {
        reports.putIfAbsent(segment, () => []).add(draft);
      }
      await work.checkpoint();
    }
  }
  work.ensureCurrent();
  return ProductionDailyReportDraftSnapshot(
    Map.unmodifiable({
      for (final entry in quantities.entries)
        entry.key: productionQuantityTextFromUnits(entry.value),
    }),
    Map.unmodifiable({
      for (final entry in reports.entries)
        entry.key: List<ProductionDailyReportListItem>.unmodifiable(
          entry.value,
        ),
    }),
  );
}

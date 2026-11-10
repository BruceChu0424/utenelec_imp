// 仓库任务中心的大类 / 分段计数(ADR-149)：与列表同一服务端范围谓词，只有一个来源。
//
// · 本人默认范围(没选仓)：读有效徽章汇总；服务端事实保持原样，独立填写草稿仅补入
//   warehouseDrafts 入口。hub 卡、工作台、导航与任务中心沿用同一投影。
// · 选了某个仓(主管或负责多个仓的人)：同一个汇总接口带 scopeWarehouseId，服务端只算仓库模块的
//   入口、各来源都按所选仓计，与带同一参数的列表 total 逐条相等(不再用 list(size:1) 凑数,
//   也不再单独请求 type-counts)。所选仓读数与全站工作台的轮询分开。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/network/api_endpoints.dart';
import '../badges/badge_registry.dart';
import '../badges/effective_badge_summary_provider.dart';
import '../providers/authenticated_scope_provider.dart';
import '../../core/network/read_scope_revision.dart';
import '../paging/scoped_paged_read.dart';
import '../providers/sensitive_read_boundary_provider.dart';
import '../providers/retain_read_snapshot.dart';
import 'warehouse_task_scope.dart';

/// The owner proof is checked before any previous value may be displayed.
typedef _WarehouseBadgeSnapshot = ({
  BadgeSummary summary,
  SensitiveReadBoundary owner,
  int revision,
});

final _selectedWarehouseBadgesProvider = AsyncNotifierProvider.autoDispose
    .family<_SelectedWarehouseBadges, _WarehouseBadgeSnapshot, String>(
      _SelectedWarehouseBadges.new,
    );

class _SelectedWarehouseBadges extends AsyncNotifier<_WarehouseBadgeSnapshot> {
  _SelectedWarehouseBadges(this.warehouseId);

  final String warehouseId;

  @override
  Future<_WarehouseBadgeSnapshot> build() async {
    // The provider owns its last accepted snapshot; no separate badge cache.
    // Its owner/revision must still match before global stale reconciliation.
    final previous = state.value;
    final owner = ref.watch(sensitiveReadBoundaryProvider);
    final revision = ref.watch(readScopeRevisionProvider);
    retainReadSnapshot(ref);
    if (ref.watch(authenticatedScopeProvider) == null) {
      return (summary: BadgeSummary.empty, owner: owner, revision: revision);
    }
    final api = ref.watch(apiClientProvider);
    final json = await AuthenticatedRequestScope.sharedRead(
      () =>
          ref.mounted &&
          ref.read(sensitiveReadBoundaryProvider) == owner &&
          ref.read(readScopeRevisionProvider) == revision &&
          identical(ref.read(apiClientProvider), api),
      () => api.get(
        ApiEndpoints.workbenchBadges,
        query: {'scopeWarehouseId': warehouseId},
      ),
    );
    final fetched = BadgeSummary.fromJson(json);
    return (
      summary:
          previous != null &&
              previous.owner == owner &&
              previous.revision == revision
          ? fetched.keepStaleFrom(previous.summary)
          : fetched,
      owner: owner,
      revision: revision,
    );
  }
}

/// 某个范围下的仓库任务汇总。还没拉到时为空汇总(各数字按「未知」处理)。
final warehouseScopedBadgesProvider = Provider.autoDispose
    .family<BadgeSummary, WarehouseTaskScope>((ref, scope) {
      final warehouseId = scope.warehouseId;
      if (warehouseId == null) return ref.watch(effectiveBadgeSummaryProvider);
      // Refreshing responsibility is not a new identity. Keep the last same-owner
      // badge visible while it is rechecked; command gates still require a fully
      // confirmed scope. A failed/revoked scope immediately withdraws the count.
      final scopeRead = ref.watch(myWarehouseScopeProvider);
      final physical = scopeRead.hasError ? null : scopeRead.value;
      if (physical == null || !physical.canSelectForTasks(warehouseId)) {
        return BadgeSummary.empty;
      }
      final read = ref.watch(_selectedWarehouseBadgesProvider(warehouseId));
      if (read.hasError && pagedReadAccessDenied(read.error!)) {
        return BadgeSummary.empty;
      }
      final snapshot = read.value;
      if (snapshot == null ||
          snapshot.owner != ref.watch(sensitiveReadBoundaryProvider) ||
          snapshot.revision != ref.watch(readScopeRevisionProvider)) {
        return BadgeSummary.empty;
      }
      return snapshot.summary;
    });

/// 任务中心当前范围下的汇总。
final warehouseTaskBadgesProvider = Provider.autoDispose<BadgeSummary>(
  (ref) => ref.watch(
    warehouseScopedBadgesProvider(ref.watch(warehouseTaskScopeProvider)),
  ),
);

/// 当前范围的单个事实数；汇总还没到或当前身份对该来源无权时为 null(不把「未知」伪装成 0)。
final warehouseTaskFactOrNullProvider = Provider.autoDispose
    .family<int?, String>((ref, key) {
      final summary = ref.watch(warehouseTaskBadgesProvider);
      return warehouseFactOrNull(summary, key);
    });

/// 当前范围的入口红数(无权 / 未到按 0)。
final warehouseTaskEntryTodoProvider = Provider.autoDispose
    .family<int, BadgeEntry>(
      (ref, entry) => ref.watch(
        warehouseTaskBadgesProvider.select((s) => s.entryTodo(entry)),
      ),
    );

/// 当前范围的入口黄数。
final warehouseTaskEntryInProgressProvider = Provider.autoDispose
    .family<int, BadgeEntry>(
      (ref, entry) => ref.watch(
        warehouseTaskBadgesProvider.select((s) => s.entryInProgress(entry)),
      ),
    );

/// 某来源在当前范围的汇总里是否带回(对当前身份可见)。
final warehouseTaskSourceGrantedProvider = Provider.autoDispose
    .family<bool, String>(
      (ref, source) => ref.watch(
        warehouseTaskBadgesProvider.select((s) => s.hasSource(source)),
      ),
    );

/// 事实数取值规则：来源没带回 = null。
int? warehouseFactOrNull(BadgeSummary summary, String key) {
  final dot = key.indexOf('.');
  final source = dot < 0 ? key : key.substring(0, dot);
  return summary.hasSource(source) ? summary.fact(key) : null;
}

/// 仓库写操作成功后让「选了某个仓」的汇总也重拉(全站汇总由 refreshBadges 负责)。
void invalidateSelectedWarehouseBadges(WidgetRef ref) =>
    ref.invalidate(_selectedWarehouseBadgesProvider);

/// Wait for the selected warehouse's authoritative summary. Callers which
/// already invalidated it while refreshing the global summary can reuse that
/// request instead of starting another one at the end of the refresh.
Future<void> refreshSelectedWarehouseBadges(
  WidgetRef ref, {
  bool invalidate = true,
  bool reuseInFlight = false,
}) async {
  final warehouseId = ref.read(warehouseTaskScopeProvider).warehouseId;
  if (warehouseId == null) return;
  final physical = confirmedMyWarehouseScope(
    ref.read(myWarehouseScopeProvider),
  );
  if (physical == null || !physical.canSelectForTasks(warehouseId)) return;
  final provider = _selectedWarehouseBadgesProvider(warehouseId);
  if (invalidate && (!reuseInFlight || !ref.read(provider).isLoading)) {
    ref.invalidate(provider);
  }
  try {
    await ref.read(provider.future);
  } catch (_) {
    // Keep the provider's existing unknown/error projection; never invent zero.
  }
}

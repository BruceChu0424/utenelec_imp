// 仓库任务中心的大类 / 分段计数(ADR-149)：与列表同一服务端范围谓词，只有一个来源。
//
// · 本人默认范围(没选仓)：直接读全站徽章汇总 badgeSummaryProvider——服务端已按本人仓库数据范围
//   计数，hub 卡、工作台、导航与任务中心是同一份数字。
// · 选了某个仓(主管或负责多个仓的人)：同一个汇总接口带 scopeWarehouseId，服务端只算仓库模块的
//   入口、各来源都按所选仓计，与带同一参数的列表 total 逐条相等(不再用 list(size:1) 凑数,
//   也不再单独请求 type-counts)。全站汇总每次轮询有变化时跟着重拉。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../badges/badge_registry.dart';
import '../providers/authenticated_scope_provider.dart';
import 'warehouse_task_scope.dart';

/// 选了某个仓时的仓库模块汇总(只在任务中心打开期间存活)。
final _selectedWarehouseBadgesProvider = FutureProvider.autoDispose
    .family<BadgeSummary, String>((ref, warehouseId) async {
      if (ref.watch(authenticatedScopeProvider) == null) {
        return BadgeSummary.empty;
      }
      // 全站汇总有变化(轮询、本端写操作后的补拉)就跟着重拉, 两份数字不会一新一旧。
      ref.watch(badgeSummaryProvider);
      final json = await ref
          .read(apiClientProvider)
          .get(
            ApiEndpoints.workbenchBadges,
            query: {'scopeWarehouseId': warehouseId},
          );
      return BadgeSummary.fromJson(json);
    });

/// 某个范围下的仓库任务汇总。还没拉到时为空汇总(各数字按「未知」处理)。
final warehouseScopedBadgesProvider = Provider.autoDispose
    .family<BadgeSummary, WarehouseTaskScope>((ref, scope) {
      final warehouseId = scope.warehouseId;
      if (warehouseId == null) return ref.watch(badgeSummaryProvider);
      return ref
              .watch(_selectedWarehouseBadgesProvider(warehouseId))
              .valueOrNull ??
          BadgeSummary.empty;
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

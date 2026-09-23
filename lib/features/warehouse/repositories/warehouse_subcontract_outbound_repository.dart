// 委外出仓工作台仓库（V304）：/api/warehouse/subcontract-outbound/* 。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/subcontract_outbound.dart';

/// `GET /warehouse/subcontract-outbound/tasks/count` 一次带回的两个数(ADR-103 §2.5):
///
/// - [count] 红 = 轮到仓库动手的待出仓任务(子件已到货可发, 或已有拣货草稿);
/// - [waitingComponent] 黄 = 有待出量但子件一件都没到、仓库此刻办不了的任务。
///
/// 两数互斥(服务端同一次扫描按任务分桶), 之和 = 待出仓任务列表行数。
/// 老服务端只回 `count` 时黄数回落 0(缺键不当异常)。
class SubcontractOutboundTaskCounts {
  const SubcontractOutboundTaskCounts({
    this.count = 0,
    this.waitingComponent = 0,
  });

  factory SubcontractOutboundTaskCounts.fromJson(Map<String, dynamic> json) =>
      SubcontractOutboundTaskCounts(
        count: (json['count'] as num?)?.toInt() ?? 0,
        waitingComponent: (json['waitingComponent'] as num?)?.toInt() ?? 0,
      );

  static const empty = SubcontractOutboundTaskCounts();

  final int count;
  final int waitingComponent;

  // 值相等: 60s 轮询每次都 new 一个快照, 没有 == 时监听方每分钟白重建一次。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubcontractOutboundTaskCounts &&
          other.count == count &&
          other.waitingComponent == waitingComponent;

  @override
  int get hashCode => Object.hash(count, waitingComponent);
}

class WarehouseSubcontractOutboundRepository {
  const WarehouseSubcontractOutboundRepository(this.api);

  final ApiClient api;

  Future<PagedResult<OutboundTask>> tasks({
    int page = 1,
    int size = 20,
    String? keyword,
    String? supplierId,
    String? status,
  }) async {
    final kw = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseSubcontractOutboundTasks,
      query: {
        'page': page,
        'size': size,
        if (kw != null && kw.isNotEmpty) 'keyword': kw,
        if (supplierId != null && supplierId.isNotEmpty)
          'supplierId': supplierId,
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    return PagedResult.fromJson(json, OutboundTask.fromJson);
  }

  /// 待出仓任务红黄两数(见 [SubcontractOutboundTaskCounts])。
  Future<SubcontractOutboundTaskCounts> taskCount() async {
    final json = await api.get(
      ApiEndpoints.warehouseSubcontractOutboundTaskCount,
    );
    return SubcontractOutboundTaskCounts.fromJson(
      (json as Map).cast<String, dynamic>(),
    );
  }

  Future<OutboundTaskDetail> taskDetail(String planId) async {
    final json = await api.get(
      ApiEndpoints.warehouseSubcontractOutboundTask(planId),
    );
    return OutboundTaskDetail.fromJson((json as Map).cast<String, dynamic>());
  }

  /// 补齐出仓草稿：有剩余量且无未审草稿时重建。返回新草稿 id。
  Future<String> regenerateDraft(String planId) async {
    final json = await api.post(
      ApiEndpoints.warehouseSubcontractOutboundDraft(planId),
    );
    return (json as Map)['draftId'] as String;
  }

  /// 不再出仓：关闭计划剩余量（必填原因）。
  Future<void> closePlan(String planId, String reason) async {
    await api.post(
      ApiEndpoints.warehouseSubcontractOutboundClose(planId),
      body: {'reason': reason.trim()},
    );
  }
}

final warehouseSubcontractOutboundRepositoryProvider =
    Provider<WarehouseSubcontractOutboundRepository>(
      (ref) =>
          WarehouseSubcontractOutboundRepository(ref.watch(apiClientProvider)),
    );

/// 委外待出仓任务红黄两枚徽章(出库任务中心「委外出库」大类行 / 「待出仓任务」
/// 小类行 / hub「出库任务中心」卡红数)唯一的服务端来源。
///
/// 红黄两支由本支派生(不各发各的请求): 卡面数字与页内分段从此同源, 「两枚之和 =
/// 列表行数」由结构保证。常驻不 autoDispose(与品质结果计数同款理由: 徽章不闪、
/// 刷新期间带住旧值), 60s 自失效; 无权限静默回空、不发请求。
final warehouseSubcontractOutboundTaskCountsProvider =
    FutureProvider<SubcontractOutboundTaskCounts>((ref) async {
      final permissions = ref.watch(currentPermissionsProvider);
      final superAdmin = ref.watch(isSuperAdminProvider);
      if (!superAdmin && !permissions.contains(Perm.subcontractOutboundView)) {
        return SubcontractOutboundTaskCounts.empty;
      }
      final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref
          .watch(warehouseSubcontractOutboundRepositoryProvider)
          .taskCount();
    });

/// 红徽章: 轮到仓库动手的待出仓任务数(子件已到货可发 / 已有拣货草稿)。
/// 等子件到货的任务按 ADR-101 不计(仓库此刻办不了), 走下面那支黄的。
///
/// 由 [warehouseSubcontractOutboundTaskCountsProvider] 派生, **失效要打在源头**;
/// 单独失效本 provider 只会拿回缓存的计数, 不会重拉。
final warehouseSubcontractOutboundCountProvider = Provider<AsyncValue<int>>(
  (ref) => _derive(
    ref.watch(warehouseSubcontractOutboundTaskCountsProvider),
    (counts) => counts.count,
  ),
);

/// 黄徽章: 等子件到货的待出仓任务数(有待出量、子件一件都没到)。
///
/// 只画在出库任务中心的分段上, **不登记黄链**(in_progress_badge_registry.dart
/// 末尾「已知重叠」): 这些委外单已在委外任务中心的 IN_PROGRESS 黄数里,
/// 仓库再数一遍是跨卡双计(准则 14 §四之八)。同样由上面那支派生, 失效打在源头。
final warehouseSubcontractOutboundWaitingComponentCountProvider =
    Provider<AsyncValue<int>>(
      (ref) => _derive(
        ref.watch(warehouseSubcontractOutboundTaskCountsProvider),
        (counts) => counts.waitingComponent,
      ),
    );

/// 取两枚徽章各自要的那一半; 刷新期间保住旧值(准则 §四之三), 所以走 valueOrNull
/// 而不是 whenData(理由见 warehouse_quality_result_count_provider.dart 的 _derive)。
AsyncValue<int> _derive(
  AsyncValue<SubcontractOutboundTaskCounts> source,
  int Function(SubcontractOutboundTaskCounts) pick,
) {
  final value = source.valueOrNull;
  if (value != null) return AsyncData(pick(value));
  final error = source.error;
  if (error != null) {
    return AsyncError(error, source.stackTrace ?? StackTrace.empty);
  }
  return const AsyncLoading();
}

// 委外出仓工作台仓库（V304）：/api/warehouse/subcontract-outbound/* 。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/subcontract_outbound.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';

class WarehouseSubcontractOutboundRepository {
  const WarehouseSubcontractOutboundRepository(this.api);

  final ApiClient api;

  Future<PagedResult<OutboundTask>> tasks({
    int page = 1,
    int size = 20,
    String? keyword,
    String? supplierId,
    String? status,
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
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
        ...scope.queryParameters,
      },
    );
    return PagedResult.fromJson(json, OutboundTask.fromJson);
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

/// 红: 轮到仓库动手的待出仓任务数(子件已到货可发 / 已有拣货草稿)。
/// 等子件到货的任务按 ADR-101 不计(仓库此刻办不了), 走下面那支黄的。
///
/// 随工作台徽章汇总一次带回(ADR-108, 原端点 /warehouse/subcontract-outbound/tasks/count),
/// 汇总未到/无权为 null。hub「出库任务中心」卡的红数由服务端目录算好。
final warehouseSubcontractOutboundCountProvider = Provider<int?>(
  (ref) => ref.watch(badgeFactOrNullProvider(BadgeFact.subcontractOutbound)),
);

/// 黄: 等子件到货的待出仓任务数(有待出量、子件一件都没到)。
///
/// 只画在出库任务中心的分段上, 不进任何徽章入口: 这些委外单已在委外任务中心的
/// IN_PROGRESS 黄数里, 仓库再数一遍是跨卡双计(准则 14 §四之八)。
final warehouseSubcontractOutboundWaitingComponentCountProvider =
    Provider<int?>(
      (ref) => ref.watch(
        badgeFactOrNullProvider(BadgeFact.subcontractOutboundWaitingComponent),
      ),
    );

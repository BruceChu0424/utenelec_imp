// 委外出仓工作台仓库（V304）：/api/warehouse/subcontract-outbound/* 。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/subcontract_outbound.dart';

class WarehouseSubcontractOutboundRepository {
  const WarehouseSubcontractOutboundRepository(this.api);

  final ApiClient api;

  Future<PagedResult<OutboundTask>> tasks({
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    final kw = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseSubcontractOutboundTasks,
      query: {
        'page': page,
        'size': size,
        if (kw != null && kw.isNotEmpty) 'keyword': kw,
      },
    );
    return PagedResult.fromJson(json, OutboundTask.fromJson);
  }

  Future<int> taskCount() async {
    final json = await api.get(
      ApiEndpoints.warehouseSubcontractOutboundTaskCount,
    );
    return ((json as Map)['count'] as num?)?.toInt() ?? 0;
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

/// hub 角标：待出仓任务数（OPEN 计划且有剩余量）。
final warehouseSubcontractOutboundCountProvider = FutureProvider<int>(
  (ref) =>
      ref.watch(warehouseSubcontractOutboundRepositoryProvider).taskCount(),
);

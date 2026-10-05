// 委外出仓工作台仓库(ADR-143 §4.3)：/api/warehouse/subcontract-outbound/* 。
//
// 列表 = 委外人员已提交、仓库未发出的领料单；详情按领料单 id 取拣货明细；
// 整单不发 = 「退回委外(不发)」(必填原因)。
// 拣货保存与审核出仓走既有 /api/subcontract/material-issues 的编辑/审核端点。
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
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
  }) async {
    final kw = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseSubcontractOutboundTasks,
      query: {
        'page': page,
        'size': size,
        if (kw != null && kw.isNotEmpty) 'keyword': kw,
        ...scope.queryParameters,
      },
    );
    return PagedResult.fromJson(json, OutboundTask.fromJson);
  }

  Future<OutboundTaskDetail> taskDetail(String issueId) async {
    final json = await api.get(
      ApiEndpoints.warehouseSubcontractOutboundTask(issueId),
    );
    return OutboundTaskDetail.fromJson((json as Map).cast<String, dynamic>());
  }

  /// 整单不发：把这张领料单退回委外。服务端作废领料单、退回占用的库存并通知
  /// 提交领料的委外人员；领料单已不在待发料时 404/409，原文提示。
  Future<void> returnToDraw(String issueId, {required String reason}) async {
    await api.post(
      ApiEndpoints.warehouseSubcontractOutboundReturnToDraw(issueId),
      body: {'reason': reason},
    );
  }
}

final warehouseSubcontractOutboundRepositoryProvider =
    Provider<WarehouseSubcontractOutboundRepository>(
      (ref) =>
          WarehouseSubcontractOutboundRepository(ref.watch(apiClientProvider)),
    );

/// 红: 调用者仓库范围内待发料的委外领料单张数(轮到仓库动手)。
///
/// 随工作台徽章汇总一次带回(ADR-108, 原端点 /warehouse/subcontract-outbound/tasks/count),
/// 汇总未到/无权为 null。hub「出库任务中心」卡的红数由服务端目录算好。
final warehouseSubcontractOutboundCountProvider = Provider<int?>(
  (ref) => ref.watch(badgeFactOrNullProvider(BadgeFact.subcontractOutbound)),
);

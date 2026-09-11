import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/warehouse_draw_task.dart';

class ProductionDrawTaskRepository {
  const ProductionDrawTaskRepository(this.api);

  final ApiClient api;

  /// READY/PARTIAL production DRAW tasks share the server open_qty projection.
  Future<int> pendingCount() async {
    final json = await api.get('/operations/workbench/warehouse/count');
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  /// 分状态计数（任务中心子分类徽章）：READY_TO_PICK / PARTIAL / OPEN_ANY。
  Future<Map<String, int>> statusBreakdown() async {
    final json = await api.get(
      '/operations/workbench/warehouse/status-breakdown',
    );
    return {
      for (final entry in (json as Map).entries)
        entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
    };
  }

  /// 单次批量出库上限（与后端 StockDocIssueBatchRequest.MAX_DOCUMENTS 同值）。
  static const int batchIssueLimit = 50;

  /// 批量全额出库（2026-09-09；2026-09-10 修订）：选中多张领料单按剩余量逐单出库，
  /// 草稿单在服务端走「审核并出库」（需同时持 stock_doc:approve），任一单失败整批回滚；
  /// [reason] 为统一备注（选填，≤200 字），随每张单追加到单据备注。
  Future<WarehouseDrawBatchIssueResult> issueFullBatch({
    required String idempotencyKey,
    required List<String> docIds,
    String? reason,
  }) async {
    final result = await api.post(
      '/stock/docs/issue-batch',
      body: {
        'idempotencyKey': idempotencyKey,
        'docIds': docIds,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
    return WarehouseDrawBatchIssueResult.fromJson(
      (result as Map).cast<String, dynamic>(),
    );
  }

  /// 待领任务分页（与履约工作台 WAREHOUSE 投影同一公开端点；仓库侧轻量读模型）。
  Future<PagedResult<WarehouseDrawTask>> tasks({
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
  }) async {
    final json = await api.get(
      '/operations/workbench/warehouse',
      query: {
        'page': page < 1 ? 1 : page,
        'size': size.clamp(1, 100),
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    return PagedResult.fromJson(json, WarehouseDrawTask.fromJson);
  }
}

final productionDrawTaskRepositoryProvider =
    Provider<ProductionDrawTaskRepository>(
      (ref) => ProductionDrawTaskRepository(ref.watch(apiClientProvider)),
    );

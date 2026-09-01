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

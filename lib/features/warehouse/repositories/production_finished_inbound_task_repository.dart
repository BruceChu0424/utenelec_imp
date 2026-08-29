import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_finished_inbound_task.dart';

class ProductionFinishedInboundTaskRepository {
  const ProductionFinishedInboundTaskRepository(this.api);

  final ApiClient api;

  Future<PagedResult<ProductionFinishedInboundTask>> tasks({
    int page = 1,
    int size = 40,
    String? keyword,
  }) async {
    final normalized = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.productionFinishedInboundTasks,
      query: {
        'page': page,
        'size': size,
        if (normalized != null && normalized.isNotEmpty) 'keyword': normalized,
      },
    );
    return PagedResult.fromJson(json, ProductionFinishedInboundTask.fromJson);
  }

  Future<int> pendingCount() async {
    final json = await api.get(ApiEndpoints.productionFinishedInboundTaskCount);
    return (json['count'] as num?)?.toInt() ?? 0;
  }
}

final productionFinishedInboundTaskRepositoryProvider =
    Provider<ProductionFinishedInboundTaskRepository>(
      (ref) =>
          ProductionFinishedInboundTaskRepository(ref.watch(apiClientProvider)),
    );

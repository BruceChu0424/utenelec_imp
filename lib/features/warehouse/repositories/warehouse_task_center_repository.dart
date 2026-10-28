import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../shared/warehouse/warehouse_task_view.dart';
import '../models/warehouse_task_center_record.dart';

export '../../../shared/warehouse/warehouse_task_view.dart';

enum WarehouseTaskDirection { inbound, outbound }

abstract interface class WarehouseTaskCenterGateway {
  Future<WarehouseTaskCenterPageResult> list({
    required WarehouseTaskDirection direction,
    String source = 'ALL',
    WarehouseTaskView view = WarehouseTaskView.active,
    String? status,
    String? keyword,
    String? billNo,
    String? dateFrom,
    String? dateTo,
    WarehouseTaskScope warehouseScope = const WarehouseTaskScope.all(),
    int page = 1,
    int size = 20,
    String? sort,
    String? order,
    Map<String, String?> columns = const {},
  });
}

class WarehouseTaskCenterRepository implements WarehouseTaskCenterGateway {
  const WarehouseTaskCenterRepository(this.api);
  final ApiClient api;

  @override
  Future<WarehouseTaskCenterPageResult> list({
    required WarehouseTaskDirection direction,
    String source = 'ALL',
    WarehouseTaskView view = WarehouseTaskView.active,
    String? status,
    String? keyword,
    String? billNo,
    String? dateFrom,
    String? dateTo,
    WarehouseTaskScope warehouseScope = const WarehouseTaskScope.all(),
    int page = 1,
    int size = 20,
    String? sort,
    String? order,
    Map<String, String?> columns = const {},
  }) async {
    final json = await api.get(
      '/warehouse/task-center/${direction.name}',
      query: {
        'source': source,
        'view': view.apiValue,
        'page': page,
        'size': size,
        if (status != null && status.isNotEmpty) 'status': status,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (billNo != null && billNo.trim().isNotEmpty) 'billNo': billNo.trim(),
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        'sort': ?sort,
        'order': ?order,
        for (final entry in columns.entries)
          if (entry.key.startsWith('search.') &&
              entry.value?.trim().isNotEmpty == true)
            entry.key: entry.value!.trim(),
        ...warehouseScope.queryParameters,
      },
    );
    return WarehouseTaskCenterPageResult.fromJson(json);
  }
}

final warehouseTaskCenterRepositoryProvider =
    Provider<WarehouseTaskCenterGateway>(
      (ref) => WarehouseTaskCenterRepository(ref.watch(apiClientProvider)),
    );

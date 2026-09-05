import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_execution_workbench.dart';

class ProductionExecutionWorkbenchRepository {
  ProductionExecutionWorkbenchRepository(this._api);

  final ApiClient _api;

  Future<PagedResult<ProductionExecutionWorkbenchGroup>> groups({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? workshopDepartmentId,
    bool mine = false,
    String sort = 'latestEndDate',
    String order = 'asc',
  }) async {
    final json = await _api.get(
      '/production/execution-workbench',
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (workshopDepartmentId?.isNotEmpty == true)
          'workshopDepartmentId': workshopDepartmentId,
        if (mine) 'mine': true,
        'sort': sort,
        'order': order,
      },
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchGroup.fromJson,
    );
  }

  Future<ProductionExecutionWorkbenchGroup> group({
    required String rootType,
    required String rootId,
  }) async => ProductionExecutionWorkbenchGroup.fromJson(
    await _api.get(_rootPath(rootType, rootId)),
  );

  Future<PagedResult<ProductionExecutionWorkbenchSegment>> workOrders({
    required String rootType,
    required String rootId,
    int page = 1,
    int size = 30,
  }) async {
    final json = await _api.get(
      '${_rootPath(rootType, rootId)}/work-orders',
      query: {'page': page, 'size': size},
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchSegment.fromJson,
    );
  }

  Future<PagedResult<ProductionExecutionWorkbenchRelatedDocument>>
  relatedDocuments({
    required String rootType,
    required String rootId,
    int page = 1,
    int size = 30,
  }) async {
    final json = await _api.get(
      '${_rootPath(rootType, rootId)}/related-documents',
      query: {'page': page, 'size': size},
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchRelatedDocument.fromJson,
    );
  }

  Future<PagedResult<ProductionExecutionWorkbenchSegment>> workshopTasks({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? status,
  }) async {
    final json = await _api.get(
      '/production/workshop-tasks',
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (status?.isNotEmpty == true) 'status': status,
      },
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchSegment.fromJson,
    );
  }

  Future<int> workshopTaskCount() async {
    final json = await _api.get('/production/workshop-tasks/count');
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  String _rootPath(String rootType, String rootId) =>
      '/production/execution-workbench/'
      '${Uri.encodeComponent(rootType)}/${Uri.encodeComponent(rootId)}';
}

final productionExecutionWorkbenchRepositoryProvider =
    Provider<ProductionExecutionWorkbenchRepository>(
      (ref) =>
          ProductionExecutionWorkbenchRepository(ref.watch(apiClientProvider)),
    );

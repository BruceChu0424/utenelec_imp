import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/operations_workbench.dart';

abstract interface class OperationsWorkbenchGateway {
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
  });
}

class OperationsWorkbenchRepository implements OperationsWorkbenchGateway {
  const OperationsWorkbenchRepository(this.api);

  final ApiClient api;

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
  }) async {
    final json = await api.get(
      '/operations/workbench/${department.apiValue}',
      query: {
        'page': page,
        'size': size,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (status != null && status.isNotEmpty) 'status': status,
        if (exception != null && exception.isNotEmpty) 'exception': exception,
      },
    );
    return OperationsWorkbenchData.fromJson(json, department);
  }
}

final operationsWorkbenchRepositoryProvider =
    Provider<OperationsWorkbenchRepository>(
      (ref) => OperationsWorkbenchRepository(ref.watch(apiClientProvider)),
    );

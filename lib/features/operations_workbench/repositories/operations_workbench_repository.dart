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

  /// 采购任务中心待分解申请明细数（WAITING_ORDER），与采购管理角标同源。
  Future<int> purchaseTaskCount() async {
    final json = await api.get('/operations/workbench/purchase/count');
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  /// 委外任务中心待办数（待分解 + 待采购完成 + 财务驳回），与委外管理角标同源。
  Future<int> subcontractTaskCount() async {
    final json = await api.get('/operations/workbench/subcontract/count');
    return (json['count'] as num?)?.toInt() ?? 0;
  }
}

final operationsWorkbenchRepositoryProvider =
    Provider<OperationsWorkbenchRepository>(
      (ref) => OperationsWorkbenchRepository(ref.watch(apiClientProvider)),
    );

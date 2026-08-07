import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/finance_procurement_workflow.dart';

abstract interface class FinanceProcurementWorkflowRepository {
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
  });

  Future<int> pendingApprovalCount();
}

class DioFinanceProcurementWorkflowRepository
    implements FinanceProcurementWorkflowRepository {
  const DioFinanceProcurementWorkflowRepository(this.api);

  final ApiClient api;

  @override
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get(
      ApiEndpoints.financeProcurementApprovalTasks,
      query: <String, dynamic>{'page': page, 'size': size},
    );
    return FinanceProcurementApprovalPage.fromJson(json);
  }

  @override
  Future<int> pendingApprovalCount() async {
    final json = await api.get(ApiEndpoints.financeProcurementApprovalCount);
    final nested = json['data'];
    final value =
        json['count'] ??
        json['pendingCount'] ??
        json['total'] ??
        (nested is Map
            ? nested['count'] ?? nested['pendingCount'] ?? nested['total']
            : nested);
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
    return parsed < 0 ? 0 : parsed;
  }
}

final financeProcurementWorkflowRepositoryProvider =
    Provider<FinanceProcurementWorkflowRepository>(
      (ref) =>
          DioFinanceProcurementWorkflowRepository(ref.watch(apiClientProvider)),
    );

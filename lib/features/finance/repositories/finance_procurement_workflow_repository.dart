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

  Future<List<FinanceWorkflowResponsibility>> responsibilities();

  Future<List<FinanceWorkflowReviewer>> reviewers();

  Future<FinanceWorkflowResponsibility> updateResponsibility({
    required String behaviorCode,
    required String assigneeUserId,
    required int expectedVersion,
    required String password,
  });
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

  @override
  Future<List<FinanceWorkflowResponsibility>> responsibilities() async {
    final rows = await api.getList(ApiEndpoints.adminWorkflowResponsibilities);
    final byCode = <String, FinanceWorkflowResponsibility>{};
    for (final row in rows) {
      final parsed = FinanceWorkflowResponsibility.fromJson(row);
      if (parsed.behaviorCode.isNotEmpty) byCode[parsed.behaviorCode] = parsed;
    }
    return byCode.values.toList(growable: false);
  }

  @override
  Future<List<FinanceWorkflowReviewer>> reviewers() async {
    final rows = await api.getList(
      ApiEndpoints.adminWorkflowResponsibilityReviewers,
    );
    final byId = <String, FinanceWorkflowReviewer>{};
    for (final row in rows) {
      final parsed = FinanceWorkflowReviewer.fromJson(row);
      if (parsed.userId.isNotEmpty && parsed.active) {
        byId[parsed.userId] = parsed;
      }
    }
    final result = byId.values.toList(growable: false)
      ..sort((a, b) {
        final byDepartment = (a.departmentName ?? '').compareTo(
          b.departmentName ?? '',
        );
        return byDepartment != 0
            ? byDepartment
            : a.employeeName.compareTo(b.employeeName);
      });
    return result;
  }

  @override
  Future<FinanceWorkflowResponsibility> updateResponsibility({
    required String behaviorCode,
    required String assigneeUserId,
    required int expectedVersion,
    required String password,
  }) async {
    final json = await api.put(
      ApiEndpoints.adminWorkflowResponsibility(behaviorCode),
      body: <String, dynamic>{
        'assigneeUserId': assigneeUserId,
        'expectedVersion': expectedVersion,
        'password': password,
      },
    );
    if (json.isEmpty) {
      return FinanceWorkflowResponsibility(
        behaviorCode: behaviorCode,
        assigneeUserId: assigneeUserId,
        version: expectedVersion + 1,
      );
    }
    return FinanceWorkflowResponsibility.fromJson(
      json,
      fallbackBehaviorCode: behaviorCode,
    );
  }
}

final financeProcurementWorkflowRepositoryProvider =
    Provider<FinanceProcurementWorkflowRepository>(
      (ref) =>
          DioFinanceProcurementWorkflowRepository(ref.watch(apiClientProvider)),
    );

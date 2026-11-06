import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_employee_picker_models.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';

class ApprovalDepartmentPolicy {
  const ApprovalDepartmentPolicy({
    required this.departmentId,
    required this.departmentCode,
    required this.departmentName,
    required this.version,
    this.managerId,
    this.managerName,
    this.substituteEmployeeId,
    this.substituteEmployeeName,
  });
  final String departmentId, departmentCode, departmentName;
  final String? managerId,
      managerName,
      substituteEmployeeId,
      substituteEmployeeName;
  final int version;
  factory ApprovalDepartmentPolicy.fromJson(Map<String, dynamic> value) =>
      ApprovalDepartmentPolicy(
        departmentId: value['departmentId'] as String,
        departmentCode: value['departmentCode'] as String,
        departmentName: value['departmentName'] as String,
        managerId: value['managerId'] as String?,
        managerName: value['managerName'] as String?,
        substituteEmployeeId: value['substituteEmployeeId'] as String?,
        substituteEmployeeName: value['substituteEmployeeName'] as String?,
        version: (value['version'] as num).toInt(),
      );
}

class ApprovalPolicyRepository {
  const ApprovalPolicyRepository(this.api);
  final ApiClient api;
  static const path = '/approval-policy/departments';
  Future<List<ApprovalDepartmentPolicy>> departments() async {
    final data = await api.get(path);
    return (data['departments'] as List)
        .map(
          (row) => ApprovalDepartmentPolicy.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList(growable: false);
  }

  Future<ApprovalDepartmentPolicy> save(
    ApprovalDepartmentPolicy policy,
    String? substituteEmployeeId,
  ) async => ApprovalDepartmentPolicy.fromJson(
    await api.put(
      '$path/${policy.departmentId}',
      body: {
        'substituteEmployeeId': substituteEmployeeId,
        'expectedVersion': policy.version,
      },
    ),
  );
  Future<UtenEmployeePickerPage> candidatesPage(
    String contextDepartmentId,
    String? search, {
    int page = 1,
    int size = 100,
  }) async {
    final data = await api.get(
      '$path/$contextDepartmentId/candidates/page',
      query: {'search': ?search, 'page': page, 'size': size},
    );
    final result = await PagedResult.fromJsonResponsive(
      data,
      (row) => UtenEmployeePickerItem(
        id: row['id'] as String,
        name: row['name'] as String,
        employeeCode: row['employeeCode'] as String?,
        departmentId: row['departmentId'] as String?,
        departmentName: row['departmentName'] as String?,
      ),
    );
    if (result.page != page) throw const FormatException('审批候选分页响应无效');
    return UtenEmployeePickerPage(
      items: result.items,
      page: result.page,
      totalPages: result.totalPages,
      total: result.total,
    );
  }
}

final approvalPolicyRepositoryProvider = Provider<ApprovalPolicyRepository>(
  (ref) => ApprovalPolicyRepository(ref.watch(apiClientProvider)),
);
final approvalDepartmentPoliciesProvider =
    FutureProvider.autoDispose<List<ApprovalDepartmentPolicy>>(
      (ref) {
        ref.watch(exportContextEpochProvider);
        return ref.watch(approvalPolicyRepositoryProvider).departments();
      },
      dependencies: [
        exportContextEpochProvider,
        approvalPolicyRepositoryProvider,
      ],
    );

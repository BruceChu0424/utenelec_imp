import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../components/inputs/uten_employee_picker_models.dart';
import '../models/department_node.dart';
import '../models/employee_reference.dart';
import '../models/paged_result.dart';
import '../paging/complete_paged_snapshot.dart';
import '../providers/sensitive_read_boundary_provider.dart';

abstract interface class EmployeeReferenceRepository {
  Future<PagedResult<EmployeeReference>> list({
    required EmployeeReferencePurpose purpose,
    int page = 1,
    int size = 100,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  });

  /// Labels for existing references only; callers never merge these into a list
  /// of candidates. Missing/deleted identities do not become invented rows.
  Future<List<EmployeeReference>> byIds(
    Iterable<String> ids, {
    required EmployeeReferencePurpose purpose,
  });

  Future<List<DepartmentNode>> departments(EmployeeReferencePurpose purpose);
}

class DioEmployeeReferenceRepository implements EmployeeReferenceRepository {
  DioEmployeeReferenceRepository(this.api);
  final ApiClient api;
  final _labelLoads =
      <(EmployeeReferencePurpose, String), Future<List<EmployeeReference>>>{};

  @override
  Future<PagedResult<EmployeeReference>> list({
    required EmployeeReferencePurpose purpose,
    int page = 1,
    int size = 100,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async => PagedResult.fromJsonResponsive(
    await api.get(
      ApiEndpoints.employeeReferences,
      query: {
        'purpose': purpose.apiValue,
        'page': page,
        'size': size,
        if (search?.trim().isNotEmpty == true) 'search': search!.trim(),
        if (statuses?.isNotEmpty == true) 'statuses': statuses!.toList(),
        'departmentId': ?departmentId,
        'includeSubtree': includeSubtree,
      },
    ),
    EmployeeReference.fromJson,
  );

  @override
  Future<List<EmployeeReference>> byIds(
    Iterable<String> ids, {
    required EmployeeReferencePurpose purpose,
  }) async {
    final unique = ids.where((id) => id.isNotEmpty).toSet();
    if (unique.isEmpty) return const [];
    if (unique.length > 100) {
      throw ArgumentError('人员引用回显一次最多100项');
    }
    final ordered = unique.toList()..sort();
    final key = (purpose, ordered.join(','));
    return _labelLoads.putIfAbsent(
      key,
      () => api
          .getList(
            ApiEndpoints.employeeReferencesByIds,
            query: {'purpose': purpose.apiValue, 'ids': unique.join(',')},
          )
          .then(
            (rows) =>
                rows.map(EmployeeReference.fromJson).toList(growable: false),
          )
          .whenComplete(() {
            _labelLoads.remove(key);
          }),
    );
  }

  @override
  Future<List<DepartmentNode>> departments(
    EmployeeReferencePurpose purpose,
  ) async {
    final rows = await api.getList(
      ApiEndpoints.employeeReferenceDepartments,
      query: {'purpose': purpose.apiValue},
    );
    return rows.map(DepartmentNode.fromJson).toList(growable: false);
  }
}

extension EmployeeReferencePickerItem on EmployeeReference {
  UtenEmployeePickerItem toPickerItem() => UtenEmployeePickerItem(
    id: id,
    name: fullName,
    employeeCode: code,
    departmentId: departmentId,
    departmentName: departmentName,
    positionName: positionName,
    accountStatus: accountStatus,
    employmentStatus: status,
  );
}

extension EmployeeReferencePickerCandidates on EmployeeReferenceRepository {
  Future<List<EmployeeReference>> listPickerCandidates({
    required EmployeeReferencePurpose purpose,
    int size = 100,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    bool Function()? isCurrent,
  }) async {
    final statusSnapshot = statuses == null ? null : Set<String>.of(statuses);
    final current = isCurrent ?? () => true;
    Future<List<EmployeeReference>> load() => loadCompletePagedSnapshot(
      loadPage: (page, _) => list(
        purpose: purpose,
        page: page,
        size: size,
        search: search,
        statuses: statusSnapshot,
        departmentId: departmentId,
        includeSubtree: includeSubtree,
      ),
      idOf: (value) => value.id,
      isCurrent: current,
    );
    final repository = this;
    if (repository is DioEmployeeReferenceRepository) {
      final scope = await repository.api.captureRequestScope(
        isCurrent: current,
      );
      final rows = await scope.run(load);
      scope.checkCurrent();
      return rows;
    }
    return load();
  }
}

final employeeReferenceRepositoryProvider =
    Provider<EmployeeReferenceRepository>((ref) {
      ref.watch(sensitiveReadBoundaryProvider);
      return DioEmployeeReferenceRepository(ref.watch(apiClientProvider));
    });

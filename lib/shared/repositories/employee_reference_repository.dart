import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/api_endpoints.dart';
import '../../components/inputs/uten_employee_picker_models.dart';
import '../models/department_node.dart';
import '../models/employee_reference.dart';
import '../models/paged_result.dart';
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
  Future<UtenEmployeePickerPage> listPickerPage(
    UtenEmployeePickerQuery query, {
    required EmployeeReferencePurpose purpose,
    int size = 100,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    final statusSnapshot = statuses == null ? null : Set<String>.of(statuses);
    final scope = await employeePickerDepartmentScope(
      query,
      departmentId: departmentId,
      includeSubtree: includeSubtree,
      loadDepartments: () => departments(purpose),
    );
    if (scope.empty) return UtenEmployeePickerPage.empty(page: query.page);
    final result = await list(
      purpose: purpose,
      page: query.page,
      size: size,
      search: query.keyword,
      statuses: statusSnapshot,
      departmentId: scope.id,
      includeSubtree: scope.subtree,
    );
    if (result.page != query.page) {
      throw ApiException('INVALID_PAGINATION', '人员候选分页响应与请求不一致');
    }
    return UtenEmployeePickerPage(
      items: result.items
          .map((row) => row.toPickerItem())
          .toList(growable: false),
      page: result.page,
      totalPages: result.totalPages,
      total: result.total,
    );
  }
}

final employeeReferenceRepositoryProvider =
    Provider<EmployeeReferenceRepository>((ref) {
      ref.watch(sensitiveReadBoundaryProvider);
      return DioEmployeeReferenceRepository(ref.watch(apiClientProvider));
    });

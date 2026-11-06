import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/inputs/uten_employee_picker_models.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/api_endpoints.dart';
import '../models/paged_result.dart';
import 'data_handover_models.dart';

class DataHandoverRepository {
  const DataHandoverRepository(this._api);

  final ApiClient _api;

  Future<PagedResult<DataHandoverCandidate>> candidates({
    required DataHandoverCandidateRole role,
    String? query,
    int page = 1,
    int size = 20,
    String? departmentId,
    bool includeSubtree = false,
    Set<String> excludeEmployeeIds = const {},
  }) async {
    final filters = {
      'role': role.apiValue,
      'page': page,
      'size': size,
      if (query?.trim().isNotEmpty == true) 'query': query!.trim(),
      'departmentId': ?departmentId,
      if (departmentId != null || includeSubtree)
        'includeSubtree': includeSubtree,
    };
    final excluded = excludeEmployeeIds.toList()..sort();
    final json = excluded.isEmpty
        ? await _api.get(
            ApiEndpoints.adminDataHandoverCandidates,
            query: filters,
          )
        : await _api.postCancellable(
            '${ApiEndpoints.adminDataHandoverCandidates}/query',
            body: {...filters, 'excludeEmployeeIds': excluded},
          );
    final responseSize = (json['size'] as num?)?.toInt() ?? size;
    if (responseSize < 1) throw const FormatException('交接候选人员分页大小无效');
    return PagedResult.fromJson({
      ...json,
      // The existing candidate DTO has page/size/total, without totalPages.
      'totalPages':
          json['totalPages'] ??
          (((json['total'] as num?)?.toInt() ?? 0) / responseSize).ceil(),
    }, DataHandoverCandidate.fromJson);
  }

  Future<DataHandoverPreview> employeePreview(
    String sourceEmployeeId, {
    String? successorEmployeeId,
  }) async {
    final json = await _api.get(
      ApiEndpoints.employeeHandoverPreview(sourceEmployeeId),
      query: {
        if (successorEmployeeId?.trim().isNotEmpty == true)
          'successorEmployeeId': successorEmployeeId!.trim(),
      },
    );
    return DataHandoverPreview.fromJson(json);
  }

  Future<DataHandoverPreview> adminPreview({
    required String sourceEmployeeId,
    required String targetEmployeeId,
    required Set<String> scopes,
  }) async {
    final json = await _api.get(
      ApiEndpoints.adminDataHandoverPreview,
      query: {
        'sourceEmployeeId': sourceEmployeeId,
        'targetEmployeeId': targetEmployeeId,
        if (scopes.isNotEmpty) 'scopes': scopes.toList()..sort(),
      },
    );
    return DataHandoverPreview.fromJson(json);
  }

  Future<DataHandoverResult> execute(DataHandoverRequest request) async {
    final json = await _api.post(
      ApiEndpoints.adminDataHandovers,
      body: request.toJson(),
    );
    return DataHandoverResult.fromJson(json);
  }
}

extension DataHandoverPickerCandidates on DataHandoverRepository {
  Future<UtenEmployeePickerPage> pickerPage(
    UtenEmployeePickerQuery query, {
    required DataHandoverCandidateRole role,
    Set<String> excludeEmployeeIds = const {},
  }) async {
    final excluded = Set<String>.of(excludeEmployeeIds);
    final result = await candidates(
      role: role,
      page: query.page,
      size: 100,
      query: query.keyword,
      departmentId: query.departmentId,
      includeSubtree: query.includeDepartmentSubtree,
      excludeEmployeeIds: excluded,
    );
    if (result.page != query.page) {
      throw ApiException('INVALID_PAGINATION', '交接候选人员分页已变化，请重新搜索');
    }
    return UtenEmployeePickerPage(
      items: [
        for (final employee in result.items)
          if (!excluded.contains(employee.employeeId))
            UtenEmployeePickerItem(
              id: employee.employeeId,
              name: employee.name,
              employeeCode: employee.code,
              departmentId: employee.departmentId,
              departmentName: employee.departmentName,
              accountStatus: employee.accountStatus,
              employmentStatus: employee.employmentStatus,
            ),
      ],
      page: result.page,
      totalPages: result.totalPages,
      total: result.total,
    );
  }
}

final dataHandoverRepositoryProvider = Provider<DataHandoverRepository>(
  (ref) => DataHandoverRepository(ref.watch(apiClientProvider)),
);

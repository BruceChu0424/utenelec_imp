import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
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
  }) async {
    final json = await _api.get(
      ApiEndpoints.adminDataHandoverCandidates,
      query: {
        'role': role.apiValue,
        'page': page,
        'size': size,
        if (query?.trim().isNotEmpty == true) 'query': query!.trim(),
      },
    );
    return PagedResult.fromJson(json, DataHandoverCandidate.fromJson);
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

final dataHandoverRepositoryProvider = Provider<DataHandoverRepository>(
  (ref) => DataHandoverRepository(ref.watch(apiClientProvider)),
);

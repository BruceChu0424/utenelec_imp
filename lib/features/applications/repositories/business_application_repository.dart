import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/business_application.dart';

class BusinessApplicationRepository {
  BusinessApplicationRepository(this.api);
  final ApiClient api;
  static const path = '/business-applications';
  Future<BusinessApplication> get(String id) async =>
      BusinessApplication.fromJson(await api.get('$path/$id'));
  Future<BusinessApplication> create(BusinessApplicationInput input) async =>
      BusinessApplication.fromJson(await api.post(path, body: input.toJson()));
  Future<BusinessApplication> update(
    String id,
    BusinessApplicationInput input,
  ) async => BusinessApplication.fromJson(
    await api.put('$path/$id', body: input.toJson()),
  );
  Future<BusinessApplication> act(
    String id,
    String action, {
    required int version,
    String? reason,
    Map<String, dynamic>? fields,
  }) async => BusinessApplication.fromJson(
    await api.post(
      '$path/$id/$action',
      body: {'expectedVersion': version, 'reason': ?reason, 'fields': ?fields},
    ),
  );
  Future<PagedResult<BusinessApplication>> list({
    String queue = 'mine',
    String? kind,
    String? status,
    String? approvalStage,
    String? departmentCode,
    int page = 1,
    int size = 24,
  }) async => PagedResult.fromJsonResponsive(
    await api.get(
      '$path/$queue',
      query: {
        'page': page,
        'size': size,
        'kind': ?kind,
        'status': ?status,
        'approvalStage': ?approvalStage,
        'departmentCode': ?departmentCode,
      },
    ),
    BusinessApplication.fromJson,
  );
  Future<Map<String, dynamic>> counts() => api.get('$path/counts');
  Future<Map<String, dynamic>> prepaymentFinanceCandidates(
    String id, {
    int page = 1,
    String? keyword,
  }) => api.get(
    '$path/$id/prepayment-finance-candidates',
    query: {'page': page, 'size': 24, 'keyword': ?keyword},
  );
}

final businessApplicationRepositoryProvider =
    Provider<BusinessApplicationRepository>(
      (ref) => BusinessApplicationRepository(ref.watch(apiClientProvider)),
    );

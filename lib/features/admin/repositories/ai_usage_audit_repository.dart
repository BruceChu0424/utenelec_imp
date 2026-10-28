import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

abstract interface class AiUsageAuditRepository {
  Future<Map<String, dynamic>> read({
    int days = 30,
    int page = 0,
    int size = 20,
    String? userId,
    String? providerId,
  });
  Future<Map<String, dynamic>> billing(String providerId);
  Future<Map<String, dynamic>> saveBilling(
    String providerId,
    Map<String, dynamic> values,
  );
}

abstract interface class AiUsageAuditHeaderRepository {
  Future<Map<String, dynamic>> readWithHeaders({
    int days = 30,
    int page = 0,
    int size = 20,
    String? userId,
    String? providerId,
    Map<String, String?> filters = const {},
    String? sort,
    bool ascending = true,
  });
}

final aiUsageAuditRepositoryProvider = Provider<AiUsageAuditRepository>(
  (ref) => DioAiUsageAuditRepository(ref.watch(apiClientProvider)),
);

class DioAiUsageAuditRepository
    implements AiUsageAuditRepository, AiUsageAuditHeaderRepository {
  DioAiUsageAuditRepository(this.api);
  final ApiClient api;

  @override
  Future<Map<String, dynamic>> read({
    int days = 30,
    int page = 0,
    int size = 20,
    String? userId,
    String? providerId,
  }) => api.get(
    '/admin/ai/usage-audit',
    query: {
      'days': days,
      'page': page,
      'size': size,
      'userId': ?userId,
      'providerId': ?providerId,
    },
  );

  @override
  Future<Map<String, dynamic>> readWithHeaders({
    int days = 30,
    int page = 0,
    int size = 20,
    String? userId,
    String? providerId,
    Map<String, String?> filters = const {},
    String? sort,
    bool ascending = true,
  }) => api.get(
    '/admin/ai/usage-audit',
    query: {
      'headerQuery': true,
      'days': days,
      'page': page,
      'size': size,
      'userId': ?userId,
      'providerId': ?providerId,
      for (final entry in filters.entries)
        if (entry.value != null && entry.value!.trim().isNotEmpty)
          entry.key.startsWith('search.') ? entry.key : 'search.${entry.key}':
              entry.value!.trim(),
      'sort': ?sort,
      if (sort != null) 'order': ascending ? 'asc' : 'desc',
    },
  );

  @override
  Future<Map<String, dynamic>> billing(String providerId) =>
      api.get('/admin/ai/providers/$providerId/billing');

  @override
  Future<Map<String, dynamic>> saveBilling(
    String providerId,
    Map<String, dynamic> values,
  ) => api.put('/admin/ai/providers/$providerId/billing', body: values);
}

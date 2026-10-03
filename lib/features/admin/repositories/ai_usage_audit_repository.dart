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

final aiUsageAuditRepositoryProvider = Provider<AiUsageAuditRepository>(
  (ref) => DioAiUsageAuditRepository(ref.watch(apiClientProvider)),
);

class DioAiUsageAuditRepository implements AiUsageAuditRepository {
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
  Future<Map<String, dynamic>> billing(String providerId) =>
      api.get('/admin/ai/providers/$providerId/billing');

  @override
  Future<Map<String, dynamic>> saveBilling(
    String providerId,
    Map<String, dynamic> values,
  ) => api.put('/admin/ai/providers/$providerId/billing', body: values);
}

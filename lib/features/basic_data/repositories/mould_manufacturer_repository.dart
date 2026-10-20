import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';

class MouldManufacturerRepository {
  MouldManufacturerRepository(this.api);
  final ApiClient api;
  Future<List<String>> suggestions(String keyword) => api.getStringList(
    '${ApiEndpoints.moulds}/manufacturer-suggestions',
    query: {'q': keyword.trim()},
  );
}

final mouldManufacturerRepositoryProvider = Provider((ref) {
  ref.watch(authenticatedScopeProvider);
  return MouldManufacturerRepository(ref.watch(apiClientProvider));
});

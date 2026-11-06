import '../paging/versioned_summary_read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../auth/permissions.dart';
import '../providers/authenticated_scope_provider.dart';
import 'business_column.dart';

class BusinessColumnsRepository {
  const BusinessColumnsRepository(this.api);
  final ApiClient api;

  Future<void> delete(String scope, String id) => api.delete(
    '/business-columns/${Uri.encodeComponent(scope)}/${Uri.encodeComponent(id)}',
  );

  Future<List<BusinessColumn>> search(String scope, String query) =>
      readCompleteVersionedSummaries<BusinessColumn>(
        // The picker's existing PagedReadIntent supplies its repository/query
        // owner. The shared reader inherits that fence for every batch.
        isCurrent: () => true,
        batchSize: 1000,
        loadPage: (page, size, revision) => api.get(
          '/business-columns/summaries',
          query: {
            'scope': scope,
            'q': query,
            'page': page,
            'size': size,
            'readSnapshotRevision': ?revision,
          },
        ),
        decode: BusinessColumn.fromJson,
        idOf: (column) => column.id,
      );

  Future<bool> supportsArithmetic(String scope) async =>
      (await api.get(
        '/business-columns/capabilities',
        query: {'scope': scope},
      ))['arithmetic'] ==
      true;

  Future<BusinessColumn> create({
    required String scope,
    required String name,
    required String type,
    required String operation,
  }) async => BusinessColumn.fromJson(
    await api.post(
      '/business-columns',
      body: {
        'scope': scope,
        'name': name,
        'type': type,
        'operation': operation,
      },
    ),
  );
}

final businessColumnsRepositoryProvider = Provider<BusinessColumnsRepository>((
  ref,
) {
  ref.watch(authenticatedScopeProvider);
  ref.watch(currentPermissionsProvider);
  return BusinessColumnsRepository(ref.watch(apiClientProvider));
});

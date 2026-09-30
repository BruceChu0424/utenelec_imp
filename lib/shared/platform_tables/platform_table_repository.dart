import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/api_client.dart';
import '../auth/permissions.dart';
import '../providers/authenticated_scope_provider.dart';
import 'platform_table_models.dart';

class PlatformTableRepository {
  PlatformTableRepository(this.api);
  final ApiClient api;
  Future<List<PlatformTableCapabilities>>? _scopes;
  Future<List<PlatformTableCapabilities>> scopes() => _scopes ??= _loadScopes();
  Future<List<PlatformTableCapabilities>> _loadScopes() async {
    try {
      return (await api.getList(
        '/platform-columns/scopes',
      )).map(PlatformTableCapabilities.fromJson).toList(growable: false);
    } catch (_) {
      _scopes = null;
      rethrow;
    }
  }

  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async => (await api.getList(
    '/platform-columns/$scope/definitions',
    query: {if (ids == null) 'q': query, if (ids != null) 'ids': ids.join(',')},
  )).map(PlatformColumnDefinition.fromJson).toList(growable: false);
  Future<PlatformColumnDefinition> create(
    String scope, {
    required String name,
    required String type,
    bool priceProtected = false,
    PlatformFormula? formula,
  }) async => PlatformColumnDefinition.fromJson(
    await api.post(
      '/platform-columns/$scope/definitions',
      body: {
        'name': name,
        'type': type,
        'priceProtected': priceProtected,
        'formula': formula?.toJson(),
      },
    ),
  );
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    final result = await api.postList(
      '/platform-columns/$scope/values:batch',
      body: {'recordIds': ids, 'columnIds': columnIds},
    );
    return result.map(PlatformRowValues.fromJson).toList(growable: false);
  }

  Future<void> recordUse(String scope, String id) async {
    await api.post('/platform-columns/$scope/definitions/$id/use');
  }

  Future<PlatformRowValues> save(
    String scope,
    String recordId, {
    required int expectedVersion,
    required List<Map<String, dynamic>> cells,
  }) async => PlatformRowValues.fromJson(
    await api.put(
      '/platform-columns/$scope/values/$recordId',
      body: {'expectedVersion': expectedVersion, 'cells': cells},
    ),
  );
}

final platformTableRepositoryProvider = Provider<PlatformTableRepository>((
  ref,
) {
  ref.watch(authenticatedScopeProvider);
  ref.watch(currentPermissionsProvider);
  return PlatformTableRepository(ref.watch(apiClientProvider));
});

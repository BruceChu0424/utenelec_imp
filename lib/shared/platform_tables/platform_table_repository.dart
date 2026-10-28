import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/api_client.dart';
import '../auth/permissions.dart';
import '../providers/authenticated_scope_provider.dart';
import 'platform_table_models.dart';

class PlatformTableRepository {
  PlatformTableRepository(this.api);
  final ApiClient api;
  Future<List<PlatformTableCapabilities>>? _scopes;
  int _scopesGeneration = 0;
  void invalidateScopes() {
    _scopesGeneration++;
    _scopes = null;
  }

  Future<List<PlatformTableCapabilities>> scopes() =>
      _scopes ??= _loadScopes(_scopesGeneration);
  Future<List<PlatformTableCapabilities>> _loadScopes(int generation) async {
    try {
      return (await api.getList(
        '/platform-columns/scopes',
      )).map(PlatformTableCapabilities.fromJson).toList(growable: false);
    } catch (_) {
      if (generation == _scopesGeneration) _scopes = null;
      rethrow;
    }
  }

  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async {
    // These ids come from display preferences, not saved business values.
    // Invalid cached ids must be omitted before Spring's UUID query binding;
    // the controller repairs the layout from the returned authorized roots.
    final selected = ids?.where(_definitionId.hasMatch).toSet().toList();
    if (selected != null && selected.isEmpty) return const [];
    return (await api.getList(
      '/platform-columns/$scope/definitions',
      query: {
        if (selected == null) 'q': query,
        if (selected != null) ...{
          'ids': selected.join(','),
          'availableOnly': true,
        },
      },
    )).map(PlatformColumnDefinition.fromJson).toList(growable: false);
  }

  static final _definitionId = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
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
  Future<PlatformColumnDefinition> createRelated(
    String scope, {
    required String name,
    required String relationKey,
  }) async => PlatformColumnDefinition.fromJson(
    await api.post(
      '/platform-columns/$scope/definitions',
      body: {
        'name': name,
        'type': 'RELATED',
        'relationKey': relationKey,
        'priceProtected': false,
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

  Future<void> deleteDefinition(String scope, String id) =>
      api.delete('/platform-columns/$scope/definitions/$id');

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

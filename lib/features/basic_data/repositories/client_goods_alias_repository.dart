// Learned customer goods cross reference (ADR-134): read the rows the server
// learned from saved sales documents and delete a wrong one.
//
// GET  /master/clients/{id}/goods-aliases?page&size&keyword  (client:view + read scope)
// DELETE /master/clients/{id}/goods-aliases/{aliasId}         (client:edit + write scope)
//
// The keyword is goods wording (model / description / our goods name or code),
// not contact data, so it is sent as a query parameter like the other master
// lists; customer phone numbers never go through this endpoint.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/client_goods_alias.dart';

/// Page size cap shared with the server's master list limit.
const kClientGoodsAliasMaxPageSize = 100;

abstract interface class ClientGoodsAliasRepository {
  /// One page (1-based) of this customer's learned aliases, newest first.
  Future<PagedResult<ClientGoodsAlias>> list(
    String clientId, {
    int page = 1,
    int size = 20,
    String? keyword,
  });

  /// Deletes one alias of this customer; the server re-checks that the alias
  /// belongs to [clientId] and that the caller may edit the customer.
  Future<void> delete(String clientId, String aliasId);
}

class DioClientGoodsAliasRepository implements ClientGoodsAliasRepository {
  DioClientGoodsAliasRepository(this.api);

  final ApiClient api;

  @override
  Future<PagedResult<ClientGoodsAlias>> list(
    String clientId, {
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    final id = _requireId(clientId, 'clientId');
    final trimmed = keyword?.trim() ?? '';
    final json = await api.get(
      ApiEndpoints.clientGoodsAliases(id),
      query: {
        'page': page < 1 ? 1 : page,
        'size': size.clamp(1, kClientGoodsAliasMaxPageSize),
        if (trimmed.isNotEmpty) 'keyword': trimmed,
      },
    );
    return PagedResult.fromJson(json, ClientGoodsAlias.fromJson);
  }

  @override
  Future<void> delete(String clientId, String aliasId) async {
    await api.delete(
      ApiEndpoints.clientGoodsAlias(
        _requireId(clientId, 'clientId'),
        _requireId(aliasId, 'aliasId'),
      ),
    );
  }
}

String _requireId(String raw, String name) {
  final id = raw.trim();
  if (id.isEmpty) {
    throw ArgumentError.value(raw, name, 'must not be blank');
  }
  return id;
}

final clientGoodsAliasRepositoryProvider = Provider<ClientGoodsAliasRepository>(
  (ref) => DioClientGoodsAliasRepository(ref.watch(apiClientProvider)),
);

// 客户主档仓库：分类下分页列表 + 详情。
//
// 仿 DioMouldRepository，端点走 ApiEndpoints.clients 系列；
// 分页结果复用 PagedResult（对应后端 PageResponse）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/client_node.dart';

abstract interface class ClientRepository {
  /// 某分类下的客户分页（page 从 1 起，与后端 Pageables 约定一致）。
  Future<PagedResult<ClientListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
  });

  Future<ClientDetail> detail(String id);

  Future<void> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

class DioClientRepository implements ClientRepository {
  DioClientRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<ClientListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get(
      ApiEndpoints.clients,
      query: {
        'categoryId': categoryId,
        'page': page,
        'size': size,
      },
    );
    return PagedResult.fromJson(json, ClientListItem.fromJson);
  }

  @override
  Future<ClientDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.client(id));
    return ClientDetail.fromJson(json);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    await api.post(ApiEndpoints.clients, body: body);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.client(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.client(id));
  }
}

final clientRepositoryProvider = Provider<ClientRepository>(
  (ref) => DioClientRepository(ref.watch(apiClientProvider)),
);

// 模具主档仓库：分类下分页列表 + 详情。
//
// 仿 DioGoodsRepository，端点走 ApiEndpoints.moulds 系列；
// 分页结果复用 PagedResult（对应后端 PageResponse）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/mould_node.dart';

abstract interface class MouldRepository {
  /// 某分类下的模具分页（page 从 1 起，与后端 Pageables 约定一致）。
  Future<PagedResult<MouldListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
  });

  Future<MouldDetail> detail(String id);

  Future<void> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

class DioMouldRepository implements MouldRepository {
  DioMouldRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<MouldListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get(
      ApiEndpoints.moulds,
      query: {
        'categoryId': categoryId,
        'page': page,
        'size': size,
      },
    );
    return PagedResult.fromJson(json, MouldListItem.fromJson);
  }

  @override
  Future<MouldDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.mould(id));
    return MouldDetail.fromJson(json);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    await api.post(ApiEndpoints.moulds, body: body);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.mould(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.mould(id));
  }
}

final mouldRepositoryProvider = Provider<MouldRepository>(
  (ref) => DioMouldRepository(ref.watch(apiClientProvider)),
);

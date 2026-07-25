// 仓库单据仓库（8 类统一，端点 /api/stock/docs，docType 区分）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/stock_doc.dart';

class StockDocFilter {
  const StockDocFilter({this.keyword, this.warehouseId, this.status});
  final String? keyword;
  final String? warehouseId;
  final int? status;
}

class StockDocRepository {
  StockDocRepository(this.api, this.type);
  final ApiClient api;
  final StockDocType type;

  Future<PagedResult<StockDocListItem>> list({
    int page = 1,
    int size = 20,
    StockDocFilter filter = const StockDocFilter(),
  }) async {
    final json = await api.get(ApiEndpoints.stockDocsBase, query: {
      'docType': type.code,
      'page': page,
      'size': size,
      if (filter.keyword != null && filter.keyword!.trim().isNotEmpty)
        'keyword': filter.keyword!.trim(),
      if (filter.warehouseId != null) 'warehouseId': filter.warehouseId,
      if (filter.status != null) 'status': filter.status,
    });
    return PagedResult.fromJson(json, StockDocListItem.fromJson);
  }

  Future<StockDocDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.stockDoc(id));
    return StockDocDetail.fromJson(json);
  }

  Future<StockDocDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(ApiEndpoints.stockDocsBase, body: body);
    return StockDocDetail.fromJson(json);
  }

  Future<StockDocDetail> update(String id, Map<String, dynamic> body) async {
    final json = await api.put(ApiEndpoints.stockDoc(id), body: body);
    return StockDocDetail.fromJson(json);
  }

  Future<void> delete(String id) async => api.delete(ApiEndpoints.stockDoc(id));
  Future<StockDocDetail> approve(String id) async =>
      StockDocDetail.fromJson(await api.post(ApiEndpoints.stockDocApprove(id)));
  Future<StockDocDetail> reverse(String id) async =>
      StockDocDetail.fromJson(await api.post(ApiEndpoints.stockDocReverse(id)));
}

final stockDocRepositoryProvider = Provider.family<StockDocRepository, StockDocType>(
  (ref, type) => StockDocRepository(ref.watch(apiClientProvider), type),
);

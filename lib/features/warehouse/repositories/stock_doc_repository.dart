// 仓库单据仓库（8 类统一，端点 /api/stock/docs，docType 区分）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/stock_doc.dart';

class StockDocFilter {
  const StockDocFilter({
    this.keyword,
    this.warehouseId,
    this.status,
    this.departmentId,
    this.issueStatus,
  });
  final String? keyword;
  final String? warehouseId;
  final int? status;

  /// 领料车间（仅 DRAW，V97）
  final String? departmentId;

  /// 出库进度（仅 DRAW，V97）：0未出库/1部分出库/2已出完
  final int? issueStatus;
}

class StockDocRepository {
  StockDocRepository(this.api, this.type);
  final ApiClient api;
  final StockDocType type;

  Future<PagedResult<StockDocListItem>> list({
    int page = 1,
    int size = 20,
    StockDocFilter filter = const StockDocFilter(),
    String? sort,
    String? order,
  }) async {
    final json = await api.get(
      ApiEndpoints.stockDocsBase,
      query: {
        'docType': type.code,
        'page': page,
        'size': size,
        if (filter.keyword != null && filter.keyword!.trim().isNotEmpty)
          'keyword': filter.keyword!.trim(),
        if (filter.warehouseId != null) 'warehouseId': filter.warehouseId,
        if (filter.status != null) 'status': filter.status,
        if (filter.departmentId != null) 'departmentId': filter.departmentId,
        if (filter.issueStatus != null) 'issueStatus': filter.issueStatus,
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
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

  /// DRAW 分轮出库（部分出库）：lines = [{itemId, qty}]
  Future<StockDocDetail> issue(
    String id,
    List<Map<String, dynamic>> lines,
  ) async => StockDocDetail.fromJson(
    await api.post(ApiEndpoints.stockDocIssue(id), body: {'lines': lines}),
  );

  /// DRAW 反出库：对称回退已出库量
  Future<StockDocDetail> reverseIssue(
    String id,
    List<Map<String, dynamic>> lines,
  ) async => StockDocDetail.fromJson(
    await api.post(
      ApiEndpoints.stockDocIssueReverse(id),
      body: {'lines': lines},
    ),
  );
}

final stockDocRepositoryProvider =
    Provider.family<StockDocRepository, StockDocType>(
      (ref, type) => StockDocRepository(ref.watch(apiClientProvider), type),
    );

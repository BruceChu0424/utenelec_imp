// 销售单据仓库（5 单据统一，按 docType 切端点）。
//
// 端点 /api/sales/{quotes|orders|shipments|other-shipments|returns}
//  CRUD + /{id}/approve + /{id}/reverse。
// 订货额外 POST /{id}/stopped?stopped= 切中止位（@RequestParam 走 query）。
// create/update 收 Map body（编辑页组装 header+items）。
//
// 端点字符串内联（api_endpoints.dart 由上层统一加 sales_* 常量；在那之前本文件用字面量，
// 与 purchase_repository 形成对照，迁移时把 '/sales/$seg' 换成 ApiEndpoints.salesBase(seg) 即可）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/sales_doc.dart';

class SalesDocFilter {
  const SalesDocFilter({
    this.keyword,
    this.clientId,
    this.warehouseId,
    this.status,
    this.dateFrom,
    this.dateTo,
  });
  final String? keyword;
  final String? clientId;
  final String? warehouseId;
  final int? status;
  final String? dateFrom; // yyyy-MM-dd
  final String? dateTo;
}

class SalesRepository {
  SalesRepository(this.api, this.type);
  final ApiClient api;
  final SalesDocType type;

  String get _base => '/sales/${type.pathSegment}';
  String _doc(String id) => '/sales/${type.pathSegment}/$id';

  Future<PagedResult<SalesDocListItem>> list({
    int page = 1,
    int size = 20,
    SalesDocFilter filter = const SalesDocFilter(),
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (filter.keyword != null && filter.keyword!.trim().isNotEmpty)
        'keyword': filter.keyword!.trim(),
      if (filter.clientId != null) 'clientId': filter.clientId,
      if (filter.warehouseId != null) 'warehouseId': filter.warehouseId,
      if (filter.status != null) 'status': filter.status,
      if (filter.dateFrom != null) 'dateFrom': filter.dateFrom,
      if (filter.dateTo != null) 'dateTo': filter.dateTo,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json = await api.get(_base, query: query);
    return PagedResult.fromJson(json, SalesDocListItem.fromJson);
  }

  Future<SalesDocDetail> detail(String id) async {
    final json = await api.get(_doc(id));
    return SalesDocDetail.fromJson(json);
  }

  Future<SalesDocDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(_base, body: body);
    return SalesDocDetail.fromJson(json);
  }

  Future<SalesDocDetail> update(String id, Map<String, dynamic> body) async {
    final json = await api.put(_doc(id), body: body);
    return SalesDocDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete(_doc(id));
  }

  Future<SalesDocDetail> approve(String id) async {
    final json = await api.post('$_doc(id)/approve');
    return SalesDocDetail.fromJson(json);
  }

  Future<SalesDocDetail> reverse(String id) async {
    final json = await api.post('$_doc(id)/reverse');
    return SalesDocDetail.fromJson(json);
  }

  /// 订货单切中止位（POST /{id}/stopped?stopped=true|false）。
  /// @RequestParam 走 query —— 直接把 query 串拼到 URL，dio 以原样发送，Spring 解析。
  Future<SalesDocDetail> setStopped(String id, {required bool stopped}) async {
    final json = await api.post(
      '$_doc(id)/stopped?stopped=${stopped ? 'true' : 'false'}',
    );
    return SalesDocDetail.fromJson(json);
  }
}

/// 按 docType 的仓库 family。
final salesRepositoryProvider =
    Provider.family<SalesRepository, SalesDocType>(
  (ref, type) => SalesRepository(ref.watch(apiClientProvider), type),
);

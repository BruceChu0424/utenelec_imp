// 采购单据仓库（4 单据统一，按 docType 切端点）。
//
// 端点 /api/purchase/{requests|orders|receipts|returns}（CRUD + /{id}/approve + /{id}/reverse）。
// create/update 收 Map body（编辑页组装 header+items）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/purchase_doc.dart';

class PurchaseDocFilter {
  const PurchaseDocFilter({
    this.keyword,
    this.supplierId,
    this.warehouseId,
    this.status,
    this.dateFrom,
    this.dateTo,
  });
  final String? keyword;
  final String? supplierId;
  final String? warehouseId;
  final int? status;
  final String? dateFrom; // yyyy-MM-dd
  final String? dateTo;
}

class PurchaseRepository {
  PurchaseRepository(this.api, this.type);
  final ApiClient api;
  final PurchaseDocType type;

  String get _base => ApiEndpoints.purchaseBase(type.pathSegment);

  Future<PagedResult<PurchaseDocListItem>> list({
    int page = 1,
    int size = 20,
    PurchaseDocFilter filter = const PurchaseDocFilter(),
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (filter.keyword != null && filter.keyword!.trim().isNotEmpty)
        'keyword': filter.keyword!.trim(),
      if (filter.supplierId != null) 'supplierId': filter.supplierId,
      if (filter.warehouseId != null) 'warehouseId': filter.warehouseId,
      if (filter.status != null) 'status': filter.status,
      if (filter.dateFrom != null) 'dateFrom': filter.dateFrom,
      if (filter.dateTo != null) 'dateTo': filter.dateTo,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json = await api.get(_base, query: query);
    return PagedResult.fromJson(json, PurchaseDocListItem.fromJson);
  }

  Future<PurchaseDocDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.purchaseDoc(type.pathSegment, id));
    return PurchaseDocDetail.fromJson(json);
  }

  Future<PurchaseDocDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(_base, body: body);
    return PurchaseDocDetail.fromJson(json);
  }

  Future<PurchaseDocDetail> update(String id, Map<String, dynamic> body) async {
    final json = await api.put(
      ApiEndpoints.purchaseDoc(type.pathSegment, id),
      body: body,
    );
    return PurchaseDocDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.purchaseDoc(type.pathSegment, id));
  }

  Future<PurchaseDocDetail> approve(String id) async {
    final json = await api.post(
      ApiEndpoints.purchaseApprove(type.pathSegment, id),
    );
    return PurchaseDocDetail.fromJson(json);
  }

  Future<PurchaseDocDetail> reverse(String id) async {
    final json = await api.post(
      ApiEndpoints.purchaseReverse(type.pathSegment, id),
    );
    return PurchaseDocDetail.fromJson(json);
  }
}

/// 按 docType 的仓库 family。
final purchaseRepositoryProvider =
    Provider.family<PurchaseRepository, PurchaseDocType>(
      (ref, type) => PurchaseRepository(ref.watch(apiClientProvider), type),
    );

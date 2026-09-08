// 采购单据仓库（4 单据统一，按 docType 切端点）。
//
// 端点 /api/purchase/{requests|orders|receipts|returns}（CRUD + /{id}/approve + /{id}/reverse）。
// create/update 收 Map body（编辑页组装 header+items）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_commercial_terms.dart';
import '../../../shared/repositories/procurement_terms_loader.dart';
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

  Future<List<ProcurementDecompositionLine>> decompositionPreview(
    Iterable<String> itemIds,
  ) async {
    final rows = await api.postList(
      '${ApiEndpoints.purchaseBase('requests')}/decomposition-preview',
      body: {'itemIds': itemIds.toSet().toList(growable: false)},
    );
    return rows
        .map(ProcurementDecompositionLine.fromJson)
        .toList(growable: false);
  }

  /// V477：分解前的明细数量修正（仅计划下达的采购申请；已订货/待财务审核
  /// 占用的明细服务端会拒绝）。返回刷新后的单据详情。
  Future<PurchaseDocDetail> adjustRequestItemQty({
    required String requestId,
    required String itemId,
    required double qty,
  }) async {
    final json = await api.put(
      '${ApiEndpoints.purchaseBase('requests')}/$requestId/items/$itemId/qty',
      body: {'qty': qty},
    );
    return PurchaseDocDetail.fromJson(json);
  }

  Future<PurchaseDocDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(_base, body: body);
    return PurchaseDocDetail.fromJson(json);
  }

  /// 按明细级供应商自动拆单创建（仅订货单用），返回生成的多张订货单。
  Future<List<PurchaseDocDetail>> createBatch(Map<String, dynamic> body) async {
    final json = await api.post('$_base/batch', body: body);
    final List<dynamic> list = json['items'] as List? ?? const [];
    return [
      for (final entry in list)
        PurchaseDocDetail.fromJson(entry as Map<String, dynamic>),
    ];
  }

  /// 货品 → 最近一次订货商业条款（行级条款「学习预填」：供应商/结账方式/币种/
  /// 汇率/税率一次带回；2026-09 行级条款改造起的预填契约）。无历史货品不在返回 Map 中。
  /// （旧 /last-suppliers 仅回供应商的端点保留一个发布周期兼容旧客户端，前端已不再使用。）
  Future<Map<String, ProcurementLastTerms>> lastTermsByGoods(
    Set<String> goodsIds,
  ) => loadProcurementTerms(api, '$_base/last-terms', goodsIds);

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

  /// 取消草稿订货单（仅 orders 族）：在审单取消时服务端同步撤回财务审批任务。
  Future<PurchaseDocDetail> cancelOrder(String id) async {
    final json = await api.post(
      '${ApiEndpoints.purchaseDoc(type.pathSegment, id)}/cancel',
    );
    return PurchaseDocDetail.fromJson(json);
  }

  Future<PurchaseDocDetail> submitFinance(String id) async {
    final json = await api.post(
      '${ApiEndpoints.purchaseDoc(type.pathSegment, id)}/submit-finance',
    );
    return PurchaseDocDetail.fromJson(json);
  }

  /// 批准后改量（POST /purchase/orders/{id}/change-qty，仅 orders 族）：
  /// 财务批准后逐行改数量，成功返回最新订单详情；服务端会自动重回财务复核。
  Future<PurchaseDocDetail> changeQty(
    String id,
    List<Map<String, dynamic>> items,
  ) async {
    final json = await api.post(
      '${ApiEndpoints.purchaseDoc(type.pathSegment, id)}/change-qty',
      body: {'items': items},
    );
    return PurchaseDocDetail.fromJson(json);
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

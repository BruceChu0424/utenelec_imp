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
    this.closed,
    this.chain,
  });
  final String? keyword;
  final String? clientId;
  final String? warehouseId;
  final int? status;
  final String? dateFrom; // yyyy-MM-dd
  final String? dateTo;
  final bool? closed; // 结案筛选（订货工作台「本月完成」卡用）
  final List<int>? chain; // 订单行链路状态组（统计卡钻取，逗号拼接多值）
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
      if (filter.closed != null) 'closed': filter.closed,
      if (filter.chain != null && filter.chain!.isNotEmpty)
        'chain': filter.chain!.join(','),
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

  /// 排产进度（仅订货）：每行 订货/可发/已排/已产/已发 + 关联生产计划溯源。
  Future<List<OrderPlanProgressLine>> planProgress(String id) async {
    final list = await api.getList('${_doc(id)}/plan-progress'); // ENDPOINT
    return list.map(OrderPlanProgressLine.fromJson).toList();
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
    final json = await api.post('${_doc(id)}/approve');
    return SalesDocDetail.fromJson(json);
  }

  Future<SalesDocDetail> reverse(String id) async {
    final json = await api.post('${_doc(id)}/reverse');
    return SalesDocDetail.fromJson(json);
  }

  /// C6 财务审核发货（仅出货单）：返回结算方式+未收余额辅助核对。
  Future<Map<String, dynamic>> financeAudit(String id) async {
    final json = await api.post('${_doc(id)}/finance-audit'); // ENDPOINT
    return json;
  }

  /// C6 财务反审（仅未审核出货的单据）。
  Future<Map<String, dynamic>> financeAuditReverse(String id) async {
    final json = await api.post(
      '${_doc(id)}/finance-audit-reverse',
    ); // ENDPOINT
    return json;
  }

  /// 订货工作台切中止位（POST /{id}/stopped?stopped=true|false）。
  /// @RequestParam 走 query —— 直接把 query 串拼到 URL，dio 以原样发送，Spring 解析。
  Future<SalesDocDetail> setStopped(String id, {required bool stopped}) async {
    final json = await api.post(
      '${_doc(id)}/stopped?stopped=${stopped ? 'true' : 'false'}',
    );
    return SalesDocDetail.fromJson(json);
  }

  /// 订货工作台统计卡（GET /api/sales/orders/stats；仅 order 类型可用）。
  Future<SalesOrderStats> stats() async {
    final json = await api.get('$_base/stats');
    return SalesOrderStats.fromJson(json);
  }

  /// 仓库驳回出货单（POST /{id}/reject?reason=...；V96，仅 shipment 类型可用）。
  Future<SalesDocDetail> reject(String id, {String? reason}) async {
    final r = reason == null || reason.trim().isEmpty
        ? ''
        : '?reason=${Uri.encodeQueryComponent(reason.trim())}';
    final json = await api.post('${_doc(id)}/reject$r');
    return SalesDocDetail.fromJson(json);
  }

  /// 订单改量（POST /{id}/change-qty；V100，仅 order 类型可用）。
  Future<SalesDocDetail> changeQty(
    String id,
    List<Map<String, dynamic>> items,
  ) async {
    final json = await api.post(
      '${_doc(id)}/change-qty',
      body: {'items': items},
    );
    return SalesDocDetail.fromJson(json);
  }

  /// 订单取消（POST /{id}/cancel；V100，仅 order 类型可用）。
  Future<SalesDocDetail> cancel(String id) async {
    final json = await api.post('${_doc(id)}/cancel');
    return SalesDocDetail.fromJson(json);
  }

  /// 报价转订货（POST /quotes/{id}/convert；SOP §三1，仅 quote 类型可用）。
  /// 返回新建订货草稿（行带入货品/数量/价格 + sourceDocNo 回联来源报价）。
  Future<SalesDocDetail> convertToOrder(String id) async {
    final json = await api.post('${_doc(id)}/convert');
    return SalesDocDetail.fromJson(json);
  }

  /// 批量发货可发行（GET /sales/orders/shippable-lines；SOP §一9，仅 order 类型可用）。
  Future<List<ShippableLine>> shippableLines() async {
    final json = await api.get('/sales/orders/shippable-lines');
    return (json as List?)
            ?.map((e) => ShippableLine.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
  }

  /// 批量发货开单（POST /sales/shipments/batch；SOP §一9）：同客户合并一张出货草稿。
  Future<List<SalesDocDetail>> batchShip({
    required String billDate,
    String? warehouseId,
    String? remark,
    required List<Map<String, dynamic>> lines,
  }) async {
    final json = await api.post(
      '/sales/shipments/batch',
      body: {
        'billDate': billDate,
        if (warehouseId != null) 'warehouseId': warehouseId,
        if (remark != null) 'remark': remark,
        'lines': lines,
      },
    );
    return (json as List?)
            ?.map((e) => SalesDocDetail.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
  }
}

/// 按 docType 的仓库 family。
final salesRepositoryProvider = Provider.family<SalesRepository, SalesDocType>(
  (ref, type) => SalesRepository(ref.watch(apiClientProvider), type),
);

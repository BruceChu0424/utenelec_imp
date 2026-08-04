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
import '../models/sales_order_progress.dart';

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
    this.sellerId,
  });
  final String? keyword;
  final String? clientId;
  final String? warehouseId;
  final int? status;
  final String? dateFrom; // yyyy-MM-dd
  final String? dateTo;
  final bool? closed; // 结案筛选（订货工作台「本月完成」卡用）
  final List<int>? chain; // 订单行链路状态组（统计卡钻取，逗号拼接多值）
  final String? sellerId; // 按销售员筛选（生产计划选来源单按跟单员收敛）
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
      if (filter.sellerId != null) 'sellerId': filter.sellerId,
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

  /// 订单进度看板（仅订货单）：已审订单生产/发货进度聚合 + 派生阶段。
  Future<PagedResult<SalesOrderProgressRow>> progress({
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get('/sales/orders/progress', query: {
      'page': page,
      'size': size,
    });
    return PagedResult.fromJson(json, SalesOrderProgressRow.fromJson);
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

  /// 登记或撤销客户对分批发货的确认（仅 CUSTOMER_CONFIRM 的履约中订单）。
  Future<SalesDocDetail> setPartialShipmentConfirmation(
    String id, {
    required bool confirmed,
    required String reason,
  }) async {
    final json = await api.post(
      '${_doc(id)}/partial-shipment-confirmation',
      body: {'confirmed': confirmed, 'reason': reason.trim()},
    );
    return SalesDocDetail.fromJson(json);
  }

  /// 推进仓库拣货状态机。新流程的正式出库只能通过 PICKED -> SHIPPED 完成。
  Future<SalesDocDetail> transitionWarehouseWork(
    String id, {
    required String targetStatus,
    String? reason,
  }) async {
    final normalizedReason = reason?.trim();
    final json = await api.post(
      '${_doc(id)}/warehouse-work',
      body: {
        'targetStatus': targetStatus,
        if (normalizedReason != null && normalizedReason.isNotEmpty)
          'reason': normalizedReason,
      },
    );
    return SalesDocDetail.fromJson(json);
  }

  /// 设置订单行优先级（POST /items/{id}/priority；V178，仅 order 类型可用）。
  /// 1急单/2普通/3现货；急单须填原因。仅稀缺让单决策用，不自动抢占。
  Future<SalesDocDetail> setLinePriority(
    String orderItemId,
    int priority, {
    String? reason,
  }) async {
    final json = await api.post(
      '/sales/orders/items/$orderItemId/priority',
      body: {'priority': priority, 'reason': ?reason},
    );
    return SalesDocDetail.fromJson(json);
  }

  /// 稀缺让单重排（POST /items/{id}/yield-reservation；V178）：主管释放某低优先级订单行的现货预留，
  /// 库存回池供急单占用，该行缺口自动回调度待排产，并通知其归属销售。
  Future<SalesDocDetail> yieldReservation(
    String orderItemId, {
    required double qty,
    required String reason,
    String? yielderOrderNo,
  }) async {
    final json = await api.post(
      '/sales/orders/items/$orderItemId/yield-reservation',
      body: {'qty': qty, 'reason': reason, 'yielderOrderNo': ?yielderOrderNo},
    );
    return SalesDocDetail.fromJson(json);
  }

  /// 稀缺库存占用视图（GET /reservations/scarce；V178）：某货品+颜色的全部生效预留 + 订单上下文 + 持有逾期。
  Future<List<ScarceReservation>> scarceReservations(
    String goodsId, {
    String? colorId,
  }) async {
    final json = await api.get(
      '/sales/orders/reservations/scarce',
      query: {'goodsId': goodsId, 'colorId': ?colorId},
    );
    return (json as List?)
            ?.map((e) => ScarceReservation.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
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
        'warehouseId': ?warehouseId,
        'remark': ?remark,
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

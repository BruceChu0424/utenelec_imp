// 仓库单据仓库（8 类统一，端点 /api/stock/docs，docType 区分）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../basic_data/models/master_facet.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/stock_doc.dart';
import '../models/stock_doc_outbound_review.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';

export '../models/stock_doc_outbound_review.dart';

class StockDocFilter {
  const StockDocFilter({
    this.keyword,
    this.warehouseId,
    this.toWarehouseId,
    this.status,
    this.departmentId,
    this.issueStatus,
    this.dateFrom,
    this.dateTo,
    this.productionReturnRequests,
    this.warehouseScope = const WarehouseTaskScope.all(),
    this.billNo,
  });
  final String? keyword;
  final String? warehouseId;

  /// 调入仓（仅转仓类单据；表头筛选，2026-09-16）
  final String? toWarehouseId;
  final int? status;

  /// 领料车间（仅 DRAW）
  final String? departmentId;

  /// 出库进度（仅 DRAW）：0未出库/1部分出库/2已出完
  final int? issueStatus;

  /// 业务日期范围（yyyy-MM-dd；历史记录段时间门控用）。
  final String? dateFrom;
  final String? dateTo;
  final bool? productionReturnRequests;

  /// 仓库任务中心选的仓(ADR-149)：发出仓或调入仓在范围内；默认 = 本人仓库数据范围(服务端强制)。
  final WarehouseTaskScope warehouseScope;

  /// 单据号表头值筛选（2026-09-25 单号列统一）：服务端精确匹配。
  final String? billNo;
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
        if (filter.toWarehouseId != null) 'toWarehouseId': filter.toWarehouseId,
        if (filter.status != null) 'status': filter.status,
        if (filter.departmentId != null) 'departmentId': filter.departmentId,
        if (filter.issueStatus != null) 'issueStatus': filter.issueStatus,
        if (filter.dateFrom != null) 'dateFrom': filter.dateFrom,
        if (filter.dateTo != null) 'dateTo': filter.dateTo,
        if (filter.productionReturnRequests != null)
          'productionReturnRequests': filter.productionReturnRequests,
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
        if (filter.billNo != null && filter.billNo!.trim().isNotEmpty)
          'billNo': filter.billNo!.trim(),
        ...filter.warehouseScope.queryParameters,
      },
    );
    return PagedResult.fromJson(json, StockDocListItem.fromJson);
  }

  /// 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径（docType 维度）。
  Future<List<MasterFacetBucket>> billNoFacets({
    StockDocFilter filter = const StockDocFilter(),
  }) async {
    final json = await api.get(
      '${ApiEndpoints.stockDocsBase}/facets',
      query: {
        'docType': type.code,
        if (filter.keyword != null && filter.keyword!.trim().isNotEmpty)
          'keyword': filter.keyword!.trim(),
        if (filter.warehouseId != null) 'warehouseId': filter.warehouseId,
        if (filter.toWarehouseId != null) 'toWarehouseId': filter.toWarehouseId,
        if (filter.status != null) 'status': filter.status,
        if (filter.departmentId != null) 'departmentId': filter.departmentId,
        if (filter.issueStatus != null) 'issueStatus': filter.issueStatus,
        if (filter.dateFrom != null) 'dateFrom': filter.dateFrom,
        if (filter.dateTo != null) 'dateTo': filter.dateTo,
        if (filter.productionReturnRequests != null)
          'productionReturnRequests': filter.productionReturnRequests,
        ...filter.warehouseScope.queryParameters,
      },
    );
    return parseFacetBuckets(json, 'billNo');
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

  /// 生产退料收仓确认; [lines] = 逐行实称重量 [{itemId, weightKg}] (千克 4 位, 只含称了的行,
  /// ADR-135 §3.9), 没称的行不发; 全部没称时不带 lines。
  Future<StockDocDetail> confirmMaterialReturn(
    String id, {
    required String warehouseId,
    required String idempotencyKey,
    List<Map<String, dynamic>> lines = const [],
  }) async => StockDocDetail.fromJson(
    await api.post(
      '${ApiEndpoints.stockDoc(id)}/material-return/confirm',
      body: {
        'warehouseId': warehouseId,
        'idempotencyKey': idempotencyKey,
        if (lines.isNotEmpty) 'lines': lines,
      },
    ),
  );

  Future<StockDocOutboundReview> review(String id) async =>
      StockDocOutboundReview.fromJson(
        await api.get('${ApiEndpoints.stockDoc(id)}/outbound-review'),
      );

  Future<StockDocDetail> approveReviewed(
    String id, {
    required String expectedReviewToken,
  }) async => StockDocDetail.fromJson(
    await api.post(
      '${ApiEndpoints.stockDoc(id)}/approve-reviewed',
      body: {'expectedReviewToken': expectedReviewToken},
    ),
  );

  /// 生产报工成品入库：仓库按实物批(ADR-148)确认实收数量 [lots] = [{lotId, acceptedQty}]；
  /// 实收先满足需求份，少收先扣实际超产，少收量由服务端拆成余量草稿。
  Future<StockDocDetail> confirmFinishedInbound(
    String id,
    List<Map<String, dynamic>> lots,
    String idempotencyKey, {
    String? varianceReason,
  }) async => StockDocDetail.fromJson(
    await api.post(
      '${ApiEndpoints.stockDoc(id)}/finished-in/confirm',
      body: {
        'idempotencyKey': idempotencyKey,
        'lots': lots,
        if (varianceReason?.trim().isNotEmpty == true)
          'varianceReason': varianceReason!.trim(),
      },
    ),
  );
  Future<StockDocDetail> reverse(String id) async =>
      StockDocDetail.fromJson(await api.post(ApiEndpoints.stockDocReverse(id)));

  /// 已点收生产成品入库专用红冲：服务端重建原 accepted slice 待点收草稿。
  Future<StockDocDetail> reverseFinishedInbound(String id) async =>
      StockDocDetail.fromJson(
        await api.post('${ApiEndpoints.stockDoc(id)}/finished-in/reverse'),
      );

  /// DRAW 分轮出库(部分出库)：lines = [{itemId, qty, weightKg?, qtyFromWeight?}]
  /// (weightKg = 本次实称千克 4 位, 只落出库流水; ADR-135 §3.6)
  Future<StockDocDetail> issue(
    String id,
    List<Map<String, dynamic>> lines,
    String idempotencyKey, {
    String? remark,
  }) async => StockDocDetail.fromJson(
    await api.post(
      ApiEndpoints.stockDocIssue(id),
      body: {
        'lines': lines,
        'idempotencyKey': idempotencyKey,
        // 出库备注（2026-09-09）：非空时服务端追加到单据 remark 留痕。
        if (remark != null && remark.trim().isNotEmpty) 'reason': remark.trim(),
      },
    ),
  );

  /// 草稿 DRAW 一键审核并完成首轮实际出库；任一步失败整笔回滚。
  /// [remark] 与 [issue] 同义(2026-09-10：此前首轮出库的备注被静默丢弃)；
  /// [lines] 行形态同 [issue] (可带本次重量)。
  Future<StockDocDetail> approveAndIssue(
    String id,
    List<Map<String, dynamic>> lines,
    String idempotencyKey, {
    String? remark,
  }) async => StockDocDetail.fromJson(
    await api.post(
      ApiEndpoints.stockDocApproveAndIssue(id),
      body: {
        'lines': lines,
        'idempotencyKey': idempotencyKey,
        if (remark != null && remark.trim().isNotEmpty) 'reason': remark.trim(),
      },
    ),
  );

  /// DRAW 取消出库：对称回退尚未进入生产执行的已出库量，原因必填；
  /// 行只带数量, 退回重量由服务端按原出库流水镜像。
  Future<StockDocDetail> reverseIssue(
    String id,
    List<Map<String, dynamic>> lines,
    String idempotencyKey,
    String reason,
  ) async => StockDocDetail.fromJson(
    await api.post(
      ApiEndpoints.stockDocIssueReverse(id),
      body: {
        'lines': lines,
        'idempotencyKey': idempotencyKey,
        'reason': reason,
      },
    ),
  );
}

final stockDocRepositoryProvider =
    Provider.family<StockDocRepository, StockDocType>(
      (ref, type) => StockDocRepository(ref.watch(apiClientProvider), type),
    );

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../models/master_facet_bucket.dart';
import 'package:uten_imp/shared/sales_review/sales_order_review.dart';

/// 销售订货两级审核共用传输入口；managerReview 明确选择负责人独立端点。
/// 财务待确认列表与计数仍属于财务阶段，不因复用详情与决策请求而更换权限或状态。
abstract interface class SalesOrderFinanceConfirmationRepository {
  /// 待确认任务分页。[rejected]：false=仅未驳回待办（默认）；true=仅已驳回；null=全部。
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
    bool confirmed = false,
    String? sort,
    String? order,
    String? billNo,
  });

  /// 销售单号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径。
  Future<List<MasterFacetBucket>> billNoFacets({
    bool? rejected,
    String? keyword,
    bool? changesOnly,
    bool confirmed = false,
  });

  Future<int> pendingCount({bool? changesOnly});

  /// 财务审核详情（专用审核页：订单 + 明细 + 客户财务快照）。
  Future<SalesOrderFinanceReview> review(String orderId);

  /// 财务确认（remark 可空）。成功无返回体；失败抛 ApiException。
  Future<void> confirm(
    String orderId, {
    String? remark,
    int? expectedRevision,
    String? expectedClaimId,
  });

  /// 原子批量确认：任一订单校验失败时服务端整批回滚；单次最多 100 笔。
  Future<void> confirmBatch(
    Iterable<String> orderIds, {
    String? remark,
    Map<String, int>? expectedRevisions,
    Map<String, String>? expectedClaimIds,
  });

  /// 财务驳回（reason 必填；决策先保留状态/预留，销售须受控修订回草稿并重新审核）。
  Future<void> reject(
    String orderId, {
    required String reason,
    int? expectedRevision,
    String? expectedClaimId,
  });
}

class DioSalesOrderFinanceConfirmationRepository
    implements SalesOrderFinanceConfirmationRepository {
  const DioSalesOrderFinanceConfirmationRepository(
    this.api, {
    this.managerReview = false,
  });

  final bool managerReview;

  final ApiClient api;

  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
    bool confirmed = false,
    String? sort,
    String? order,
    String? billNo,
  }) async {
    final normalizedKeyword = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.salesOrderFinanceConfirmationPending,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        'rejected': ?rejected,
        'changesOnly': ?changesOnly,
        if (confirmed) 'confirmed': true,
        if (normalizedKeyword != null && normalizedKeyword.isNotEmpty)
          'keyword': normalizedKeyword,
        // 2026-09-25 单号列统一：表头排序 + 销售单号表头值筛选。
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
        if (billNo != null && billNo.trim().isNotEmpty) 'billNo': billNo.trim(),
      },
    );
    return SalesOrderFinancePendingPage.fromJson(json);
  }

  @override
  Future<List<MasterFacetBucket>> billNoFacets({
    bool? rejected,
    String? keyword,
    bool? changesOnly,
    bool confirmed = false,
  }) async {
    final normalizedKeyword = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.salesOrderFinanceConfirmationFacets,
      query: <String, dynamic>{
        'rejected': ?rejected,
        'changesOnly': ?changesOnly,
        if (confirmed) 'confirmed': true,
        if (normalizedKeyword != null && normalizedKeyword.isNotEmpty)
          'keyword': normalizedKeyword,
      },
    );
    return parseFacetBuckets(json, 'billNo');
  }

  @override
  Future<int> pendingCount({bool? changesOnly}) async {
    final json = await api.get(
      ApiEndpoints.salesOrderFinanceConfirmationCount,
      query: {'changesOnly': ?changesOnly},
    );
    final nested = json['data'];
    final value = json['count'] ?? (nested is Map ? nested['count'] : nested);
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
    return parsed < 0 ? 0 : parsed;
  }

  @override
  Future<SalesOrderFinanceReview> review(String orderId) async {
    final json = await api.get(
      managerReview
          ? '/sales/manager-review/orders/${Uri.encodeComponent(orderId)}'
          : ApiEndpoints.salesOrderFinanceReview(orderId),
    );
    return SalesOrderFinanceReview.fromJson(json);
  }

  @override
  Future<void> confirm(
    String orderId, {
    String? remark,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {
    await api.post(
      managerReview
          ? '/sales/manager-review/orders/${Uri.encodeComponent(orderId)}/confirm'
          : ApiEndpoints.salesOrderFinanceConfirm(orderId),
      body: <String, dynamic>{
        'expectedRevision': ?expectedRevision,
        'expectedClaimId': ?expectedClaimId,
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
      },
    );
  }

  @override
  Future<void> confirmBatch(
    Iterable<String> orderIds, {
    String? remark,
    Map<String, int>? expectedRevisions,
    Map<String, String>? expectedClaimIds,
  }) async {
    final normalizedIds =
        orderIds
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort();
    await api.post(
      managerReview
          ? '/sales/manager-review/orders/batch'
          : ApiEndpoints.salesOrderFinanceConfirmationBatch,
      body: <String, dynamic>{
        'orderIds': normalizedIds,
        'expectedRevisions': ?expectedRevisions,
        'expectedClaimIds': ?expectedClaimIds,
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
      },
    );
  }

  Future<void> reverseManager(
    String orderId, {
    required String decisionId,
    required String reason,
    required int expectedRevision,
  }) async {
    await api.post(
      '/sales/manager-review/orders/${Uri.encodeComponent(orderId)}/reverse',
      body: {
        'decisionId': decisionId,
        'reason': reason,
        'expectedRevision': expectedRevision,
      },
    );
  }

  @override
  Future<void> reject(
    String orderId, {
    required String reason,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {
    await api.post(
      managerReview
          ? '/sales/manager-review/orders/${Uri.encodeComponent(orderId)}/reject'
          : ApiEndpoints.salesOrderFinanceReject(orderId),
      body: <String, dynamic>{
        'reason': reason.trim(),
        'expectedRevision': ?expectedRevision,
        'expectedClaimId': ?expectedClaimId,
      },
    );
  }
}

final salesOrderFinanceConfirmationRepositoryProvider =
    Provider<SalesOrderFinanceConfirmationRepository>(
      (ref) => DioSalesOrderFinanceConfirmationRepository(
        ref.watch(apiClientProvider),
      ),
    );

final salesManagerOrderReviewRepositoryProvider =
    Provider<DioSalesOrderFinanceConfirmationRepository>(
      (ref) => DioSalesOrderFinanceConfirmationRepository(
        ref.watch(apiClientProvider),
        managerReview: true,
      ),
    );

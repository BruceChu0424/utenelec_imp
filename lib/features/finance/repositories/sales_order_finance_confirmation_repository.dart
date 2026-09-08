import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/sales_order_finance_confirmation.dart';

/// 销售订货单财务确认（V294 闸门，V300 补驳回与审核详情）：
/// 待确认列表 / 徽标计数 / 审核详情 / 确认 / 驳回。
abstract interface class SalesOrderFinanceConfirmationRepository {
  /// 待确认任务分页。[rejected]：false=仅未驳回待办（默认）；true=仅已驳回；null=全部。
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
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
  const DioSalesOrderFinanceConfirmationRepository(this.api);

  final ApiClient api;

  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
  }) async {
    final normalizedKeyword = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.salesOrderFinanceConfirmationPending,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        'rejected': ?rejected,
        'changesOnly': ?changesOnly,
        if (normalizedKeyword != null && normalizedKeyword.isNotEmpty)
          'keyword': normalizedKeyword,
      },
    );
    return SalesOrderFinancePendingPage.fromJson(json);
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
    final json = await api.get(ApiEndpoints.salesOrderFinanceReview(orderId));
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
      ApiEndpoints.salesOrderFinanceConfirm(orderId),
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
      ApiEndpoints.salesOrderFinanceConfirmationBatch,
      body: <String, dynamic>{
        'orderIds': normalizedIds,
        'expectedRevisions': ?expectedRevisions,
        'expectedClaimIds': ?expectedClaimIds,
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
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
      ApiEndpoints.salesOrderFinanceReject(orderId),
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

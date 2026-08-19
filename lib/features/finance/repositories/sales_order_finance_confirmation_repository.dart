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
  });

  Future<int> pendingCount();

  /// 财务审核详情（专用审核页：订单 + 明细 + 客户财务快照）。
  Future<SalesOrderFinanceReview> review(String orderId);

  /// 财务确认（remark 可空）。成功无返回体；失败抛 ApiException。
  Future<void> confirm(String orderId, {String? remark});

  /// 财务驳回（reason 必填；不改订单状态/预留，通知归属销售修正）。
  Future<void> reject(String orderId, {required String reason});
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
  }) async {
    final json = await api.get(
      ApiEndpoints.salesOrderFinanceConfirmationPending,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        'rejected': ?rejected,
      },
    );
    return SalesOrderFinancePendingPage.fromJson(json);
  }

  @override
  Future<int> pendingCount() async {
    final json = await api.get(ApiEndpoints.salesOrderFinanceConfirmationCount);
    final nested = json['data'];
    final value = json['count'] ??
        (nested is Map ? nested['count'] : nested);
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
  Future<void> confirm(String orderId, {String? remark}) async {
    await api.post(
      ApiEndpoints.salesOrderFinanceConfirm(orderId),
      body: <String, dynamic>{
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
      },
    );
  }

  @override
  Future<void> reject(String orderId, {required String reason}) async {
    await api.post(
      ApiEndpoints.salesOrderFinanceReject(orderId),
      body: <String, dynamic>{'reason': reason.trim()},
    );
  }
}

final salesOrderFinanceConfirmationRepositoryProvider =
    Provider<SalesOrderFinanceConfirmationRepository>(
      (ref) => DioSalesOrderFinanceConfirmationRepository(
        ref.watch(apiClientProvider),
      ),
    );

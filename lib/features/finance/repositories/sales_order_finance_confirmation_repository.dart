import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/sales_order_finance_confirmation.dart';

/// 销售订货单财务确认（V294 闸门）：待确认列表 / 徽标计数 / 确认动作。
abstract interface class SalesOrderFinanceConfirmationRepository {
  Future<SalesOrderFinancePendingPage> pending({int page = 1, int size = 20});

  Future<int> pendingCount();

  /// 财务确认（remark 可空）。成功无返回体；失败抛 ApiException。
  Future<void> confirm(String orderId, {String? remark});
}

class DioSalesOrderFinanceConfirmationRepository
    implements SalesOrderFinanceConfirmationRepository {
  const DioSalesOrderFinanceConfirmationRepository(this.api);

  final ApiClient api;

  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get(
      ApiEndpoints.salesOrderFinanceConfirmationPending,
      query: <String, dynamic>{'page': page, 'size': size},
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
  Future<void> confirm(String orderId, {String? remark}) async {
    await api.post(
      ApiEndpoints.salesOrderFinanceConfirm(orderId),
      body: <String, dynamic>{
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/customer_prepayment.dart';

class CustomerPrepaymentRepository {
  const CustomerPrepaymentRepository(this.api);

  final ApiClient api;

  Future<CustomerPrepaymentPage> list({
    String? clientId,
    String? currencyId,
    String? salesOrderId,
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get(
      '/finance/customer-prepayments',
      query: {
        'page': page,
        'size': size,
        if (clientId?.trim().isNotEmpty == true) 'clientId': clientId,
        if (currencyId?.trim().isNotEmpty == true) 'currencyId': currencyId,
        if (salesOrderId?.trim().isNotEmpty == true)
          'salesOrderId': salesOrderId,
      },
    );
    return CustomerPrepaymentPage.fromJson(json);
  }

  Future<SalesOrderMoneySummary> salesOrderSummary(String salesOrderId) async {
    final json = await api.get(
      '/finance/customer-prepayments/sales-orders/$salesOrderId/summary',
    );
    return SalesOrderMoneySummary.fromJson(json);
  }

  Future<CustomerPrepaymentOffsetResult> apply({
    required String sourceLedgerId,
    required List<CustomerPrepaymentOffsetTarget> targets,
    required String reason,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      '/finance/customer-prepayment-offsets',
      body: {
        'sourceLedgerId': sourceLedgerId,
        'targets': targets.map((target) => target.toJson()).toList(),
        'reason': reason.trim(),
        'idempotencyKey': idempotencyKey,
      },
    );
    return CustomerPrepaymentOffsetResult.fromJson(json);
  }

  Future<CustomerPrepaymentOffsetResult> reverse({
    required String batchId,
    required int expectedVersion,
    required String reason,
  }) async {
    final json = await api.post(
      '/finance/customer-prepayment-offsets/$batchId/reverse',
      body: {'expectedVersion': expectedVersion, 'reason': reason.trim()},
    );
    return CustomerPrepaymentOffsetResult.fromJson(json);
  }
}

final customerPrepaymentRepositoryProvider =
    Provider<CustomerPrepaymentRepository>(
      (ref) => CustomerPrepaymentRepository(ref.watch(apiClientProvider)),
    );

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/finance_procurement_workflow.dart';

abstract interface class FinanceProcurementWorkflowRepository {
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
    FinanceProcurementOrderType? orderType,
  });

  Future<int> pendingApprovalCount();

  /// 待审任务按订货类型计数（全部/采购/委外筛选卡的全量口径）：{PURCHASE: n, ...}。
  Future<Map<String, int>> approvalTypeCounts();

  /// 页内审批：直接调采购/委外订货的审批端点（HTTP API 即公开契约，
  /// 不 import 各自 feature 的 repository，守 ADR 前端依赖图）。
  Future<void> approveOrder(
    FinanceProcurementOrderType orderType,
    String orderId,
    int expectedVersion,
  );

  Future<void> rejectOrder(
    FinanceProcurementOrderType orderType,
    String orderId,
    int expectedVersion,
    String reason,
  );
}

class DioFinanceProcurementWorkflowRepository
    implements FinanceProcurementWorkflowRepository {
  const DioFinanceProcurementWorkflowRepository(this.api);

  final ApiClient api;

  @override
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
    FinanceProcurementOrderType? orderType,
  }) async {
    final json = await api.get(
      ApiEndpoints.financeProcurementApprovalTasks,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (orderType != null &&
            orderType != FinanceProcurementOrderType.unknown)
          'orderType': orderType.name.toUpperCase(),
      },
    );
    return FinanceProcurementApprovalPage.fromJson(json);
  }

  @override
  Future<Map<String, int>> approvalTypeCounts() async {
    final json = await api.get(
      ApiEndpoints.financeProcurementApprovalTypeCounts,
    );
    return {
      for (final entry in (json as Map).entries)
        entry.key.toString(): (entry.value as num).toInt(),
    };
  }

  @override
  Future<int> pendingApprovalCount() async {
    final json = await api.get(ApiEndpoints.financeProcurementApprovalCount);
    final nested = json['data'];
    final value =
        json['count'] ??
        json['pendingCount'] ??
        json['total'] ??
        (nested is Map
            ? nested['count'] ?? nested['pendingCount'] ?? nested['total']
            : nested);
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
    return parsed < 0 ? 0 : parsed;
  }

  @override
  Future<void> approveOrder(
    FinanceProcurementOrderType orderType,
    String orderId,
    int expectedVersion,
  ) async {
    await api.post(
      _orderApprovePath(orderType, orderId),
      body: {'expectedVersion': expectedVersion},
    );
  }

  @override
  Future<void> rejectOrder(
    FinanceProcurementOrderType orderType,
    String orderId,
    int expectedVersion,
    String reason,
  ) async {
    await api.post(
      '${_orderApprovePath(orderType, orderId)}/reject',
      body: {'expectedVersion': expectedVersion, 'reason': reason.trim()},
    );
  }

  /// 采购/委外订货审批端点（与各自 feature repository 调用的同一后端契约）。
  static String _orderApprovePath(
    FinanceProcurementOrderType orderType,
    String orderId,
  ) {
    final segment = orderType == FinanceProcurementOrderType.purchase
        ? 'purchase'
        : 'subcontract';
    return '/$segment/orders/$orderId/approve';
  }
}

final financeProcurementWorkflowRepositoryProvider =
    Provider<FinanceProcurementWorkflowRepository>(
      (ref) =>
          DioFinanceProcurementWorkflowRepository(ref.watch(apiClientProvider)),
    );

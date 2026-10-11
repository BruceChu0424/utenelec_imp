import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../basic_data/models/master_facet.dart';
import '../models/finance_procurement_workflow.dart';

abstract interface class FinanceProcurementWorkflowRepository {
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
    FinanceProcurementOrderType? orderType,
    String? keyword,
    String? sort,
    String? order,
    String? billNo,
  });

  /// 待审任务订货单号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径。
  Future<List<MasterFacetBucket>> approvalBillNoFacets({
    FinanceProcurementOrderType? orderType,
    String? keyword,
  });

  /// 待审任务按订货类型计数（全部/采购/委外筛选卡的全量口径）：{PURCHASE: n, ...}。
  Future<Map<String, int>> approvalTypeCounts();

  /// 审核详情（财务专用视图）：订单头 + 供应商应付快照 + 明细 + 审批历史。
  Future<FinanceProcurementApprovalReview> review(String caseId);

  Future<void> approveOrdersBatch(
    List<FinanceProcurementDecisionItem> items, {
    String? remark,

    /// 财务通过时确认的记账汇率（2026-10-10 财务订货审批口径）：>0 才随请求
    /// 提交，落在本笔审批 case 上（V438 迁移冻结期间订单头汇率禁改）；
    /// 缺省不传，由服务端按 1 处理。
    double? exchangeRate,
  });

  Future<void> rejectOrdersBatch(
    List<FinanceProcurementDecisionItem> items,
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
    String? keyword,
    String? sort,
    String? order,
    String? billNo,
  }) async {
    final json = await api.get(
      ApiEndpoints.financeProcurementApprovalTasks,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (orderType != null &&
            orderType != FinanceProcurementOrderType.unknown)
          'orderType': orderType.name.toUpperCase(),
        if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
        // 2026-09-25 单号列统一：表头排序 + 订货单号表头值筛选。
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
        if (billNo != null && billNo.trim().isNotEmpty) 'billNo': billNo.trim(),
      },
    );
    return FinanceProcurementApprovalPage.fromJson(json);
  }

  @override
  Future<List<MasterFacetBucket>> approvalBillNoFacets({
    FinanceProcurementOrderType? orderType,
    String? keyword,
  }) async {
    final json = await api.get(
      ApiEndpoints.financeProcurementApprovalFacets,
      query: <String, dynamic>{
        if (orderType != null &&
            orderType != FinanceProcurementOrderType.unknown)
          'orderType': orderType.name.toUpperCase(),
        if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
      },
    );
    return parseFacetBuckets(json, 'billNo');
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
  Future<FinanceProcurementApprovalReview> review(String caseId) async {
    final json = await api.get(
      ApiEndpoints.financeProcurementApprovalReview(
        Uri.encodeComponent(caseId),
      ),
    );
    return FinanceProcurementApprovalReview.fromJson(json);
  }

  @override
  Future<void> approveOrdersBatch(
    List<FinanceProcurementDecisionItem> items, {
    String? remark,
    double? exchangeRate,
  }) async {
    await api.post(
      ApiEndpoints.financeProcurementApprovalBatchApprove,
      body: {
        'items': [for (final item in items) item.toJson()],
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
        // 汇率只随「通过」提交（驳回不改单不落汇率）；>0 才进请求体。
        if (exchangeRate != null && exchangeRate > 0)
          'exchangeRate': exchangeRate,
      },
    );
  }

  @override
  Future<void> rejectOrdersBatch(
    List<FinanceProcurementDecisionItem> items,
    String reason,
  ) async {
    await api.post(
      ApiEndpoints.financeProcurementApprovalBatchReject,
      body: {
        'items': [for (final item in items) item.toJson()],
        'reason': reason.trim(),
      },
    );
  }
}

final financeProcurementWorkflowRepositoryProvider =
    Provider<FinanceProcurementWorkflowRepository>(
      (ref) =>
          DioFinanceProcurementWorkflowRepository(ref.watch(apiClientProvider)),
    );

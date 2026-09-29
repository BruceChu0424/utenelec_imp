// 库存分析接口 (ADR-135 §7.4, /api/stock/insights/*, stock_report:view)。
//
// 仓库范围沿用仓库任务中心的「仓库范围」(warehouse.taskScope), 服务端同一口径解析:
// 指定仓 -> warehouseId (含子仓); 我的仓库 -> warehouseScope=MINE; 全部仓库不带参数。
// 称重异常与单重学习是货品级口径, 不按仓过滤。分页页码从 1 起, 回包平铺 {items, page, ...}。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../models/warehouse_insight.dart';

/// 库存分析列表的默认页大小。
const int warehouseInsightPageSize = 50;

class WarehouseInsightRepository {
  WarehouseInsightRepository(this.api);

  final ApiClient api;

  /// 仓库范围 -> 查询参数。
  static Map<String, String> scopeQuery(WarehouseTaskScope scope) =>
      switch (scope.mode) {
        WarehouseTaskScopeMode.all => const {},
        WarehouseTaskScopeMode.mine => const {'warehouseScope': 'MINE'},
        WarehouseTaskScopeMode.warehouse => {'warehouseId': scope.warehouseId!},
      };

  /// 呆滞与库龄 (含顶部 KPI 概览)。
  Future<InsightHealthResult> health({
    required WarehouseTaskScope scope,
    int page = 1,
    int size = warehouseInsightPageSize,
    String? keyword,
    String? abc,
    bool onlyDead = false,
    bool agedOver180 = false,
    String? sort,
    bool ascending = true,
  }) async {
    final json = await api.get(
      ApiEndpoints.stockInsightsHealth,
      query: {
        ...scopeQuery(scope),
        'page': page,
        'size': size,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        'abc': ?abc,
        if (onlyDead) 'onlyDead': true,
        if (agedOver180) 'agedOver180': true,
        if (sort != null) ...{
          'sort': sort,
          'order': ascending ? 'asc' : 'desc',
        },
      },
    );
    return InsightHealthResult.fromJson(json);
  }

  /// 今日建议盘点 (仓库 x 货品 x 颜色; 默认每仓每天最多 20 条)。
  Future<PagedResult<InsightCycleCountRow>> cycleCount({
    required WarehouseTaskScope scope,
    int page = 1,
    int size = warehouseInsightPageSize,
  }) async {
    final json = await api.get(
      ApiEndpoints.stockInsightsCycleCount,
      query: {...scopeQuery(scope), 'page': page, 'size': size},
    );
    return PagedResult.fromJson(json, InsightCycleCountRow.fromJson);
  }

  /// 称重异常 (近 [days] 天) + 供应商/车间汇总。
  Future<InsightWeightAlertsResult> weightAlerts({
    int days = 30,
    int page = 1,
    int size = warehouseInsightPageSize,
    String? kind,
    String? supplierId,
  }) async {
    final json = await api.get(
      ApiEndpoints.stockInsightsWeightAlerts,
      query: {
        'days': days,
        'page': page,
        'size': size,
        'kind': ?kind,
        'supplierId': ?supplierId,
      },
    );
    return InsightWeightAlertsResult.fromJson(json);
  }

  /// 单重学习清单 (批量称样上线用)。
  Future<PagedResult<InsightLearningRow>> learning({
    InsightLearningFilter filter = InsightLearningFilter.needsSample,
    String? keyword,
    int page = 1,
    int size = warehouseInsightPageSize,
  }) async {
    final json = await api.get(
      ApiEndpoints.stockInsightsLearning,
      query: {
        'filter': filter.code,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        'page': page,
        'size': size,
      },
    );
    return PagedResult.fromJson(json, InsightLearningRow.fromJson);
  }
}

final warehouseInsightRepositoryProvider = Provider<WarehouseInsightRepository>(
  (ref) => WarehouseInsightRepository(ref.watch(apiClientProvider)),
);

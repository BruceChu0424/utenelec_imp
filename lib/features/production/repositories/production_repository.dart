// 生产模块仓库（生产管理 / production）。
//
// 4 个仓库 + 4 个 Provider（底部）：
//   ① ProductionPlanRepository        — 计划单 CRUD + /approve + /reverse
//   ② ProductionPlanCostRepository    — BOM 成本只读（list/detail/aggregate；本期不重算）
//   ③ ProductionDailyReportRepository — 日报 CRUD + /approve + /reverse（空结构保未来）
//   ④ ProductionReportRepository      — 4 报表（明细分页 / 汇总 MV，裸数组返回）
//
// 端点（后端 @RequestMapping 全部在 /api/production/* 下，baseUrl 由 ApiClient 注入）：
//   GET    /production/plans                 列表（PageResponse<PlanListItem>）
//   GET    /production/plans/{id}            详情（PlanDetail）
//   POST   /production/plans                 新建（草稿）
//   PUT    /production/plans/{id}            编辑（仅草稿）
//   DELETE /production/plans/{id}            软删（仅草稿；已审需红冲）
//   POST   /production/plans/{id}/approve    审核 0→1
//   POST   /production/plans/{id}/reverse    红冲 1→-1
//   GET    /production/plan-costs            BOM 行分页（PageResponse<PlanCostRow>）
//   GET    /production/plan-costs/{id}       单 BOM 行
//   GET    /production/plan-costs/aggregate  汇总（裸数组 List<PlanCostAggregation>）
//   GET    /production/daily-reports         列表（PageResponse<DailyReportListItem>）
//   GET    /production/daily-reports/{id}    详情（DailyReportDetail）
//   POST   /production/daily-reports         新建（草稿）
//   PUT    /production/daily-reports/{id}    编辑（仅草稿）
//   DELETE /production/daily-reports/{id}    软删
//   POST   /production/daily-reports/{id}/approve
//   POST   /production/daily-reports/{id}/reverse
//   GET    /production/reports/plan/detail    List<PlanDetailRow>（分页）
//   GET    /production/reports/plan/summary   List<MonthlySummaryRow>
//   GET    /production/reports/daily/detail   List<DailyDetailRow>（分页，0 行）
//   GET    /production/reports/daily/summary  List<MonthlySummaryRow>（0 行）
//
// ⚠ 端点路径目前写死在仓库内（带 // ENDPOINT 注释），便于 grep；
//   共享接线时把它们搬到 lib/core/network/api_endpoints.dart（同 purchase 段）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_daily_report.dart';
import '../models/production_plan.dart';
import '../models/production_plan_cost.dart';
import '../models/production_report.dart';

// ───────────────────────── 生产计划单 ─────────────────────────

/// 生产计划单过滤参数（列表 query 拼装用）。
class ProductionPlanFilter {
  const ProductionPlanFilter({
    this.keyword,
    this.departmentId,
    this.status,
    this.closed,
    this.dateFrom,
    this.dateTo,
  });

  final String? keyword; // 模糊匹配 bill_no
  final String? departmentId;
  final int? status; // 0/1/-1
  final bool? closed; // is_closed
  final String? dateFrom; // yyyy-MM-dd
  final String? dateTo;

  Map<String, dynamic> toQuery() => <String, dynamic>{
        if (keyword != null && keyword!.trim().isNotEmpty) 'keyword': keyword!.trim(),
        if (departmentId != null) 'departmentId': departmentId,
        if (status != null) 'status': status,
        if (closed != null) 'closed': closed,
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
      };
}

class ProductionPlanRepository {
  ProductionPlanRepository(this.api);
  final ApiClient api;

  Future<PagedResult<ProductionPlanListItem>> list({
    int page = 1,
    int size = 20,
    ProductionPlanFilter filter = const ProductionPlanFilter(),
  }) async {
    final query = <String, dynamic>{'page': page, 'size': size, ...filter.toQuery()};
    final json = await api.get('/production/plans', query: query); // ENDPOINT
    return PagedResult.fromJson(json, ProductionPlanListItem.fromJson);
  }

  Future<ProductionPlanDetail> detail(String id) async {
    final json = await api.get('/production/plans/$id'); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<ProductionPlanDetail> create(Map<String, dynamic> body) async {
    final json = await api.post('/production/plans', body: body); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<ProductionPlanDetail> update(String id, Map<String, dynamic> body) async {
    final json = await api.put('/production/plans/$id', body: body); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete('/production/plans/$id'); // ENDPOINT
  }

  Future<ProductionPlanDetail> approve(String id) async {
    final json = await api.post('/production/plans/$id/approve'); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<ProductionPlanDetail> reverse(String id) async {
    final json = await api.post('/production/plans/$id/reverse'); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }
}

// ───────────────────────── 生产计划成本（BOM 展开，只读） ─────────────────────────

/// BOM 成本查询过滤（136 万行分区表，靠索引 + 分区裁剪；过滤驱动后端 SQL）。
class ProductionPlanCostFilter {
  const ProductionPlanCostFilter({
    this.planItemId,
    this.masterGoodsId,
    this.goodsId,
    this.parentId,
    this.supplierId,
    this.salesOrderCostItemId,
    this.dateFrom,
    this.dateTo,
  });

  /// 经 BillID 陷阱→production_plan_items.id（不是 plans.id）。
  final String? planItemId;
  final String? masterGoodsId; // 顶层成品（最常用，走 idx_ppc_mgoods）
  final String? goodsId; // 节点物料
  final String? parentId; // BOM 子树
  final String? supplierId; // 建议供应
  final String? salesOrderCostItemId; // 销售→生产成本溯源
  final String? dateFrom; // 分区裁剪
  final String? dateTo;

  Map<String, dynamic> toQuery() => <String, dynamic>{
        if (planItemId != null) 'planItemId': planItemId,
        if (masterGoodsId != null) 'masterGoodsId': masterGoodsId,
        if (goodsId != null) 'goodsId': goodsId,
        if (parentId != null) 'parentId': parentId,
        if (supplierId != null) 'supplierId': supplierId,
        if (salesOrderCostItemId != null)
          'salesOrderCostItemId': salesOrderCostItemId,
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
      };
}

/// BOM 成本只读仓库（本期严格只读；不做 BOM 展开/级联重算/MRP 需购量）。
class ProductionPlanCostRepository {
  ProductionPlanCostRepository(this.api);
  final ApiClient api;

  Future<PagedResult<ProductionPlanCostRow>> list({
    int page = 1,
    int size = 50,
    ProductionPlanCostFilter filter = const ProductionPlanCostFilter(),
  }) async {
    final query = <String, dynamic>{'page': page, 'size': size, ...filter.toQuery()};
    final json = await api.get('/production/plan-costs', query: query); // ENDPOINT
    return PagedResult.fromJson(json, ProductionPlanCostRow.fromJson);
  }

  Future<ProductionPlanCostRow> detail(String id) async {
    final json = await api.get('/production/plan-costs/$id'); // ENDPOINT
    return ProductionPlanCostRow.fromJson(json);
  }

  /// 按顶层成品上卷汇总（裸数组，非 PageResponse）。
  Future<List<ProductionPlanCostAggregation>> aggregate({
    String? masterGoodsId,
    String? planItemId,
    String? dateFrom,
    String? dateTo,
    int limit = 200,
  }) async {
    final query = <String, dynamic>{
      if (masterGoodsId != null) 'masterGoodsId': masterGoodsId,
      if (planItemId != null) 'planItemId': planItemId,
      if (dateFrom != null) 'dateFrom': dateFrom,
      if (dateTo != null) 'dateTo': dateTo,
      'limit': limit,
    };
    final list = await api.getList('/production/plan-costs/aggregate', query: query); // ENDPOINT
    return list
        .map((e) => ProductionPlanCostAggregation.fromJson(e))
        .toList();
  }
}

// ───────────────────────── 生产日报（空结构保未来） ─────────────────────────

class ProductionDailyReportFilter {
  const ProductionDailyReportFilter({
    this.keyword,
    this.warehouseId,
    this.departmentId,
    this.workerId,
    this.status,
    this.dateFrom,
    this.dateTo,
  });

  final String? keyword;
  final String? warehouseId;
  final String? departmentId;
  final String? workerId;
  final int? status;
  final String? dateFrom;
  final String? dateTo;

  Map<String, dynamic> toQuery() => <String, dynamic>{
        if (keyword != null && keyword!.trim().isNotEmpty) 'keyword': keyword!.trim(),
        if (warehouseId != null) 'warehouseId': warehouseId,
        if (departmentId != null) 'departmentId': departmentId,
        if (workerId != null) 'workerId': workerId,
        if (status != null) 'status': status,
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
      };
}

class ProductionDailyReportRepository {
  ProductionDailyReportRepository(this.api);
  final ApiClient api;

  Future<PagedResult<ProductionDailyReportListItem>> list({
    int page = 1,
    int size = 20,
    ProductionDailyReportFilter filter = const ProductionDailyReportFilter(),
  }) async {
    final query = <String, dynamic>{'page': page, 'size': size, ...filter.toQuery()};
    final json = await api.get('/production/daily-reports', query: query); // ENDPOINT
    return PagedResult.fromJson(json, ProductionDailyReportListItem.fromJson);
  }

  Future<ProductionDailyReportDetail> detail(String id) async {
    final json = await api.get('/production/daily-reports/$id'); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<ProductionDailyReportDetail> create(Map<String, dynamic> body) async {
    final json = await api.post('/production/daily-reports', body: body); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<ProductionDailyReportDetail> update(String id, Map<String, dynamic> body) async {
    final json = await api.put('/production/daily-reports/$id', body: body); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete('/production/daily-reports/$id'); // ENDPOINT
  }

  Future<ProductionDailyReportDetail> approve(String id) async {
    final json = await api.post('/production/daily-reports/$id/approve'); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<ProductionDailyReportDetail> reverse(String id) async {
    final json = await api.post('/production/daily-reports/$id/reverse'); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }
}

// ───────────────────────── 生产报表（4 入口） ─────────────────────────

/// 报表通用过滤（明细带分页 + 单号/状态；汇总仅日期 + limit）。
class ProductionReportFilter {
  const ProductionReportFilter({
    this.dateFrom,
    this.dateTo,
    this.goodsId,
    this.status,
    this.billNo,
    this.page = 1,
    this.size = 50,
    this.limit = 200,
  });

  final String? dateFrom;
  final String? dateTo;
  final String? goodsId;
  final int? status; // 明细：plan/daily 头 status
  final String? billNo; // 明细：精确匹配
  final int page;
  final int size;
  final int limit;

  Map<String, dynamic> toDetailQuery() => <String, dynamic>{
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
        if (goodsId != null) 'goodsId': goodsId,
        if (status != null) 'status': status,
        if (billNo != null && billNo!.trim().isNotEmpty) 'billNo': billNo!.trim(),
        'page': page,
        'size': size,
      };

  Map<String, dynamic> toSummaryQuery() => <String, dynamic>{
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
        'limit': limit,
      };
}

class ProductionReportRepository {
  ProductionReportRepository(this.api);
  final ApiClient api;

  /// 计划明细报表（分页，裸数组）。
  Future<List<ProductionPlanDetailReportRow>> planDetail({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList('/production/reports/plan/detail', query: filter.toDetailQuery()); // ENDPOINT
    return list.map(ProductionPlanDetailReportRow.fromJson).toList();
  }

  /// 计划汇总报表（MV doc_type='PLAN'）。
  Future<List<ProductionMonthlySummaryRow>> planSummary({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList('/production/reports/plan/summary', query: filter.toSummaryQuery()); // ENDPOINT
    return list.map(ProductionMonthlySummaryRow.fromJson).toList();
  }

  /// 日报明细报表（分页，0 行）。
  Future<List<ProductionDailyDetailReportRow>> dailyDetail({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList('/production/reports/daily/detail', query: filter.toDetailQuery()); // ENDPOINT
    return list.map(ProductionDailyDetailReportRow.fromJson).toList();
  }

  /// 日报汇总报表（MV doc_type='DAILY'，0 行）。
  Future<List<ProductionMonthlySummaryRow>> dailySummary({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList('/production/reports/daily/summary', query: filter.toSummaryQuery()); // ENDPOINT
    return list.map(ProductionMonthlySummaryRow.fromJson).toList();
  }
}

// ───────────────────────── Providers ─────────────────────────
// 4 个 plain Provider（无 family 参数，区别于 purchase 的 .family(docType)）。
// 命名带 Production 前缀避免与占位 mock 的 productionRepositoryProvider 冲突。

final productionPlanRepositoryProvider = Provider<ProductionPlanRepository>(
  (ref) => ProductionPlanRepository(ref.watch(apiClientProvider)),
);

final productionPlanCostRepositoryProvider =
    Provider<ProductionPlanCostRepository>(
  (ref) => ProductionPlanCostRepository(ref.watch(apiClientProvider)),
);

final productionDailyReportRepositoryProvider =
    Provider<ProductionDailyReportRepository>(
  (ref) => ProductionDailyReportRepository(ref.watch(apiClientProvider)),
);

final productionReportRepositoryProvider = Provider<ProductionReportRepository>(
  (ref) => ProductionReportRepository(ref.watch(apiClientProvider)),
);

/// 报表数据联合体（明细/汇总统一承载；页面按 reportType 分支取用）。
sealed class ProductionReportData {}

class ProductionReportDetailData extends ProductionReportData {
  ProductionReportDetailData(this.planRows, this.dailyRows);
  final List<ProductionPlanDetailReportRow> planRows;
  final List<ProductionDailyDetailReportRow> dailyRows;
}

class ProductionReportSummaryData extends ProductionReportData {
  ProductionReportSummaryData(this.rows);
  final List<ProductionMonthlySummaryRow> rows;
}

/// 通用加载入口（按 reportType 路由到具体端点；供 report page 调用）。
Future<ProductionReportData> loadProductionReport(
  ProductionReportType type,
  ProductionReportRepository repo,
  ProductionReportFilter filter,
) async {
  switch (type) {
    case ProductionReportType.planDetail:
      return ProductionReportDetailData(await repo.planDetail(filter: filter), const []);
    case ProductionReportType.dailyDetail:
      return ProductionReportDetailData(const [], await repo.dailyDetail(filter: filter));
    case ProductionReportType.planSummary:
      return ProductionReportSummaryData(await repo.planSummary(filter: filter));
    case ProductionReportType.dailySummary:
      return ProductionReportSummaryData(await repo.dailySummary(filter: filter));
  }
}

/// 沿用 purchase 的错误文案策略（ApiException 取 message，其余给中性提示）。
String productionErrorMessage(Object e, {String fallback = '操作失败，请稍后重试'}) =>
    e is ApiException ? e.message : fallback;

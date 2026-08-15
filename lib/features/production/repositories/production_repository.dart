// 生产模块仓库（生产管理 / production）。
//
// 3 个仓库 + 3 个 Provider（底部）：
//   ① ProductionPlanRepository        — 计划单 CRUD + /approve + /reverse
//   ② ProductionDailyReportRepository — 日报 CRUD + /approve + /reverse（空结构保未来）
//   ③ ProductionReportRepository      — 4 报表（明细分页 / 汇总 MV，裸数组返回）
//
// 端点（后端 @RequestMapping 全部在 /api/production/* 下，baseUrl 由 ApiClient 注入）：
//   GET    /production/plans                 列表（PageResponse<PlanListItem>）
//   GET    /production/plans/{id}            详情（PlanDetail）
//   POST   /production/plans                 新建（草稿）
//   PUT    /production/plans/{id}            编辑（仅草稿）
//   DELETE /production/plans/{id}            软删（仅草稿；已审需红冲）
//   POST   /production/plans/{id}/approve    审核 0→1
//   POST   /production/plans/{id}/reverse    红冲 1→-1
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
import '../../basic_data/models/master_facet.dart';
import '../models/production_daily_report.dart';
import '../models/production_execution_planning.dart';
import '../models/production_material_analysis.dart';
import '../models/production_plan.dart';
import '../models/production_report.dart';
import '../models/production_work_card.dart';
import '../models/reportable_plan_line.dart';

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
    if (keyword != null && keyword!.trim().isNotEmpty)
      'keyword': keyword!.trim(),
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

  static const _materialAnalysesBase = '/production/material-analyses';

  Future<PagedResult<ProductionPlanListItem>> list({
    int page = 1,
    int size = 20,
    ProductionPlanFilter filter = const ProductionPlanFilter(),
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      ...filter.toQuery(),
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
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

  Future<ProductionPlanDetail> update(
    String id,
    Map<String, dynamic> body,
  ) async {
    final json = await api.put('/production/plans/$id', body: body); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete('/production/plans/$id'); // ENDPOINT
  }

  /// 计划单向导预填（V192）：读取正式排产确认学习出的货品车间偏好。
  /// 返回 goodsId → (departmentId, departmentName)；无有效偏好的货品不在结果中。
  Future<Map<String, ({String departmentId, String? departmentName})>>
  defaultWorkshops(Set<String> goodsIds) async {
    if (goodsIds.isEmpty) return const {};
    // 200 个 UUID 加逗号 URL 编码后接近常见代理的 8KB request-line 上限；
    // 客户端用 100 分块留出路径、查询名与代理差异余量，服务端仍保留 200 硬上限。
    const requestLimit = 100;
    final orderedIds = goodsIds.toList(growable: false)..sort();
    final result = <String, ({String departmentId, String? departmentName})>{};
    for (var start = 0; start < orderedIds.length; start += requestLimit) {
      final proposedEnd = start + requestLimit;
      final end = proposedEnd < orderedIds.length
          ? proposedEnd
          : orderedIds.length;
      final list = await api.getList(
        '$_materialAnalysesBase/default-workshops', // ENDPOINT
        query: {'ids': orderedIds.sublist(start, end).join(',')},
      );
      for (final entry in list) {
        final goodsId = entry['goodsId'] as String?;
        final departmentId = entry['departmentId'] as String?;
        if (goodsId == null || departmentId == null) continue;
        result[goodsId] = (
          departmentId: departmentId,
          departmentName: entry['departmentName'] as String?,
        );
      }
    }
    return result;
  }

  Future<ProductionPlanDetail> approve(String id) async {
    final json = await api.post('/production/plans/$id/approve'); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<ProductionPlanDetail> reverse(String id) async {
    final json = await api.post('/production/plans/$id/reverse'); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  /// 生产进度看板（服务端分页）：closed=false 进行中（默认）/ true 已完成。
  /// sort=billDate|billDateDesc|deliveryDate|progress；dateFrom/dateTo 开单日期范围。
  Future<PagedResult<PlanProgressRow>> planProgress({
    bool closed = false,
    String sort = 'billDate',
    int page = 1,
    int size = 20,
    String keyword = '',
    String workshop = '',
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await api.get(
      '/production/plans/progress',
      query: {
        'closed': closed,
        'sort': sort,
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (workshop.isNotEmpty) 'workshop': workshop,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
      },
    ); // ENDPOINT
    return PagedResult.fromJson(json, PlanProgressRow.fromJson);
  }

  /// 进度看板汇总（同过滤、跨全部页）：{count, sumQty, sumInbound}。
  Future<Map<String, dynamic>> planProgressSummary({
    bool closed = false,
    String keyword = '',
    String workshop = '',
    String? dateFrom,
    String? dateTo,
  }) async {
    return api.get(
      '/production/plans/progress/summary',
      query: {
        'closed': closed,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (workshop.isNotEmpty) 'workshop': workshop,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
      },
    ); // ENDPOINT
  }

  /// 进度看板车间筛选选项（去重车间名，不受当前筛选影响）。
  Future<List<String>> planProgressWorkshops({bool closed = false}) async {
    final list = await api.getList(
      '/production/plans/progress/workshops',
      query: {'closed': closed},
    ); // ENDPOINT
    return [
      for (final e in list)
        if (e['name'] is String) e['name'] as String,
    ];
  }

  /// 看板标记（V127）：置顶 / 重要；传 null 的字段保持不变。
  Future<void> updatePlanFlags(
    String id, {
    bool? pinned,
    bool? important,
  }) async {
    await api.post(
      '/production/plans/$id/flags',
      body: {'pinned': ?pinned, 'important': ?important},
    ); // ENDPOINT
  }

  // ───────────────────────── MRP-lite（物料需求 → 采购申请） ─────────────────────────

  /// 物料需求预览：BOM 展开毛需求 − 库存 − 在途 = 净需求（自制件标记）。
  Future<List<MrpRow>> mrpPreview(String id) async {
    final list = await api.getList('/production/plans/$id/mrp'); // ENDPOINT
    return list.map(MrpRow.fromJson).toList();
  }

  /// 目标发料仓口径的齐套预览。服务端返回指纹和 READY/WAITING 执行段，
  /// 确认时必须原样回传，避免预览后库存变化导致重复占料。
  Future<ProductionPlanningPreview> planningExecutionPreview(
    String id,
    String warehouseId,
  ) async {
    final json = await api.get(
      '/production/plans/$id/mrp/planning-preview',
      query: {'warehouseId': warehouseId},
    ); // ENDPOINT
    return ProductionPlanningPreview.fromJson(json);
  }

  Future<ProductionPlanningConfirmResult> confirmExecutionPlanning(
    String id,
    ProductionPlanningConfirmRequest request,
  ) async {
    final json = await api.post(
      '/production/plans/$id/mrp/generate-planning-package',
      body: request.toJson(),
    ); // ENDPOINT
    return ProductionPlanningConfirmResult.fromJson(json);
  }

  Future<ProductionPlanningDraftView> planningDraft(String id) async {
    final json = await api.get(
      '/production/plans/$id/mrp/planning-draft',
    ); // ENDPOINT
    if (json.isEmpty) {
      throw ApiException('NOT_FOUND', '当前计划没有预排草案');
    }
    return ProductionPlanningDraftView.fromJson(json);
  }

  Future<ProductionPlanningDraftView> savePlanningDraft(
    String id,
    ProductionPlanningConfirmRequest request,
  ) async {
    final json = await api.put(
      '/production/plans/$id/mrp/planning-draft',
      body: request.toJson(),
    ); // ENDPOINT
    return ProductionPlanningDraftView.fromJson(json);
  }

  Future<ProductionPlanningConfirmResult> latestPlanningPackageResult(
    String id,
  ) async {
    final json = await api.get(
      '/production/plans/$id/mrp/planning-package-result',
    ); // ENDPOINT
    if (json.isEmpty) {
      throw ApiException('NOT_FOUND', '当前计划没有已确认的计划包');
    }
    return ProductionPlanningConfirmResult.fromJson(json);
  }

  Future<ProductionWorkCardView> productionWorkCards(
    String planId,
    String packageId,
  ) async {
    final json = await api.get(
      '/production/plans/$planId/planning-packages/$packageId/work-cards',
    ); // ENDPOINT
    if (json.isEmpty) {
      throw ApiException('NOT_FOUND', '当前计划包没有可打印的生产执行工卡');
    }
    return ProductionWorkCardView.fromJson(json);
  }

  Future<List<ProductionExecutionSegmentView>> executionSegments(
    String planId,
  ) async {
    final list = await api.getList(
      '/production/plans/$planId/execution-segments',
    ); // ENDPOINT
    return list.map(ProductionExecutionSegmentView.fromJson).toList();
  }

  Future<ProductionExecutionSegmentView> assignExecutionSegment(
    String planId,
    String segmentId, {
    required int expectedVersion,
    required String idempotencyKey,
    String? workshopDepartmentId,
    String? teamDepartmentId,
    String? responsibleEmployeeId,
    String? planBeginDate,
    String? planEndDate,
  }) async {
    final json = await api.patch(
      '/production/plans/$planId/execution-segments/$segmentId/assignment',
      body: {
        'expectedVersion': expectedVersion,
        'idempotencyKey': idempotencyKey,
        'workshopDepartmentId': workshopDepartmentId,
        'teamDepartmentId': teamDepartmentId,
        'responsibleEmployeeId': responsibleEmployeeId,
        'planBeginDate': planBeginDate,
        'planEndDate': planEndDate,
      },
    ); // ENDPOINT
    return ProductionExecutionSegmentView.fromJson(json);
  }

  Future<ProductionExecutionSegmentView> transitionExecutionSegment(
    String planId,
    String segmentId, {
    required String action,
    required int expectedVersion,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      '/production/plans/$planId/execution-segments/$segmentId/$action',
      body: {
        'expectedVersion': expectedVersion,
        'idempotencyKey': idempotencyKey,
      },
    ); // ENDPOINT
    return ProductionExecutionSegmentView.fromJson(json);
  }

  /// D3 订单物料分析：已审销售订货单直接 BOM 展开。
  Future<List<MrpRow>> mrpOrderPreview(String orderId) async {
    final list = await api.getList(
      '/production/mrp/order-preview',
      query: {'orderId': orderId},
    ); // ENDPOINT
    return list.map(MrpRow.fromJson).toList();
  }

  /// 按 BOM 毛需求生成生产领料单（草稿，需指定仓库）。
  Future<MrpGenerateResult> mrpGenerateDraw(
    String id,
    String warehouseId,
  ) async {
    final json = await api.post(
      '/production/plans/$id/mrp/generate-draw',
      body: {'warehouseId': warehouseId},
    ); // ENDPOINT
    return MrpGenerateResult.fromJson(json);
  }

  /// 按计划明细（排产量−已入库量）生成成品入库单（草稿，需指定仓库）。
  Future<MrpGenerateResult> mrpGenerateFinishedIn(
    String id,
    String warehouseId,
  ) async {
    final json = await api.post(
      '/production/plans/$id/mrp/generate-finished-in',
      body: {'warehouseId': warehouseId},
    ); // ENDPOINT
    return MrpGenerateResult.fromJson(json);
  }

  /// 已生成的自制件子计划溯源（父计划 MRP 面板展示，可跳子计划详情）。
  Future<List<MrpSubplanRef>> mrpSubplans(String id) async {
    final list = await api.getList(
      '/production/plans/$id/mrp/subplans',
    ); // ENDPOINT
    return list.map(MrpSubplanRef.fromJson).toList();
  }

  // ───────────────────────── 计划前物料分析 ─────────────────────────

  /// Object-scoped analysis task/history list. Server-side scope decides
  /// which owners are visible to the current employee.
  Future<PagedResult<MaterialAnalysisListItem>> materialAnalysisList({
    int page = 1,
    int size = 20,
    String keyword = '',
    String? status,
    String? sourceType,
  }) async {
    final json = await api.get(
      _materialAnalysesBase,
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (status?.trim().isNotEmpty == true) 'status': status!.trim(),
        if (sourceType?.trim().isNotEmpty == true)
          'sourceType': sourceType!.trim(),
      },
    ); // ENDPOINT
    return PagedResult.fromJson(json, MaterialAnalysisListItem.fromJson);
  }

  /// Production-scoped approved sales-order candidates. This endpoint omits
  /// price data and does not require broad sales module visibility.
  Future<MaterialAnalysisSalesCandidatePage> materialAnalysisSalesCandidates({
    int page = 1,
    int size = 20,
    String keyword = '',
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await api.get(
      '$_materialAnalysesBase/sales-candidates',
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
      },
    ); // ENDPOINT
    return MaterialAnalysisSalesCandidatePage.fromJson(json);
  }

  /// Loads the complete persisted joint analysis. Resume flows must not POST a
  /// subset of sources because that could change requested quantities or fail
  /// the server's source-set CAS validation.
  Future<ProductionMaterialAnalysisView> materialAnalysisDetail(
    String analysisId,
  ) async {
    final json = await api.get(
      '$_materialAnalysesBase/$analysisId',
    ); // ENDPOINT
    return ProductionMaterialAnalysisView.fromJson(json);
  }

  /// Creates or CAS-refreshes one joint analysis. BOM expansion, warehouse
  /// availability and readiness quantities are all server-owned facts.
  Future<ProductionMaterialAnalysisView> previewMaterialAnalysis({
    String? analysisId,
    int? expectedVersion,
    String? analysisFingerprint,
    required String warehouseId,
    required String idempotencyKey,
    required List<MaterialAnalysisSourceInput> sources,
  }) async {
    final json = await api.post(
      '$_materialAnalysesBase/preview',
      body: {
        'analysisId': ?analysisId,
        'version': ?expectedVersion,
        'fingerprint': ?analysisFingerprint,
        'warehouseId': warehouseId,
        'idempotencyKey': idempotencyKey,
        'sources': [for (final source in sources) source.toJson()],
      },
    ); // ENDPOINT
    return ProductionMaterialAnalysisView.fromJson(json);
  }

  Future<ProductionMaterialAnalysisView> updateMaterialAnalysisRoutes({
    required ProductionMaterialAnalysisView analysis,
    required String idempotencyKey,
    required List<MaterialRouteDecision> decisions,
  }) async {
    final json = await api.put(
      '$_materialAnalysesBase/${analysis.analysisId}/routes',
      body: {
        'version': analysis.version,
        'fingerprint': analysis.fingerprint,
        'idempotencyKey': idempotencyKey,
        'decisions': [for (final decision in decisions) decision.toJson()],
      },
    ); // ENDPOINT
    return ProductionMaterialAnalysisView.fromJson(json);
  }

  /// Changes only the pre-plan simulation order for shared free stock. The
  /// server recalculates readiness and does not create formal reservations.
  Future<ProductionMaterialAnalysisView> updateMaterialAllocationPriorities({
    required ProductionMaterialAnalysisView analysis,
    required String idempotencyKey,
    required List<MaterialAllocationPriorityInput> items,
  }) async {
    final json = await api.put(
      '$_materialAnalysesBase/${analysis.analysisId}/allocation-priorities',
      body: {
        'version': analysis.version,
        'fingerprint': analysis.fingerprint,
        'idempotencyKey': idempotencyKey,
        'items': [for (final item in items) item.toJson()],
      },
    ); // ENDPOINT
    return ProductionMaterialAnalysisView.fromJson(json);
  }

  /// 现货层借用（调货）：把 from 路径的已分配覆盖量调给 to 路径。
  /// 服务端重算齐套投影并返回最新分析视图。
  Future<ProductionMaterialAnalysisView> createMaterialAnalysisBorrow({
    required ProductionMaterialAnalysisView analysis,
    required String idempotencyKey,
    required String fromMaterialLineId,
    required String toMaterialLineId,
    required double qty,
    required String reason,
  }) async {
    final json = await api.post(
      '$_materialAnalysesBase/${analysis.analysisId}/borrows',
      body: {
        'version': analysis.version,
        'fingerprint': analysis.fingerprint,
        'idempotencyKey': idempotencyKey,
        'fromMaterialLineId': fromMaterialLineId,
        'toMaterialLineId': toMaterialLineId,
        'qty': qty,
        'reason': reason,
      },
    ); // ENDPOINT
    return ProductionMaterialAnalysisView.fromJson(json);
  }

  /// 撤销一笔 ACTIVE 借用，恢复基线分配投影。
  Future<ProductionMaterialAnalysisView> revokeMaterialAnalysisBorrow({
    required ProductionMaterialAnalysisView analysis,
    required String borrowId,
    required String idempotencyKey,
    required String reason,
  }) async {
    final json = await api.post(
      '$_materialAnalysesBase/${analysis.analysisId}/borrows/$borrowId/revoke',
      body: {
        'version': analysis.version,
        'fingerprint': analysis.fingerprint,
        'idempotencyKey': idempotencyKey,
        'reason': reason,
      },
    ); // ENDPOINT
    return ProductionMaterialAnalysisView.fromJson(json);
  }

  Future<ProductionMaterialAnalysisView> notifyMaterialAnalysis({
    required ProductionMaterialAnalysisView analysis,
    required String idempotencyKey,
    required MaterialSupplyRoute target,
    List<String> actionGroupKeys = const [],
    List<String> materialLineIds = const [],
  }) async {
    final json = await api.post(
      '$_materialAnalysesBase/${analysis.analysisId}/notify',
      body: {
        'version': analysis.version,
        'fingerprint': analysis.fingerprint,
        'idempotencyKey': idempotencyKey,
        'target': target.wireName,
        if (actionGroupKeys.isNotEmpty) 'actionGroupKeys': actionGroupKeys,
        if (materialLineIds.isNotEmpty) 'materialLineIds': materialLineIds,
      },
    ); // ENDPOINT
    return ProductionMaterialAnalysisView.fromJson(json);
  }

  /// Server-side final validation before plan generation. The returned
  /// preview fingerprint, not the analysis fingerprint, authorises generate.
  Future<ProductionMaterialPlanPreview> previewMaterialAnalysisPlan({
    required ProductionMaterialAnalysisView analysis,
    required String warehouseId,
    required List<MaterialAnalysisPlanItemInput> items,
    List<MaterialRouteDecision> routes = const [],
    List<MaterialBomOverride> bomOverrides = const [],
  }) async {
    final json = await api.post(
      '$_materialAnalysesBase/${analysis.analysisId}/plan-preview',
      body: {
        'version': analysis.version,
        'fingerprint': analysis.fingerprint,
        'warehouseId': warehouseId,
        'items': [for (final item in items) item.toQuantityJson()],
        if (routes.isNotEmpty)
          'routes': [for (final route in routes) route.toJson()],
        if (bomOverrides.isNotEmpty)
          'bomOverrides': [
            for (final override in bomOverrides) override.toJson(),
          ],
      },
    ); // ENDPOINT
    return ProductionMaterialPlanPreview.fromJson(json);
  }

  /// Atomically generates the selected batches after a successful server plan
  /// preview. Inventory changes between preview and submit fail with 409.
  Future<ProductionMaterialGenerateResult> generateMaterialAnalysisPlan({
    required ProductionMaterialPlanPreview preview,
    required String warehouseId,
    required String idempotencyKey,
    required String billDate,
    required List<MaterialAnalysisPlanItemInput> items,
    String? deliveryDate,
    String? departmentId,
    String? workshopName,
    String? workerId,
    bool approveNow = false,
    List<MaterialRouteDecision> routes = const [],
    List<MaterialBomOverride> bomOverrides = const [],
  }) async {
    final json = await api.post(
      '$_materialAnalysesBase/${preview.analysisId}/generate-plan',
      body: {
        'version': preview.version,
        'fingerprint': preview.analysisFingerprint,
        'previewFingerprint': preview.previewFingerprint,
        'warehouseId': warehouseId,
        'idempotencyKey': idempotencyKey,
        'billDate': billDate,
        'deliveryDate': ?deliveryDate,
        'departmentId': ?departmentId,
        'workshopName': ?workshopName,
        'workerId': ?workerId,
        'approveNow': approveNow,
        'items': [for (final item in items) item.toJson()],
        if (routes.isNotEmpty)
          'routes': [for (final route in routes) route.toJson()],
        if (bomOverrides.isNotEmpty)
          'bomOverrides': [
            for (final override in bomOverrides) override.toJson(),
          ],
      },
    ); // ENDPOINT
    return ProductionMaterialGenerateResult.fromJson(json);
  }

  // ───────────────────────── 调度工作台（业务链 · 排产段 V90） ─────────────────────────

  /// 待排产订单行（服务端分页；交货升序，urgent=距交货 ≤3 天；dateFrom/dateTo 交货日期范围）。
  Future<PagedResult<SchedulePendingRow>> schedulePending({
    int page = 1,
    int size = 20,
    String keyword = '',
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    String? status,
  }) async {
    final json = await api.get(
      '/production/schedule/pending',
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        'sort': ?sort,
        'order': ?order,
        'status': ?status,
      },
    ); // ENDPOINT
    return PagedResult.fromJson(json, SchedulePendingRow.fromJson);
  }

  /// 待排产状态 facets（表头值筛选用）：{status:[MasterFacetBucket]}（BOM缺失/紧急/正常）。
  Future<SchedulePendingFacets> schedulePendingFacets({
    String keyword = '',
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await api.get(
      '/production/schedule/pending/facets',
      query: {
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
      },
    ); // ENDPOINT
    return SchedulePendingFacets.fromJson(json);
  }

  /// 待排产计数（生产部工作台徽标）：{'count': n, 'urgent': m, 'overdue': k}。
  Future<Map<String, int>> schedulePendingCount() async {
    final json = await api.get(
      '/production/schedule/pending-count',
    ); // ENDPOINT
    return {
      'count': (json['count'] as num?)?.toInt() ?? 0,
      'urgent': (json['urgent'] as num?)?.toInt() ?? 0,
      'overdue': (json['overdue'] as num?)?.toInt() ?? 0,
    };
  }

  /// 已审订单明细 + 每行货品一层 BOM 零件（新建计划单「从订单带明细」用）。
  Future<List<ScheduleOrderLine>> scheduleOrderLines(String orderId) async {
    final list = await api.getList(
      '/production/schedule/order-lines',
      query: {'orderId': orderId},
    ); // ENDPOINT
    return list.map(ScheduleOrderLine.fromJson).toList();
  }

  /// 待排产 BOM 缺失 → 转发工程研发部（建研发任务 + 通知）。返回任务 id。
  Future<String> forwardToRd(String orderItemId, {String? note}) async {
    final json = await api.post(
      '/production/schedule/forward-rd',
      body: {
        'orderItemId': orderItemId,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    ); // ENDPOINT
    return json['taskId'] as String;
  }

  /// 一键批量转发 BOM 缺失（成品 + 自制组件）给工程研发部。
  /// 每货品按 goods 去重（研发每件只收一条）；当前计划员登记为每个货品的等待者。
  /// 返回 {created, reused, items:[{goodsId, taskId, isNew}]}。
  Future<Map<String, dynamic>> forwardToRdBatch(
    List<({String goodsId, String? orderItemId})> items, {
    String? note,
    String? sourcePlanId,
    String? sourcePlanNo,
  }) async {
    if (items.isEmpty) {
      return const {
        'created': 0,
        'reused': 0,
        'items': <Map<String, dynamic>>[],
      };
    }
    return Map<String, dynamic>.from(
      await api.post(
        '/production/schedule/forward-rd-batch',
        body: {
          'items': [
            for (final it in items)
              {
                'goodsId': it.goodsId,
                if (it.orderItemId != null) 'orderItemId': it.orderItemId,
              },
          ],
          if (note != null && note.isNotEmpty) 'note': note,
          'sourcePlanId': ?sourcePlanId,
          'sourcePlanNo': ?sourcePlanNo,
        },
      ),
    ); // ENDPOINT
  }

  /// D2 建议完工日期（历史日均完工×BOM 层级缓冲）。
  Future<Map<String, dynamic>> suggestFinish(Map<String, dynamic> body) async {
    final json = await api.post(
      '/production/schedule/suggest-finish',
      body: body,
    ); // ENDPOINT
    return Map<String, dynamic>.from(json as Map);
  }
}

/// 调度工作台待排产行（对应后端 PendingPlanRow）。
class SchedulePendingRow {
  const SchedulePendingRow({
    required this.orderItemId,
    required this.orderId,
    this.orderBillNo,
    this.clientName,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorName,
    this.unitName,
    this.qty,
    this.reservedQty,
    this.plannedQty,
    this.needQty,
    this.readyNowQty,
    this.readyByDateQty,
    this.readinessRatio,
    this.materialAnalysisId,
    this.materialAnalysisLineId,
    this.materialAnalysisStatus,
    this.materialAnalysisVersion,
    this.materialAnalyzedAt,
    this.analyzedQty,
    this.submittedPlanQty,
    this.approvedPlannedQty,
    this.deliverDate,
    this.chainStatus,
    this.bomReady = true,
    this.urgent = false,
    this.rdForwarded = false,
    this.myForward = false,
  });
  final String orderItemId;
  final String orderId;
  final String? orderBillNo;
  final String? clientName;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorName;
  final String? unitName;
  final double? qty;
  final double? reservedQty;
  final double? plannedQty;
  final double? needQty;

  /// Server-authoritative readiness facts. Nullable for older pending APIs.
  final double? readyNowQty;
  final double? readyByDateQty;
  final double? readinessRatio;
  final String? materialAnalysisId;
  final String? materialAnalysisLineId;
  final String? materialAnalysisStatus;
  final int? materialAnalysisVersion;
  final String? materialAnalyzedAt;
  final double? analyzedQty;
  final double? submittedPlanQty;
  final double? approvedPlannedQty;
  final String? deliverDate;
  final int? chainStatus;
  final bool bomReady;
  final bool urgent;

  /// 该货品已有人转发研发维护 BOM 且仍在等待（goods 级）。
  final bool rdForwarded;

  /// 当前登录计划员已登记为该货品的等待者（在 rd_task_forwarders 中）。
  final bool myForward;

  factory SchedulePendingRow.fromJson(
    Map<String, dynamic> j,
  ) => SchedulePendingRow(
    orderItemId: j['orderItemId'] as String,
    orderId: j['orderId'] as String,
    orderBillNo: j['orderBillNo'] as String?,
    clientName: j['clientName'] as String?,
    goodsId: j['goodsId'] as String?,
    goodsCode: j['goodsCode'] as String?,
    goodsName: j['goodsName'] as String?,
    spec: j['spec'] as String?,
    colorName: j['colorName'] as String?,
    unitName: j['unitName'] as String?,
    qty: (j['qty'] as num?)?.toDouble(),
    reservedQty: (j['reservedQty'] as num?)?.toDouble(),
    plannedQty: (j['plannedQty'] as num?)?.toDouble(),
    needQty: (j['needQty'] as num?)?.toDouble(),
    readyNowQty: (j['readyNowQty'] as num?)?.toDouble(),
    readyByDateQty: (j['readyByDateQty'] as num?)?.toDouble(),
    readinessRatio: _scheduleRatio(j['readinessRatio']),
    materialAnalysisId: j['materialAnalysisId'] as String?,
    materialAnalysisLineId: j['materialAnalysisLineId'] as String?,
    materialAnalysisStatus: j['materialAnalysisStatus'] as String?,
    materialAnalysisVersion: (j['materialAnalysisVersion'] as num?)?.toInt(),
    materialAnalyzedAt: (j['materialAnalyzedAt'] ?? j['analyzedAt']) as String?,
    analyzedQty: (j['analyzedQty'] as num?)?.toDouble(),
    submittedPlanQty: (j['submittedPlanQty'] as num?)?.toDouble(),
    approvedPlannedQty: (j['approvedPlannedQty'] as num?)?.toDouble(),
    deliverDate: j['deliverDate'] as String?,
    chainStatus: (j['chainStatus'] as num?)?.toInt(),
    bomReady: j['bomReady'] != false,
    urgent: j['urgent'] == true,
    rdForwarded: j['rdForwarded'] == true,
    myForward: j['myForward'] == true,
  );
}

double? _scheduleRatio(Object? raw) {
  final value = (raw as num?)?.toDouble();
  if (value == null) return null;
  return value > 1 ? value / 100 : value;
}

/// 待排产 facets（表头值筛选用）。当前仅 status 键：BOM缺失/紧急/正常 三桶。
/// 形状对齐主档 GoodsFacets（`fields: Map<key, List<MasterFacetBucket>>`），供 MasterDataTableView。
class SchedulePendingFacets {
  const SchedulePendingFacets({this.fields = const {}});

  final Map<String, List<MasterFacetBucket>> fields;

  factory SchedulePendingFacets.fromJson(Map<String, dynamic> json) {
    final fields = <String, List<MasterFacetBucket>>{};
    final status = json['status'];
    if (status is List) {
      fields['status'] = [
        for (final b in status)
          if (b is Map<String, dynamic>) MasterFacetBucket.fromJson(b),
      ];
    }
    return SchedulePendingFacets(fields: fields);
  }
}

/// 已审订单明细行（含一层 BOM 零件），对应后端 ScheduleOrderLine。
class ScheduleOrderLine {
  const ScheduleOrderLine({
    required this.orderItemId,
    this.lineNo,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.qty,
    this.plannedQty,
    this.needQty,
    this.unitRate,
    this.deliverDate,
    this.orderBillNo,
    this.clientName,
    this.bom = const [],
  });
  final String orderItemId;
  final int? lineNo;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double? qty;
  final double? plannedQty;
  final double? needQty;
  final double? unitRate;
  final String? deliverDate;
  final String? orderBillNo;
  final String? clientName;
  final List<ScheduleBomComponent> bom;

  factory ScheduleOrderLine.fromJson(Map<String, dynamic> j) =>
      ScheduleOrderLine(
        orderItemId: j['orderItemId'] as String,
        lineNo: (j['lineNo'] as num?)?.toInt(),
        goodsId: j['goodsId'] as String?,
        goodsCode: j['goodsCode'] as String?,
        goodsName: j['goodsName'] as String?,
        spec: j['spec'] as String?,
        colorId: j['colorId'] as String?,
        colorName: j['colorName'] as String?,
        unitId: j['unitId'] as String?,
        unitName: j['unitName'] as String?,
        qty: (j['qty'] as num?)?.toDouble(),
        plannedQty: (j['plannedQty'] as num?)?.toDouble(),
        needQty: (j['needQty'] as num?)?.toDouble(),
        unitRate: (j['unitRate'] as num?)?.toDouble(),
        deliverDate: j['deliverDate'] as String?,
        orderBillNo: j['orderBillNo'] as String?,
        clientName: j['clientName'] as String?,
        bom: [
          for (final b in (j['bom'] as List? ?? const []))
            ScheduleBomComponent.fromJson(b as Map<String, dynamic>),
        ],
      );
}

/// 货品一层 BOM 零件（单件用量 × 待排产缺口 = 需求小计）。
class ScheduleBomComponent {
  const ScheduleBomComponent({
    required this.goodsId,
    this.code,
    this.name,
    this.spec,
    this.perQty,
    this.needQty,
    this.onhand,
    this.selfMade = false,
  });
  final String goodsId;
  final String? code;
  final String? name;
  final String? spec;
  final double? perQty;
  final double? needQty;
  final double? onhand;
  final bool selfMade;

  factory ScheduleBomComponent.fromJson(Map<String, dynamic> j) =>
      ScheduleBomComponent(
        goodsId: j['goodsId'] as String,
        code: j['code'] as String?,
        name: j['name'] as String?,
        spec: j['spec'] as String?,
        perQty: (j['perQty'] as num?)?.toDouble(),
        needQty: (j['needQty'] as num?)?.toDouble(),
        onhand: (j['onhand'] as num?)?.toDouble(),
        selfMade: j['selfMade'] == true,
      );
}

/// 生产进度看板行（对应后端 PlanProgressRow）。
class PlanProgressRow {
  const PlanProgressRow({
    required this.planId,
    this.billNo,
    this.billDate,
    this.deliveryDate,
    this.workshopName,
    this.departmentId,
    this.lineCount = 0,
    this.totalQty,
    this.reportedQty,
    this.inboundQty,
    this.materialState,
    this.materialSegmentCount = 0,
    this.materialReadySegmentCount = 0,
    this.materialTotalQty,
    this.materialReadyQty,
    this.materialPercent,
    this.canStartNow = false,
    this.planBeginDate,
    this.planEndDate,
    this.percent = 0,
    this.closed = false,
    this.urgent = false,
    this.overdue = false,
    this.pinned = false,
    this.important = false,
    this.todayQty,
    this.subplans = const [],
  });
  final String planId;
  final String? billNo;
  final String? billDate;
  final String? deliveryDate;
  final String? workshopName;
  final String? departmentId;
  final int lineCount;
  final double? totalQty;
  final double? reportedQty;
  final double? inboundQty;
  final String? materialState;
  final int materialSegmentCount;
  final int materialReadySegmentCount;
  final double? materialTotalQty;
  final double? materialReadyQty;
  final double? materialPercent;
  final bool canStartNow;
  final String? planBeginDate;
  final String? planEndDate;
  final double percent;
  final bool closed;
  final bool urgent;
  final bool overdue;
  final bool pinned;
  final bool important;
  final double? todayQty;
  final List<SubPlanProgress> subplans;

  factory PlanProgressRow.fromJson(Map<String, dynamic> j) => PlanProgressRow(
    planId: j['planId'] as String,
    billNo: j['billNo'] as String?,
    billDate: j['billDate'] as String?,
    deliveryDate: j['deliveryDate'] as String?,
    workshopName: j['workshopName'] as String?,
    departmentId: j['departmentId'] as String?,
    lineCount: (j['lineCount'] as num?)?.toInt() ?? 0,
    totalQty: (j['totalQty'] as num?)?.toDouble(),
    reportedQty: (j['reportedQty'] as num?)?.toDouble(),
    inboundQty: (j['inboundQty'] as num?)?.toDouble(),
    materialState: j['materialState'] as String?,
    materialSegmentCount: (j['materialSegmentCount'] as num?)?.toInt() ?? 0,
    materialReadySegmentCount:
        (j['materialReadySegmentCount'] as num?)?.toInt() ?? 0,
    materialTotalQty: (j['materialTotalQty'] as num?)?.toDouble(),
    materialReadyQty: (j['materialReadyQty'] as num?)?.toDouble(),
    materialPercent: (j['materialPercent'] as num?)?.toDouble(),
    canStartNow: j['canStartNow'] == true,
    planBeginDate: j['planBeginDate'] as String?,
    planEndDate: j['planEndDate'] as String?,
    percent: (j['percent'] as num?)?.toDouble() ?? 0,
    closed: j['closed'] == true,
    urgent: j['urgent'] == true,
    overdue: j['overdue'] == true,
    pinned: j['pinned'] == true,
    important: j['important'] == true,
    todayQty: (j['todayQty'] as num?)?.toDouble(),
    subplans: [
      for (final s in (j['subplans'] as List? ?? const []))
        SubPlanProgress.fromJson(s as Map<String, dynamic>),
    ],
  );

  /// 看板标记本地乐观更新用（置顶/重要）。
  PlanProgressRow copyWith({bool? pinned, bool? important}) => PlanProgressRow(
    planId: planId,
    billNo: billNo,
    billDate: billDate,
    deliveryDate: deliveryDate,
    workshopName: workshopName,
    departmentId: departmentId,
    lineCount: lineCount,
    totalQty: totalQty,
    reportedQty: reportedQty,
    inboundQty: inboundQty,
    materialState: materialState,
    materialSegmentCount: materialSegmentCount,
    materialReadySegmentCount: materialReadySegmentCount,
    materialTotalQty: materialTotalQty,
    materialReadyQty: materialReadyQty,
    materialPercent: materialPercent,
    canStartNow: canStartNow,
    planBeginDate: planBeginDate,
    planEndDate: planEndDate,
    percent: percent,
    closed: closed,
    urgent: urgent,
    overdue: overdue,
    pinned: pinned ?? this.pinned,
    important: important ?? this.important,
    todayQty: todayQty,
    subplans: subplans,
  );
}

/// 子计划嵌套进度（对应后端 PlanProgressRow.SubProgress）。
class SubPlanProgress {
  const SubPlanProgress({
    required this.planId,
    this.billNo,
    this.workshopName,
    this.status,
    this.closed = false,
    this.totalQty,
    this.reportedQty,
    this.inboundQty,
    this.materialState,
    this.materialSegmentCount = 0,
    this.materialReadySegmentCount = 0,
    this.materialTotalQty,
    this.materialReadyQty,
    this.materialPercent,
    this.canStartNow = false,
    this.percent = 0,
  });
  final String planId;
  final String? billNo;
  final String? workshopName;
  final int? status;
  final bool closed;
  final double? totalQty;
  final double? reportedQty;
  final double? inboundQty;
  final String? materialState;
  final int materialSegmentCount;
  final int materialReadySegmentCount;
  final double? materialTotalQty;
  final double? materialReadyQty;
  final double? materialPercent;
  final bool canStartNow;
  final double percent;

  factory SubPlanProgress.fromJson(Map<String, dynamic> j) => SubPlanProgress(
    planId: j['planId'] as String,
    billNo: j['billNo'] as String?,
    workshopName: j['workshopName'] as String?,
    status: (j['status'] as num?)?.toInt(),
    closed: j['closed'] == true,
    totalQty: (j['totalQty'] as num?)?.toDouble(),
    reportedQty: (j['reportedQty'] as num?)?.toDouble(),
    inboundQty: (j['inboundQty'] as num?)?.toDouble(),
    materialState: j['materialState'] as String?,
    materialSegmentCount: (j['materialSegmentCount'] as num?)?.toInt() ?? 0,
    materialReadySegmentCount:
        (j['materialReadySegmentCount'] as num?)?.toInt() ?? 0,
    materialTotalQty: (j['materialTotalQty'] as num?)?.toDouble(),
    materialReadyQty: (j['materialReadyQty'] as num?)?.toDouble(),
    materialPercent: (j['materialPercent'] as num?)?.toDouble(),
    canStartNow: j['canStartNow'] == true,
    percent: (j['percent'] as num?)?.toDouble() ?? 0,
  );
}

/// MRP 预览行。旧字段保留兼容；新版字段显式区分账面、保留、安全库存、及时在途与净缺口。
class MrpRow {
  const MrpRow({
    required this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.gross,
    this.onhand,
    this.openPo,
    this.net,
    required this.selfMade,
    this.unitId,
    this.bookStock,
    this.salesReserved,
    this.safetyStock,
    this.availableNow,
    this.openPoTotal,
    this.openPoOnTime,
    this.needDate,
    this.earliestArrivalDate,
    this.purchaseNetShortage,
    this.timelyShortage,
    this.materialStatus,
    this.allocationBacked = false,
    this.planningWriteReady = false,
    this.isLegacyAvailability = false,
  });

  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;

  /// 旧口径：毛需求 / 账面库存 / 全部在途 / 采购总净缺口。
  final double? gross;
  final double? onhand;
  final double? openPo;
  final double? net;
  final bool selfMade;
  final String? unitId;

  /// 新口径：账面库存、销售锁定、安全库存和当前可用库存。
  final double? bookStock;
  final double? salesReserved;
  final double? safetyStock;
  final double? availableNow;

  /// 新口径：全部在途、需求日前能到的在途及日期信息。
  final double? openPoTotal;
  final double? openPoOnTime;
  final String? needDate;
  final String? earliestArrivalDate;

  /// 新口径：不考虑到货日/考虑到货日的净缺口。
  final double? purchaseNetShortage;
  final double? timelyShortage;

  /// READY / PARTIAL_SHORTAGE / SHORTAGE。
  final String? materialStatus;

  /// 是否已由统一原料占用账和采购供给挂接支撑。
  final bool allocationBacked;

  /// 是否允许基于本次 MRP 结果执行排产、采购和领料写操作。
  final bool planningWriteReady;

  /// 后端未返回完整新口径时为 true；UI 应明确显示兼容口径提示。
  final bool isLegacyAvailability;

  /// 只有齐套口径完整且供给已分配时才可作为排产数量。
  double? get planningShortage =>
      isLegacyAvailability || !allocationBacked || !planningWriteReady
      ? null
      : timelyShortage;

  String get statusLabel => switch (materialStatus) {
    'READY_NOW' => '可立即生产',
    'READY_BY_DATE' => '按期到料',
    'INBOUND_LATE' => '在途晚到',
    'PARTIAL' || 'PARTIAL_SHORTAGE' => '部分缺料',
    'SHORTAGE' => '缺料',
    'BOM_MISSING' => 'BOM 缺失',
    'READY' => '齐套',
    _ => '待复核',
  };

  factory MrpRow.fromJson(Map<String, dynamic> j) {
    const newKeys = <String>[
      'bookStock',
      'salesReserved',
      'safetyStock',
      'availableNow',
      'openPoTotal',
      'openPoOnTime',
      'purchaseNetShortage',
      'timelyShortage',
      'materialStatus',
    ];
    final legacy = newKeys.any((key) => !j.containsKey(key));

    return MrpRow(
      goodsId: j['goodsId'] as String,
      goodsCode: j['goodsCode'] as String?,
      goodsName: j['goodsName'] as String?,
      spec: j['spec'] as String?,
      colorId: j['colorId'] as String?,
      gross: (j['gross'] as num?)?.toDouble(),
      onhand: (j['onhand'] as num?)?.toDouble(),
      openPo: (j['openPo'] as num?)?.toDouble(),
      net: (j['net'] as num?)?.toDouble(),
      selfMade: j['selfMade'] == true,
      unitId: j['unitId'] as String?,
      bookStock: (j['bookStock'] as num?)?.toDouble(),
      salesReserved: (j['salesReserved'] as num?)?.toDouble(),
      safetyStock: (j['safetyStock'] as num?)?.toDouble(),
      availableNow: (j['availableNow'] as num?)?.toDouble(),
      openPoTotal: (j['openPoTotal'] as num?)?.toDouble(),
      openPoOnTime: (j['openPoOnTime'] as num?)?.toDouble(),
      needDate: j['needDate'] as String?,
      earliestArrivalDate: j['earliestArrivalDate'] as String?,
      purchaseNetShortage: (j['purchaseNetShortage'] as num?)?.toDouble(),
      timelyShortage: (j['timelyShortage'] as num?)?.toDouble(),
      materialStatus: j['materialStatus']?.toString(),
      allocationBacked: j['allocationBacked'] == true,
      planningWriteReady: j['planningWriteReady'] == true,
      isLegacyAvailability: legacy,
    );
  }
}

/// MRP 生成结果。
class MrpGenerateResult {
  const MrpGenerateResult({
    required this.requestId,
    required this.requestBillNo,
    required this.lineCount,
    this.skippedSelfMade = const [],
  });
  final String requestId;
  final String requestBillNo;
  final int lineCount;
  final List<String> skippedSelfMade;

  factory MrpGenerateResult.fromJson(Map<String, dynamic> j) =>
      MrpGenerateResult(
        requestId: j['requestId'] as String,
        requestBillNo: j['requestBillNo'] as String,
        lineCount: (j['lineCount'] as num).toInt(),
        skippedSelfMade: [
          for (final id in (j['skippedSelfMade'] as List? ?? const []))
            id.toString(),
        ],
      );
}

/// 自制件子计划溯源行（父计划 MRP 面板/详情页进度区展示用，含完工进度）。
class MrpSubplanRef {
  const MrpSubplanRef({
    required this.planId,
    this.billNo,
    this.status,
    this.closed = false,
    this.billDate,
    this.deliveryDate,
    this.totalQty,
    this.inboundQty,
    this.percent = 0,
  });
  final String planId;
  final String? billNo;
  final int? status; // 0草稿 1已审 -1红冲
  final bool closed;
  final String? billDate;
  final String? deliveryDate;
  final double? totalQty;
  final double? inboundQty;
  final double percent;

  factory MrpSubplanRef.fromJson(Map<String, dynamic> j) => MrpSubplanRef(
    planId: j['planId'] as String,
    billNo: j['billNo'] as String?,
    status: (j['status'] as num?)?.toInt(),
    closed: j['closed'] == true,
    billDate: j['billDate'] as String?,
    deliveryDate: j['deliveryDate'] as String?,
    totalQty: (j['totalQty'] as num?)?.toDouble(),
    inboundQty: (j['inboundQty'] as num?)?.toDouble(),
    percent: (j['percent'] as num?)?.toDouble() ?? 0,
  );
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
    if (keyword != null && keyword!.trim().isNotEmpty)
      'keyword': keyword!.trim(),
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
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      ...filter.toQuery(),
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json = await api.get(
      '/production/daily-reports',
      query: query,
    ); // ENDPOINT
    return PagedResult.fromJson(json, ProductionDailyReportListItem.fromJson);
  }

  Future<ProductionDailyReportDetail> detail(String id) async {
    final json = await api.get('/production/daily-reports/$id'); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<PagedResult<ReportablePlanLine>> reportablePlanLines({
    int page = 1,
    int size = 30,
    String? keyword,
    String? departmentId,
    String? executionSegmentId,
  }) async {
    final json = await api.get(
      '/production/daily-reports/reportable-plan-lines',
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (departmentId != null && departmentId.isNotEmpty)
          'departmentId': departmentId,
        if (executionSegmentId != null && executionSegmentId.isNotEmpty)
          'executionSegmentId': executionSegmentId,
      },
    );
    return PagedResult.fromJson(json, ReportablePlanLine.fromJson);
  }

  Future<ProductionDailyReportDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(
      '/production/daily-reports',
      body: body,
    ); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<ProductionDailyReportDetail> update(
    String id,
    Map<String, dynamic> body,
  ) async {
    final json = await api.put(
      '/production/daily-reports/$id',
      body: body,
    ); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete('/production/daily-reports/$id'); // ENDPOINT
  }

  Future<ProductionDailyReportDetail> approve(String id) async {
    final json = await api.post(
      '/production/daily-reports/$id/approve',
    ); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<ProductionDailyReportDetail> reverse(String id) async {
    final json = await api.post(
      '/production/daily-reports/$id/reverse',
    ); // ENDPOINT
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
    final list = await api.getList(
      '/production/reports/plan/detail',
      query: filter.toDetailQuery(),
    ); // ENDPOINT
    return list.map(ProductionPlanDetailReportRow.fromJson).toList();
  }

  /// 计划汇总报表（MV doc_type='PLAN'）。
  Future<List<ProductionMonthlySummaryRow>> planSummary({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList(
      '/production/reports/plan/summary',
      query: filter.toSummaryQuery(),
    ); // ENDPOINT
    return list.map(ProductionMonthlySummaryRow.fromJson).toList();
  }

  /// 日报明细报表（分页，0 行）。
  Future<List<ProductionDailyDetailReportRow>> dailyDetail({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList(
      '/production/reports/daily/detail',
      query: filter.toDetailQuery(),
    ); // ENDPOINT
    return list.map(ProductionDailyDetailReportRow.fromJson).toList();
  }

  /// 日报汇总报表（MV doc_type='DAILY'，0 行）。
  Future<List<ProductionMonthlySummaryRow>> dailySummary({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList(
      '/production/reports/daily/summary',
      query: filter.toSummaryQuery(),
    ); // ENDPOINT
    return list.map(ProductionMonthlySummaryRow.fromJson).toList();
  }
}

// ───────────────────────── Providers ─────────────────────────
// 3 个 plain Provider（无 family 参数，区别于 purchase 的 .family(docType)）。
// 命名带 Production 前缀避免与占位 mock 的 productionRepositoryProvider 冲突。

final productionPlanRepositoryProvider = Provider<ProductionPlanRepository>(
  (ref) => ProductionPlanRepository(ref.watch(apiClientProvider)),
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
      return ProductionReportDetailData(
        await repo.planDetail(filter: filter),
        const [],
      );
    case ProductionReportType.dailyDetail:
      return ProductionReportDetailData(
        const [],
        await repo.dailyDetail(filter: filter),
      );
    case ProductionReportType.planSummary:
      return ProductionReportSummaryData(
        await repo.planSummary(filter: filter),
      );
    case ProductionReportType.dailySummary:
      return ProductionReportSummaryData(
        await repo.dailySummary(filter: filter),
      );
  }
}

/// 沿用 purchase 的错误文案策略（ApiException 取 message，其余给中性提示）。
String productionErrorMessage(Object e, {String fallback = '操作失败，请稍后重试'}) =>
    e is ApiException ? e.message : fallback;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../basic_data/models/master_facet.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_execution_workbench.dart';

class ProductionExecutionWorkbenchRepository {
  ProductionExecutionWorkbenchRepository(this._api);

  final ApiClient _api;

  /// 2026-09-06 起列表不再携带车间参数（顶部筛选已下线，默认按计划完工日期
  /// 升序）。2026-09-25 单号列统一：关联订单列表头排序（sort 白名单 orders）
  /// 与值筛选（salesOrder 精确匹配 preview）。
  Future<PagedResult<ProductionExecutionWorkbenchGroup>> groups({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? sort,
    String? order,
    String? salesOrder,
  }) async {
    final json = await _api.get(
      '/production/execution-workbench',
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        'sort': ?sort,
        'order': ?order,
        if (salesOrder?.isNotEmpty == true) 'salesOrder': salesOrder,
      },
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchGroup.fromJson,
    );
  }

  /// 「进行中」关联订单列 facets（2026-09-25 单号列统一）：
  /// {orders:[MasterFacetBucket]}，与列表同一过滤上下文（不含 salesOrder 自身）。
  Future<Map<String, List<MasterFacetBucket>>> groupFacets({
    String keyword = '',
  }) async {
    final json = await _api.get(
      '/production/execution-workbench/facets',
      query: {if (keyword.trim().isNotEmpty) 'keyword': keyword.trim()},
    );
    final result = <String, List<MasterFacetBucket>>{};
    for (final entry in json.entries) {
      if (entry.value is List) {
        result[entry.key] = parseFacetBuckets(json, entry.key);
      }
    }
    return result;
  }

  // 2026-09-05 起删除 group()/workOrders() 客户端方法：
  // 它们只服务于「进行中」滑窗详情与外层直报（已下线——双击直达物料分析/计划
  // 详情，报工统一在 /production/workshop-tasks）。服务端端点保留兼容。

  /// 本批次关联单据（采购/委外申请与订货单、本批次计划树）——
  /// 计划详情页「本批次关联单据」卡片消费。
  Future<List<ProductionExecutionWorkbenchRelatedDocument>> relatedDocuments({
    required String rootType,
    required String rootId,
    int size = 100,
  }) async {
    final json = await _api.get(
      '/production/execution-workbench/$rootType/$rootId/related-documents',
      query: {'page': 1, 'size': size},
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchRelatedDocument.fromJson,
    ).items;
  }

  /// 车间任务列表。[dateFrom]/[dateTo]（yyyy-MM-dd）只对「历史任务」段
  /// （status=COMPLETED，服务端扩为 完工/取消/红冲 终态集）生效——ADR-066 §1.3
  /// 时间门控；活动段服务端忽略日期参数。
  /// 2026-09-25 单号列统一：analysisNo/segmentCode 表头值筛选 + sort 白名单
  /// （sourcePlan/order/segment）。
  Future<PagedResult<ProductionExecutionWorkbenchSegment>> workshopTasks({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? status,
    String? preparationFilter,
    String? routeFilter,
    String? workshopDepartmentId,
    String? dateFrom,
    String? dateTo,
    String? analysisNo,
    String? segmentCode,
    String? sort,
    String? order,
  }) async {
    final json = await _api.get(
      '/production/workshop-tasks',
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (status?.isNotEmpty == true) 'status': status,
        if (preparationFilter?.isNotEmpty == true)
          'preparationFilter': preparationFilter,
        // 「下一步」表头筛选(ADR-095)：UNCONFIRMED / FULL_KIT / CONTINUOUS / BATCH。
        if (routeFilter?.isNotEmpty == true) 'routeFilter': routeFilter,
        if (workshopDepartmentId?.isNotEmpty == true)
          'workshopDepartmentId': workshopDepartmentId,
        if (dateFrom?.isNotEmpty == true) 'dateFrom': dateFrom,
        if (dateTo?.isNotEmpty == true) 'dateTo': dateTo,
        if (analysisNo?.isNotEmpty == true) 'analysisNo': analysisNo,
        if (segmentCode?.isNotEmpty == true) 'segmentCode': segmentCode,
        'sort': ?sort,
        'order': ?order,
      },
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchSegment.fromJson,
    );
  }

  /// 我的车间任务单号列 facets（2026-09-25 单号列统一）：
  /// {sourcePlan:[MasterFacetBucket], segment:[MasterFacetBucket]}。
  Future<Map<String, List<MasterFacetBucket>>> workshopTaskFacets({
    String keyword = '',
    String? status,
    String? preparationFilter,
    String? routeFilter,
    String? workshopDepartmentId,
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await _api.get(
      '/production/workshop-tasks/facets',
      query: {
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (status?.isNotEmpty == true) 'status': status,
        if (preparationFilter?.isNotEmpty == true)
          'preparationFilter': preparationFilter,
        if (routeFilter?.isNotEmpty == true) 'routeFilter': routeFilter,
        if (workshopDepartmentId?.isNotEmpty == true)
          'workshopDepartmentId': workshopDepartmentId,
        if (dateFrom?.isNotEmpty == true) 'dateFrom': dateFrom,
        if (dateTo?.isNotEmpty == true) 'dateTo': dateTo,
      },
    );
    final result = <String, List<MasterFacetBucket>>{};
    for (final entry in json.entries) {
      if (entry.value is List) {
        result[entry.key] = parseFacetBuckets(json, entry.key);
      }
    }
    return result;
  }

  /// 本任务逐种物料事实(ADR-095)：只读，服务端按车间任务范围校验。
  Future<List<ProductionWorkshopTaskMaterial>> workshopTaskMaterials(
    String segmentId,
  ) async {
    final rows = await _api.getList(
      '/production/workshop-tasks/${Uri.encodeComponent(segmentId)}/materials',
    );
    return [
      for (final item in rows) ProductionWorkshopTaskMaterial.fromJson(item),
    ];
  }

  /// 催计划(ADR-117)：本任务缺的料里有计划还没下单的，提醒计划员去下单。
  /// 30 分钟内再点不再打扰计划员，返回 [WorkshopPlanningUrgeResult.notified] = false。
  Future<WorkshopPlanningUrgeResult> urgePlanning(String segmentId) async {
    final json = await _api.post(
      '/production/workshop-tasks/${Uri.encodeComponent(segmentId)}/planning-urge',
    );
    return WorkshopPlanningUrgeResult.fromJson(json);
  }
}

/// 一次催计划的结果。
class WorkshopPlanningUrgeResult {
  const WorkshopPlanningUrgeResult({
    required this.notified,
    this.urgeCount = 0,
    this.nextUrgeAllowedAt,
    this.gapKindCount = 0,
    this.gapSummary,
  });

  /// false = 30 分钟内刚催过，这次没有再提醒计划员。
  final bool notified;
  final int urgeCount;
  final DateTime? nextUrgeAllowedAt;
  final int gapKindCount;
  final String? gapSummary;

  factory WorkshopPlanningUrgeResult.fromJson(Map<String, dynamic> json) =>
      WorkshopPlanningUrgeResult(
        notified: json['notified'] == true,
        urgeCount: (json['urgeCount'] as num?)?.toInt() ?? 0,
        nextUrgeAllowedAt: DateTime.tryParse(
          json['nextUrgeAllowedAt'] as String? ?? '',
        ),
        gapKindCount: (json['gapKindCount'] as num?)?.toInt() ?? 0,
        gapSummary: json['gapSummary'] as String?,
      );
}

/// 车间任务分段计数：总数 + 与顶部分类一致的互斥分段
/// (等待物料/生产中/报工送检，相加=总数；报工送检=已报完未完工，2026-10-10 加)。
class WorkshopTaskCountBreakdown {
  const WorkshopTaskCountBreakdown({
    this.count = 0,
    this.preparing = 0,
    this.inProgress = 0,
    this.reportInspection = 0,
  });

  final int count;
  final int preparing;
  final int inProgress;
  final int reportInspection;

  // 值相等：徽章汇总每分钟换一份新对象，计数没变时不把「我的车间任务」整页重建。
  // 数字随工作台徽章汇总带回(ADR-108)，见 productionWorkshopTaskCountProvider。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkshopTaskCountBreakdown &&
          other.count == count &&
          other.preparing == preparing &&
          other.inProgress == inProgress &&
          other.reportInspection == reportInspection;

  @override
  int get hashCode =>
      Object.hash(count, preparing, inProgress, reportInspection);
}

final productionExecutionWorkbenchRepositoryProvider =
    Provider<ProductionExecutionWorkbenchRepository>(
      (ref) =>
          ProductionExecutionWorkbenchRepository(ref.watch(apiClientProvider)),
    );

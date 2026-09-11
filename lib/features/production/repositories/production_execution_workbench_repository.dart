import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_execution_workbench.dart';

class ProductionExecutionWorkbenchRepository {
  ProductionExecutionWorkbenchRepository(this._api);

  final ApiClient _api;

  /// 2026-09-06 起列表不再携带车间/排序参数（顶部筛选已下线，默认按计划
  /// 完工日期升序）；服务端查询参数保留兼容，客户端不再使用。
  Future<PagedResult<ProductionExecutionWorkbenchGroup>> groups({
    int page = 1,
    int size = 50,
    String keyword = '',
  }) async {
    final json = await _api.get(
      '/production/execution-workbench',
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      },
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchGroup.fromJson,
    );
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
  Future<PagedResult<ProductionExecutionWorkbenchSegment>> workshopTasks({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? status,
    String? workshopDepartmentId,
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await _api.get(
      '/production/workshop-tasks',
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (status?.isNotEmpty == true) 'status': status,
        if (workshopDepartmentId?.isNotEmpty == true)
          'workshopDepartmentId': workshopDepartmentId,
        if (dateFrom?.isNotEmpty == true) 'dateFrom': dateFrom,
        if (dateTo?.isNotEmpty == true) 'dateTo': dateTo,
      },
    );
    return PagedResult.fromJson(
      json,
      ProductionExecutionWorkbenchSegment.fromJson,
    );
  }

  /// 车间任务分段计数：总数 + 与顶部分类一致的互斥分段（等待物料/生产中，
  /// 相加=总数）。旧消费者只读 count 不受影响。
  Future<WorkshopTaskCountBreakdown> workshopTaskCount() async {
    final json = await _api.get('/production/workshop-tasks/count');
    return WorkshopTaskCountBreakdown.fromJson(json);
  }
}

class WorkshopTaskCountBreakdown {
  const WorkshopTaskCountBreakdown({
    this.count = 0,
    this.preparing = 0,
    this.inProgress = 0,
  });

  final int count;
  final int preparing;
  final int inProgress;

  factory WorkshopTaskCountBreakdown.fromJson(Map<String, dynamic> json) =>
      WorkshopTaskCountBreakdown(
        count: (json['count'] as num?)?.toInt() ?? 0,
        preparing: (json['preparing'] as num?)?.toInt() ?? 0,
        inProgress: (json['inProgress'] as num?)?.toInt() ?? 0,
      );

  // 2026-09-11 值相等：60s 轮询每次都 new 一个快照，没有 == 时
  // StateNotifier 每分钟都把「我的车间任务」整页重建一次（计数没变也重建）。
  // 有了 == 之后 notifier 里的 `if (breakdown != state)` 才能真正拦下来。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkshopTaskCountBreakdown &&
          other.count == count &&
          other.preparing == preparing &&
          other.inProgress == inProgress;

  @override
  int get hashCode => Object.hash(count, preparing, inProgress);
}

final productionExecutionWorkbenchRepositoryProvider =
    Provider<ProductionExecutionWorkbenchRepository>(
      (ref) =>
          ProductionExecutionWorkbenchRepository(ref.watch(apiClientProvider)),
    );

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/operations_workbench.dart';

abstract interface class OperationsWorkbenchGateway {
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  });
}

class OperationsWorkbenchRepository implements OperationsWorkbenchGateway {
  const OperationsWorkbenchRepository(this.api);

  final ApiClient api;

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) async {
    final json = await api.get(
      '/operations/workbench/${department.apiValue}',
      query: {
        'page': page,
        'size': size,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (status != null && status.isNotEmpty) 'status': status,
        if (exception != null && exception.isNotEmpty) 'exception': exception,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        'sort': ?sort,
        if (sort != null) 'order': order ?? 'asc',
        for (final entry in columnFilters.entries)
          if (entry.value != null) 'f.${entry.key}': entry.value,
        'issuedFrom': ?issuedFrom,
        'issuedTo': ?issuedTo,
        'needFrom': ?needFrom,
        'needTo': ?needTo,
      },
    );
    return OperationsWorkbenchData.fromJson(json, department);
  }

  /// 采购任务中心待办单据数（申请待分解 + 财务驳回），与采购管理角标同源。
  /// 「等待财务审核 / 财务已通过」不计入: 下一步在别人手上, 页面里走黄色在办徽章。
  Future<int> purchaseTaskCount() async => (await purchaseTaskCounts()).pending;

  /// 委外任务中心待办数（待分解 + 财务驳回），与委外管理角标同源。
  /// 2026-09-11 起「财务已通过·待采购完成」与「等待财务审核」不再计入——
  /// 下一步在别人手上，是监控数（见后端 countPending 的口径说明）。
  Future<int> subcontractTaskCount() async =>
      (await subcontractTaskCounts()).pending;

  /// 采购任务中心的两个数(ADR-100): pending = 等采购动手的单据数(红徽章),
  /// inProgress = 进行中段合计(等待财务审核 + 财务已通过 + 财务驳回, 黄徽章)。
  ///
  /// 两者不是互斥切片: 财务驳回的单既在跑(黄)又等本人改单重报(红), 这是两条链
  /// 对两个问题各自的答案, 不算双计(ADR-100 §2.3)。
  Future<({int pending, int inProgress})> purchaseTaskCounts() =>
      _taskCounts('purchase');

  /// 委外任务中心的两个数, 口径同 [purchaseTaskCounts]。
  Future<({int pending, int inProgress})> subcontractTaskCounts() =>
      _taskCounts('subcontract');

  /// `pending` 兼容旧字段名 `count`: 黄色上线前该端点只回一个待办数, 灰度期间
  /// 新旧服务端都要能读出红数字, 不能因为字段改名让角标掉成 0。
  Future<({int pending, int inProgress})> _taskCounts(String department) async {
    final json = await api.get('/operations/workbench/$department/count');
    final pending = (json['pending'] ?? json['count']) as num?;
    return (
      pending: pending?.toInt() ?? 0,
      inProgress: (json['inProgress'] as num?)?.toInt() ?? 0,
    );
  }
}

final operationsWorkbenchRepositoryProvider =
    Provider<OperationsWorkbenchRepository>(
      (ref) => OperationsWorkbenchRepository(ref.watch(apiClientProvider)),
    );

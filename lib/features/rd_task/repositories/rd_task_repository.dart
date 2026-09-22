// 工程研发部任务中心数据接入（后端 /api/rd-tasks）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/rd_task.dart';

class RdTaskRepository {
  const RdTaskRepository(this._api);

  final ApiClient _api;

  /// status: 'open'（OPEN/IN_PROGRESS）| 'done'（DONE/CANCELED）。
  Future<RdTaskData> load({
    required String status,
    String? category,
    String? keyword,
    String? assignee,
    int page = 1,
    int size = 20,
  }) async {
    final json = await _api.get(
      ApiEndpoints.rdTasks,
      query: {
        'status': status,
        if (category != null && category.isNotEmpty) 'category': category,
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        if (assignee != null && assignee.isNotEmpty) 'assignee': assignee,
        'page': page,
        'size': size,
      },
    );
    return RdTaskData.fromJson(json);
  }

  /// 还没人接手的任务数(红色待办徽章，ADR-100)。
  ///
  /// 读服务端的 `open` 而不是 `count`：`count` 是 `open + inProgress` 的旧口径，
  /// 红徽章读它就等于把「已认领在做」那半也喊成待办，而那半已经由黄色进行中徽章
  /// 单独数了一遍——同一批任务被两条累加链各数一次，正是 ADR-100 明令禁止的双计。
  /// (2026-09-21 发布前审查发现；同款问题在「车间生产任务」卡已按 `preparing` 改过。)
  Future<int> count() async {
    final json = await _api.get(ApiEndpoints.rdTaskCount);
    return (json['open'] as num?)?.toInt() ?? 0;
  }

  /// 已认领、正在做的任务数(黄色进行中徽章，ADR-100)。
  ///
  /// 与 [count] 同一端点：服务端一次就把 count / open / inProgress 都带回来，
  /// 红黄两支徽章各自常驻轮询、各读各的字段。
  Future<int> inProgressCount() async {
    final json = await _api.get(ApiEndpoints.rdTaskCount);
    return (json['inProgress'] as num?)?.toInt() ?? 0;
  }

  Future<RdTaskRow> resolve(
    String id,
    int expectedVersion,
    String? note,
  ) async {
    final json = await _api.post(
      ApiEndpoints.rdTaskResolve(id),
      body: {
        'expectedVersion': expectedVersion,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
    return RdTaskRow.fromJson(json);
  }

  Future<RdTaskRow> assign(String id, String? employeeId) async {
    final json = await _api.post(
      ApiEndpoints.rdTaskAssign(id),
      body: {'assigneeEmployeeId': ?employeeId},
    );
    return RdTaskRow.fromJson(json);
  }
}

final rdTaskRepositoryProvider = Provider<RdTaskRepository>(
  (ref) => RdTaskRepository(ref.watch(apiClientProvider)),
);

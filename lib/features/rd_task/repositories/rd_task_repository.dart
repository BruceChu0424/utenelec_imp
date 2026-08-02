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
    final json = await _api.get(ApiEndpoints.rdTasks, query: {
      'status': status,
      if (category != null && category.isNotEmpty) 'category': category,
      if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
      if (assignee != null && assignee.isNotEmpty) 'assignee': assignee,
      'page': page,
      'size': size,
    });
    return RdTaskData.fromJson(json);
  }

  Future<int> count() async {
    final json = await _api.get(ApiEndpoints.rdTaskCount);
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  Future<RdTaskRow> resolve(String id, int expectedVersion, String? note) async {
    final json = await _api.post(ApiEndpoints.rdTaskResolve(id), body: {
      'expectedVersion': expectedVersion,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    return RdTaskRow.fromJson(json);
  }

  Future<RdTaskRow> assign(String id, String? employeeId) async {
    final json = await _api.post(ApiEndpoints.rdTaskAssign(id), body: {
      'assigneeEmployeeId': ?employeeId,
    });
    return RdTaskRow.fromJson(json);
  }
}

final rdTaskRepositoryProvider = Provider<RdTaskRepository>(
  (ref) => RdTaskRepository(ref.watch(apiClientProvider)),
);

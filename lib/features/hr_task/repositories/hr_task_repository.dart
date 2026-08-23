// HR 任务中心数据接入（后端 /api/org/hr-tasks）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/hr_task_summary.dart';

class HrTaskRepository {
  const HrTaskRepository(this._api);

  final ApiClient _api;

  Future<HrTaskSummary> summary() async {
    final json = await _api.get(ApiEndpoints.hrTaskSummary);
    return HrTaskSummary.fromJson(json);
  }

  Future<int> count() async {
    final json = await _api.get(ApiEndpoints.hrTaskCount);
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  // ===== 任务软认领（ADR-021） =====

  /// 认领（幂等：自己已认领 = 续租；他人在租约内 = 409）。
  Future<void> claim(String taskType, String employeeId) => _api.post(
    ApiEndpoints.hrTaskClaims,
    body: {'taskType': taskType, 'employeeId': employeeId},
  );

  /// 释放（本人或持 employee:task_takeover 者；无有效认领时幂等成功）。
  Future<void> release(String taskType, String employeeId) =>
      _api.delete(ApiEndpoints.hrTaskClaim(taskType, employeeId));

  /// 接管（employee:task_takeover）：原认领强制释放，转由我认领。
  Future<void> takeover(String taskType, String employeeId) =>
      _api.post(ApiEndpoints.hrTaskClaimTakeover(taskType, employeeId));
}

final hrTaskRepositoryProvider = Provider<HrTaskRepository>(
  (ref) => HrTaskRepository(ref.watch(apiClientProvider)),
);

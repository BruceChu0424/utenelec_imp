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
}

final hrTaskRepositoryProvider = Provider<HrTaskRepository>(
  (ref) => HrTaskRepository(ref.watch(apiClientProvider)),
);

// 统一任务软认领数据接入（后端 /api/task-claims；ADR-023）。
// 纯 UX/防碰撞层：失败不抛出影响业务动作（后端守卫 requireNoActiveClaimByOther 是安全网）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/task_claim_view.dart';

class TaskClaimRepository {
  const TaskClaimRepository(this._api);

  final ApiClient _api;

  /// 某类型全部有效认领（key=targetKey）。列表装配「XX 处理中」用，一次请求。
  Future<Map<String, TaskClaimView>> activeClaims(String targetType) async {
    final json = await _api.get(ApiEndpoints.taskClaims(targetType));
    // 后端直接返回 {targetKey: view} 映射（兼容偶发 {claims: {...}} 包裹）。
    final raw = (json['claims'] is Map)
        ? json['claims'] as Map<String, dynamic>
        : json;
    final map = <String, TaskClaimView>{};
    raw.forEach((key, value) {
      final view = TaskClaimView.fromJson(value);
      if (view != null) map[key] = view;
    });
    return map;
  }

  /// 单个目标当前认领；无认领返回 null。
  Future<TaskClaimView?> activeClaim(
    String targetType,
    String targetKey,
  ) async {
    final json = await _api.get(ApiEndpoints.taskClaim(targetType, targetKey));
    return TaskClaimView.fromJson(json.isEmpty ? null : json);
  }

  /// 认领（自己已认领=续租；他人在租约内 → 后端 409）。失败吞掉（UX 层）。
  Future<TaskClaimView?> claim(String targetType, String targetKey) async {
    try {
      final json = await _api.post(
        ApiEndpoints.taskClaimClaim(targetType, targetKey),
      );
      return TaskClaimView.fromJson(json);
    } on Object {
      return null;
    }
  }

  /// 心跳续租（仅认领人）。
  Future<void> heartbeat(String targetType, String targetKey) async {
    try {
      await _api.post(ApiEndpoints.taskClaimHeartbeat(targetType, targetKey));
    } on Object {
      // 心跳失败忽略：租约过期后他人可接管，不影响正确性（后端守卫兜底）。
    }
  }

  /// 释放（本人；无认领时幂等）。
  Future<void> release(String targetType, String targetKey) async {
    try {
      await _api.delete(ApiEndpoints.taskClaim(targetType, targetKey));
    } on Object {
      // 释放失败忽略：租约会自然过期。
    }
  }
}

final taskClaimRepositoryProvider = Provider<TaskClaimRepository>(
  (ref) => TaskClaimRepository(ref.watch(apiClientProvider)),
);

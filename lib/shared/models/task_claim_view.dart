// 统一任务软认领视图（后端 TaskClaimService.TaskClaimView；ADR-023 show-as-locked）。
// 后端 GET /api/task-claims/{type}[/{key}] 返回；前端据此显示「XXX 处理中」徽标。
import 'package:flutter/foundation.dart';

@immutable
class TaskClaimView {
  const TaskClaimView({
    required this.targetType,
    required this.targetKey,
    required this.claimedBy,
    required this.claimedByName,
    required this.claimedByMe,
    required this.claimedAt,
    required this.leaseUntil,
  });

  final String targetType;
  final String targetKey;
  final String claimedBy; // 认领人 employeeId
  final String claimedByName;
  final bool claimedByMe;
  final DateTime claimedAt;
  final DateTime leaseUntil;

  /// 无认领时后端返回 null（200 + 空 body）。
  static TaskClaimView? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    return TaskClaimView(
      targetType: json['targetType'] as String? ?? '',
      targetKey: json['targetKey'] as String? ?? '',
      claimedBy: json['claimedBy'] as String? ?? '',
      claimedByName: json['claimedByName'] as String? ?? '同事',
      claimedByMe: json['claimedByMe'] as bool? ?? false,
      claimedAt:
          DateTime.tryParse(json['claimedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      leaseUntil:
          DateTime.tryParse(json['leaseUntil'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

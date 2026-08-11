import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';

String? employeeLeadershipLabel({
  required bool departmentManager,
  String? positionLevel,
  int? leaderRank,
}) {
  if (departmentManager || leaderRank == 0) return '负责人';
  if (positionLevel == '领导层' || leaderRank == 1) return '领导';
  if (positionLevel == '班组管理' || leaderRank == 2) return '班组管理';
  return null;
}

class EmployeeLeadershipBadge extends StatelessWidget {
  const EmployeeLeadershipBadge({
    super.key,
    required this.departmentManager,
    this.positionLevel,
    this.leaderRank,
  });

  final bool departmentManager;
  final String? positionLevel;
  final int? leaderRank;

  @override
  Widget build(BuildContext context) {
    final label = employeeLeadershipLabel(
      departmentManager: departmentManager,
      positionLevel: positionLevel,
      leaderRank: leaderRank,
    );
    if (label == null) return const SizedBox.shrink();
    return UtenStatusBadge(
      label: label,
      icon: departmentManager
          ? Icons.supervisor_account_rounded
          : Icons.workspace_premium_outlined,
      type: departmentManager
          ? UtenStatusBadgeType.accent
          : UtenStatusBadgeType.info,
      size: UtenStatusBadgeSize.small,
    );
  }
}

// EmployeeStatusBadge - 员工状态 → UtenStatusBadge（业务映射层）
// 文档：docs/02-组件库/UtenStatusBadge.md
// 把员工状态枚举映射为统一徽章；改这里全站员工状态视觉一起变。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';

class EmployeeStatusBadge extends StatelessWidget {
  const EmployeeStatusBadge({
    super.key,
    required this.status,
    this.size = UtenStatusBadgeSize.small,
  });

  final String? status;

  final UtenStatusBadgeSize size;

  @override
  Widget build(BuildContext context) {
    return UtenStatusBadge(label: _label, type: _type, size: size);
  }

  String get _label => const {
        'active': '在职',
        'probation': '试用',
        'onLeave': '休假',
        'resigned': '离职',
      }[status ?? ''] ??
      '未知';

  UtenStatusBadgeType get _type => switch (status) {
        'active' => UtenStatusBadgeType.success,
        'probation' => UtenStatusBadgeType.warning,
        'onLeave' => UtenStatusBadgeType.info,
        'resigned' => UtenStatusBadgeType.neutral,
        _ => UtenStatusBadgeType.neutral,
      };
}

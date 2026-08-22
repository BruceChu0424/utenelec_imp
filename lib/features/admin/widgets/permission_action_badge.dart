import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permission_action_type.dart';

/// 由后端权限目录动作分类驱动的紧凑徽标。
class PermissionActionBadge extends StatelessWidget {
  const PermissionActionBadge({super.key, required this.actionType});

  final PermissionActionType actionType;

  @override
  Widget build(BuildContext context) => UtenStatusBadge(
    label: actionType.label,
    type: _badgeType(actionType),
    icon: _icon(actionType),
    size: UtenStatusBadgeSize.small,
  );
}

/// 权限名称、动作徽标和边界说明的统一目录行标题。
class PermissionTitleBlock extends StatelessWidget {
  const PermissionTitleBlock({
    super.key,
    required this.name,
    required this.actionType,
    this.description,
    this.nameStyle,
  });

  final String name;
  final PermissionActionType actionType;
  final String? description;
  final TextStyle? nameStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = description?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(name, style: nameStyle),
            PermissionActionBadge(actionType: actionType),
          ],
        ),
        if (detail.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s4),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

UtenStatusBadgeType _badgeType(PermissionActionType type) => switch (type) {
  PermissionActionType.view => UtenStatusBadgeType.info,
  PermissionActionType.create => UtenStatusBadgeType.success,
  PermissionActionType.edit => UtenStatusBadgeType.accent,
  PermissionActionType.delete => UtenStatusBadgeType.danger,
  PermissionActionType.approve => UtenStatusBadgeType.warning,
  PermissionActionType.importData => UtenStatusBadgeType.info,
  PermissionActionType.exportData => UtenStatusBadgeType.info,
  PermissionActionType.execute => UtenStatusBadgeType.warning,
  PermissionActionType.configure => UtenStatusBadgeType.accent,
  PermissionActionType.assign => UtenStatusBadgeType.accent,
  PermissionActionType.other => UtenStatusBadgeType.neutral,
};

IconData _icon(PermissionActionType type) => switch (type) {
  PermissionActionType.view => Icons.visibility_outlined,
  PermissionActionType.create => Icons.add_circle_outline_rounded,
  PermissionActionType.edit => Icons.edit_outlined,
  PermissionActionType.delete => Icons.delete_outline_rounded,
  PermissionActionType.approve => Icons.fact_check_outlined,
  PermissionActionType.importData => Icons.file_upload_outlined,
  PermissionActionType.exportData => Icons.file_download_outlined,
  PermissionActionType.execute => Icons.play_circle_outline_rounded,
  PermissionActionType.configure => Icons.tune_rounded,
  PermissionActionType.assign => Icons.person_add_alt_1_outlined,
  PermissionActionType.other => Icons.more_horiz_rounded,
};

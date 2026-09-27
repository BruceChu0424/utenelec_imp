import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_tokens.dart';
import '../../shared/badges/badge_scope.dart';
import 'uten_in_progress_badge.dart';
import 'uten_notification_badge.dart';

/// 根据声明的范围订阅红黄计数，统一顺序、零值隐藏与间距。
/// 专用逾期/异常/读屏展示可覆盖单种颜色，不影响另一种颜色的公共取数。
class UtenScopedBadges extends ConsumerWidget {
  const UtenScopedBadges({
    super.key,
    required this.scope,
    this.showLabel = false,
    this.todoOverride,
    this.inProgressOverride,
  });

  final BadgeScope scope;
  final bool showLabel;
  final Widget? todoOverride;
  final Widget? inProgressOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(badgeScopeCountsProvider(scope));
    final todo =
        todoOverride ??
        (counts.todo > 0
            ? UtenNotificationBadge(count: counts.todo, showLabel: showLabel)
            : null);
    final inProgress =
        inProgressOverride ??
        (counts.inProgress > 0
            ? UtenInProgressBadge(
                count: counts.inProgress,
                showLabel: showLabel,
              )
            : null);
    if (todo == null && inProgress == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?inProgress,
        // 专用组件可能保留零值读屏节点；计数为零时仍不留下颜色间距。
        if (inProgress != null &&
            todo != null &&
            counts.inProgress > 0 &&
            counts.todo > 0)
          const SizedBox(width: UtenSpacing.s6),
        ?todo,
      ],
    );
  }
}

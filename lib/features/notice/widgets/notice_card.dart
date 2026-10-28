import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/notice.dart';
import '../models/notice_group.dart';
import 'celebration_subjects.dart';
import 'notice_interaction_footer.dart';

/// One visual contract for the inbox and the cards unfolded from a stack.
/// Reading, acknowledging and completing a business task remain separate actions.
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.notice,
    required this.onTap,
    this.onLongPress,
    this.onAcknowledge,
    this.selecting = false,
    this.checked = false,
    this.unread,
    this.groupCount,
    this.groupUnread = 0,
    this.priority,
    this.resolved,
    this.showInteractions = true,
  });

  final Notice notice;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final FutureOr<void> Function()? onAcknowledge;
  final bool selecting;
  final bool checked;
  final bool? unread;
  final int? groupCount;
  final int groupUnread;
  final NoticePriority? priority;
  final bool? resolved;
  final bool showInteractions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isUnread = unread ?? !notice.isRead;
    final isResolved = resolved ?? notice.isResolved;
    final effectivePriority = priority ?? notice.priority;
    final accent = notice.type == NoticeType.urgent
        ? notice.type.color
        : effectivePriority.showBadge
        ? effectivePriority.color
        : notice.type.color;
    final grouped = (groupCount ?? 0) > 1;
    final typeColor = _readableColor(
      context,
      notice.type.color,
      scheme.surface,
    );

    return Semantics(
      button: true,
      selected: selecting ? checked : null,
      child: Opacity(
        opacity: isResolved ? 0.64 : 1,
        child: UtenCard(
          padding: EdgeInsets.zero,
          selected: selecting && checked,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(height: UtenSpacing.s4, color: accent),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: UtenSpacing.s48,
                          height: UtenSpacing.s48,
                          decoration: BoxDecoration(
                            color: notice.type.color.withValues(alpha: 0.12),
                            borderRadius: UtenRadius.lgAll,
                          ),
                          child: Icon(
                            notice.type.icon,
                            color: typeColor,
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                notice.type.label,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: typeColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: UtenSpacing.s2),
                              Text(
                                notice.type.isWork
                                    ? '业务消息'
                                    : notice.type.isCelebratory
                                    ? '同事庆典'
                                    : notice.sourceEvent == null &&
                                          notice.type != NoticeType.system
                                    ? '公司通知'
                                    : '系统提醒',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        if (selecting)
                          Icon(
                            checked
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked,
                            color: checked ? scheme.primary : scheme.outline,
                            semanticLabel: checked ? '已选择' : '未选择',
                          )
                        else if (grouped)
                          Tooltip(
                            message: '$groupCount 条相关通知，点击展开',
                            child: Container(
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: UtenSpacing.s8,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: UtenRadius.pillAll,
                              ),
                              child: Text(
                                '$groupCount',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color:
                                      ThemeData.estimateBrightnessForColor(
                                            accent,
                                          ) ==
                                          Brightness.dark
                                      ? Colors.white
                                      : Colors.black,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          )
                        else if (isUnread)
                          Padding(
                            padding: const EdgeInsets.only(top: UtenSpacing.s4),
                            child: Text(
                              '未读',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.error,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (effectivePriority.showBadge ||
                        notice.type == NoticeType.urgent ||
                        notice.topPriority ||
                        isResolved ||
                        notice.kind == NoticeKind.todo) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      Wrap(
                        spacing: UtenSpacing.s6,
                        runSpacing: UtenSpacing.s6,
                        children: [
                          if (effectivePriority.showBadge ||
                              notice.type == NoticeType.urgent)
                            _Status(
                              label: effectivePriority.showBadge
                                  ? effectivePriority.label
                                  : '紧急',
                              icon: Icons.priority_high_rounded,
                              color: effectivePriority.showBadge
                                  ? effectivePriority.color
                                  : notice.type.color,
                            ),
                          if (notice.topPriority)
                            _Status(
                              label: '置顶',
                              icon: Icons.push_pin_rounded,
                              color: scheme.onSurfaceVariant,
                            ),
                          if (isResolved)
                            _Status(
                              label: '已办结',
                              icon: Icons.task_alt_rounded,
                              color: scheme.onSurfaceVariant,
                            )
                          else if (notice.kind == NoticeKind.todo && !grouped)
                            _Status(
                              label: notice.taskCompleted ? '待办已完成' : '待办',
                              icon: notice.taskCompleted
                                  ? Icons.task_alt_rounded
                                  : Icons.pending_actions_rounded,
                              color: notice.taskCompleted
                                  ? scheme.primary
                                  : scheme.error,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s16),
                    Text(
                      notice.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: isUnread
                            ? FontWeight.w800
                            : FontWeight.w600,
                        height: 1.45,
                      ),
                    ),
                    if (notice.isGroupCelebration) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      CelebrationSubjectChips(
                        subjects: notice.subjects,
                        showEventLabel: notice.type == NoticeType.anniversary,
                        accent: notice.type.color,
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      notice.content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.65,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s20),
                    Wrap(
                      spacing: UtenSpacing.s12,
                      runSpacing: UtenSpacing.s6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          notice.publisher,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _formatTime(notice.publishedAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    if (grouped) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      Divider(height: 1, color: accent.withValues(alpha: 0.2)),
                      const SizedBox(height: UtenSpacing.s12),
                      Wrap(
                        spacing: UtenSpacing.s8,
                        runSpacing: UtenSpacing.s6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Icon(
                            Icons.layers_rounded,
                            size: 18,
                            color: typeColor,
                          ),
                          Text(
                            '共 $groupCount 条${groupUnread > 0 ? ' · $groupUnread 未读' : ' · 全部已读'}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: typeColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '展开查看',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ] else if (showInteractions &&
                        !selecting &&
                        notice.interactionMode !=
                            NoticeInteractionMode.none) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      NoticeInteractionFooter(
                        notice: notice,
                        onOpenDetail: onTap,
                        onAcknowledge: onAcknowledge,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatTime(DateTime value) {
  final diff = ChinaDateTime.now().difference(value);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${ChinaDateTime.formatDate(value)}(北京)';
}

class _Status extends StatelessWidget {
  const _Status({required this.label, required this.icon, required this.color});
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final background = Color.alphaBlend(
      color.withValues(alpha: 0.1),
      Theme.of(context).colorScheme.surface,
    );
    final ink = _readableColor(context, color, background);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: ink),
          const SizedBox(width: UtenSpacing.s4),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color _readableColor(BuildContext context, Color color, Color background) {
  final target = Theme.of(context).colorScheme.onSurface;
  final baseLuminance = background.computeLuminance();
  for (var step = 0; step <= 10; step++) {
    final candidate = Color.lerp(color, target, step / 10)!;
    final luminance = candidate.computeLuminance();
    final contrast =
        (math.max(luminance, baseLuminance) + 0.05) /
        (math.min(luminance, baseLuminance) + 0.05);
    if (contrast >= 4.5) return candidate;
  }
  return target;
}

/// A stack retains the highest active priority even if its newest message is routine.
class NoticeStackCard extends StatelessWidget {
  const NoticeStackCard({
    super.key,
    required this.group,
    required this.onTap,
    this.onLongPress,
    this.selecting = false,
    this.checked = false,
  });
  final NoticeGroup group;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selecting;
  final bool checked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final depth = math.min(2, group.notices.length - 1);
    final active = group.notices.where((notice) => !notice.isResolved);
    final priority = active.fold(
      NoticePriority.normal,
      (value, notice) => notice.type == NoticeType.urgent
          ? NoticePriority.urgent
          : notice.priority.index > value.index
          ? notice.priority
          : value,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: depth * UtenSpacing.s8),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var layer = depth; layer > 0; layer--)
            Positioned.fill(
              top: layer * UtenSpacing.s8,
              bottom: -layer * UtenSpacing.s8,
              left: layer * UtenSpacing.s8,
              right: layer * UtenSpacing.s8,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                        group.face.type.color.withValues(alpha: 0.035 * layer),
                        scheme.surface,
                      ),
                      borderRadius: UtenRadius.cardAll,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                  ),
                ),
              ),
            ),
          NoticeCard(
            notice: group.face,
            onTap: onTap,
            onLongPress: onLongPress,
            selecting: selecting,
            checked: checked,
            unread: group.unreadCount > 0,
            groupCount: group.notices.length,
            groupUnread: group.unreadCount,
            priority: priority,
            resolved: active.isEmpty,
          ),
        ],
      ),
    );
  }
}

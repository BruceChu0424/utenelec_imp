// 通知单卡、叠放顶卡与展开卡共用同一卡面；展示分组不改变业务事实。
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_motion.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/notice.dart';
import '../models/notice_group.dart';
import 'celebration_subjects.dart';
import 'notice_interaction_footer.dart';

class NoticeCard extends StatefulWidget {
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
    this.hoverLift = true,
  });
  final Notice notice;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final FutureOr<void> Function()? onAcknowledge;
  final bool selecting, checked;
  final bool? unread;
  final int? groupCount;
  final int groupUnread;
  final NoticePriority? priority;
  final bool? resolved;
  final bool showInteractions;

  /// 叠放顶卡由整组处理悬停，不再重复位移。
  final bool hoverLift;
  @override
  State<NoticeCard> createState() => _NoticeCardState();
}

class _NoticeCardState extends State<NoticeCard> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final notice = widget.notice;
    final unread = widget.unread ?? !notice.isRead;
    final resolved = widget.resolved ?? notice.isResolved;
    final priority = widget.priority ?? notice.priority;
    final grouped = (widget.groupCount ?? 0) > 1;
    final typeInk = _readableColor(context, notice.type.color, scheme.surface);
    final lift = widget.hoverLift && _hovered && !widget.selecting;
    // 类型已显示紧急时，不再另起一行重复同一标记。
    final showPriority =
        priority.showBadge &&
        !(notice.type == NoticeType.urgent &&
            priority == NoticePriority.urgent);
    final showStatus =
        showPriority ||
        notice.topPriority ||
        resolved ||
        (notice.kind == NoticeKind.todo && !grouped);
    final showFooter =
        grouped ||
        (widget.showInteractions &&
            !widget.selecting &&
            notice.interactionMode != NoticeInteractionMode.none);
    return Semantics(
      button: true,
      selected: widget.selecting ? widget.checked : null,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: utenMotionDurationOf(context, UtenAnim.fast),
          curve: UtenAnim.standard,
          transform: lift
              ? Matrix4.translationValues(0, -UtenSpacing.s2, 0)
              : null,
          child: UtenCard(
            padding: EdgeInsets.zero,
            elevation: UtenCardElevation.low,
            selected: widget.selecting && widget.checked,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: UtenSpacing.s32,
                            height: UtenSpacing.s32,
                            decoration: BoxDecoration(
                              color: notice.type.color.withValues(alpha: 0.10),
                              borderRadius: UtenRadius.mdAll,
                            ),
                            child: Icon(
                              notice.type.icon,
                              size: 18,
                              color: typeInk,
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Expanded(
                            child: Text(
                              notice.type.label,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: typeInk,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (unread) ...[
                            const SizedBox(width: UtenSpacing.s8),
                            const _UnreadBadge(),
                          ],
                          if (widget.selecting) ...[
                            const SizedBox(width: UtenSpacing.s8),
                            Icon(
                              widget.checked
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked,
                              color: widget.checked
                                  ? scheme.primary
                                  : scheme.outline,
                              semanticLabel: widget.checked ? '已选择' : '未选择',
                            ),
                          ],
                        ],
                      ),
                      if (showStatus) ...[
                        const SizedBox(height: UtenSpacing.s12),
                        Wrap(
                          spacing: UtenSpacing.s6,
                          runSpacing: UtenSpacing.s6,
                          children: [
                            if (showPriority)
                              _Status(
                                label: priority.label,
                                icon: Icons.priority_high_rounded,
                                color: priority.color,
                              ),
                            if (notice.topPriority)
                              _Status(
                                label: '置顶',
                                icon: Icons.push_pin_rounded,
                                color: scheme.onSurfaceVariant,
                              ),
                            if (resolved)
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
                      const SizedBox(height: UtenSpacing.s12),
                      Text(
                        notice.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: unread
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: resolved
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
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
                      if (notice.content.isNotEmpty) ...[
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
                      ],
                      const SizedBox(height: UtenSpacing.s16),
                      Wrap(
                        spacing: UtenSpacing.s12,
                        runSpacing: UtenSpacing.s4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            notice.publisher,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
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
                    ],
                  ),
                ),
                if (showFooter) ...[
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.55),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s16,
                      vertical: UtenSpacing.s12,
                    ),
                    child: grouped
                        ? Row(
                            children: [
                              Icon(
                                Icons.layers_outlined,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: UtenSpacing.s8),
                              Expanded(
                                child: Text(
                                  '共 ${widget.groupCount} 条${widget.groupUnread > 0 ? ' · ${widget.groupUnread} 未读' : ' · 全部已读'}',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (!widget.selecting) ...[
                                const SizedBox(width: UtenSpacing.s8),
                                Icon(
                                  Icons.unfold_more_rounded,
                                  size: 20,
                                  color: scheme.onSurfaceVariant,
                                  semanticLabel: '展开相关通知',
                                ),
                              ],
                            ],
                          )
                        : NoticeInteractionFooter(
                            notice: notice,
                            onOpenDetail: widget.onTap,
                            onAcknowledge: widget.onAcknowledge,
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      key: const ValueKey('notice-unread-indicator'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: UtenSpacing.s6,
          height: UtenSpacing.s6,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: UtenSpacing.s6),
        Text(
          '未读',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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
                fontWeight: FontWeight.w600,
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
  final base = background.computeLuminance();
  for (var step = 0; step <= 10; step++) {
    final candidate = Color.lerp(color, target, step / 10)!;
    final luminance = candidate.computeLuminance();
    if ((math.max(luminance, base) + 0.05) /
            (math.min(luminance, base) + 0.05) >=
        4.5) {
      return candidate;
    }
  }
  return target;
}

/// 底卡露出两级边缘，表达真实组数量；底卡无独立交互和读屏焦点。
class NoticeStackCard extends StatefulWidget {
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
  final bool selecting, checked;
  @override
  State<NoticeStackCard> createState() => _NoticeStackCardState();
}

class _NoticeStackCardState extends State<NoticeStackCard> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final depth = math.min(2, widget.group.notices.length - 1);
    final active = widget.group.notices.where((n) => !n.isResolved);
    final priority = active.fold(
      NoticePriority.normal,
      (value, notice) => notice.type == NoticeType.urgent
          ? NoticePriority.urgent
          : notice.priority.index > value.index
          ? notice.priority
          : value,
    );
    final border = dark ? UtenColors.darkBorder : UtenColors.border;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: utenMotionDurationOf(context, UtenAnim.fast),
        curve: UtenAnim.standard,
        transform: _hovered && !widget.selecting
            ? Matrix4.translationValues(0, -UtenSpacing.s2, 0)
            : null,
        child: Padding(
          padding: EdgeInsets.only(bottom: depth * UtenSpacing.s8),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var layer = depth; layer > 0; layer--)
                Positioned(
                  top: layer * UtenSpacing.s8,
                  bottom: -layer * UtenSpacing.s8,
                  left: layer * UtenSpacing.s6,
                  right: layer * UtenSpacing.s6,
                  child: ExcludeSemantics(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: ValueKey('notice-stack-layer-$layer'),
                        decoration: BoxDecoration(
                          color: Color.alphaBlend(
                            scheme.onSurface.withValues(alpha: layer * 0.025),
                            scheme.surface,
                          ),
                          borderRadius: UtenRadius.cardAll,
                          border: Border.all(color: border),
                        ),
                      ),
                    ),
                  ),
                ),
              NoticeCard(
                notice: widget.group.face,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                selecting: widget.selecting,
                checked: widget.checked,
                unread: widget.group.unreadCount > 0,
                groupCount: widget.group.notices.length,
                groupUnread: widget.group.unreadCount,
                priority: priority,
                resolved: active.isEmpty,
                hoverLift: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

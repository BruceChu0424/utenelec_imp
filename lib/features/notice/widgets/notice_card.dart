// 通知卡片（柔光渐变 · 悬浮叠放版，2026-10-29 改版）。
//
// 视觉契约（用户定稿口径）：
// - 卡面 = 明亮底色 + 类型主题色「柔光渐变」：颜色从卡片右上角开始，
//   向中部与左下方逐渐淡化——渐变即类型识别信息，不是装饰；
// - 卡下阴影 = 柔软扩散的同色弥散影（近景接触影保持中性色），
//   让卡片像轻轻浮在背景上，与叠层、徽章同色系呼应；
// - 顶部 = 类型图标（同色浅底托）+ 类型名（主题色）；
//   通知标题是主要视觉重点，来源/时间/阅读状态是次级层次；
// - 分组顶卡右上角 = 数量徽章（实色主题色 + 浅色描边圈）；
// - 悬停整组轻轻上浮、阴影加深（点击展开的暗示）。
//
// 本卡是「渐变卡」的定制表面（UtenCard 契约是白底+细边框、不用渐变），
// 圆角/间距/阴影仍全部走 Uten token；读/收到/完成业务动作语义不变。
// 收起/展开的舞台见 notice_group_dialog.dart。

import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/feedback/uten_motion.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/notice.dart';
import '../models/notice_group.dart';
import 'celebration_subjects.dart';
import 'notice_interaction_footer.dart';

/// One visual contract for the inbox and the cards unfolded from a stack.
/// Reading, acknowledging and completing a business task remain separate actions.
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
  final bool selecting;
  final bool checked;
  final bool? unread;
  final int? groupCount;
  final int groupUnread;
  final NoticePriority? priority;
  final bool? resolved;
  final bool showInteractions;

  /// 是否响应悬停上浮。分组顶卡由 [NoticeStackCard] 整组托起，传 false
  /// 避免「组内再抬一次」叠加位移。
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
    final isDark = theme.brightness == Brightness.dark;
    final notice = widget.notice;
    final isUnread = widget.unread ?? !notice.isRead;
    final isResolved = widget.resolved ?? notice.isResolved;
    final effectivePriority = widget.priority ?? notice.priority;
    final accent = notice.type == NoticeType.urgent
        ? notice.type.color
        : effectivePriority.showBadge
        ? effectivePriority.color
        : notice.type.color;
    final grouped = (widget.groupCount ?? 0) > 1;
    final typeColor = notice.type.color;
    final typeInk = _readableColor(context, typeColor, scheme.surface);
    final lift =
        widget.hoverLift && _hovered && !widget.selecting && !isResolved;

    return Semantics(
      button: true,
      selected: widget.selecting ? widget.checked : null,
      child: Opacity(
        opacity: isResolved ? 0.64 : 1,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: utenMotionDurationOf(context, UtenAnim.fast),
            curve: UtenAnim.standard,
            transform: lift ? Matrix4.translationValues(0, -3, 0) : null,
            decoration: BoxDecoration(
              borderRadius: UtenRadius.cardAll,
              boxShadow: _glowShadow(accent, isDark: isDark, hovered: lift),
            ),
            child: Material(
              color: scheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: UtenRadius.cardAll,
                side: BorderSide(
                  color: widget.selecting && widget.checked
                      ? scheme.primary
                      : (isDark ? UtenColors.darkBorder : UtenColors.border),
                  width: widget.selecting && widget.checked ? 1.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: BoxDecoration(
                  borderRadius: UtenRadius.cardAll,
                  gradient: _glowGradient(typeColor, isDark: isDark),
                ),
                child: InkWell(
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                  child: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: typeColor.withValues(alpha: 0.14),
                                borderRadius: UtenRadius.lgAll,
                              ),
                              child: Icon(
                                notice.type.icon,
                                color: typeInk,
                                size: 22,
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
                                      color: typeInk,
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
                            if (widget.selecting)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: UtenSpacing.s4,
                                ),
                                child: Icon(
                                  widget.checked
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked,
                                  color: widget.checked
                                      ? scheme.primary
                                      : scheme.outline,
                                  semanticLabel: widget.checked ? '已选择' : '未选择',
                                ),
                              )
                            else if (grouped)
                              _CountBadge(
                                count: widget.groupCount!,
                                color: accent,
                              ),
                          ],
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                        Text(
                          notice.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: isUnread
                                ? FontWeight.w800
                                : FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                        if (notice.isGroupCelebration) ...[
                          const SizedBox(height: UtenSpacing.s8),
                          CelebrationSubjectChips(
                            subjects: notice.subjects,
                            showEventLabel:
                                notice.type == NoticeType.anniversary,
                            accent: typeColor,
                          ),
                        ],
                        const SizedBox(height: UtenSpacing.s8),
                        Wrap(
                          spacing: UtenSpacing.s8,
                          runSpacing: UtenSpacing.s4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              notice.publisher,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '·',
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
                            if (isUnread) ...[
                              const SizedBox(width: UtenSpacing.s2),
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: scheme.error,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: UtenSpacing.s4),
                              Text(
                                '未读',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.error,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (effectivePriority.showBadge ||
                            notice.type == NoticeType.urgent ||
                            notice.topPriority ||
                            isResolved ||
                            notice.kind == NoticeKind.todo) ...[
                          const SizedBox(height: UtenSpacing.s8),
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
                              else if (notice.kind == NoticeKind.todo &&
                                  !grouped)
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
                        const SizedBox(height: UtenSpacing.s16),
                        if (grouped) ...[
                          Container(
                            height: 1,
                            color: accent.withValues(alpha: 0.18),
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          Wrap(
                            spacing: UtenSpacing.s8,
                            runSpacing: UtenSpacing.s6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Icon(
                                Icons.layers_rounded,
                                size: 18,
                                color: typeInk,
                              ),
                              Text(
                                '共 ${widget.groupCount} 条${widget.groupUnread > 0 ? ' · ${widget.groupUnread} 未读' : ' · 全部已读'}',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: typeInk,
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
                        ] else if (widget.showInteractions &&
                            !widget.selecting &&
                            notice.interactionMode !=
                                NoticeInteractionMode.none) ...[
                          NoticeInteractionFooter(
                            notice: notice,
                            onOpenDetail: widget.onTap,
                            onAcknowledge: widget.onAcknowledge,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 类型柔光渐变：主题色以右上角为光源（径向柔光），向中部与左下方
/// 逐渐淡化——「光从右上角洒下来」的存在感一眼可辨。
/// 左侧 2/3 保持干净，保证标题/正文可读性；深色模式略提一档存在感。
RadialGradient _glowGradient(Color color, {required bool isDark}) =>
    RadialGradient(
      center: Alignment.topRight,
      radius: 1.6,
      stops: const [0, 0.4, 1],
      colors: isDark
          ? [
              color.withValues(alpha: 0.34),
              color.withValues(alpha: 0.15),
              color.withValues(alpha: 0.04),
            ]
          : [
              color.withValues(alpha: 0.30),
              color.withValues(alpha: 0.13),
              color.withValues(alpha: 0.03),
            ],
    );

/// 柔软扩散的悬浮阴影：近景接触影保持中性（任何主题色下落影干净），
/// 远景弥散影融入主题色，卡片像浮在同色光晕上；悬停时加深加大。
List<BoxShadow> _glowShadow(
  Color color, {
  required bool isDark,
  bool hovered = false,
}) => [
  BoxShadow(
    color: isDark
        ? Colors.black.withValues(alpha: 0.30)
        : UtenColors.slate900.withValues(alpha: 0.05),
    blurRadius: 2,
    offset: const Offset(0, 1),
  ),
  BoxShadow(
    color: color.withValues(
      alpha: isDark ? (hovered ? 0.36 : 0.26) : (hovered ? 0.30 : 0.22),
    ),
    blurRadius: hovered ? 40 : 30,
    offset: Offset(0, hovered ? 16 : 12),
  ),
];

/// 分组数量徽章：实色主题色 + 浅色描边圈 + 清楚数字。
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Tooltip(
      message: '$count 条相关通知，点击展开',
      child: Container(
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: UtenRadius.pillAll,
          border: Border.all(
            color: scheme.surface.withValues(alpha: 0.85),
            width: 2,
          ),
        ),
        child: Text(
          '$count',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: onColor,
            fontWeight: FontWeight.w800,
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

/// 同一业务对象的多条通知叠成一组：顶卡完整展示，背后 1-2 层向下错开
/// 露出底缘，叠层延续类型主题色；悬停整组上浮、加深同色阴影。
/// A stack retains the highest active priority even if its newest message is routine.
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
  final bool selecting;
  final bool checked;

  @override
  State<NoticeStackCard> createState() => _NoticeStackCardState();
}

class _NoticeStackCardState extends State<NoticeStackCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typeColor = widget.group.face.type.color;
    final depth = math.min(2, widget.group.notices.length - 1);
    final active = widget.group.notices.where((notice) => !notice.isResolved);
    final priority = active.fold(
      NoticePriority.normal,
      (value, notice) => notice.type == NoticeType.urgent
          ? NoticePriority.urgent
          : notice.priority.index > value.index
          ? notice.priority
          : value,
    );
    final lift = _hovered && !widget.selecting;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: utenMotionDurationOf(context, UtenAnim.fast),
        curve: UtenAnim.standard,
        transform: lift ? Matrix4.translationValues(0, -4, 0) : null,
        decoration: BoxDecoration(
          borderRadius: UtenRadius.cardAll,
          boxShadow: lift
              ? [
                  BoxShadow(
                    color: typeColor.withValues(alpha: isDark ? 0.30 : 0.20),
                    blurRadius: 44,
                    offset: const Offset(0, 18),
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: depth * UtenSpacing.s16),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 底部叠层：向下错开露出底缘，颜色延续类型主题色
              //（越深的层着色越重，形成厚度感），不参与交互与语义。
              for (var layer = depth; layer > 0; layer--)
                Positioned(
                  top: layer * 13.0,
                  bottom: -layer * 13.0,
                  left: layer * 3.0,
                  right: layer * 3.0,
                  child: ExcludeSemantics(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          // 叠层保持卡面本色（像真实叠着的卡），
                          // 类型色走描边与阴影，两条边各自分明不糊成色带。
                          color: scheme.surface,
                          borderRadius: UtenRadius.cardAll,
                          border: Border.all(
                            color: typeColor.withValues(
                              alpha: 0.45 + 0.15 * layer,
                            ),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: typeColor.withValues(alpha: 0.16),
                              blurRadius: 6,
                              offset: Offset(0, 3.0 * layer),
                            ),
                          ],
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

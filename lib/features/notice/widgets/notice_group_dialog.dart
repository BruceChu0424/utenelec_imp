// Same-object stacks unfold into full notification cards on a dimmed stage.
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_motion.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../models/notice.dart';
import '../models/notice_group.dart';
import '../providers/notice_providers.dart';
import 'notice_card.dart';
import 'notice_detail_dialog.dart';

/// The source rectangle is captured before pushing, in the root overlay's coordinates.
Future<void> showNoticeGroupDialog(
  BuildContext originContext, {
  required NoticeGroup group,
  Rect? originRect,
}) {
  final duration = utenMotionDurationOf(originContext, UtenAnim.slow);
  return showGeneralDialog<void>(
    context: originContext,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(
      originContext,
    ).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.48),
    transitionDuration: duration,
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: SizedBox(
              width: math.min(
                920,
                math.max(0, constraints.maxWidth - UtenSpacing.s32),
              ),
              height: math.min(
                math.max(0, constraints.maxHeight - UtenSpacing.s32),
                144 +
                    math.min(group.notices.length, 3) *
                        232 *
                        MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.8),
              ),
              child: _NoticeGroupPanel(
                group: group,
                originContext: originContext,
                animation: animation,
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final size = MediaQuery.sizeOf(context);
      final delta = originRect == null
          ? Offset.zero
          : originRect.center - size.center(Offset.zero);
      return AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final progress = UtenAnim.standard.transform(animation.value);
          final initialScale = originRect == null
              ? 0.86
              : (originRect.width /
                        math.min(
                          920,
                          math.max(1, size.width - UtenSpacing.s32),
                        ))
                    .clamp(0.3, 0.9);
          return Transform.translate(
            offset: delta * (1 - progress),
            child: Transform.scale(
              scale: initialScale + (1 - initialScale) * progress,
              child: Opacity(
                opacity: Curves.easeOut.transform(
                  (animation.value / 0.32).clamp(0, 1),
                ),
                child: child,
              ),
            ),
          );
        },
      );
    },
  );
}

class _NoticeGroupPanel extends StatefulWidget {
  const _NoticeGroupPanel({
    required this.group,
    required this.originContext,
    required this.animation,
  });
  final NoticeGroup group;
  final BuildContext originContext;
  final Animation<double> animation;

  @override
  State<_NoticeGroupPanel> createState() => _NoticeGroupPanelState();
}

class _NoticeGroupPanelState extends State<_NoticeGroupPanel> {
  final Set<String> _readIds = {};
  bool _markingAll = false;
  String? _openingId;

  bool _isUnread(Notice notice) =>
      !notice.isRead && !_readIds.contains(notice.id);
  int get _unreadCount => widget.group.notices.where(_isUnread).length;

  Future<void> _openNotice(Notice notice) async {
    if (_openingId != null || _markingAll) return;
    setState(() => _openingId = notice.id);
    final container = ProviderScope.containerOf(
      widget.originContext,
      listen: false,
    );
    try {
      if (_isUnread(notice)) {
        await markNoticeReadContainer(container, notice.id);
        if (!mounted) return;
        setState(() => _readIds.add(notice.id));
      }
      if (!mounted || !widget.originContext.mounted) return;
      await showNoticeDetailDialog(
        widget.originContext,
        noticeId: notice.id,
        // A business action must dismiss both the detail and this group stage.
        onBeforeActionNavigate: () {
          if (mounted && ModalRoute.of(context)?.isCurrent == true) {
            Navigator.of(context).pop();
          }
        },
      );
    } catch (error) {
      if (mounted) context.appError(humanErrorMessage(error) ?? '通知打开失败，请重试');
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  Future<void> _markAllRead() async {
    final targets = widget.group.notices.where(_isUnread).toList();
    if (targets.isEmpty || _markingAll || _openingId != null) return;
    setState(() => _markingAll = true);
    final container = ProviderScope.containerOf(
      widget.originContext,
      listen: false,
    );
    var failed = 0;
    try {
      for (final notice in targets) {
        if (!mounted || !widget.originContext.mounted) break;
        try {
          await markNoticeReadContainer(container, notice.id);
          if (mounted) setState(() => _readIds.add(notice.id));
        } catch (_) {
          failed++;
        }
      }
      if (mounted && failed > 0) context.appError('$failed 条通知未能标为已读，请重试');
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = _unreadCount;
    final notices = [...widget.group.notices]
      ..sort((a, b) {
        if (_isUnread(a) != _isUnread(b)) return _isUnread(a) ? -1 : 1;
        final byTime = b.publishedAt.compareTo(a.publishedAt);
        return byTime == 0 ? a.id.compareTo(b.id) : byTime;
      });
    return Material(
      key: const ValueKey('notice-group-stage'),
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.dialogAll,
      clipBehavior: Clip.antiAlias,
      child: UtenDialogSurface(
        child: Column(
          children: [
            UtenDialogHeader(
              title: const Text('相关通知'),
              subtitle: Text(
                '共 ${notices.length} 条${unread > 0 ? ' · 未读 $unread 条' : ' · 全部已读'}，未读排在前面',
              ),
              icon: Icons.notifications_none_rounded,
              trailing: UtenCloseButton(
                onPressed: () => Navigator.of(context).maybePop(),
                tooltip: '收起相关通知',
              ),
            ),
            if (unread > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s20,
                  0,
                  UtenSpacing.s20,
                  UtenSpacing.s8,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _markingAll || _openingId != null
                        ? null
                        : _markAllRead,
                    icon: _markingAll
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.done_all_rounded, size: 18),
                    label: const Text('全部已读'),
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                key: const PageStorageKey('notice-group-cards'),
                padding: const EdgeInsets.all(UtenSpacing.s16),
                itemCount: notices.length,
                separatorBuilder: (_, index) =>
                    const SizedBox(height: UtenSpacing.s12),
                itemBuilder: (context, index) {
                  final notice = notices[index];
                  return AnimatedBuilder(
                    key: ValueKey(notice.id),
                    animation: widget.animation,
                    child: NoticeCard(
                      notice: notice,
                      unread: _isUnread(notice),
                      showInteractions: false,
                      onTap: () => _openNotice(notice),
                    ),
                    builder: (context, child) {
                      final progress = UtenAnim.standard.transform(
                        ((widget.animation.value - 0.12) / 0.88).clamp(
                          0.0,
                          1.0,
                        ),
                      );
                      return Transform.translate(
                        key: ValueKey('notice-unfold-${notice.id}'),
                        offset: Offset(
                          0,
                          -(1 - progress) * math.min(index, 4) * 92,
                        ),
                        child: Opacity(opacity: progress, child: child),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

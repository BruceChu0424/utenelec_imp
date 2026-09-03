// ReviewPendingDialog —— 审核待办居中弹窗（V459/ADR-063 第二轮：用户口径修订）
//
// 一个待审事件的三种提醒形态并存：通知中心条目 + 顶部通知条 + 本居中弹窗。
// 本弹窗承载主交互：
// - 登录检查（ReviewPendingLoginGate）与在线到达（dispatchReviewCard）共用；
// - 弹窗内实时显示「是否有人在处理」（30s 心跳 pending-review-status：
//   他人认领 → 「XX 正在审核」黄色 chip；办结 → 条目自动移除，清空则弹窗自关）；
// - 【去审核】：标已读 → 跳 actionRoute（域专属审核页）→ 关弹窗；
// - 【稍后再看】：全部条目标已读 + 服务端 snooze 15 分钟（跨设备一致，
//   到点未办结下次登录/到达再弹）；
// - 右上 X：仅关闭本次（不 snooze——「每次登录检查、有待办就弹」的产品口径）。
// 文档：docs/02-组件库/ReviewPendingDialog.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/uten_tokens.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';
import '../repositories/notice_repository.dart';
import '../providers/notice_route_read_bridge.dart';

/// 居中弹窗单例守卫：已打开时不再叠新弹窗（在线多事件同到/登录检查与
/// 到达链竞争时只保一层；新待办由已开弹窗的心跳与收件台兜底）。
bool _reviewPendingDialogOpen = false;

/// 仅测试用：重置单例守卫（widget 测试间隔离）。
@visibleForTesting
void resetReviewPendingDialogForTest() {
  _reviewPendingDialogOpen = false;
}

/// 弹出居中审核待办弹窗。[pending] 非空（调用方保证）；全空由心跳自然自关。
/// 弹窗已打开时本次调用为空操作（返回已完成 Future）。
Future<void> showReviewPendingDialog(
  BuildContext context, {
  required List<Notice> pending,
}) {
  if (_reviewPendingDialogOpen) {
    return Future<void>.value();
  }
  _reviewPendingDialogOpen = true;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => ReviewPendingDialog(
      key: const ValueKey('review-pending-dialog'),
      pending: pending,
    ),
  ).whenComplete(() => _reviewPendingDialogOpen = false);
}

class ReviewPendingDialog extends ConsumerStatefulWidget {
  const ReviewPendingDialog({super.key, required this.pending});

  final List<Notice> pending;

  @override
  ConsumerState<ReviewPendingDialog> createState() =>
      _ReviewPendingDialogState();
}

class _ReviewPendingDialogState extends ConsumerState<ReviewPendingDialog> {
  late List<Notice> _items;
  final Map<String, PendingReviewStatus> _statusById = {};
  Timer? _heartbeat;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.pending);
    _refreshStatus();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshStatus(),
    );
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    if (!mounted || _items.isEmpty) return;
    try {
      final statuses = await ref
          .read(noticeRepositoryProvider)
          .pendingReviewStatus([for (final n in _items) n.id]);
      if (!mounted) return;
      setState(() {
        _statusById
          ..clear()
          ..addAll({for (final s in statuses) s.noticeId: s});
        // 办结撤回：条目自动移除；全部办结则弹窗自关（不打扰已无需处理的人）。
        _items.removeWhere((n) => _statusById[n.id]?.resolved ?? false);
        if (_items.isEmpty) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      });
    } catch (_) {
      // 真态校验失败可容忍：条目保持上次状态。
    }
  }

  Future<void> _openReview(Notice notice) async {
    if (_busy) return;
    _busy = true;
    final container = ProviderScope.containerOf(context, listen: false);
    markNoticeReadContainer(container, notice.id).ignore();
    container.read(noticeTargetRoutesProvider.notifier).recordRoutes([
      notice.actionRoute,
    ]);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    try {
      final target = noticeActionTarget(notice);
      if (target != null) {
        final router = GoRouter.of(context);
        final match = router.configuration.findMatch(Uri.parse(target));
        if (!match.isError) {
          router.go(target);
          return;
        }
      }
    } catch (_) {
      // 历史脏路由回退：无操作（通知中心仍可进详情）。
    }
  }

  Future<void> _snoozeAll() async {
    if (_busy) return;
    _busy = true;
    final container = ProviderScope.containerOf(context, listen: false);
    final repository = container.read(noticeRepositoryProvider);
    for (final n in _items) {
      markNoticeReadContainer(container, n.id).ignore();
      repository.snooze(n.id).ignore();
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final single = _items.length == 1;
    return Dialog(
      backgroundColor: scheme.surface,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(theme: theme, count: _items.length),
              const SizedBox(height: UtenSpacing.s16),
              Flexible(
                child: single
                    ? _LargeItemCard(
                        theme: theme,
                        notice: _items.first,
                        status: _statusById[_items.first.id],
                        onTap: () => _openReview(_items.first),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final item in _items)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: UtenSpacing.s8,
                              ),
                              child: _CompactItemCard(
                                theme: theme,
                                notice: item,
                                status: _statusById[item.id],
                                onTap: () => _openReview(item),
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _Actions(
                theme: theme,
                single: single,
                busy: _busy,
                onReview: () => _openReview(_items.first),
                onSnooze: _snoozeAll,
                onClose: () => Navigator.of(context, rootNavigator: true).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.theme, required this.count});

  final ThemeData theme;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            Icons.fact_check_rounded,
            size: 28,
            color: scheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '待办审核',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  count == 1 ? '有 1 项事务等待你处理' : '有 $count 项事务等待你处理',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          icon: Icon(
            Icons.close_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          tooltip: '关闭（本次登录稍后可从收件台进入）',
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }
}

IconData _eventIcon(String? sourceEvent) => switch (sourceEvent) {
  'SALES_ORDER_PENDING_FINANCE_CONFIRM' => Icons.request_quote_outlined,
  'PROCUREMENT_FINANCE_SUBMITTED' => Icons.approval_outlined,
  'PROCUREMENT_IQC_PENDING' => Icons.science_outlined,
  'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' => Icons.local_shipping_outlined,
  _ => Icons.fact_check_outlined,
};

/// 单条：大卡布局（图标+标题+摘要+状态+操作提示）。
class _LargeItemCard extends StatelessWidget {
  const _LargeItemCard({
    required this.theme,
    required this.notice,
    required this.status,
    required this.onTap,
  });

  final ThemeData theme;
  final Notice notice;
  final PendingReviewStatus? status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final claimedBy = status?.claimedByName;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _eventIcon(notice.sourceEvent),
                    size: 22,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Text(
                    notice.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (notice.content.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                notice.content,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            _ClaimChip(theme: theme, claimedByName: claimedBy),
          ],
        ),
      ),
    );
  }
}

/// 多条：紧凑行（图标+标题+时间+状态 chip）。
class _CompactItemCard extends StatelessWidget {
  const _CompactItemCard({
    required this.theme,
    required this.notice,
    required this.status,
    required this.onTap,
  });

  final ThemeData theme;
  final Notice notice;
  final PendingReviewStatus? status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s12,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              _eventIcon(notice.sourceEvent),
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                notice.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            _ClaimChip(theme: theme, claimedByName: status?.claimedByName),
          ],
        ),
      ),
    );
  }
}

/// 认领状态 chip：他人处理中（黄）/ 待处理（绿点）——「对应的人是否操作」。
class _ClaimChip extends StatelessWidget {
  const _ClaimChip({required this.theme, required this.claimedByName});

  final ThemeData theme;
  final String? claimedByName;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final claimed = claimedByName != null && claimedByName!.isNotEmpty;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: claimed
            ? scheme.tertiaryContainer.withValues(alpha: 0.7)
            : scheme.primaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            claimed ? Icons.person_pin_circle_rounded : Icons.schedule_rounded,
            size: 14,
            color: claimed
                ? scheme.onTertiaryContainer
                : scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 5),
          Text(
            claimed ? '$claimedByName 正在审核' : '待处理',
            style: theme.textTheme.labelSmall?.copyWith(
              color: claimed
                  ? scheme.onTertiaryContainer
                  : scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.theme,
    required this.single,
    required this.busy,
    required this.onReview,
    required this.onSnooze,
    required this.onClose,
  });

  final ThemeData theme;
  final bool single;
  final bool busy;
  final VoidCallback onReview;
  final VoidCallback onSnooze;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: busy ? null : onReview,
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            label: Text(single ? '去审核' : '去处理第一条'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              textStyle: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: OutlinedButton(
            onPressed: busy ? null : onSnooze,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            child: Text(single ? '稍后再看' : '全部稍后再看'),
          ),
        ),
      ],
    );
  }
}

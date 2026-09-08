// ReviewPendingLoginGate —— 登录后的居中审核弹窗检查门（V459/ADR-063 第二轮）。
//
// 产品口径：「每次登录检查是否有新的待审，有就弹居中弹窗」。
// - 登录会话（authenticated + notice:read）从无到有时触发一次（登出再登入会重新触发）；
// - 首屏短暂稳定后拉 GET /notices/pending-reviews（未办结+未稍后），不固定等 3s；
// - 弹窗单例（review_pending_dialog 内部守卫）：在线到达链已弹时不重复；
// - 「稍后再看」是唯一静默途径（snooze 15 分钟）；右上 X 仅本次关闭，
//   下次登录仍会提醒（未办结就还该提醒）。
// 不渲染任何 UI（SizedBox.shrink），挂 app.dart 外壳 Column（与路由桥同位）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/notice_providers.dart';
import '../widgets/review_pending_dialog.dart';

class ReviewPendingLoginGate extends ConsumerStatefulWidget {
  const ReviewPendingLoginGate({
    super.key,
    required this.enabled,
    required this.identityKey,
    required this.dialogContext,
  });

  /// 与 NoticeArrivalListener 同源：authenticated 且持有 notice:read。
  final bool enabled;

  /// 账号/模拟身份会话键：切换身份视为新会话（重新检查）。
  final String identityKey;

  /// 根 Navigator context 提供者（appNavigatorKey.currentContext）。
  final BuildContext? Function() dialogContext;

  @override
  ConsumerState<ReviewPendingLoginGate> createState() =>
      _ReviewPendingLoginGateState();
}

class _ReviewPendingLoginGateState
    extends ConsumerState<ReviewPendingLoginGate> {
  String? _checkedForIdentity;
  Timer? _timer;
  int _generation = 0;
  int _retryAttempt = 0;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant ReviewPendingLoginGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityKey != widget.identityKey ||
        oldWidget.enabled != widget.enabled) {
      _generation++;
      _timer?.cancel();
      _checkedForIdentity = null;
      _retryAttempt = 0;
      closeReviewPendingDialog();
      _schedule();
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  void _schedule() {
    if (widget.enabled && _checkedForIdentity != widget.identityKey) {
      _checkedForIdentity = widget.identityKey;
      final generation = _generation;
      _timer = Timer(
        const Duration(milliseconds: 300),
        () => _check(generation),
      );
    }
  }

  Future<void> _check(int generation) async {
    if (!mounted || generation != _generation || !widget.enabled) return;
    final initialContext = widget.dialogContext();
    if (initialContext == null || !initialContext.mounted) {
      _retry(generation);
      return;
    }
    try {
      final pending = await ref.read(noticeRepositoryProvider).pendingReviews();
      if (!mounted ||
          generation != _generation ||
          !widget.enabled ||
          pending.isEmpty) {
        return;
      }
      final dialogContext = widget.dialogContext();
      if (dialogContext == null || !dialogContext.mounted) {
        _retry(generation);
        return;
      }
      await showReviewPendingDialog(dialogContext, pending: pending);
    } catch (_) {
      // A temporary failure is not a successful login check. Retry with a
      // bounded delay, while identity/disposal guards cancel obsolete work.
      _retry(generation);
    }
  }

  void _retry(int generation) {
    if (!mounted || generation != _generation || !widget.enabled) return;
    _retryAttempt++;
    final milliseconds = (500 * (1 << _retryAttempt.clamp(0, 4))).clamp(
      500,
      8000,
    );
    _timer?.cancel();
    _timer = Timer(
      Duration(milliseconds: milliseconds),
      () => _check(generation),
    );
  }
}

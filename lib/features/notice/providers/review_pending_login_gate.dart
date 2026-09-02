// ReviewPendingLoginGate —— 登录后的居中审核弹窗检查门（V459/ADR-063 第二轮）。
//
// 产品口径：「每次登录检查是否有新的待审，有就弹居中弹窗」。
// - 登录会话（authenticated + notice:read）从无到有时触发一次（登出再登入会重新触发）；
// - 延迟 3s 等首屏稳定后拉 GET /notices/pending-reviews（未办结+未稍后）；
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
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      // 登出：解除已检查标记，下次登录重新检查。
      if (_checkedForIdentity != null) {
        _checkedForIdentity = null;
      }
      return const SizedBox.shrink();
    }
    if (_checkedForIdentity != widget.identityKey && !_checking) {
      _checkedForIdentity = widget.identityKey;
      _checking = true;
      // 延迟到首屏稳定后（登录瞬间全屏弹窗会盖住工作台首屏）。
      Timer(const Duration(seconds: 3), _check);
    }
    return const SizedBox.shrink();
  }

  Future<void> _check() async {
    try {
      final pending = await ref.read(noticeRepositoryProvider).pendingReviews();
      if (!mounted || pending.isEmpty) return;
      final dialogContext = widget.dialogContext();
      if (dialogContext == null || !dialogContext.mounted) return;
      await showReviewPendingDialog(dialogContext, pending: pending);
    } catch (_) {
      // 检查失败可容忍：不阻塞登录流程，在线到达链与收件台仍覆盖。
    } finally {
      _checking = false;
    }
  }
}

// 访客审批待办数量 Provider（工作台/导航红色数字徽章用）。
// 默认 60s 轮询一次；权限不足时返回 0。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';

const Duration _kPendingPollInterval = Duration(seconds: 60);

/// HR 访客待办数（visitor:approve）：60s 轮询；无权限返回 0。
/// 返回 0 时不渲染徽章。
final visitorPendingCountProvider =
    StateNotifierProvider<VisitorPendingCountNotifier, int>((ref) {
      // 新登录会话从零重建并立即重拉（见 shared/auth/session_epoch_provider.dart）。
      ref.watch(sessionEpochProvider);
      final notifier = VisitorPendingCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class VisitorPendingCountNotifier extends StateNotifier<int> {
  VisitorPendingCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kPendingPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    // 仅在有 HR 审批权限时拉取；普通用户静默返回 0。
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.visitorApprove) || ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      final count = await ref
          .read(visitorStaffRepositoryProvider)
          .pendingCount();
      if (mounted) state = count; // 会话重建后旧实例已释放，丢弃迟到结果
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（审批 / 确认动作完成后调用）。
  Future<void> refresh() => _tick();
}

/// 被访人待确认数（visitor:host-confirm）：60s 轮询；无权限返回 0。
final visitorHostPendingCountProvider =
    StateNotifierProvider<VisitorHostPendingCountNotifier, int>((ref) {
      // 新登录会话从零重建并立即重拉（见 shared/auth/session_epoch_provider.dart）。
      ref.watch(sessionEpochProvider);
      final notifier = VisitorHostPendingCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class VisitorHostPendingCountNotifier extends StateNotifier<int> {
  VisitorHostPendingCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kPendingPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    // 仅在有被访人确认权限时拉取；普通用户静默返回 0。
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.visitorHostConfirm) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      final count = await ref
          .read(visitorStaffRepositoryProvider)
          .hostPendingCount();
      if (mounted) state = count; // 会话重建后旧实例已释放，丢弃迟到结果
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（确认 / 拒绝动作完成后调用）。
  Future<void> refresh() => _tick();
}

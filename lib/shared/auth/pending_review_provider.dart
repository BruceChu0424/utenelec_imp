// HR 待办数量 Provider（导航红色数字徽章用）。
// 默认 60s 轮询一次；权限不足时返回 0。
// 文档：docs/03-页面/我的页.md（§4.6 HR 导航红色数字徽章）

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/profile/repositories/profile_change_repository.dart';
import 'permissions.dart';

const Duration _kPendingPollInterval = Duration(seconds: 60);

/// 当前用户为 HR / admin 时，60s 轮询待审数；其它角色返回 0。
/// 返回 0 时不渲染徽章。
final pendingReviewCountProvider =
    StateNotifierProvider<PendingReviewCountNotifier, int>((ref) {
      final notifier = PendingReviewCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class PendingReviewCountNotifier extends StateNotifier<int> {
  PendingReviewCountNotifier(this.ref) : super(0);

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
    // 仅在有 review 权限时拉取；普通用户静默返回 0。
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.profileReview) || ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      final count = await ref
          .read(profileChangeRepositoryProvider)
          .hrPendingCount();
      state = count;
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（审批 / 提交动作完成后调用）。
  Future<void> refresh() => _tick();
}

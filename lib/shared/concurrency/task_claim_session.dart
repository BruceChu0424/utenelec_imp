// 任务认领会话：管理一组 (targetType, targetKey) 的认领 + 心跳 + 释放生命周期。
// 用于多目标认领场景（如采购跨申请分解订货）。单目标用 TaskClaimHandle（Widget）更简单。
// 纯 UX/防碰撞层：认领失败 fail-open（不阻塞业务动作，后端守卫是安全网）。
import 'dart:async';

import '../repositories/task_claim_repository.dart';

class TaskClaimSession {
  TaskClaimSession(this._repo, {Duration? heartbeatInterval})
    : _interval = heartbeatInterval ?? const Duration(seconds: 30);

  final TaskClaimRepository _repo;
  final Duration _interval;
  final List<_HeldClaim> _held = [];
  Timer? _timer;

  /// 任一目标被他人占用（应禁用动作 + 提示）。
  bool blocked = false;
  String? blockedByName;

  /// 认领一组目标。本人持有的进 _held（启心跳）；他人占用的置 blocked。
  Future<void> claimAll(String targetType, Iterable<String> keys) async {
    for (final key in keys) {
      final view = await _repo.claim(targetType, key);
      if (view == null) continue; // 认领失败（网络等）→ fail open，不阻塞
      if (view.claimedByMe) {
        _held.add(_HeldClaim(targetType, key));
      } else {
        blocked = true;
        blockedByName = view.claimedByName;
      }
    }
    if (_held.isNotEmpty && _timer == null) {
      _timer = Timer.periodic(_interval, (_) {
        for (final h in _held) {
          _repo.heartbeat(h.type, h.key);
        }
      });
    }
  }

  /// 释放本人持有的全部认领（幂等；释放失败忽略，租约会自然过期）。
  Future<void> releaseAll() async {
    _timer?.cancel();
    _timer = null;
    for (final h in _held) {
      await _repo.release(h.type, h.key);
    }
    _held.clear();
  }
}

class _HeldClaim {
  const _HeldClaim(this.type, this.key);
  final String type;
  final String key;
}

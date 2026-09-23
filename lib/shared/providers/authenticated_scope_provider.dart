// 已登录会话作用域——所有会话级轮询/快照的生命周期锚点(ADR-108)。
//
// 只有「已登录」时才非空; 登出、会话失效、换账号、进出代操作都会让它变成 null 或新值,
// watch 它的轮询 provider 随之整体重建: 旧定时器与迟到响应一并作废, 新身份从零开始。
// 此前未读数轮询只看会话纪元不看登录状态, 登出后仍按 60s 节拍打出几千次 401。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session_epoch_provider.dart';
import 'session_provider.dart';

/// 一个已登录会话的身份键(值相等 = 同一会话身份)。
class AuthenticatedScope {
  const AuthenticatedScope({
    required this.userId,
    this.actorId,
    this.readOnly = false,
    this.epoch = 0,
  });

  final String userId;

  /// 代操作(模拟身份)时的真实操作人。
  final String? actorId;
  final bool readOnly;

  /// 登录纪元: 清空业务数据后重新登录也要从零重建。
  final int epoch;

  @override
  bool operator ==(Object other) =>
      other is AuthenticatedScope &&
      other.userId == userId &&
      other.actorId == actorId &&
      other.readOnly == readOnly &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(userId, actorId, readOnly, epoch);
}

/// 当前已登录会话; 未登录 / 必须改密 / 会话失效时为 null。
final authenticatedScopeProvider = Provider<AuthenticatedScope?>((ref) {
  final identity = ref.watch(
    sessionProvider.select(
      (session) => (
        session.status,
        session.user?.id,
        session.actor?.id,
        session.impersonationReadOnly,
      ),
    ),
  );
  if (identity.$1 != AuthStatus.authenticated || identity.$2 == null) {
    return null;
  }
  return AuthenticatedScope(
    userId: identity.$2!,
    actorId: identity.$3,
    readOnly: identity.$4,
    epoch: ref.watch(sessionEpochProvider),
  );
});

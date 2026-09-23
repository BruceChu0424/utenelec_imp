// 会话快照(ADR-108) —— 只随登录、切身份、授权变化而变的会话级事实, 由 /auth/me 一次带回:
//
//   · delegableSurfaceKeys: 当前主体能打开「本页权限设置」的页面 key。此前每个页面顶栏
//     现拉一次 capability(一周 5024 次, 三成与上一次相隔不到 2 秒);
//   · documentScopes: 六个单据范围的普通写能力。此前详情页每次加载都作废重拉;
//   · preferences: 用户偏好整表。此前 9 个页面偏好各自 GET 整张表。
//
// 快照只决定按钮显隐与默认值, 服务端写接口的对象级校验不变, 仍是最终把关。
// 刷新时机: 登录/恢复会话/切换代操作(作用域变化即重建); 令牌刷新带回的权限点变了;
// 页面权限设置保存后调 [SessionSnapshotNotifier.refresh]。
// 取数失败不让整段会话停在失败态: 断网恢复时立即重取, 另按 5s/15s/45s 退避自动重试三次。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/connection_recovery.dart';
import '../../features/auth/repositories/auth_repository.dart';
import '../providers/authenticated_scope_provider.dart';
import '../providers/session_provider.dart';
import 'document_scope_capability.dart';

/// 会话快照内容, 见文件头。
@immutable
class SessionSnapshot {
  SessionSnapshot({
    this.delegableSurfaceKeys = const {},
    this.documentScopes = const {},
    this.preferences = const {},
    int? generation,
  }) : generation = generation ?? ++_generations;

  static int _generations = 0;

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) {
    final keys = json['delegableSurfaceKeys'];
    final scopes = json['documentScopes'];
    final prefs = json['preferences'];
    return SessionSnapshot(
      delegableSurfaceKeys: {
        if (keys is List)
          for (final key in keys)
            if (key is String && key.isNotEmpty) key,
      },
      documentScopes: {
        if (scopes is Map)
          for (final scope in DocumentDataScope.values)
            if (scopes[scope.apiValue] is Map<String, dynamic>)
              scope: DocumentScopeCapability.fromJson(
                scopes[scope.apiValue] as Map<String, dynamic>,
              ),
      },
      preferences: {
        if (prefs is Map)
          for (final entry in prefs.entries) entry.key.toString(): entry.value,
      },
    );
  }

  /// 能打开「本页权限设置」的页面 key。
  final Set<String> delegableSurfaceKeys;

  /// 各单据范围的普通写能力(缺项 = 该范围不可写)。
  final Map<DocumentDataScope, DocumentScopeCapability> documentScopes;

  /// 用户偏好整表: key → 服务端原始 JSON 值。
  final Map<String, Object?> preferences;

  /// 加载批次: 每次从服务端取到(或新建)一份快照都是新批次; 本端写偏好后就地派生的
  /// 快照([withPreference])沿用原批次。偏好 notifier 只认新批次, 不把本端刚推上去的
  /// 值回灌成自己的状态(否则推送期间的新改动会被冲掉)。
  final int generation;

  bool canDelegate(String surfaceKey) =>
      delegableSurfaceKeys.contains(surfaceKey);

  SessionSnapshot withPreference(String key, Object? value) => SessionSnapshot(
    delegableSurfaceKeys: delegableSurfaceKeys,
    documentScopes: documentScopes,
    preferences: {...preferences, key: value},
    generation: generation,
  );
}

/// 当前会话快照; 未登录为 null。加载失败时各消费方按「只读 / 不显示 / 本地默认」降级。
final sessionSnapshotProvider =
    AsyncNotifierProvider<SessionSnapshotNotifier, SessionSnapshot?>(
      SessionSnapshotNotifier.new,
    );

class SessionSnapshotNotifier extends AsyncNotifier<SessionSnapshot?> {
  /// 失败后自动重试的退避间隔(用完即止, 之后只等断网恢复或下次授权变化)。
  static const retryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
  ];

  AuthenticatedScope? _scope;
  int _failures = 0;
  Timer? _retry;

  @override
  Future<SessionSnapshot?> build() async {
    final scope = ref.watch(authenticatedScopeProvider);
    _retry?.cancel();
    _retry = null;
    if (scope != _scope) {
      _scope = scope;
      _failures = 0;
    }
    ref.onDispose(() {
      _retry?.cancel();
      _retry = null;
    });
    if (scope == null) return null;
    // 断网恢复: 快照若停在失败态立即重取, 不因一次网络抖动让整段会话只读。
    ref.listen<int>(
      connectionRecoveryProvider.select((state) => state.recoveryEpoch),
      (previous, next) {
        if (next > (previous ?? 0) && state.hasError) ref.invalidateSelf();
      },
    );
    // 令牌刷新带回的权限点变了(被授权/收权): 快照里的可委派页面与单据范围随之重取。
    ref.listen<List<String>?>(
      sessionProvider.select((state) => state.user?.permissions),
      (previous, next) {
        if (previous != null && next != null && !listEquals(previous, next)) {
          ref.invalidateSelf();
        }
      },
    );
    final recent = RecentMeSnapshot.take(scope.userId);
    if (recent != null) return SessionSnapshot.fromJson(recent);
    try {
      final snapshot = await _fetch();
      _failures = 0;
      return snapshot;
    } catch (_) {
      _scheduleRetry(scope);
      rethrow;
    }
  }

  void _scheduleRetry(AuthenticatedScope scope) {
    if (_failures >= retryDelays.length) return;
    final delay = retryDelays[_failures++];
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      if (_scope == scope && state.hasError) ref.invalidateSelf();
    });
  }

  Future<SessionSnapshot> _fetch() async {
    final json = await ref.read(apiClientProvider).get(ApiEndpoints.authMe);
    final session = json['session'];
    // 服务端本次没算出快照(/me 只回了资料): 按失败处理, 走退避重取, 不把「空快照」
    // 当成真实结果让整段会话只读。
    if (session is! Map<String, dynamic>) {
      throw StateError('会话快照本次未算出');
    }
    return SessionSnapshot.fromJson(session);
  }

  /// 授权变化后(如页面权限设置保存)重取快照。
  Future<void> refresh() async {
    final scope = ref.read(authenticatedScopeProvider);
    if (scope == null) return;
    state = await AsyncValue.guard(_fetch);
    if (state.hasError) _scheduleRetry(scope);
  }

  /// 本端写偏好成功(或乐观写入)后就地更新, 不为此重拉整份快照。
  void updatePreference(String key, Object? value) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.withPreference(key, value));
  }
}

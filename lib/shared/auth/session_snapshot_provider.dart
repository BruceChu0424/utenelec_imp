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
import '../../core/security/secure_storage.dart';
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

SessionSnapshot? confirmedSessionSnapshot(AsyncValue<SessionSnapshot?> value) =>
    value.isLoading || value.hasError ? null : value.valueOrNull;

class SessionSnapshotNotifier extends AsyncNotifier<SessionSnapshot?> {
  /// 失败后自动重试的退避间隔(用完即止, 之后只等断网恢复或下次授权变化)。
  static const retryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
  ];

  AuthenticatedScope? _scope;
  ApiClient? _client;
  int _lifecycle = 0;
  int _refreshRevision = 0;
  Future<SessionSnapshot>? _latestRead;
  int _failures = 0;
  Timer? _retry;
  Set<String>? _publishedProfilePermissions;

  @override
  Future<SessionSnapshot?> build() async {
    final scope = ref.watch(authenticatedScopeProvider);
    // The client is rebuilt for a backend switch; snapshots never cross it.
    final client = ref.watch(apiClientProvider);
    final lifecycle = ++_lifecycle;
    final revision = ++_refreshRevision;
    _publishedProfilePermissions = null;
    _latestRead = null;
    _retry?.cancel();
    _retry = null;
    if (scope != _scope || !identical(client, _client)) {
      _scope = scope;
      _client = client;
      _failures = 0;
    }
    ref.onDispose(() {
      if (lifecycle != _lifecycle) return;
      _lifecycle++;
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
        final published = _publishedProfilePermissions;
        _publishedProfilePermissions = null;
        if (published != null &&
            next != null &&
            setEquals(published, next.toSet())) {
          return;
        }
        if ((previous == null) != (next == null)) {
          ref.invalidateSelf();
          return;
        }
        if (previous != null &&
            next != null &&
            !setEquals(previous.toSet(), next.toSet())) {
          ref.invalidateSelf();
        }
      },
    );
    Map<String, dynamic>? recent;
    if (scope.actorId == null && RecentMeSnapshot.hasCandidate) {
      try {
        final tokens = await ref
            .read(secureStorageProvider)
            .getAuthTokenSnapshot();
        if (!_active(lifecycle, scope, client)) return null;
        recent = RecentMeSnapshot.take(scope.userId, client, tokens);
      } catch (_) {
        // A reuse optimization must never substitute unowned authorization.
        RecentMeSnapshot.clear();
      }
    } else {
      RecentMeSnapshot.clear();
    }
    if (!_active(lifecycle, scope, client)) return null;
    if (revision != _refreshRevision) {
      return _latestForBuild(lifecycle, scope, client);
    }
    if (recent != null) return SessionSnapshot.fromJson(recent);
    final pending = _fetch(client, lifecycle, scope, revision);
    _latestRead = pending;
    try {
      final snapshot = await pending;
      if (revision != _refreshRevision) {
        return _latestForBuild(lifecycle, scope, client);
      }
      if (_active(lifecycle, scope, client)) _failures = 0;
      return snapshot;
    } catch (_) {
      if (revision != _refreshRevision) {
        return _latestForBuild(lifecycle, scope, client);
      }
      _scheduleRetry(lifecycle, scope, client);
      rethrow;
    }
  }

  /// A manual refresh may supersede an initial build without invalidating the
  /// provider. That build must join the latest read rather than publish its old
  /// authorization (or schedule an obsolete error retry) afterward.
  Future<SessionSnapshot?> _latestForBuild(
    int lifecycle,
    AuthenticatedScope scope,
    ApiClient client,
  ) async {
    while (_active(lifecycle, scope, client)) {
      final revision = _refreshRevision;
      final pending = _latestRead;
      if (pending == null) return confirmedSessionSnapshot(state);
      try {
        final result = await pending;
        if (!_active(lifecycle, scope, client)) return null;
        if (revision == _refreshRevision) return result;
      } catch (_) {
        if (!_active(lifecycle, scope, client)) return null;
        if (revision == _refreshRevision) rethrow;
      }
    }
    return null;
  }

  bool _active(int lifecycle, AuthenticatedScope scope, ApiClient client) =>
      lifecycle == _lifecycle &&
      _scope == scope &&
      identical(client, _client) &&
      ref.read(authenticatedScopeProvider) == scope &&
      identical(ref.read(apiClientProvider), client);

  void _scheduleRetry(
    int lifecycle,
    AuthenticatedScope scope,
    ApiClient client,
  ) {
    if (!_active(lifecycle, scope, client)) return;
    if (_failures >= retryDelays.length) return;
    final delay = retryDelays[_failures++];
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      if (_active(lifecycle, scope, client) && state.hasError) {
        ref.invalidateSelf();
      }
    });
  }

  Future<SessionSnapshot> _fetch(
    ApiClient client,
    int lifecycle,
    AuthenticatedScope scope,
    int revision,
  ) async {
    final owner = ref.read(sessionProvider.notifier);
    final profileRead = owner.captureProfileRead();
    final json = await client.get(ApiEndpoints.authMe);
    if (_active(lifecycle, scope, client) && revision == _refreshRevision) {
      if (profileRead != null && !owner.isCurrentProfileRead(profileRead)) {
        // Same-account replacement intents can settle between provider flushes.
        // Their old response must not publish scopes even when user IDs match.
        ref.invalidateSelf();
        throw StateError('会话身份或权限已变化，正在重新读取当前会话');
      }
      // A profile belonging to another user cannot authorize this snapshot.
      if (json['id'] is String && json['id'] != scope.userId) {
        throw StateError('会话资料与当前登录身份不一致，请重新核对登录状态');
      }
      if (profileRead != null) {
        final permissions = json['permissions'];
        final before = ref.read(sessionProvider).user?.permissions;
        if (permissions is List &&
            permissions.every((value) => value is String) &&
            before != null &&
            !setEquals(before.toSet(), permissions.cast<String>().toSet())) {
          // Register before the synchronous owner publication: its permission
          // listener must not issue a duplicate /me for this same response.
          _publishedProfilePermissions = permissions.cast<String>().toSet();
        }
        var applied = false;
        try {
          applied = owner.applyMeProfileIfCurrent(json, request: profileRead);
        } finally {
          if (!applied) _publishedProfilePermissions = null;
        }
      }
    }
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
    final client = ref.read(apiClientProvider);
    final lifecycle = _lifecycle;
    if (!_active(lifecycle, scope, client)) return;
    final revision = ++_refreshRevision;
    _retry?.cancel();
    _retry = null;
    final pending = _fetch(client, lifecycle, scope, revision);
    _latestRead = pending;
    state = const AsyncLoading<SessionSnapshot?>().copyWithPrevious(state);
    final result = await AsyncValue.guard(() => pending);
    if (!_active(lifecycle, scope, client) || revision != _refreshRevision) {
      return;
    }
    state = result;
    if (result.hasError) {
      _scheduleRetry(lifecycle, scope, client);
    } else {
      _failures = 0;
    }
  }

  /// 本端写偏好成功(或乐观写入)后就地更新, 不为此重拉整份快照。
  void updatePreference(String key, Object? value) {
    final scope = _scope, client = _client;
    if (scope == null ||
        client == null ||
        !_active(_lifecycle, scope, client)) {
      return;
    }
    final current = confirmedSessionSnapshot(state);
    if (current == null) return;
    state = AsyncData(current.withPreference(key, value));
  }
}

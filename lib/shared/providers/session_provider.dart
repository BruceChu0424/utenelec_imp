// 会话 Provider（真实后端鉴权）。
// 状态：unauthenticated / authenticated / mustChangePassword。
// 令牌存 SecureStorage；启动时凭 refresh 恢复；401 明确失效时由事件总线通知登出。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/connection_recovery.dart';
import '../../core/network/session_event_bus.dart';
import '../../core/security/auth_logout_fence.dart';
import '../../core/security/auth_refresh_lock.dart';
import '../../core/security/secure_storage.dart';
import '../../features/auth/models/auth_session.dart';
import '../../features/auth/repositories/auth_repository.dart';
import '../models/role.dart';
import '../models/user.dart';

enum AuthStatus { unauthenticated, authenticated, mustChangePassword }

class SessionState {
  const SessionState({this.status = AuthStatus.unauthenticated, this.user});

  final AuthStatus status;
  final AppUser? user;

  bool get isLoggedIn => status == AuthStatus.authenticated;
  bool get mustChangePassword => status == AuthStatus.mustChangePassword;
  AppUser? get u => user;
}

class SessionNotifier extends Notifier<SessionState> {
  bool _restoreInProgress = false;
  bool _restoreRequested = false;

  // Local ordering complements the cross-tab intentGeneration stored in the
  // authoritative record. Network exchanges remain outside this short queue.
  var _sessionMutationEpoch = 0;
  Future<void> _sessionCommitTail = Future<void>.value();

  // When an authoritative replacement/logout write fails, visible state stays
  // logged out and automatic restore is forbidden until a later user intent
  // successfully reaches secure storage.
  bool _localStorageFailClosed = false;
  String? _visibleSessionLineage;
  var _visibleIntentGeneration = 0;

  static const _profileGenerationKey = '_utenAuthTokenGeneration';
  static const _profileIntentKey = '_utenAuthIntentGeneration';
  static const _profileLineageKey = '_utenAuthSessionLineage';

  @override
  SessionState build() {
    Future<void>.microtask(_restore);
    ref.listen<int>(
      connectionRecoveryProvider.select((value) => value.recoveryEpoch),
      (previous, next) {
        if (next > (previous ?? 0) &&
            state.status == AuthStatus.unauthenticated) {
          Future<void>.microtask(_restore);
        }
      },
    );

    final expirationSubscription = SessionEventBus.instance.onSessionExpired
        .listen((_) {
          final observedEpoch = _sessionMutationEpoch;
          unawaited(_expireIfStillCurrent(observedEpoch));
        });
    final profileSubscription = SessionEventBus.instance.onProfileRefreshed
        .listen((userJson) {
          unawaited(_applyRefreshedProfileIfCurrent(userJson));
        });
    final tokenChangeSubscription = _storage.onExternalAuthTokenChanged.listen((
      notice,
    ) {
      unawaited(_reconcileExternalTokenChange(notice));
    });
    ref.onDispose(() {
      unawaited(expirationSubscription.cancel());
      unawaited(profileSubscription.cancel());
      unawaited(tokenChangeSubscription.cancel());
    });
    return const SessionState();
  }

  AuthRepository get _auth => ref.read(authRepositoryProvider);
  AuthLogoutFence get _logoutFence => ref.read(authLogoutFenceProvider);
  SecureStorage get _storage => ref.read(secureStorageProvider);

  Future<void> _applyRefreshedProfileIfCurrent(
    Map<String, dynamic> userJson,
  ) async {
    final generation = userJson[_profileGenerationKey];
    final intent = userJson[_profileIntentKey];
    final lineage = userJson[_profileLineageKey];
    if (generation is! num || intent is! num || lineage is! String) return;

    try {
      final current = await _storage.getAuthTokenSnapshot();
      if (state.status != AuthStatus.authenticated ||
          current.generation != generation.toInt() ||
          current.intentGeneration != intent.toInt() ||
          current.sessionLineage != lineage ||
          _visibleSessionLineage != lineage) {
        return;
      }
      _rememberVisibleRecord(current);
      state = SessionState(
        status: AuthStatus.authenticated,
        user: _toAppUser(UserProfile.fromJson(userJson)),
      );
    } catch (_) {
      // A profile event is advisory; storage/read failure cannot change state.
    }
  }

  Future<void> _reconcileExternalTokenChange(
    AuthTokenChangeNotice notice,
  ) async {
    if (_localStorageFailClosed) return;
    try {
      final current = await _storage.getAuthTokenSnapshot();
      // A delayed BroadcastChannel signal may describe an older record. The
      // authoritative read above is the only state that can be applied.
      if (current.generation < notice.generation) return;

      final intentChanged =
          current.intentGeneration != _visibleIntentGeneration;
      final lineageChanged = current.sessionLineage != _visibleSessionLineage;
      if (intentChanged || lineageChanged) {
        ++_sessionMutationEpoch;
      }

      if (!current.hasRefreshToken) {
        _rememberVisibleRecord(current);
        state = const SessionState();
        return;
      }

      if (lineageChanged) {
        // Never render the prior profile while requests already use a different
        // cross-tab session. /auth/me will install the matching profile.
        state = const SessionState();
      } else if (intentChanged) {
        _visibleIntentGeneration = current.intentGeneration;
      }
      await _restore();
    } catch (_) {
      // A notification is only a wakeup. Recovery/startup can retry the read.
    }
  }

  Future<void> _expireIfStillCurrent(int observedEpoch) async {
    try {
      final snapshot = await _storage.getAuthTokenSnapshot();
      if (observedEpoch != _sessionMutationEpoch ||
          snapshot.hasAccessToken ||
          snapshot.hasRefreshToken) {
        return;
      }
      _rememberVisibleRecord(snapshot);
    } catch (_) {
      // Confirmed credential rejection is fail-closed when secure storage is
      // unreadable, unless a newer local session operation has started.
      if (observedEpoch != _sessionMutationEpoch) return;
    }
    state = const SessionState();
  }

  Future<bool> _hasDurableLogoutFence() async {
    try {
      return await _logoutFence.isActive();
    } catch (_) {
      // An unreadable durable fence can mean a prior logout did not finish.
      // Startup therefore stays logged out until an explicit login safely
      // replaces the token record and clears the marker.
      return true;
    }
  }

  Future<void> _restore() async {
    if (_localStorageFailClosed || await _hasDurableLogoutFence()) return;
    if (_restoreInProgress) {
      _restoreRequested = true;
      return;
    }
    _restoreInProgress = true;
    try {
      do {
        _restoreRequested = false;
        try {
          if (await _restoreCurrentTokens(_sessionMutationEpoch)) {
            _restoreRequested = true;
          }
        } catch (_) {
          // Secure-storage/platform failures are not evidence that credentials
          // are invalid. A later recovery event or app start can retry.
        }
      } while (_restoreRequested && !_localStorageFailClosed);
    } finally {
      _restoreInProgress = false;
    }
  }

  /// Returns true when the record changed during /auth/me and the latest
  /// generation must be read again.
  Future<bool> _restoreCurrentTokens(int observedEpoch) async {
    if (_localStorageFailClosed) return false;
    final submitted = await _storage.getAuthTokenSnapshot();
    if (!submitted.hasRefreshToken) return false;
    try {
      final profile = await _auth.me();
      final current = await _storage.getAuthTokenSnapshot();
      if (_localStorageFailClosed || observedEpoch != _sessionMutationEpoch) {
        return false;
      }
      if (!current.isSameSession(submitted)) {
        return current.hasRefreshToken;
      }
      _rememberVisibleRecord(current);
      state = SessionState(
        status: AuthStatus.authenticated,
        user: _toAppUser(profile),
      );
    } on ApiException catch (error) {
      if (const {
        'UNAUTHORIZED',
        'ACCOUNT_LOCKED',
        'ACCOUNT_DISABLED',
      }.contains(error.code)) {
        final cleared = await _storage.clearTokensIfUnchanged(submitted);
        if (cleared && observedEpoch == _sessionMutationEpoch) {
          final current = await _storage.getAuthTokenSnapshot();
          _rememberVisibleRecord(current);
          state = const SessionState();
        } else if (!cleared &&
            observedEpoch == _sessionMutationEpoch &&
            !_localStorageFailClosed) {
          final current = await _storage.getAuthTokenSnapshot();
          return current.hasRefreshToken;
        }
      }
    } catch (_) {
      // An abnormal response is not a credential revocation.
    }
    return false;
  }

  /// Login first reserves a cross-tab replacement intent and tombstones the old
  /// session. Only that exact latest intent may commit the network response.
  Future<void> login({
    required String account,
    required String password,
  }) async {
    final operationEpoch = ++_sessionMutationEpoch;
    state = const SessionState();
    _localStorageFailClosed = true;

    final reservation = await _serializeSessionCommit(() async {
      final reserved = await _storage.beginSessionIntent(clearTokens: true);
      if (operationEpoch == _sessionMutationEpoch) {
        // The new tombstone is authoritative before the durable logout fence
        // is removed. A failed clear leaves this login fail-closed.
        await _logoutFence.clear();
      }
      return reserved;
    });
    await _revokeRemote(refresh: reservation.previous.refreshToken);
    if (operationEpoch != _sessionMutationEpoch) return;

    _rememberVisibleRecord(reservation.reserved);
    _localStorageFailClosed = false;

    final result = await _auth.login(account, password);
    var committedLocally = false;
    await _serializeSessionCommit(() async {
      if (operationEpoch != _sessionMutationEpoch) {
        await _revokeRemote(refresh: result.refreshToken);
        return;
      }
      final committed = await _commitAuthResult(
        operationEpoch,
        reservation.intent,
        result,
      );
      if (committed == null) {
        await _revokeRemote(refresh: result.refreshToken);
        return;
      }
      if (operationEpoch != _sessionMutationEpoch) {
        await _storage.clearTokensIfUnchanged(committed);
        await _revokeRemote(refresh: result.refreshToken);
        return;
      }

      ++_sessionMutationEpoch;
      _localStorageFailClosed = false;
      _rememberVisibleRecord(committed);
      state = SessionState(
        status: result.mustChangePassword
            ? AuthStatus.mustChangePassword
            : AuthStatus.authenticated,
        user: _toAppUser(result.user),
      );
      committedLocally = true;
    });
    if (committedLocally) {
      unawaited(_saveLoginAccountBestEffort(account));
    }
  }

  /// Password change reserves a global intent while preserving the active
  /// credentials needed by the authenticated network call. Its response moves
  /// the session to the reserved new lineage.
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final operationEpoch = ++_sessionMutationEpoch;
    final reservation = await _serializeSessionCommit(
      () => _storage.beginSessionIntent(clearTokens: false),
    );
    if (operationEpoch != _sessionMutationEpoch) return;
    _rememberVisibleRecord(reservation.reserved);

    final result = await _auth.changePassword(oldPassword, newPassword);
    await _serializeSessionCommit(() async {
      if (operationEpoch != _sessionMutationEpoch) {
        await _revokeRemote(refresh: result.refreshToken);
        return;
      }
      final committed = await _commitAuthResult(
        operationEpoch,
        reservation.intent,
        result,
      );
      if (committed == null) {
        await _revokeRemote(refresh: result.refreshToken);
        return;
      }
      if (operationEpoch != _sessionMutationEpoch) {
        await _storage.clearTokensIfUnchanged(committed);
        await _revokeRemote(refresh: result.refreshToken);
        return;
      }

      ++_sessionMutationEpoch;
      _rememberVisibleRecord(committed);
      state = SessionState(
        status: AuthStatus.authenticated,
        user: _toAppUser(result.user),
      );
    });
  }

  Future<void> logout() {
    final operationEpoch = ++_sessionMutationEpoch;
    state = const SessionState();
    _localStorageFailClosed = true;

    return _serializeSessionCommit(() async {
      // Try both independent persistence layers. If the preferences fence is
      // unavailable but secure-token deletion succeeds, reload is still safe;
      // if token deletion fails, a successfully written fence remains active.
      try {
        await _logoutFence.activate();
      } catch (_) {
        // Continue with authoritative token clearing. Its failure is surfaced
        // below and the current process remains fail-closed.
      }
      // Persist the old refresh token in the encrypted revocation queue while
      // the atomic cross-tab token lock is still held, before deleting the
      // only local copy. Network drain remains asynchronous.
      final cleared = await _clearForLogoutWithRetry(
        beforeClear: (previous) => _revokeRemote(
          refresh: previous.refreshToken,
          propagateFailure: true,
        ),
      );
      if (operationEpoch == _sessionMutationEpoch) {
        _rememberVisibleRecord(cleared.tombstone);
        await _logoutFence.clear();
        _localStorageFailClosed = false;
      }
    });
  }

  Future<AuthTokenClearResult> _clearForLogoutWithRetry({
    Future<void> Function(AuthTokenSnapshot previous)? beforeClear,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    const retryDelays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 30),
      Duration(milliseconds: 120),
    ];
    for (var attempt = 0; attempt < retryDelays.length; attempt++) {
      final delay = retryDelays[attempt];
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      try {
        return await _storage.clearForLogoutIntent(beforeClear: beforeClear);
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<AuthTokenSnapshot?> _commitAuthResult(
    int operationEpoch,
    AuthSessionIntent intent,
    AuthResult result,
  ) async {
    if (operationEpoch != _sessionMutationEpoch) return null;
    final committed = await _storage.commitSessionIntentTokens(
      intent: intent,
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
    );
    if (committed == null) return null;
    if (operationEpoch != _sessionMutationEpoch) {
      await _storage.clearTokensIfUnchanged(committed);
      return null;
    }
    return committed;
  }

  Future<void> _saveLoginAccountBestEffort(String account) async {
    try {
      await _storage.saveLoginAccount(account);
    } catch (_) {
      // Remembering an account is convenience only and never owns token order.
    }
  }

  void _rememberVisibleRecord(AuthTokenSnapshot snapshot) {
    _visibleSessionLineage = snapshot.sessionLineage;
    _visibleIntentGeneration = snapshot.intentGeneration;
  }

  Future<T> _serializeSessionCommit<T>(Future<T> Function() commit) async {
    final predecessor = _sessionCommitTail;
    final release = Completer<void>();
    _sessionCommitTail = release.future;
    await predecessor;
    try {
      return await commit();
    } finally {
      release.complete();
    }
  }

  Future<void> _revokeRemote({
    required String? refresh,
    bool propagateFailure = false,
  }) async {
    if (refresh == null || refresh.isEmpty) return;
    try {
      await _auth.logout(refresh);
    } catch (error, stackTrace) {
      if (propagateFailure) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      // Superseded login/password responses already lost ownership of local
      // state. Their queueing failure must not revive or overwrite the winner.
    }
  }

  AppUser _toAppUser(UserProfile profile) => AppUser(
    id: profile.id,
    code: profile.code ?? profile.loginAccount,
    name: profile.name ?? profile.loginAccount,
    roles: profile.roles.map(_toRole).toList(),
    department: profile.department,
    position: profile.position,
    permissions: profile.permissions,
    superAdmin: profile.superAdmin,
    employeeId: profile.employeeId,
  );

  static Role _toRole(String code) => Role.values.firstWhere(
    (role) => role.name == code,
    orElse: () => Role.employee,
  );
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(
  SessionNotifier.new,
);

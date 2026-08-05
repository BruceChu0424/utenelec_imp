// 安全存储：令牌（access/refresh）与登录账号。
// 文档：docs/00-项目准则/10-安全准则.md（敏感数据走 flutter_secure_storage，不进 shared_preferences）
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_refresh_lock.dart';

/// 员工令牌对的一致性快照。
///
/// [generation] 随每次权威记录写入递增；[intentGeneration] 只在用户发起登录、
/// 退出、改密或凭据被明确拒绝时递增。[sessionLineage] 是不含凭据的随机会话世系，
/// refresh 保持它不变，重新登录/退出/改密则切换世系。
class AuthTokenSnapshot {
  const AuthTokenSnapshot({
    required this.accessToken,
    required this.refreshToken,
    required this.generation,
    required this.intentGeneration,
    required this.sessionLineage,
  });

  const AuthTokenSnapshot.empty()
    : accessToken = null,
      refreshToken = null,
      generation = 0,
      intentGeneration = 0,
      sessionLineage = null;

  final String? accessToken;
  final String? refreshToken;
  final int generation;
  final int intentGeneration;
  final String? sessionLineage;

  bool get hasAccessToken => accessToken != null && accessToken!.isNotEmpty;
  bool get hasRefreshToken => refreshToken != null && refreshToken!.isNotEmpty;
  bool get hasTokens => hasAccessToken || hasRefreshToken;

  bool get hasCompleteMetadata {
    if (generation == 0 &&
        intentGeneration == 0 &&
        !hasTokens &&
        sessionLineage == null) {
      return true;
    }
    return sessionLineage != null && sessionLineage!.isNotEmpty;
  }

  /// Exact record identity used by refresh/restore compare-and-set operations.
  bool isSameSession(AuthTokenSnapshot other) =>
      generation == other.generation &&
      intentGeneration == other.intentGeneration &&
      sessionLineage == other.sessionLineage &&
      accessToken == other.accessToken &&
      refreshToken == other.refreshToken;

  bool isSameLineage(AuthTokenSnapshot other) {
    final lineage = sessionLineage;
    return lineage != null &&
        lineage.isNotEmpty &&
        lineage == other.sessionLineage;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 2,
    'generation': generation,
    'intentGeneration': intentGeneration,
    'sessionLineage': sessionLineage,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
  };

  static AuthTokenSnapshot? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final generationValue = decoded['generation'];
      final intentValue = decoded['intentGeneration'];
      final lineageValue = decoded['sessionLineage'];
      final access = decoded['accessToken'];
      final refresh = decoded['refreshToken'];
      if (generationValue is! num ||
          (intentValue != null && intentValue is! num) ||
          (lineageValue != null && lineageValue is! String) ||
          (access != null && access is! String) ||
          (refresh != null && refresh is! String)) {
        return null;
      }
      final parsedGeneration = generationValue.toInt();
      final generation = parsedGeneration < 0 ? 0 : parsedGeneration;
      final parsedIntent = intentValue is num
          ? intentValue.toInt()
          : generation;
      final intentGeneration = parsedIntent < 0 ? 0 : parsedIntent;
      final lineage = lineageValue is String && lineageValue.isNotEmpty
          ? lineageValue
          : null;
      return AuthTokenSnapshot(
        accessToken: access as String?,
        refreshToken: refresh as String?,
        generation: generation,
        intentGeneration: intentGeneration,
        sessionLineage: lineage,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A globally ordered user session intent. Its target lineage is random metadata,
/// not a credential.
class AuthSessionIntent {
  const AuthSessionIntent({
    required this.intentGeneration,
    required this.reservedLineage,
    required this.targetLineage,
  });

  final int intentGeneration;
  final String reservedLineage;
  final String targetLineage;
}

class AuthSessionIntentReservation {
  const AuthSessionIntentReservation({
    required this.intent,
    required this.previous,
    required this.reserved,
  });

  final AuthSessionIntent intent;
  final AuthTokenSnapshot previous;
  final AuthTokenSnapshot reserved;
}

class AuthTokenClearResult {
  const AuthTokenClearResult({required this.previous, required this.tombstone});

  final AuthTokenSnapshot previous;
  final AuthTokenSnapshot tombstone;
}

/// 模拟身份（admin「切换人」）会话记录：目标用户的 access token + 窗口到期 + 世系。
///
/// 独立于员工主令牌记录（[AuthTokenSnapshot]）：admin 的真实令牌全程不动，
/// 模拟 token 存独立 key，[AuthInterceptor] 按请求选择凭证源。模拟不跨重启。
class ImpersonationRecord {
  const ImpersonationRecord({
    required this.accessToken,
    required this.windowExpiresAtEpochMs,
    required this.lineage,
    this.generation = 1,
  });

  final String accessToken;
  final int windowExpiresAtEpochMs;
  final String lineage;
  final int generation;

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch >= windowExpiresAtEpochMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'accessToken': accessToken,
        'windowExpiresAtEpochMs': windowExpiresAtEpochMs,
        'lineage': lineage,
        'generation': generation,
      };

  static ImpersonationRecord? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final access = decoded['accessToken'];
      final exp = decoded['windowExpiresAtEpochMs'];
      final lineage = decoded['lineage'];
      if (access is! String || access.isEmpty) return null;
      if (exp is! num) return null;
      if (lineage is! String || lineage.isEmpty) return null;
      final gen = decoded['generation'];
      return ImpersonationRecord(
        accessToken: access,
        windowExpiresAtEpochMs: exp.toInt(),
        lineage: lineage,
        generation: gen is num ? gen.toInt() : 1,
      );
    } catch (_) {
      return null;
    }
  }
}

class _AuthTokenRecordRead {
  const _AuthTokenRecordRead({required this.exists, required this.snapshot});

  const _AuthTokenRecordRead.absent() : exists = false, snapshot = null;

  final bool exists;
  final AuthTokenSnapshot? snapshot;
}

class SecureStorage {
  SecureStorage(this._storage)
    : _staffTokenRecordLock = AuthRefreshLock('staff-token-record.v2'),
      _staffTokenChangeBus = AuthTokenChangeBus('staff-token-record.v2'),
      _origin = _newIdentifier();

  final FlutterSecureStorage _storage;
  final AuthRefreshLock _staffTokenRecordLock;
  final AuthTokenChangeBus _staffTokenChangeBus;
  final String _origin;

  static const _keyTokenRecord = 'auth.token_record.v1';
  static const _keyAccess = 'auth.access_token';
  static const _keyRefresh = 'auth.refresh_token';
  static const _keyAccount = 'auth.login_account';

  // 模拟身份（独立于员工主令牌；admin 真实令牌不动）
  static const _keyImpersonationRecord = 'auth.impersonation_record.v1';
  static const _keyImpersonationMode = 'auth.impersonation_mode.v1';

  static const _keyVisitorAccess = 'visitor.access_token';
  static const _keyVisitorRefresh = 'visitor.refresh_token';

  static final Random _random = Random.secure();

  /// Record changes made by another SecureStorage instance or browser tab.
  Stream<AuthTokenChangeNotice> get onExternalAuthTokenChanged =>
      _staffTokenChangeBus.changes.where((notice) => notice.origin != _origin);

  Future<String?> getAccessToken() async =>
      (await getAuthTokenSnapshot()).accessToken;
  Future<String?> getRefreshToken() async =>
      (await getAuthTokenSnapshot()).refreshToken;
  Future<String?> getLoginAccount() => _storage.read(key: _keyAccount);

  /// Unconditional replacement kept for bootstrap/tests. Production refreshes
  /// must use [saveTokensIfUnchanged], while user operations use an intent.
  Future<void> saveTokens({String? accessToken, String? refreshToken}) async {
    await _mutateStaffTokens(() async {
      final current = await _readOrMigrateStaffTokensLocked();
      final nextAccess = accessToken ?? current.accessToken;
      final nextRefresh = refreshToken ?? current.refreshToken;
      if (nextAccess == current.accessToken &&
          nextRefresh == current.refreshToken) {
        return;
      }
      await _writeStaffTokenRecord(
        AuthTokenSnapshot(
          accessToken: nextAccess,
          refreshToken: nextRefresh,
          generation: current.generation + 1,
          intentGeneration: current.intentGeneration + 1,
          sessionLineage: _newIdentifier(),
        ),
      );
    });
  }

  /// Returns one consistent access/refresh/generation/intent/lineage snapshot.
  ///
  /// Existing v1 records and two-key installations are upgraded lazily while
  /// holding the cross-instance record lock.
  Future<AuthTokenSnapshot> getAuthTokenSnapshot() async {
    final record = await _readStaffTokenRecord();
    final stored = record.snapshot;
    if (stored != null && stored.hasCompleteMetadata) return stored;
    return _mutateStaffTokens(_readOrMigrateStaffTokensLocked);
  }

  /// Atomically reserves the next global user intent before its network call.
  ///
  /// Login passes [clearTokens] so the old session is fenced immediately.
  /// Password change preserves the active credentials until its response wins.
  Future<AuthSessionIntentReservation> beginSessionIntent({
    required bool clearTokens,
  }) => _mutateStaffTokens(() async {
    final current = await _readOrMigrateStaffTokensLocked();
    final targetLineage = _newIdentifier();
    final reservedLineage = clearTokens
        ? targetLineage
        : (current.sessionLineage ?? _newIdentifier());
    final intent = AuthSessionIntent(
      intentGeneration: current.intentGeneration + 1,
      reservedLineage: reservedLineage,
      targetLineage: targetLineage,
    );
    final reserved = AuthTokenSnapshot(
      accessToken: clearTokens ? null : current.accessToken,
      refreshToken: clearTokens ? null : current.refreshToken,
      generation: current.generation + 1,
      intentGeneration: intent.intentGeneration,
      sessionLineage: reservedLineage,
    );
    await _writeStaffTokenRecord(reserved);
    return AuthSessionIntentReservation(
      intent: intent,
      previous: current,
      reserved: reserved,
    );
  });

  /// Commits a login/password-change response only while its global intent is
  /// still latest. Refresh generations that occurred under that intent do not
  /// prevent the user operation from winning.
  Future<AuthTokenSnapshot?> commitSessionIntentTokens({
    required AuthSessionIntent intent,
    required String accessToken,
    required String refreshToken,
  }) => _mutateStaffTokens(() async {
    final current = await _readOrMigrateStaffTokensLocked();
    if (current.intentGeneration != intent.intentGeneration ||
        current.sessionLineage != intent.reservedLineage) {
      return null;
    }
    final committed = AuthTokenSnapshot(
      accessToken: accessToken,
      refreshToken: refreshToken,
      generation: current.generation + 1,
      intentGeneration: current.intentGeneration,
      sessionLineage: intent.targetLineage,
    );
    await _writeStaffTokenRecord(committed);
    return committed;
  });

  /// Saves a refresh response only while the exact submitted record is current.
  /// Refresh preserves both the user-intent generation and session lineage.
  Future<bool> saveTokensIfUnchanged({
    required AuthTokenSnapshot expected,
    required String accessToken,
    String? refreshToken,
  }) => _mutateStaffTokens(() async {
    final current = await _readOrMigrateStaffTokensLocked();
    if (!current.isSameSession(expected)) return false;
    await _writeStaffTokenRecord(
      AuthTokenSnapshot(
        accessToken: accessToken,
        refreshToken: refreshToken ?? current.refreshToken,
        generation: current.generation + 1,
        intentGeneration: current.intentGeneration,
        sessionLineage: current.sessionLineage,
      ),
    );
    return true;
  });

  /// Clears a definitively rejected exact generation. The new tombstone also
  /// fences all requests from the rejected lineage.
  Future<bool> clearTokensIfUnchanged(AuthTokenSnapshot expected) =>
      _mutateStaffTokens(() async {
        final current = await _readOrMigrateStaffTokensLocked();
        if (!current.isSameSession(expected)) return false;
        await _writeStaffTokenRecord(
          AuthTokenSnapshot(
            accessToken: null,
            refreshToken: null,
            generation: current.generation + 1,
            intentGeneration: current.intentGeneration + 1,
            sessionLineage: _newIdentifier(),
          ),
        );
        return true;
      });

  Future<void> saveLoginAccount(String account) =>
      _storage.write(key: _keyAccount, value: account);

  // 通用键值读写（供账号历史等结构化数据用，仍走 flutter_secure_storage 加密）
  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  Future<void> delete(String key) => _storage.delete(key: key);

  /// Atomically captures the latest pair and writes a globally ordered logout
  /// tombstone. A refresh that finishes later cannot cross this intent fence.
  ///
  /// [beforeClear], when supplied, runs while the cross-tab token-record lock
  /// is still held. Its durable revocation handoff must succeed before the
  /// only local copy of the refresh token is erased.
  Future<AuthTokenClearResult> clearForLogoutIntent({
    Future<void> Function(AuthTokenSnapshot previous)? beforeClear,
  }) => _mutateStaffTokens(() async {
    var current = const AuthTokenSnapshot.empty();
    try {
      // Destructive clear deliberately avoids the lazy migration write:
      // even an incomplete v1 record can be captured and then replaced.
      current = await _readStaffTokensForDestructiveClearLocked();
    } catch (_) {
      // An unreadable authoritative record cannot be safely handed off. Make
      // it non-reloadable; corrupt data is never allowed to revive a session.
      await _forceDeleteAllStaffTokenKeys();
      const empty = AuthTokenSnapshot.empty();
      _publishTokenChange(empty);
      return const AuthTokenClearResult(previous: empty, tombstone: empty);
    }

    // Do not catch this failure in the destructive fallback below. If the
    // encrypted queue cannot persist the token, keep the credential behind
    // the already-active logout fence so the user can retry the handoff.
    if (beforeClear != null) await beforeClear(current);

    try {
      final tombstone = AuthTokenSnapshot(
        accessToken: null,
        refreshToken: null,
        generation: current.generation + 1,
        intentGeneration: current.intentGeneration + 1,
        sessionLineage: _newIdentifier(),
      );
      await _writeStaffTokenRecord(tombstone);
      return AuthTokenClearResult(previous: current, tombstone: tombstone);
    } catch (_) {
      // Queue handoff has already succeeded. If tombstone persistence fails,
      // deletion is the safe local fallback and the queued revocation remains.
      await _forceDeleteAllStaffTokenKeys();
      const empty = AuthTokenSnapshot.empty();
      _publishTokenChange(empty);
      return AuthTokenClearResult(previous: current, tombstone: empty);
    }
  });

  Future<AuthTokenSnapshot> clearAndReturnPreviousTokens() async =>
      (await clearForLogoutIntent()).previous;

  Future<void> clear() async {
    await clearForLogoutIntent();
  }

  // 保留账号名（记住登录），仅清令牌
  Future<void> clearTokens() => clear();

  // ===== 访客令牌（独立于员工，存独立 key）=====
  Future<String?> getVisitorAccessToken() =>
      _storage.read(key: _keyVisitorAccess);
  Future<String?> getVisitorRefreshToken() =>
      _storage.read(key: _keyVisitorRefresh);
  Future<void> saveVisitorTokens({
    String? accessToken,
    String? refreshToken,
  }) async {
    if (accessToken != null) {
      await _storage.write(key: _keyVisitorAccess, value: accessToken);
    }
    if (refreshToken != null) {
      await _storage.write(key: _keyVisitorRefresh, value: refreshToken);
    }
  }

  Future<void> clearVisitorTokens() async {
    await _storage.delete(key: _keyVisitorAccess);
    await _storage.delete(key: _keyVisitorRefresh);
  }

  // ===== 模拟身份令牌（独立 key，不与员工主令牌记录耦合）=====

  /// 读取当前模拟会话记录（含可能已过期的）。
  /// 注意：不在此处按过期自动删除——由调用方（AuthInterceptor / 横幅 / 退出）判定过期并
  /// 触发恢复 admin，避免「读到过期记录→静默回退 admin」导致 UI 与真实身份不一致。
  Future<ImpersonationRecord?> getImpersonationRecord() async {
    final raw = await _storage.read(key: _keyImpersonationRecord);
    return ImpersonationRecord.tryParse(raw);
  }

  Future<void> saveImpersonationRecord(ImpersonationRecord record) =>
      _storage.write(
        key: _keyImpersonationRecord,
        value: jsonEncode(record.toJson()),
      );

  Future<String?> getImpersonationModeToken() =>
      _storage.read(key: _keyImpersonationMode);

  Future<void> saveImpersonationModeToken(String token) =>
      _storage.write(key: _keyImpersonationMode, value: token);

  /// 清除全部模拟状态（退出 / 到期 / 冷启动丢弃）。
  Future<void> clearAllImpersonation() async {
    await _storage.delete(key: _keyImpersonationRecord);
    await _storage.delete(key: _keyImpersonationMode);
  }

  /// 仅清模拟会话记录（目标 token），保留 mode token。
  /// 用于模拟 token 到期但模式窗口仍有效时——admin 可在窗口内免密切换。
  Future<void> clearImpersonationRecord() =>
      _storage.delete(key: _keyImpersonationRecord);

  Future<_AuthTokenRecordRead> _readStaffTokenRecord() async {
    final raw = await _storage.read(key: _keyTokenRecord);
    if (raw == null) return const _AuthTokenRecordRead.absent();
    return _AuthTokenRecordRead(
      exists: true,
      snapshot: AuthTokenSnapshot.tryParse(raw),
    );
  }

  Future<AuthTokenSnapshot> _readStaffTokensForDestructiveClearLocked() async {
    final record = await _readStaffTokenRecord();
    final stored = record.snapshot;
    if (stored != null) return stored;
    if (record.exists) {
      // A corrupt authoritative record is a fail-closed boundary. Never revive
      // stale legacy keys that an earlier best-effort cleanup left behind.
      return const AuthTokenSnapshot.empty();
    }

    final access = await _storage.read(key: _keyAccess);
    final refresh = await _storage.read(key: _keyRefresh);
    if (access == null && refresh == null) {
      return const AuthTokenSnapshot.empty();
    }
    return AuthTokenSnapshot(
      accessToken: access,
      refreshToken: refresh,
      generation: 0,
      intentGeneration: 0,
      sessionLineage: null,
    );
  }

  Future<AuthTokenSnapshot> _readOrMigrateStaffTokensLocked() async {
    final record = await _readStaffTokenRecord();
    final stored = record.snapshot;
    if (stored != null) {
      if (stored.hasCompleteMetadata) return stored;
      final upgraded = AuthTokenSnapshot(
        accessToken: stored.accessToken,
        refreshToken: stored.refreshToken,
        generation: stored.generation + 1,
        intentGeneration: stored.intentGeneration,
        sessionLineage: _newIdentifier(),
      );
      await _writeStaffTokenRecord(upgraded);
      return upgraded;
    }

    if (record.exists) {
      // The record key exists but is not parseable. Treat it as authoritative
      // corruption and replace it with a tombstone; legacy credentials must
      // never be migrated back into an active session.
      final tombstone = AuthTokenSnapshot(
        accessToken: null,
        refreshToken: null,
        generation: 1,
        intentGeneration: 1,
        sessionLineage: _newIdentifier(),
      );
      await _writeStaffTokenRecord(tombstone);
      return tombstone;
    }

    final access = await _storage.read(key: _keyAccess);
    final refresh = await _storage.read(key: _keyRefresh);
    if (access == null && refresh == null) {
      return const AuthTokenSnapshot.empty();
    }
    final migrated = AuthTokenSnapshot(
      accessToken: access,
      refreshToken: refresh,
      generation: 1,
      intentGeneration: 1,
      sessionLineage: _newIdentifier(),
    );
    await _writeStaffTokenRecord(migrated);
    return migrated;
  }

  Future<void> _writeStaffTokenRecord(AuthTokenSnapshot snapshot) async {
    // The authoritative single-key write must succeed or the mutation fails.
    // Legacy cleanup and change notification are explicitly best-effort.
    await _storage.write(
      key: _keyTokenRecord,
      value: jsonEncode(snapshot.toJson()),
    );
    try {
      await _storage.delete(key: _keyAccess);
    } catch (_) {}
    try {
      await _storage.delete(key: _keyRefresh);
    } catch (_) {}
    _publishTokenChange(snapshot);
  }

  Future<void> _forceDeleteAllStaffTokenKeys() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final key in <String>[_keyTokenRecord, _keyAccess, _keyRefresh]) {
      try {
        await _storage.delete(key: key);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void _publishTokenChange(AuthTokenSnapshot snapshot) {
    try {
      _staffTokenChangeBus.publish(
        AuthTokenChangeNotice(
          origin: _origin,
          generation: snapshot.generation,
          intentGeneration: snapshot.intentGeneration,
          sessionLineage: snapshot.sessionLineage,
          hasTokens: snapshot.hasTokens,
        ),
      );
    } catch (_) {}
  }

  Future<T> _mutateStaffTokens<T>(Future<T> Function() mutation) =>
      _staffTokenRecordLock.synchronized(mutation);

  static String _newIdentifier() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${_random.nextInt(0x7fffffff).toRadixString(36)}-'
      '${_random.nextInt(0x7fffffff).toRadixString(36)}';
}

final secureStorageProvider = Provider<SecureStorage>((ref) {
  return SecureStorage(const FlutterSecureStorage());
});

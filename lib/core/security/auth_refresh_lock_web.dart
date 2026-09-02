import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:web/web.dart' as web;

/// Serializes staff token refreshes in this isolate and across same-origin tabs.
///
/// Web Locks is the primary mechanism. Browsers without that API use a short,
/// renewable localStorage lease. The lock/lease contains only random ownership
/// metadata and expiry timestamps; credentials are never copied into it.
///
/// 会话记录自 ADR-061 起按标签页隔离，本锁不再承担「跨标签页会话协调」，
/// 只保留互斥语义（同一标签页内的登录/登出/刷新串行化，跨标签页退化为
/// 短临界区的全局互斥，无害）。
class AuthRefreshLock {
  factory AuthRefreshLock(String scope) =>
      _locks.putIfAbsent(scope, () => AuthRefreshLock._(scope));

  AuthRefreshLock._(String scope)
    : _scopeHash = _stableHash(scope),
      _owner = _randomOwner();

  static final Map<String, AuthRefreshLock> _locks =
      <String, AuthRefreshLock>{};

  // The fallback lease must outlive the API policy's worst normal refresh
  // window (15s connect + 45s receive) and ordinary background-tab throttling.
  // A crashed owner is still recoverable after the bounded lease expires.
  static const Duration _leaseDuration = Duration(seconds: 90);
  static const Duration _leaseHeartbeat = Duration(seconds: 20);
  static const Duration _claimSettleDelay = Duration(milliseconds: 40);
  static const Duration _pollDelay = Duration(milliseconds: 80);
  static const Duration _acquireTimeout = Duration(seconds: 105);

  final String _scopeHash;
  final String _owner;
  Future<void> _tail = Future<void>.value();

  String get _lockName => 'uten-auth-refresh-$_scopeHash';
  String get _leaseKey => 'uten.auth.refresh.lease.$_scopeHash';

  Future<T> synchronized<T>(Future<T> Function() action) async {
    final predecessor = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await predecessor;
    try {
      if (web.window.navigator.has('locks')) {
        return await _withWebLock(action);
      }
      return await _withLease(action);
    } finally {
      release.complete();
    }
  }

  Future<T> _withWebLock<T>(Future<T> Function() action) {
    final result = Completer<T>();

    Future<JSAny?> runWhileLocked() async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
      return null;
    }

    final callback = ((web.Lock? _) => runWhileLocked().toJS).toJS;
    final options = web.LockOptions(
      signal: web.AbortSignal.timeout(_acquireTimeout.inMilliseconds),
    );
    final request = web.window.navigator.locks.request(
      _lockName,
      options,
      callback,
    );
    unawaited(
      request.toDart.catchError((Object error, StackTrace stackTrace) {
        if (!result.isCompleted) {
          // AbortError/TimeoutError while waiting is surfaced to the caller.
          // AuthInterceptor maps every lock-acquisition failure to the
          // non-destructive `unavailable` refresh disposition.
          result.completeError(error, stackTrace);
        }
        return null;
      }),
    );
    return result.future;
  }

  Future<T> _withLease<T>(Future<T> Function() action) async {
    final leaseId = '$_owner-${DateTime.now().microsecondsSinceEpoch}';
    await _acquireLease(leaseId);
    final heartbeat = Timer.periodic(
      _leaseHeartbeat,
      (_) => _renewLease(leaseId),
    );
    try {
      return await action();
    } finally {
      heartbeat.cancel();
      _releaseLease(leaseId);
    }
  }

  Future<void> _acquireLease(String leaseId) async {
    final deadline = DateTime.now().add(_acquireTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final current = _readLease();
      if (current == null || current.expiresAt <= now) {
        final claim = _Lease(
          owner: leaseId,
          expiresAt: now + _leaseDuration.inMilliseconds,
        );
        _writeLease(claim);
        // localStorage has no compare-and-swap. A short settle window followed
        // by ownership verification prevents simultaneous contenders from both
        // proceeding after overwriting one another's claim.
        await Future<void>.delayed(_claimSettleDelay);
        final confirmed = _readLease();
        if (confirmed?.owner == leaseId &&
            confirmed?.expiresAt == claim.expiresAt) {
          return;
        }
      }
      await Future<void>.delayed(_pollDelay);
    }
    throw TimeoutException(
      'Timed out waiting for the cross-tab authentication refresh lock',
      _acquireTimeout,
    );
  }

  void _renewLease(String leaseId) {
    final current = _readLease();
    if (current?.owner != leaseId) return;
    _writeLease(
      _Lease(
        owner: leaseId,
        expiresAt:
            DateTime.now().millisecondsSinceEpoch +
            _leaseDuration.inMilliseconds,
      ),
    );
  }

  void _releaseLease(String leaseId) {
    final current = _readLease();
    if (current?.owner == leaseId) {
      web.window.localStorage.removeItem(_leaseKey);
    }
  }

  _Lease? _readLease() {
    final raw = web.window.localStorage.getItem(_leaseKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final owner = decoded['owner'];
      final expiresAt = decoded['expiresAt'];
      if (owner is! String || expiresAt is! num) return null;
      return _Lease(owner: owner, expiresAt: expiresAt.toInt());
    } catch (_) {
      return null;
    }
  }

  void _writeLease(_Lease lease) {
    web.window.localStorage.setItem(
      _leaseKey,
      jsonEncode(<String, Object>{
        'owner': lease.owner,
        'expiresAt': lease.expiresAt,
      }),
    );
  }

  static String _randomOwner() {
    final random = Random.secure();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${random.nextInt(0x7fffffff).toRadixString(36)}-'
        '${random.nextInt(0x7fffffff).toRadixString(36)}';
  }
}

String _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

class _Lease {
  const _Lease({required this.owner, required this.expiresAt});

  final String owner;
  final int expiresAt;
}

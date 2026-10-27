// Named public parameters intentionally initialize private implementation fields.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/connection_recovery.dart';
import '../../../core/network/server_config.dart';
import '../../../core/security/auth_token_issuer.dart';
import '../../../core/security/pending_refresh_revocation_store.dart';
import '../../../core/security/secure_storage.dart';

typedef RefreshTokenRevoker =
    Future<bool> Function(PendingRefreshRevocation entry);

/// Eventually sends queued refresh tokens only to the public, idempotent
/// logout endpoint. It never replays a business mutation.
class PendingRefreshRevocationDrainer {
  PendingRefreshRevocationDrainer({
    required PendingRefreshRevocationStore store,
    required RefreshTokenRevoker revoke,
    List<Duration> retryDelays = defaultRetryDelays,
  }) : _store = store,
       _revoke = revoke,
       _retryDelays = List<Duration>.unmodifiable(retryDelays);

  static const List<Duration> defaultRetryDelays = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
    Duration(minutes: 30),
  ];

  final PendingRefreshRevocationStore _store;
  final RefreshTokenRevoker _revoke;
  final List<Duration> _retryDelays;

  Timer? _retryTimer;
  Future<void>? _activeDrain;
  var _consecutiveFailures = 0;
  var _disposed = false;

  bool get isDraining => _activeDrain != null;
  bool get hasScheduledRetry => _retryTimer?.isActive == true;

  /// Durably queues a token before starting a non-blocking network attempt.
  /// Secure-storage failures are surfaced; network failures are retained and
  /// retried independently so logout/login UI flows do not wait for the wire.
  Future<bool> enqueueAndDrain(
    String? refreshToken, {
    AuthTokenIssuer? issuer,
  }) async {
    final queued = await _store.enqueue(refreshToken, issuer: issuer);
    if (queued && !_disposed) unawaited(drain());
    return queued;
  }

  /// Coalesces startup, recovery, timer, and multi-caller wakeups into a single
  /// sequential drain. Repeated failures schedule one capped-backoff timer.
  Future<void> drain() {
    if (_disposed) return Future<void>.value();
    final active = _activeDrain;
    if (active != null) return active;

    _retryTimer?.cancel();
    _retryTimer = null;
    late final Future<void> run;
    run = _runDrain().whenComplete(() {
      if (identical(_activeDrain, run)) _activeDrain = null;
    });
    _activeDrain = run;
    return run;
  }

  Future<void> _runDrain() async {
    try {
      while (!_disposed) {
        final pending = await _store.pendingEntries();
        if (pending.isEmpty) {
          _consecutiveFailures = 0;
          return;
        }

        var progressed = false;
        for (final entry in pending) {
          if (_disposed) return;
          if (!await _revoke(entry)) continue;
          // A failed secure-storage deletion leaves the token queued. The next
          // attempt may duplicate logout, which is deliberately idempotent.
          await _store.remove(entry.refreshToken, issuer: entry.issuer);
          progressed = true;
        }
        _consecutiveFailures = 0;
        if (!progressed) return;
        // Re-read before returning so an enqueue that raced this snapshot is
        // drained without requiring another wakeup.
      }
    } catch (_) {
      if (_disposed) return;
      _consecutiveFailures++;
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer?.isActive == true) return;
    final int index;
    if (_retryDelays.isEmpty) {
      index = -1;
    } else {
      index = (_consecutiveFailures - 1).clamp(0, _retryDelays.length - 1);
    }
    final delay = index < 0 ? const Duration(minutes: 5) : _retryDelays[index];
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(drain());
    });
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
  }
}

final pendingRefreshRevocationStoreProvider =
    Provider<PendingRefreshRevocationStore>(
      (ref) => PendingRefreshRevocationStore(ref.watch(secureStorageProvider)),
    );

/// Dedicated transport for the only mutation this retry queue may replay.
/// Reading [apiClientProvider] at attempt time picks up a post-recovery client
/// without rebuilding or disposing the single-flight drainer.
final pendingRefreshLogoutTransportProvider = Provider<RefreshTokenRevoker>(
  (ref) => (entry) async {
    final endpoint = ref.read(apiBaseUrlProvider);
    if (!ref
        .read(authBackendRealmPolicyProvider)
        .canUse(entry.issuer, endpoint))
      return false;
    final client = ref.read(apiClientProvider);
    if (!ref
        .read(authBackendRealmPolicyProvider)
        .canUse(entry.issuer, client.baseUrl))
      return false;
    await client.post(
      ApiEndpoints.authLogout,
      body: <String, String>{'refreshToken': entry.refreshToken},
    );
    return true;
  },
);

/// App-lifetime coordinator: drains once at startup, on connection recovery,
/// and on its own capped backoff. The app root watches this provider even when
/// no local authenticated session remains.
final pendingRefreshRevocationDrainerProvider =
    Provider<PendingRefreshRevocationDrainer>((ref) {
      final drainer = PendingRefreshRevocationDrainer(
        store: ref.watch(pendingRefreshRevocationStoreProvider),
        revoke: ref.watch(pendingRefreshLogoutTransportProvider),
      );
      ref.listen<int>(
        connectionRecoveryProvider.select((state) => state.recoveryEpoch),
        (previous, next) {
          if (previous != null && next > previous) unawaited(drainer.drain());
        },
      );
      ref.listen<String>(apiBaseUrlProvider, (previous, next) {
        if (previous != null && previous != next) unawaited(drainer.drain());
      });
      ref.onDispose(drainer.dispose);
      unawaited(drainer.drain());
      return drainer;
    });

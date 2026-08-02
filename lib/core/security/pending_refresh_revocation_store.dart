import 'dart:convert';

import 'auth_refresh_lock.dart';
import 'secure_storage.dart';

/// One refresh token waiting for the public, idempotent logout endpoint.
///
/// The token remains exclusively inside [SecureStorage]. Callers must never
/// log, broadcast, or copy instances into ordinary preference storage.
class PendingRefreshRevocation {
  const PendingRefreshRevocation({
    required this.refreshToken,
    required this.createdAt,
    required this.expiresAt,
  });

  final String refreshToken;
  final DateTime createdAt;
  final DateTime expiresAt;

  Map<String, Object> toJson() => <String, Object>{
    'refreshToken': refreshToken,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
  };

  static PendingRefreshRevocation? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final refreshToken = value['refreshToken'];
    final createdAt = value['createdAt'];
    final expiresAt = value['expiresAt'];
    if (refreshToken is! String ||
        refreshToken.isEmpty ||
        refreshToken.length > PendingRefreshRevocationStore.maxTokenLength ||
        createdAt is! num ||
        expiresAt is! num) {
      return null;
    }
    final createdAtMillis = createdAt.toInt();
    final expiresAtMillis = expiresAt.toInt();
    if (createdAtMillis < 0 || expiresAtMillis <= createdAtMillis) return null;
    return PendingRefreshRevocation(
      refreshToken: refreshToken,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMillis),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMillis),
    );
  }
}

/// Encrypted, bounded queue for refresh-token revocations that could not yet
/// reach the server.
///
/// Queue mutations use a separate cross-tab lock. A drain reads a snapshot,
/// releases the lock for the network call, and removes only the exact token
/// after a successful response. Therefore concurrent tabs may make duplicate
/// idempotent logout calls, but cannot overwrite newer queued tokens.
class PendingRefreshRevocationStore {
  PendingRefreshRevocationStore(
    this._storage, {
    DateTime Function()? now,
    this.maxEntries = defaultMaxEntries,
    this.retention = defaultRetention,
  }) : _now = now ?? DateTime.now,
       _lock = AuthRefreshLock(_lockScope) {
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
    if (retention <= Duration.zero) {
      throw ArgumentError.value(retention, 'retention', 'must be positive');
    }
  }

  static const int defaultMaxEntries = 32;
  static const int maxTokenLength = 512;

  /// Longer than the normal seven-day server TTL, while still bounding how
  /// long an unreachable credential remains on the device.
  static const Duration defaultRetention = Duration(days: 30);

  static const String _storageKey = 'auth.pending_refresh_revocations.v1';
  static const String _lockScope = 'pending-refresh-revocations.v1';

  final SecureStorage _storage;
  final DateTime Function() _now;
  final int maxEntries;
  final Duration retention;
  final AuthRefreshLock _lock;

  /// Persists [refreshToken] before any best-effort network revocation starts.
  /// Exact duplicates are folded into one newest entry with a fresh expiry.
  Future<bool> enqueue(String? refreshToken) {
    if (!_isQueueable(refreshToken)) return Future<bool>.value(false);
    final token = refreshToken!;
    return _lock.synchronized(() async {
      final now = _now();
      final entries = await _readActiveLocked(now);
      entries.removeWhere((entry) => entry.refreshToken == token);
      entries.add(
        PendingRefreshRevocation(
          refreshToken: token,
          createdAt: now,
          expiresAt: now.add(retention),
        ),
      );
      entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (entries.length > maxEntries) {
        entries.removeRange(0, entries.length - maxEntries);
      }
      await _writeLocked(entries);
      return true;
    });
  }

  /// Returns active raw tokens only to the dedicated logout drainer.
  Future<List<String>> pendingTokens() => _lock.synchronized(() async {
    final entries = await _readActiveLocked(_now());
    return List<String>.unmodifiable(
      entries.map((entry) => entry.refreshToken),
    );
  });

  /// Removes only the exact token that received a successful 2xx response.
  Future<void> remove(String refreshToken) => _lock.synchronized(() async {
    final entries = await _readActiveLocked(_now());
    entries.removeWhere((entry) => entry.refreshToken == refreshToken);
    await _writeLocked(entries);
  });

  Future<List<PendingRefreshRevocation>> _readActiveLocked(DateTime now) async {
    final raw = await _storage.read(_storageKey);
    if (raw == null || raw.isEmpty) return <PendingRefreshRevocation>[];

    var rewrite = false;
    final parsed = <PendingRefreshRevocation>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['entries'] is! List<dynamic>) {
        await _storage.delete(_storageKey);
        return parsed;
      }
      for (final value in decoded['entries'] as List<dynamic>) {
        final entry = PendingRefreshRevocation.tryParse(value);
        if (entry == null || !entry.expiresAt.isAfter(now)) {
          rewrite = true;
          continue;
        }
        final duplicate = parsed.indexWhere(
          (candidate) => candidate.refreshToken == entry.refreshToken,
        );
        if (duplicate < 0) {
          parsed.add(entry);
        } else {
          rewrite = true;
          if (entry.expiresAt.isAfter(parsed[duplicate].expiresAt)) {
            parsed[duplicate] = entry;
          }
        }
      }
    } catch (_) {
      // A malformed revocation queue must never influence auth restoration.
      // Erase it without inspecting or exporting its credential-like content.
      await _storage.delete(_storageKey);
      return parsed;
    }

    parsed.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (parsed.length > maxEntries) {
      parsed.removeRange(0, parsed.length - maxEntries);
      rewrite = true;
    }
    if (rewrite) await _writeLocked(parsed);
    return parsed;
  }

  Future<void> _writeLocked(List<PendingRefreshRevocation> entries) async {
    if (entries.isEmpty) {
      await _storage.delete(_storageKey);
      return;
    }
    await _storage.write(
      _storageKey,
      jsonEncode(<String, Object>{
        'version': 1,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      }),
    );
  }

  static bool _isQueueable(String? token) =>
      token != null && token.isNotEmpty && token.length <= maxTokenLength;
}

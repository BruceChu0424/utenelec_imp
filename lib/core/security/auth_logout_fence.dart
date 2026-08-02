import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/providers/shared_providers.dart';

/// Non-sensitive durable marker that blocks token restoration after a logout
/// whose authoritative secure-storage clear could not be completed.
abstract interface class AuthLogoutFence {
  Future<bool> isActive();

  Future<void> activate();

  Future<void> clear();
}

class SharedPreferencesAuthLogoutFence implements AuthLogoutFence {
  SharedPreferencesAuthLogoutFence(this._preferences);

  static const storageKey = 'auth.logout_fail_closed.v1';

  final SharedPreferences _preferences;

  @override
  Future<bool> isActive() async {
    await _preferences.reload();
    final value = _preferences.get(storageKey);
    // A malformed marker is still treated as active. Only an explicit,
    // verified removal may re-enable automatic token restoration.
    return value == null
        ? false
        : value is bool
        ? value
        : true;
  }

  @override
  Future<void> activate() async {
    final saved = await _preferences.setBool(storageKey, true);
    if (saved) return;

    // Some platform implementations can report a failed write after the value
    // was persisted. Verify the independent store before failing closed.
    await _preferences.reload();
    if (_preferences.get(storageKey) != true) {
      throw StateError('Unable to persist the logout fence');
    }
  }

  @override
  Future<void> clear() async {
    await _preferences.reload();
    if (_preferences.get(storageKey) == null) return;

    final removed = await _preferences.remove(storageKey);
    if (removed) return;

    // Removal is idempotent: a platform may report false when the key is
    // already absent. A still-present marker remains a hard failure.
    await _preferences.reload();
    if (_preferences.get(storageKey) != null) {
      throw StateError('Unable to clear the logout fence');
    }
  }
}

final authLogoutFenceProvider = Provider<AuthLogoutFence>((ref) {
  return SharedPreferencesAuthLogoutFence(ref.watch(sharedPreferencesProvider));
});

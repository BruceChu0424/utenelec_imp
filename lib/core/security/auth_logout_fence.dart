import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/providers/shared_providers.dart';
import 'tab_scoped_store.dart';

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

/// 登出栅栏的标签页级实现（Web；ADR-061）。
///
/// 栅栏守护的是「本标签页登出未完成，禁止自动恢复」——多账号多标签页并行后，
/// 它必须只封闭本标签页：A 标签页登出失败不得把 B 标签页（另一账号）也挡在
/// 恢复之外。存储随标签页销毁，无需跨标签页 reload 校验。
class TabScopedAuthLogoutFence implements AuthLogoutFence {
  TabScopedAuthLogoutFence(this._store);

  static const storageKey = 'auth.logout_fail_closed.v1';

  final TabScopedStore _store;

  @override
  Future<bool> isActive() async {
    final value = await _store.read(storageKey);
    // 与 SharedPreferences 版一致：只有明确的删除才能解除封闭；
    // 任何残留/异常值一律视为激活（fail-closed）。
    return value != null;
  }

  @override
  Future<void> activate() => _store.write(storageKey, 'true');

  @override
  Future<void> clear() => _store.delete(storageKey);
}

final authLogoutFenceProvider = Provider<AuthLogoutFence>((ref) {
  final tabScoped = createBrowserTabScopedStore();
  if (tabScoped != null) {
    return TabScopedAuthLogoutFence(tabScoped);
  }
  return SharedPreferencesAuthLogoutFence(ref.watch(sharedPreferencesProvider));
});

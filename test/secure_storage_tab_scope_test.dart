// 标签页级会话隔离（ADR-061）：同一浏览器多个标签页各自登录不同账号互不顶替。
// 覆盖：记录按 scope 隔离、登录/登出互不影响、旧版共享记录一次性收编、
// 模拟身份键隔离、登出栅栏标签页化、共享键（撤销队列/记住账号）保持跨标签页可见。
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/security/tab_scoped_store.dart';

class _InMemoryTabScopedStore implements TabScopedStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('staff token records are isolated per tab-scoped store', () async {
    const rawStorage = FlutterSecureStorage();
    final tabA = SecureStorage(
      rawStorage,
      sessionScope: _InMemoryTabScopedStore(),
    );
    final tabB = SecureStorage(
      rawStorage,
      sessionScope: _InMemoryTabScopedStore(),
    );

    await tabA.saveTokens(accessToken: 'a-access', refreshToken: 'a-refresh');

    final snapshotA = await tabA.getAuthTokenSnapshot();
    final snapshotB = await tabB.getAuthTokenSnapshot();
    expect(snapshotA.accessToken, 'a-access');
    expect(snapshotA.refreshToken, 'a-refresh');
    expect(snapshotB.hasTokens, isFalse);
  });

  test(
    'a later login in another tab never replaces an earlier tab session',
    () async {
      const rawStorage = FlutterSecureStorage();
      final tabA = SecureStorage(
        rawStorage,
        sessionScope: _InMemoryTabScopedStore(),
      );
      final tabB = SecureStorage(
        rawStorage,
        sessionScope: _InMemoryTabScopedStore(),
      );

      await tabA.saveTokens(accessToken: 'a-access', refreshToken: 'a-refresh');
      await tabB.saveTokens(accessToken: 'b-access', refreshToken: 'b-refresh');

      expect(
        (await tabA.getAuthTokenSnapshot()).refreshToken,
        'a-refresh',
        reason: 'B 标签页登录后，A 标签页必须仍是 A 账号',
      );
      expect((await tabB.getAuthTokenSnapshot()).refreshToken, 'b-refresh');
    },
  );

  test('logout in one tab only tombstones its own record', () async {
    const rawStorage = FlutterSecureStorage();
    final tabA = SecureStorage(
      rawStorage,
      sessionScope: _InMemoryTabScopedStore(),
    );
    final tabB = SecureStorage(
      rawStorage,
      sessionScope: _InMemoryTabScopedStore(),
    );
    await tabA.saveTokens(accessToken: 'a-access', refreshToken: 'a-refresh');
    await tabB.saveTokens(accessToken: 'b-access', refreshToken: 'b-refresh');

    final cleared = await tabA.clearForLogoutIntent();

    expect(cleared.previous.refreshToken, 'a-refresh');
    expect((await tabA.getAuthTokenSnapshot()).hasTokens, isFalse);
    final survivor = await tabB.getAuthTokenSnapshot();
    expect(survivor.accessToken, 'b-access');
    expect(survivor.refreshToken, 'b-refresh');
  });

  test(
    'legacy shared record is adopted once and the shared copy removed',
    () async {
      const legacy = AuthTokenSnapshot(
        accessToken: 'legacy-access',
        refreshToken: 'legacy-refresh',
        generation: 4,
        intentGeneration: 3,
        sessionLineage: 'lineage-legacy',
      );
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'auth.token_record.v1': jsonEncode(legacy.toJson()),
      });
      const rawStorage = FlutterSecureStorage();
      final firstTab = SecureStorage(
        rawStorage,
        sessionScope: _InMemoryTabScopedStore(),
      );

      final snapshot = await firstTab.getAuthTokenSnapshot();

      expect(snapshot.accessToken, 'legacy-access');
      expect(snapshot.refreshToken, 'legacy-refresh');
      expect(snapshot.sessionLineage, 'lineage-legacy');
      // 共享副本已删除：后续新开的标签页（独立 scope）不得继承旧会话。
      expect(await rawStorage.read(key: 'auth.token_record.v1'), isNull);
      final secondTab = SecureStorage(
        rawStorage,
        sessionScope: _InMemoryTabScopedStore(),
      );
      expect((await secondTab.getAuthTokenSnapshot()).hasTokens, isFalse);
    },
  );

  test('scoped record wins over a stale legacy shared copy', () async {
    const legacy = AuthTokenSnapshot(
      accessToken: 'legacy-access',
      refreshToken: 'legacy-refresh',
      generation: 4,
      intentGeneration: 3,
      sessionLineage: 'lineage-legacy',
    );
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'auth.token_record.v1': jsonEncode(legacy.toJson()),
    });
    const rawStorage = FlutterSecureStorage();
    const scoped = AuthTokenSnapshot(
      accessToken: 'scoped-access',
      refreshToken: 'scoped-refresh',
      generation: 9,
      intentGeneration: 8,
      sessionLineage: 'lineage-scoped',
    );
    final scope = _InMemoryTabScopedStore();
    await scope.write('auth.token_record.v1', jsonEncode(scoped.toJson()));
    final tab = SecureStorage(rawStorage, sessionScope: scope);

    final snapshot = await tab.getAuthTokenSnapshot();

    expect(snapshot.accessToken, 'scoped-access');
    expect(snapshot.sessionLineage, 'lineage-scoped');
  });

  test('impersonation keys are isolated per tab scope', () async {
    const rawStorage = FlutterSecureStorage();
    final tabA = SecureStorage(
      rawStorage,
      sessionScope: _InMemoryTabScopedStore(),
    );
    final tabB = SecureStorage(
      rawStorage,
      sessionScope: _InMemoryTabScopedStore(),
    );

    await tabA.saveImpersonationRecord(
      ImpersonationRecord(
        accessToken: 'imp-access',
        windowExpiresAtEpochMs: DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
        lineage: 'imp-lineage',
      ),
    );

    expect((await tabA.getImpersonationRecord())?.accessToken, 'imp-access');
    expect(await tabB.getImpersonationRecord(), isNull);
  });

  test('shared keys remain visible across tab scopes', () async {
    const rawStorage = FlutterSecureStorage();
    final tabA = SecureStorage(
      rawStorage,
      sessionScope: _InMemoryTabScopedStore(),
    );
    final tabB = SecureStorage(
      rawStorage,
      sessionScope: _InMemoryTabScopedStore(),
    );

    // 登出撤销队列必须跨标签页持久（登出后关标签页仍要能补撤销）。
    await tabA.write(
      'auth.pending_refresh_revocations.v1',
      '{"version":1,"entries":[]}',
    );
    expect(await tabB.read('auth.pending_refresh_revocations.v1'), isNotNull);
    // 记住账号是设备级便利功能，各标签页共享。
    await tabA.saveLoginAccount('boss');
    expect(await tabB.getLoginAccount(), 'boss');
  });

  test('tab-scoped logout fence activates, clears and fails closed', () async {
    final store = _InMemoryTabScopedStore();
    final fence = TabScopedAuthLogoutFence(store);
    final otherTabFence = TabScopedAuthLogoutFence(_InMemoryTabScopedStore());

    expect(await fence.isActive(), isFalse);
    await fence.activate();
    expect(await fence.isActive(), isTrue);
    // 栅栏只属于本标签页：另一标签页的栅栏不受影响。
    expect(await otherTabFence.isActive(), isFalse);
    await fence.clear();
    expect(await fence.isActive(), isFalse);

    // 异常值一律视为激活（fail-closed），与 SharedPreferences 版一致。
    await store.write(TabScopedAuthLogoutFence.storageKey, 'malformed');
    expect(await fence.isActive(), isTrue);
  });
}

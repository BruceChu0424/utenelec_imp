import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('conditional refresh cannot overwrite another instance login', () async {
    const rawStorage = FlutterSecureStorage();
    final refreshStorage = SecureStorage(rawStorage);
    final loginStorage = SecureStorage(rawStorage);
    await refreshStorage.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
    );
    final submitted = await refreshStorage.getAuthTokenSnapshot();

    final loginWrite = loginStorage.saveTokens(
      accessToken: 'login-access',
      refreshToken: 'login-refresh',
    );
    final staleRefreshWrite = refreshStorage.saveTokensIfUnchanged(
      expected: submitted,
      accessToken: 'stale-access',
      refreshToken: 'stale-refresh',
    );

    await loginWrite;
    expect(await staleRefreshWrite, isFalse);
    final current = await refreshStorage.getAuthTokenSnapshot();
    expect(current.accessToken, 'login-access');
    expect(current.refreshToken, 'login-refresh');
    expect(current.generation, submitted.generation + 1);
    expect(current.sessionLineage, isNot(submitted.sessionLineage));
  });

  test('later cross-instance logout fences an older login response', () async {
    const rawStorage = FlutterSecureStorage();
    final oldTab = SecureStorage(rawStorage);
    final logoutTab = SecureStorage(rawStorage);
    await oldTab.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
    );
    final oldLogin = await oldTab.beginSessionIntent(clearTokens: true);

    final logout = await logoutTab.clearForLogoutIntent();
    final staleCommit = await oldTab.commitSessionIntentTokens(
      intent: oldLogin.intent,
      accessToken: 'stale-access',
      refreshToken: 'stale-refresh',
    );

    expect(staleCommit, isNull);
    final current = await oldTab.getAuthTokenSnapshot();
    expect(current.hasTokens, isFalse);
    expect(current.sessionLineage, logout.tombstone.sessionLineage);
    expect(
      current.intentGeneration,
      greaterThan(oldLogin.intent.intentGeneration),
    );
  });

  test('later cross-instance login wins over an earlier logout', () async {
    const rawStorage = FlutterSecureStorage();
    final logoutTab = SecureStorage(rawStorage);
    final loginTab = SecureStorage(rawStorage);
    await logoutTab.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
    );
    final logout = await logoutTab.clearForLogoutIntent();

    final login = await loginTab.beginSessionIntent(clearTokens: true);
    final committed = await loginTab.commitSessionIntentTokens(
      intent: login.intent,
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
    );

    expect(committed, isNotNull);
    expect(committed!.accessToken, 'new-access');
    expect(
      committed.intentGeneration,
      greaterThan(logout.tombstone.intentGeneration),
    );
  });

  test(
    'reserved lineage rejects an old response after counter reset',
    () async {
      const rawStorage = FlutterSecureStorage();
      final oldTab = SecureStorage(rawStorage);
      final newTab = SecureStorage(rawStorage);
      final oldIntent = await oldTab.beginSessionIntent(clearTokens: true);

      // Simulate the all-key deletion fallback: the next record starts counters
      // from zero, so intentGeneration alone would collide at 1.
      await rawStorage.delete(key: 'auth.token_record.v1');
      final newIntent = await newTab.beginSessionIntent(clearTokens: true);
      expect(
        newIntent.intent.intentGeneration,
        oldIntent.intent.intentGeneration,
      );
      expect(
        newIntent.intent.reservedLineage,
        isNot(oldIntent.intent.reservedLineage),
      );

      final staleCommit = await oldTab.commitSessionIntentTokens(
        intent: oldIntent.intent,
        accessToken: 'stale-access',
        refreshToken: 'stale-refresh',
      );
      final currentAfterStale = await newTab.getAuthTokenSnapshot();

      expect(staleCommit, isNull);
      expect(
        currentAfterStale.sessionLineage,
        newIntent.intent.reservedLineage,
      );
      final currentCommit = await newTab.commitSessionIntentTokens(
        intent: newIntent.intent,
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );
      expect(currentCommit?.accessToken, 'new-access');
    },
  );

  test(
    'another storage instance receives non-sensitive record notice',
    () async {
      const rawStorage = FlutterSecureStorage();
      final observing = SecureStorage(rawStorage);
      final writing = SecureStorage(rawStorage);
      final noticeFuture = observing.onExternalAuthTokenChanged.first;

      await writing.saveTokens(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );
      final notice = await noticeFuture;
      final current = await observing.getAuthTokenSnapshot();

      expect(notice.generation, current.generation);
      expect(notice.intentGeneration, current.intentGeneration);
      expect(notice.sessionLineage, current.sessionLineage);
      expect(notice.hasTokens, isTrue);
    },
  );
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/security/auth_refresh_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const raw = FlutterSecureStorage();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'dynamic owner locks retain queued callers and recover after failure',
    () async {
      var active = 0, maximum = 0, completed = 0;
      await Future.wait([
        for (var i = 0; i < 50; i++)
          AuthRefreshLock.runScoped('visitor-lock-test', () async {
            active++;
            if (active > maximum) maximum = active;
            try {
              await Future<void>.delayed(Duration.zero);
              if (i == 25) throw StateError('one failed rotation');
            } finally {
              active--;
              completed++;
            }
          }, requireWebLocks: true).then<void>(
            (_) {},
            onError: (Object error) {
              expect(i, 25);
              expect(error, isA<StateError>());
            },
          ),
      ]);
      expect(maximum, 1);
      expect(completed, 50);
      expect(
        await AuthRefreshLock.runScoped(
          'visitor-lock-test',
          () async => 7,
          requireWebLocks: true,
        ),
        7,
      );
    },
  );

  test(
    'login and logout retire in-flight rotations before remote completion',
    () async {
      final storage = SecureStorage(raw);
      await storage.saveVisitorTokens(accessToken: 'A', refreshToken: 'AR');
      final a = await storage.getVisitorTokenSnapshot();
      final intent = await storage.beginVisitorLoginIntent();
      expect(intent.hasAccessToken, false);
      expect(intent.hasRefreshToken, false);
      expect(
        await storage.saveVisitorTokensIfUnchanged(
          expected: a,
          accessToken: 'late-A',
          refreshToken: 'late-AR',
        ),
        false,
      );
      expect(
        await storage.completeVisitorLoginIfUnchanged(
          expected: intent,
          accessToken: 'B',
          refreshToken: 'BR',
        ),
        true,
      );
      final b = await storage.getVisitorTokenSnapshot();
      expect(
        (await storage.retireVisitorSessionIfCurrent(b))!.isSameRecord(b),
        true,
      );
      expect((await storage.getVisitorTokenSnapshot()).hasAccessToken, false);
      expect(
        await storage.saveVisitorTokensIfUnchanged(
          expected: b,
          accessToken: 'late-B',
          refreshToken: 'late-BR',
        ),
        false,
      );
    },
  );

  test(
    'new owner replacement never mixes a missing credential with the old owner',
    () async {
      final storage = SecureStorage(raw);
      await storage.saveVisitorTokens(accessToken: 'A', refreshToken: 'AR');
      final a = await storage.getVisitorTokenSnapshot();
      await storage.saveVisitorTokens(accessToken: 'B');
      final b = await storage.getVisitorTokenSnapshot();
      expect(b.accessToken, 'B');
      expect(b.refreshToken, isNull);
      expect(b.isSameSession(a), false);
      await storage.saveVisitorTokens(refreshToken: 'CR');
      final c = await storage.getVisitorTokenSnapshot();
      expect(c.accessToken, isNull);
      expect(c.refreshToken, 'CR');
      expect(c.isSameSession(b), false);
    },
  );

  test(
    'legacy visitor pair migrates once and refresh preserves its owner',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'visitor.access_token': 'A',
        'visitor.refresh_token': 'R',
      });
      final storage = SecureStorage(raw);
      final before = await storage.getVisitorTokenSnapshot();
      expect(before.accessToken, 'A');
      expect(before.refreshToken, 'R');
      expect(await raw.read(key: 'visitor.access_token'), isNull);
      expect(await raw.read(key: 'visitor.refresh_token'), isNull);
      expect(
        await storage.saveVisitorTokensIfUnchanged(
          expected: before,
          accessToken: 'A2',
        ),
        true,
      );
      final refreshed = await storage.getVisitorTokenSnapshot();
      expect(refreshed.sessionLineage, before.sessionLineage);
      expect(refreshed.generation, before.generation + 1);
      expect(refreshed.refreshToken, 'R');
      await storage.saveVisitorTokens(accessToken: 'B', refreshToken: 'BR');
      final login = await storage.getVisitorTokenSnapshot();
      expect(login.sessionLineage, isNot(refreshed.sessionLineage));
      expect(await storage.clearVisitorTokensIfUnchanged(refreshed), false);
      expect(
        await storage.saveVisitorTokensIfUnchanged(
          expected: refreshed,
          accessToken: 'late',
        ),
        false,
      );
      expect(
        (await storage.getVisitorTokenSnapshot()).isSameRecord(login),
        true,
      );
    },
  );

  test(
    'corrupt or cleared authority never revives abandoned legacy tokens',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'visitor.token_record.v1': '{corrupt',
        'visitor.access_token': 'stale',
        'visitor.refresh_token': 'stale-refresh',
      });
      final storage = SecureStorage(raw);
      expect((await storage.getVisitorTokenSnapshot()).hasAccessToken, false);
      await storage.saveVisitorTokens(accessToken: 'A', refreshToken: 'R');
      await storage.clearVisitorTokens();
      await raw.write(key: 'visitor.access_token', value: 'residual');
      await raw.write(key: 'visitor.refresh_token', value: 'residual-refresh');
      expect((await storage.getVisitorTokenSnapshot()).hasAccessToken, false);
      expect((await storage.getVisitorTokenSnapshot()).hasRefreshToken, false);
    },
  );

  test(
    'hundreds of competing instances have one CAS winner and no mixed pair',
    () async {
      final first = SecureStorage(raw), second = SecureStorage(raw);
      await first.saveVisitorTokens(accessToken: 'A', refreshToken: 'R');
      final owner = await first.getVisitorTokenSnapshot();
      final saves = await Future.wait([
        for (var i = 0; i < 100; i++)
          (i.isEven ? first : second).saveVisitorTokensIfUnchanged(
            expected: owner,
            accessToken: 'access-$i',
            refreshToken: 'refresh-$i',
          ),
      ]);
      expect(saves.where((saved) => saved), hasLength(1));
      final after = await first.getVisitorTokenSnapshot();
      expect(after.generation, owner.generation + 1);
      expect(after.accessToken!.substring(7), after.refreshToken!.substring(8));
      final clears = await Future.wait([
        for (var i = 0; i < 100; i++)
          (i.isEven ? first : second).clearVisitorTokensIfUnchanged(after),
      ]);
      expect(clears.where((cleared) => cleared), hasLength(1));
      final cleared = await first.getVisitorTokenSnapshot();
      expect(cleared.hasAccessToken, false);
      expect(cleared.hasRefreshToken, false);
      expect(cleared.generation, after.generation + 1);
    },
  );

  test(
    'failed atomic write keeps legacy pair and releases the queue',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'visitor.access_token': 'A',
        'visitor.refresh_token': 'R',
      });
      final failed = SecureStorage(const _FaultyStorage(failWrite: true));
      await expectLater(failed.getVisitorTokenSnapshot(), throwsStateError);
      expect(await raw.read(key: 'visitor.access_token'), 'A');
      expect(await raw.read(key: 'visitor.refresh_token'), 'R');
      final normal = SecureStorage(raw);
      expect((await normal.getVisitorTokenSnapshot()).accessToken, 'A');
      await expectLater(
        failed.saveVisitorTokens(accessToken: 'B', refreshToken: 'BR'),
        throwsStateError,
      );
      expect((await normal.getVisitorTokenSnapshot()).accessToken, 'A');
    },
  );

  test(
    'legacy cleanup failure leaves the single authority committed',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'visitor.access_token': 'A',
        'visitor.refresh_token': 'R',
      });
      final storage = SecureStorage(const _FaultyStorage(failDelete: true));
      expect((await storage.getVisitorTokenSnapshot()).accessToken, 'A');
      await storage.clearVisitorTokens();
      expect(await raw.read(key: 'visitor.access_token'), 'A');
      expect((await storage.getVisitorTokenSnapshot()).hasAccessToken, false);
    },
  );
}

class _FaultyStorage extends FlutterSecureStorage {
  const _FaultyStorage({this.failWrite = false, this.failDelete = false});
  final bool failWrite, failDelete;
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failWrite && key == 'visitor.token_record.v1') {
      throw StateError('record write failed');
    }
    return super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failDelete) throw StateError('legacy cleanup failed');
    return super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

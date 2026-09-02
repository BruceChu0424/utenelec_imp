import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rawStorage = FlutterSecureStorage();

  group('SecureStorage staff token record', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
    });

    test('从旧 access/refresh 键迁移为单一带代次记录', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'auth.access_token': 'legacy-access',
        'auth.refresh_token': 'legacy-refresh',
      });
      final storage = SecureStorage(rawStorage);

      final snapshot = await storage.getAuthTokenSnapshot();

      expect(snapshot.accessToken, 'legacy-access');
      expect(snapshot.refreshToken, 'legacy-refresh');
      expect(snapshot.generation, 1);
      final record =
          jsonDecode((await rawStorage.read(key: 'auth.token_record.v1'))!)
              as Map<String, dynamic>;
      expect(record['accessToken'], 'legacy-access');
      expect(record['refreshToken'], 'legacy-refresh');
      expect(record['generation'], 1);
      expect(record['intentGeneration'], 1);
      expect(record['sessionLineage'], isA<String>());
      expect(await rawStorage.read(key: 'auth.access_token'), isNull);
      expect(await rawStorage.read(key: 'auth.refresh_token'), isNull);
    });

    test(
      'corrupt authoritative record never revives residual legacy tokens',
      () async {
        FlutterSecureStorage.setMockInitialValues(<String, String>{
          'auth.token_record.v1': '{corrupt-json',
          'auth.access_token': 'stale-access',
          'auth.refresh_token': 'stale-refresh',
        });
        final storage = SecureStorage(rawStorage);

        final snapshot = await storage.getAuthTokenSnapshot();

        expect(snapshot.hasTokens, isFalse);
        expect(snapshot.sessionLineage, isNotEmpty);
        expect(await rawStorage.read(key: 'auth.access_token'), isNull);
        expect(await rawStorage.read(key: 'auth.refresh_token'), isNull);
        final persisted = AuthTokenSnapshot.tryParse(
          await rawStorage.read(key: 'auth.token_record.v1'),
        );
        expect(persisted, isNotNull);
        expect(persisted!.hasTokens, isFalse);
      },
    );

    test('令牌对在一个记录内更新且未提供的 refresh 会被保留', () async {
      final storage = SecureStorage(rawStorage);
      await storage.saveTokens(
        accessToken: 'first-access',
        refreshToken: 'first-refresh',
      );
      final first = await storage.getAuthTokenSnapshot();

      await storage.saveTokens(accessToken: 'second-access');
      final second = await storage.getAuthTokenSnapshot();

      expect(first.generation, 1);
      expect(second.accessToken, 'second-access');
      expect(second.refreshToken, 'first-refresh');
      expect(second.generation, 2);
      final record =
          jsonDecode((await rawStorage.read(key: 'auth.token_record.v1'))!)
              as Map<String, dynamic>;
      expect(record['version'], 2);
      expect(record['generation'], 2);
      expect(record['intentGeneration'], 2);
      expect(record['sessionLineage'], isA<String>());
      expect(record['accessToken'], 'second-access');
      expect(record['refreshToken'], 'first-refresh');
    });

    test('旧代次不能覆盖或清理已经更新的令牌对', () async {
      final storage = SecureStorage(rawStorage);
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      final old = await storage.getAuthTokenSnapshot();
      await storage.saveTokens(
        accessToken: 'current-access',
        refreshToken: 'current-refresh',
      );

      expect(await storage.clearTokensIfUnchanged(old), isFalse);
      expect(
        await storage.saveTokensIfUnchanged(
          expected: old,
          accessToken: 'stale-access',
          refreshToken: 'stale-refresh',
        ),
        isFalse,
      );
      expect(await storage.getAccessToken(), 'current-access');
      expect(await storage.getRefreshToken(), 'current-refresh');
    });

    test('清理写入不含令牌的新代次 tombstone', () async {
      final storage = SecureStorage(rawStorage);
      await storage.saveTokens(accessToken: 'access', refreshToken: 'refresh');
      final before = await storage.getAuthTokenSnapshot();

      await storage.clearTokens();
      final after = await storage.getAuthTokenSnapshot();

      expect(after.accessToken, isNull);
      expect(after.refreshToken, isNull);
      expect(after.generation, before.generation + 1);
      final raw = await rawStorage.read(key: 'auth.token_record.v1');
      expect(raw, isNot(contains(':"access"')));
      expect(raw, isNot(contains(':"refresh"')));
    });
    test(
      'legacy cleanup failure does not roll back the authoritative record',
      () async {
        FlutterSecureStorage.setMockInitialValues(<String, String>{
          'auth.access_token': 'legacy-access',
          'auth.refresh_token': 'legacy-refresh',
        });
        final storage = SecureStorage(
          const _FaultyRawStorage(
            failDeletes: <String>{'auth.access_token', 'auth.refresh_token'},
          ),
        );

        final snapshot = await storage.getAuthTokenSnapshot();

        expect(snapshot.accessToken, 'legacy-access');
        expect(snapshot.refreshToken, 'legacy-refresh');
        expect(await rawStorage.read(key: 'auth.token_record.v1'), isNotNull);
      },
    );

    test(
      'logout falls back to deleting every token key when record write fails',
      () async {
        final normal = SecureStorage(rawStorage);
        await normal.saveTokens(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
        );
        final failing = SecureStorage(
          const _FaultyRawStorage(failRecordWrites: true),
        );

        final result = await failing.clearForLogoutIntent();

        expect(result.previous.accessToken, 'old-access');
        expect(await rawStorage.read(key: 'auth.token_record.v1'), isNull);
        expect(await rawStorage.read(key: 'auth.access_token'), isNull);
        expect(await rawStorage.read(key: 'auth.refresh_token'), isNull);
      },
    );

    test(
      'logout propagates when record write and deletion fallback both fail',
      () async {
        final normal = SecureStorage(rawStorage);
        await normal.saveTokens(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
        );
        final failing = SecureStorage(
          const _FaultyRawStorage(
            failRecordWrites: true,
            failDeletes: <String>{'auth.token_record.v1'},
          ),
        );

        await expectLater(
          failing.clearForLogoutIntent(),
          throwsA(isA<StateError>()),
        );
        expect(await normal.getAccessToken(), 'old-access');
        expect(await normal.getRefreshToken(), 'old-refresh');
      },
    );

    test(
      'failed user-intent write preserves the previous authoritative record',
      () async {
        final normal = SecureStorage(rawStorage);
        await normal.saveTokens(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
        );
        final failing = SecureStorage(
          const _FaultyRawStorage(failRecordWrites: true),
        );

        await expectLater(
          failing.beginSessionIntent(clearTokens: true),
          throwsA(isA<StateError>()),
        );
        expect(await normal.getAccessToken(), 'old-access');
        expect(await normal.getRefreshToken(), 'old-refresh');
      },
    );
  });
}

class _FaultyRawStorage extends FlutterSecureStorage {
  const _FaultyRawStorage({
    this.failRecordWrites = false,
    this.failDeletes = const <String>{},
  });

  final bool failRecordWrites;
  final Set<String> failDeletes;

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
    if (failRecordWrites && key == 'auth.token_record.v1') {
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
    if (failDeletes.contains(key)) {
      throw StateError('delete failed: $key');
    }
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

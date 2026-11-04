@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/security/tab_scoped_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platformStorage = FlutterSecureStorage();
  final issuer = AuthBackendRealmPolicy().issuerFor('https://old.example/api');

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'desktop restart cannot restore or change another running process',
    () async {
      final runningScope = ProcessSessionScopedStore();
      final running = SecureStorage(
        platformStorage,
        sessionScope: runningScope,
      );
      await running.saveTokens(
        accessToken: 'active-access',
        refreshToken: 'active-refresh',
        issuer: issuer,
      );
      final sameProcess = SecureStorage(
        platformStorage,
        sessionScope: runningScope,
      );
      expect(await sameProcess.getRefreshToken(), 'active-refresh');
      expect(await platformStorage.read(key: 'auth.token_record.v1'), isNull);

      final reopened = SecureStorage(
        platformStorage,
        sessionScope: ProcessSessionScopedStore(),
      );
      final retired = <AuthTokenSnapshot>[];
      await reopened.prepareForApplicationSession(
        retirePersistedSession: (previous) async => retired.add(previous),
      );
      expect((await reopened.getAuthTokenSnapshot()).hasTokens, isFalse);
      expect(retired, isEmpty);
      expect(await running.getRefreshToken(), 'active-refresh');
    },
  );

  test(
    'legacy desktop credentials are queued with their original issuer before deletion',
    () async {
      final legacy = AuthTokenSnapshot(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        generation: 7,
        intentGeneration: 3,
        sessionLineage: 'old-lineage',
        issuer: issuer,
      );
      FlutterSecureStorage.setMockInitialValues({
        'auth.token_record.v1': jsonEncode(legacy.toJson()),
        'auth.login_account': 'remembered-account',
        'auth.impersonation_mode.v1': 'old-mode',
      });
      final storage = SecureStorage(
        platformStorage,
        sessionScope: ProcessSessionScopedStore(),
      );
      // Requests racing bootstrap cannot revive the old installation's login.
      expect((await storage.getAuthTokenSnapshot()).hasTokens, isFalse);
      final queue = PendingRefreshRevocationStore(storage);
      var calls = 0;
      Future<void> retire(AuthTokenSnapshot previous) async {
        calls++;
        expect(
          await platformStorage.read(key: 'auth.token_record.v1'),
          isNotNull,
        );
        await queue.enqueue(previous.refreshToken, issuer: previous.issuer);
      }

      await storage.prepareForApplicationSession(
        retirePersistedSession: retire,
      );
      await storage.prepareForApplicationSession(
        retirePersistedSession: retire,
      );
      expect(calls, 1);
      expect(await platformStorage.read(key: 'auth.token_record.v1'), isNull);
      expect(
        await platformStorage.read(key: 'auth.impersonation_mode.v1'),
        isNull,
      );
      expect(await storage.getLoginAccount(), 'remembered-account');
      final entries = await queue.pendingEntries();
      expect(entries.single.refreshToken, 'old-refresh');
      expect(entries.single.issuer, issuer);
      expect((await storage.getAuthTokenSnapshot()).hasTokens, isFalse);
    },
  );

  test(
    'failed durable queueing preserves cleanup retry without restoring credentials',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'auth.access_token': 'old-access',
        'auth.refresh_token': 'old-refresh',
      });
      final storage = SecureStorage(
        platformStorage,
        sessionScope: ProcessSessionScopedStore(),
      );
      await expectLater(
        storage.prepareForApplicationSession(
          retirePersistedSession: (_) async =>
              throw StateError('storage unavailable'),
        ),
        throwsStateError,
      );
      expect(
        await platformStorage.read(key: 'auth.refresh_token'),
        'old-refresh',
      );
      expect((await storage.getAuthTokenSnapshot()).hasTokens, isFalse);
      final retired = <String?>[];
      await storage.prepareForApplicationSession(
        retirePersistedSession: (previous) async =>
            retired.add(previous.refreshToken),
      );
      expect(retired, ['old-refresh']);
      expect(await platformStorage.read(key: 'auth.refresh_token'), isNull);
    },
  );

  test(
    'corrupt authoritative record never revives stale two-key credentials',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'auth.token_record.v1': '{broken',
        'auth.refresh_token': 'stale-refresh',
      });
      final storage = SecureStorage(
        platformStorage,
        sessionScope: ProcessSessionScopedStore(),
      );
      final retired = <AuthTokenSnapshot>[];
      await storage.prepareForApplicationSession(
        retirePersistedSession: (previous) async => retired.add(previous),
      );
      expect(retired, isEmpty);
      expect((await storage.getAuthTokenSnapshot()).hasTokens, isFalse);
      expect(await platformStorage.read(key: 'auth.refresh_token'), isNull);
    },
  );

  test(
    'an early explicit login preserves legacy retirement and its new process session',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'auth.refresh_token': 'previous-refresh',
      });
      final storage = SecureStorage(
        platformStorage,
        sessionScope: ProcessSessionScopedStore(),
      );
      await storage.saveTokens(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
        issuer: issuer,
      );
      expect(
        await platformStorage.read(key: 'auth.refresh_token'),
        'previous-refresh',
      );
      final retired = <String?>[];
      await storage.prepareForApplicationSession(
        retirePersistedSession: (previous) async =>
            retired.add(previous.refreshToken),
      );
      expect(retired, ['previous-refresh']);
      expect(await storage.getRefreshToken(), 'new-refresh');
      expect(await platformStorage.read(key: 'auth.refresh_token'), isNull);
    },
  );
}

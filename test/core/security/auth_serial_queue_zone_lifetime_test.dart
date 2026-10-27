@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/auth_refresh_lock.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an idle shared auth lock remains usable after its first FakeAsync zone ends',
    () {
      late AuthRefreshLock lock;
      final calls = <String>[];
      int? firstResult;
      Object? error;
      fakeAsync((firstZone) {
        // Creating the initial queue inside this zone avoids a RootZone future
        // making the first operation itself an unrelated false failure.
        lock = AuthRefreshLock('auth-lock-zone-lifetime-regression');
        unawaited(
          lock
              .synchronized(() async {
                calls.add('first');
                return 1;
              })
              .then<void>(
                (result) => firstResult = result,
                onError: (Object failure, StackTrace _) => error = failure,
              ),
        );
        firstZone.flushMicrotasks();
        expect(error, isNull);
        expect(firstResult, 1);
        expect(calls, ['first']);
      });

      int? secondResult;
      fakeAsync((secondZone) {
        final sameScope = AuthRefreshLock('auth-lock-zone-lifetime-regression');
        expect(identical(sameScope, lock), isTrue);
        unawaited(
          sameScope
              .synchronized(() async {
                calls.add('second');
                return 2;
              })
              .then<void>(
                (result) => secondResult = result,
                onError: (Object failure, StackTrace _) => error = failure,
              ),
        );
        secondZone.flushMicrotasks();
        expect(error, isNull);
        expect(
          secondResult,
          2,
          reason:
              'An idle queue must not await a completed predecessor through an ended FakeAsync zone.',
        );
        expect(calls, ['first', 'second']);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'independent staff record queues can CAS the same record across FakeAsync zones',
    () {
      late SecureStorage storage;
      late AuthTokenSnapshot initial;
      AuthTokenSnapshot? firstRead;
      bool? firstSaved;
      Object? error;
      fakeAsync((firstZone) {
        initial = AuthTokenSnapshot(
          accessToken: 'initial-access',
          refreshToken: 'initial-refresh',
          generation: 7,
          intentGeneration: 3,
          sessionLineage: 'zone-lifetime-session',
          issuer: AuthBackendRealmPolicy().issuerFor(
            'https://zone-lifetime.example.test/api',
          ),
        );
        FlutterSecureStorage.setMockInitialValues({
          'auth.token_record.v1': jsonEncode(initial.toJson()),
        });
        storage = SecureStorage(
          const FlutterSecureStorage(),
          staffTokenRecordLock: AuthRefreshLock(
            'staff-record-zone-lifetime-regression',
          ),
        );
        unawaited(
          storage.getAuthTokenSnapshot().then<void>(
            (record) => firstRead = record,
            onError: (Object failure, StackTrace _) => error = failure,
          ),
        );
        firstZone.flushMicrotasks();
        expect(error, isNull);
        expect(firstRead?.isSameSession(initial), isTrue);

        unawaited(
          storage
              .saveTokensIfUnchanged(
                expected: initial,
                accessToken: 'first-zone-access',
                refreshToken: 'first-zone-refresh',
                issuer: initial.issuer,
              )
              .then<void>(
                (saved) => firstSaved = saved,
                onError: (Object failure, StackTrace _) => error = failure,
              ),
        );
        firstZone.flushMicrotasks();
        expect(error, isNull);
        expect(firstSaved, isTrue);
      });

      AuthTokenSnapshot? secondRead;
      bool? secondSaved;
      bool? staleSaved;
      AuthTokenSnapshot? finalRead;
      fakeAsync((secondZone) {
        // This instance and its mutation lock are both new in the second zone.
        // Only SecureStorage's process-wide access queue spans the two zones.
        final nextStorage = SecureStorage(
          const FlutterSecureStorage(),
          staffTokenRecordLock: AuthRefreshLock(
            'staff-record-zone-lifetime-regression-second',
          ),
        );
        unawaited(
          nextStorage.getAuthTokenSnapshot().then<void>(
            (record) => secondRead = record,
            onError: (Object failure, StackTrace _) => error = failure,
          ),
        );
        secondZone.flushMicrotasks();
        expect(error, isNull);
        expect(
          secondRead,
          isNotNull,
          reason:
              'The shared staff record access queue must release its completed zone before a later reader arrives.',
        );
        expect(secondRead!.accessToken, 'first-zone-access');
        expect(secondRead!.generation, initial.generation + 1);
        expect(secondRead!.intentGeneration, initial.intentGeneration);
        expect(secondRead!.sessionLineage, initial.sessionLineage);
        expect(secondRead!.issuer, initial.issuer);

        unawaited(
          nextStorage
              .saveTokensIfUnchanged(
                expected: secondRead!,
                accessToken: 'second-zone-access',
                refreshToken: 'second-zone-refresh',
                issuer: initial.issuer,
              )
              .then<void>(
                (saved) => secondSaved = saved,
                onError: (Object failure, StackTrace _) => error = failure,
              ),
        );
        secondZone.flushMicrotasks();
        expect(error, isNull);
        expect(secondSaved, isTrue);
        unawaited(
          nextStorage
              .saveTokensIfUnchanged(
                expected: initial,
                accessToken: 'stale-access',
                refreshToken: 'stale-refresh',
              )
              .then<void>(
                (saved) => staleSaved = saved,
                onError: (Object failure, StackTrace _) => error = failure,
              ),
        );
        secondZone.flushMicrotasks();
        expect(error, isNull);
        expect(staleSaved, isFalse);
        unawaited(
          nextStorage.getAuthTokenSnapshot().then<void>(
            (record) => finalRead = record,
            onError: (Object failure, StackTrace _) => error = failure,
          ),
        );
        secondZone.flushMicrotasks();
        expect(error, isNull);
        expect(finalRead?.accessToken, 'second-zone-access');
        expect(finalRead?.refreshToken, 'second-zone-refresh');
        expect(finalRead?.generation, initial.generation + 2);
        expect(finalRead?.intentGeneration, initial.intentGeneration);
        expect(finalRead?.sessionLineage, initial.sessionLineage);
        expect(finalRead?.issuer, initial.issuer);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

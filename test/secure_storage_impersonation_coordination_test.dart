import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/core/security/auth_refresh_lock.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/security/tab_scoped_store.dart';

const _impKey = 'auth.impersonation_record.v1';
const _modeKey = 'auth.impersonation_mode.v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('ordinary scope reads do not acquire a new platform lease', () async {
    final lock = _CountingMutationLock();
    final storage = SecureStorage(
      const FlutterSecureStorage(),
      sessionScope: _Store(),
      staffTokenRecordLock: lock,
    );
    await storage.saveTokens(accessToken: 'staff', refreshToken: 'refresh');
    await storage.saveImpersonationRecord(_imp('target'));
    await storage.saveImpersonationModeToken('mode');
    final writes = lock.acquisitions;
    for (var index = 0; index < 12; index++) {
      expect((await storage.getAuthTokenSnapshot()).hasAccessToken, isTrue);
      expect((await storage.getImpersonationRecord())?.lineage, 'target');
      expect(await storage.getImpersonationModeToken(), 'mode');
    }
    expect(lock.acquisitions, writes);
    expect(writes, 3);
  });

  test(
    'lazy metadata migration takes one mutation lease without read deadlock',
    () async {
      final lock = _CountingMutationLock();
      final store = _Store();
      store.values['auth.token_record.v1'] = jsonEncode({
        'version': 1,
        'generation': 4,
        'accessToken': 'legacy-access',
        'refreshToken': 'legacy-refresh',
      });
      final storage = SecureStorage(
        const FlutterSecureStorage(),
        sessionScope: store,
        staffTokenRecordLock: lock,
      );
      final upgraded = await storage.getAuthTokenSnapshot().timeout(
        const Duration(seconds: 2),
      );
      expect(upgraded.hasCompleteMetadata, isTrue);
      expect(lock.acquisitions, 1);
      expect(await storage.getImpersonationRecord(), isNull);
      expect(await storage.getImpersonationModeToken(), isNull);
      expect(
        (await storage.getAuthTokenSnapshot()).sessionLineage,
        upgraded.sessionLineage,
      );
      expect(lock.acquisitions, 1);
    },
  );

  test(
    'first conditional save can adopt the old shared record inside the write gate',
    () async {
      const legacy = AuthTokenSnapshot(
        accessToken: 'legacy-access',
        refreshToken: 'legacy-refresh',
        generation: 4,
        intentGeneration: 3,
        sessionLineage: 'legacy-lineage',
      );
      FlutterSecureStorage.setMockInitialValues({
        'auth.token_record.v1': jsonEncode(legacy.toJson()),
      });
      final lock = _CountingMutationLock();
      final storage = SecureStorage(
        const FlutterSecureStorage(),
        sessionScope: _Store(),
        staffTokenRecordLock: lock,
      );
      expect(
        await storage
            .saveImpersonationRecordIfCurrent(
              record: _imp('target'),
              staffLineage: 'legacy-lineage',
              staffIntent: 3,
            )
            .timeout(const Duration(seconds: 2)),
        isTrue,
      );
      expect(lock.acquisitions, 1);
      expect((await storage.getImpersonationRecord())?.lineage, 'target');
      expect(
        await const FlutterSecureStorage().read(key: 'auth.token_record.v1'),
        isNull,
      );
    },
  );

  test(
    'explicit exit can clear mode after the target record disappeared',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationModeToken('remaining-mode');
      expect(
        await fixture.first.clearImpersonationIfUnchanged(
          lineage: null,
          clearMode: true,
          staffLineage: fixture.auth.sessionLineage,
          staffIntent: fixture.auth.intentGeneration,
          isCurrent: () => true,
        ),
        isTrue,
      );
      expect(await fixture.first.getImpersonationRecord(), isNull);
      expect(await fixture.first.getImpersonationModeToken(), isNull);
    },
  );

  test(
    'absent-record exit refuses a new or unreadable target record',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationModeToken('new-mode');
      for (final raw in [
        jsonEncode(_imp('new-target').toJson()),
        '{unreadable',
      ]) {
        fixture.store.values[_impKey] = raw;
        expect(
          await fixture.first.clearImpersonationIfUnchanged(
            lineage: null,
            clearMode: true,
            staffLineage: fixture.auth.sessionLineage,
            staffIntent: fixture.auth.intentGeneration,
            isCurrent: () => true,
          ),
          isFalse,
        );
        expect(fixture.store.values[_impKey], raw);
        expect(await fixture.first.getImpersonationModeToken(), 'new-mode');
      }
    },
  );

  test(
    'stale expiry leaves a newer impersonation and mode untouched',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationRecord(_imp('new'));
      await fixture.first.saveImpersonationModeToken('new-mode');
      expect(
        await fixture.first.clearImpersonationIfUnchanged(
          lineage: 'old',
          clearMode: true,
          staffLineage: fixture.auth.sessionLineage,
          staffIntent: fixture.auth.intentGeneration,
        ),
        isFalse,
      );
      expect((await fixture.first.getImpersonationRecord())?.lineage, 'new');
      expect(await fixture.first.getImpersonationModeToken(), 'new-mode');
    },
  );

  test(
    'queued newer save and mode survive an old clear paused at deletion',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationRecord(_imp('old'));
      await fixture.first.saveImpersonationModeToken('old-mode');
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.store.beforeDelete = (key) async {
        if (key == _impKey) {
          entered.complete();
          await release.future;
        }
      };
      final clear = fixture.first.clearImpersonationIfUnchanged(
        lineage: 'old',
        clearMode: true,
        staffLineage: fixture.auth.sessionLineage,
        staffIntent: fixture.auth.intentGeneration,
      );
      await entered.future;
      var newerSaved = false;
      final save = fixture.save('new').then((value) {
        newerSaved = value;
        return value;
      });
      final mode = fixture.second.saveImpersonationModeToken('new-mode');
      await Future<void>.delayed(Duration.zero);
      expect(newerSaved, isFalse);
      release.complete();
      expect(await clear, isTrue);
      expect(await save, isTrue);
      await mode;
      expect((await fixture.first.getImpersonationRecord())?.lineage, 'new');
      expect(await fixture.first.getImpersonationModeToken(), 'new-mode');
    },
  );

  test(
    'old clear waiting behind a newer platform save cannot delete it',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationRecord(_imp('old'));
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.store.afterWrite = (key, value) async {
        if (key == _impKey && _lineage(value) == 'new') {
          entered.complete();
          await release.future;
        }
      };
      final save = fixture.save('new');
      await entered.future;
      final staleClear = fixture.first.clearImpersonationIfUnchanged(
        lineage: 'old',
      );
      release.complete();
      expect(await save, isTrue);
      expect(await staleClear, isFalse);
      expect((await fixture.first.getImpersonationRecord())?.lineage, 'new');
    },
  );

  test(
    'superseded platform write rolls back before readers and next switch',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationRecord(_imp('original'));
      final entered = Completer<void>();
      final release = Completer<void>();
      var current = true;
      fixture.store.afterWrite = (key, value) async {
        if (key == _impKey && _lineage(value) == 'superseded') {
          entered.complete();
          await release.future;
        }
      };
      final oldSave = fixture.save('superseded', isCurrent: () => current);
      await entered.future;
      current = false;
      var readFinished = false;
      final reader = fixture.first.getImpersonationRecord().then((value) {
        readFinished = true;
        return value;
      });
      final newerSave = fixture.save('winner');
      await Future<void>.delayed(Duration.zero);
      expect(readFinished, isFalse);
      release.complete();
      expect(await oldSave, isFalse);
      expect((await reader)?.lineage, 'original');
      expect(await newerSave, isTrue);
      expect((await fixture.first.getImpersonationRecord())?.lineage, 'winner');
    },
  );

  test(
    'a newer login ordered before impersonation commit rejects old staff',
    () async {
      final fixture = await _Fixture.create();
      final login = fixture.first.saveTokens(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );
      final stale = fixture.save('stale');
      await login;
      expect(await stale, isFalse);
      expect(await fixture.first.getImpersonationRecord(), isNull);
    },
  );

  test(
    'a failed platform acknowledgement restores the previous record',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationRecord(_imp('original'));
      fixture.store.afterWrite = (key, value) async {
        if (key == _impKey && _lineage(value) == 'unconfirmed') {
          throw StateError('platform acknowledgement failed after write');
        }
      };
      await expectLater(fixture.save('unconfirmed'), throwsStateError);
      expect(
        (await fixture.first.getImpersonationRecord())?.lineage,
        'original',
      );
    },
  );

  test(
    'new local intent during expiry deletion keeps its source mode usable',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationRecord(_imp('original'));
      await fixture.first.saveImpersonationModeToken('original-mode');
      final entered = Completer<void>();
      final release = Completer<void>();
      var current = true;
      fixture.store.beforeDelete = (key) async {
        if (key == _impKey) {
          entered.complete();
          await release.future;
        }
      };
      final clear = fixture.first.clearImpersonationIfUnchanged(
        lineage: 'original',
        clearMode: true,
        isCurrent: () => current,
        staffLineage: fixture.auth.sessionLineage,
        staffIntent: fixture.auth.intentGeneration,
      );
      await entered.future;
      current = false;
      final mode = fixture.second.getImpersonationModeToken();
      final newerSave = fixture.save('winner');
      release.complete();
      expect(await clear, isFalse);
      expect(await mode, 'original-mode');
      expect(await newerSave, isTrue);
      expect((await fixture.first.getImpersonationRecord())?.lineage, 'winner');
    },
  );

  test('a refresh generation preserves the original staff identity', () async {
    final fixture = await _Fixture.create();
    expect(
      await fixture.first.saveTokensIfUnchanged(
        expected: fixture.auth,
        accessToken: 'refreshed',
        refreshToken: 'refreshed-refresh',
      ),
      isTrue,
    );
    expect(await fixture.save('same-session'), isTrue);
    expect(
      (await fixture.first.getImpersonationRecord())?.lineage,
      'same-session',
    );
  });

  test(
    'password intent blocks stale expiry even when staff lineage stays equal',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationRecord(_imp('target'));
      await fixture.first.saveImpersonationModeToken('mode');
      await fixture.second.beginSessionIntent(clearTokens: false);
      expect(
        await fixture.first.clearImpersonationIfUnchanged(
          lineage: 'target',
          clearMode: true,
          staffLineage: fixture.auth.sessionLineage,
          staffIntent: fixture.auth.intentGeneration,
        ),
        isFalse,
      );
      expect((await fixture.first.getImpersonationRecord())?.lineage, 'target');
      expect(await fixture.first.getImpersonationModeToken(), 'mode');
    },
  );

  test(
    'lost local intent before save cannot overwrite the current record',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationRecord(_imp('winner'));
      expect(await fixture.save('old', isCurrent: () => false), isFalse);
      expect((await fixture.first.getImpersonationRecord())?.lineage, 'winner');
    },
  );

  test(
    'a stale mode-entry response cannot replace the new login mode',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveTokens(
        accessToken: 'new-login',
        refreshToken: 'new-refresh',
      );
      await fixture.first.saveImpersonationModeToken('winner-mode');
      expect(await fixture.saveMode('old-mode'), isFalse);
      expect(await fixture.first.getImpersonationModeToken(), 'winner-mode');
    },
  );

  test(
    'superseded mode platform write rolls back before readers and next entry',
    () async {
      final fixture = await _Fixture.create();
      await fixture.first.saveImpersonationModeToken('original-mode');
      final entered = Completer<void>();
      final release = Completer<void>();
      var current = true;
      fixture.store.afterWrite = (key, value) async {
        if (key == _modeKey && value == 'superseded-mode') {
          entered.complete();
          await release.future;
        }
      };
      final oldSave = fixture.saveMode(
        'superseded-mode',
        isCurrent: () => current,
      );
      await entered.future;
      current = false;
      var readFinished = false;
      final reader = fixture.first.getImpersonationModeToken().then((value) {
        readFinished = true;
        return value;
      });
      final newer = fixture.saveMode('winner-mode');
      await Future<void>.delayed(Duration.zero);
      expect(readFinished, isFalse);
      release.complete();
      expect(await oldSave, isFalse);
      expect(await reader, 'original-mode');
      expect(await newer, isTrue);
      expect(await fixture.first.getImpersonationModeToken(), 'winner-mode');
      expect(await fixture.first.getImpersonationRecord(), isNull);
    },
  );

  test(
    'expiry bus retains exact metadata and distinguishes banner signals',
    () async {
      const notice = ImpersonationExpiryNotice(
        lineage: 'target',
        staffLineage: 'staff',
        staffIntent: 3,
        baseUrl: 'https://erp.example.test/api',
      );
      final events = <ImpersonationExpiryNotice?>[];
      final complete = Completer<void>();
      final subscription = SessionEventBus.instance.onImpersonationExpired
          .listen((event) {
            events.add(event);
            if (events.length == 2) complete.complete();
          });
      try {
        SessionEventBus.instance.impersonationExpired(notice);
        SessionEventBus.instance.impersonationExpired();
        await complete.future;
        expect(events, [same(notice), isNull]);
        expect(events.first!.staffIntent, 3);
      } finally {
        await subscription.cancel();
      }
    },
  );
}

ImpersonationRecord _imp(String lineage) => ImpersonationRecord(
  accessToken: '$lineage-access',
  lineage: lineage,
  windowExpiresAtEpochMs: DateTime.now()
      .add(const Duration(minutes: 5))
      .millisecondsSinceEpoch,
);

String _lineage(String raw) =>
    (jsonDecode(raw) as Map<String, dynamic>)['lineage'] as String;

class _Fixture {
  _Fixture(this.store, this.first, this.second, this.auth);
  final _Store store;
  final SecureStorage first;
  final SecureStorage second;
  final AuthTokenSnapshot auth;

  static Future<_Fixture> create() async {
    final store = _Store();
    final first = SecureStorage(
      const FlutterSecureStorage(),
      sessionScope: store,
    );
    final second = SecureStorage(
      const FlutterSecureStorage(),
      sessionScope: store,
    );
    await first.saveTokens(
      accessToken: 'staff-access',
      refreshToken: 'staff-refresh',
    );
    return _Fixture(store, first, second, await first.getAuthTokenSnapshot());
  }

  Future<bool> save(String lineage, {bool Function()? isCurrent}) =>
      second.saveImpersonationRecordIfCurrent(
        record: _imp(lineage),
        staffLineage: auth.sessionLineage!,
        staffIntent: auth.intentGeneration,
        isCurrent: isCurrent,
      );

  Future<bool> saveMode(String token, {bool Function()? isCurrent}) =>
      second.saveImpersonationModeTokenIfCurrent(
        token: token,
        staffLineage: auth.sessionLineage!,
        staffIntent: auth.intentGeneration,
        isCurrent: isCurrent,
      );
}

class _Store implements TabScopedStore {
  final values = <String, String>{};
  Future<void> Function(String key, String value)? afterWrite;
  Future<void> Function(String key)? beforeDelete;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    await afterWrite?.call(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await beforeDelete?.call(key);
    values.remove(key);
  }
}

class _CountingMutationLock implements AuthRefreshLock {
  int acquisitions = 0;

  @override
  Future<T> synchronized<T>(Future<T> Function() action) async {
    acquisitions++;
    return await action();
  }
}

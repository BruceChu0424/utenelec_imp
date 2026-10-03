import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/audit/device_audit_receipt_storage_api.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture f;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    f = _Fixture(await SharedPreferences.getInstance());
  });

  for (final kind in [
    'plain',
    'v2-valid',
    'v2-invalid',
    'v3-valid',
    'v3-invalid',
    'v3-unverified',
  ]) {
    test(
      'imports every $kind original without laundering its provenance',
      () async {
        final id = _id(1);
        final raw = await f.seed(kind, [_receipt(id)]);
        final expected = kind == 'v2-valid' || kind == 'v3-valid';
        expect((await f.store.findReceipt(id))?.integrityVerified, expected);
        expect(f.ledger.values.values, contains(raw));
        await f.seed('v2-valid', [
          _receipt(id),
        ]); // An older writer cannot replace v4.
        await _begin(f.store, _id(2));
        expect((await f.store.findReceipt(id))?.integrityVerified, expected);
        expect((await f.store.findReceipt(_id(2)))?.integrityVerified, isTrue);
      },
    );
  }

  for (final broken in [null, '', '{broken']) {
    test(
      'adopted v3 $broken never falls back to an older signed legacy ledger',
      () async {
        await f.seed('v2-valid', [_receipt(_id(3))]);
        await f.secure.write(_v3Adopted, '3');
        if (broken != null) await f.preferences.setString(_v3, broken);
        expect(await f.store.findReceipt(_id(3)), isNull);
        expect(
          f.ledger.values.keys.where((key) => key.startsWith('legacy_')),
          isNotEmpty,
        );
      },
    );
    test('adopted v4 $broken never reimports an older ledger', () async {
      await f.seed('v2-valid', [_receipt(_id(4))]);
      expect(await f.store.findReceipt(_id(4)), isNotNull);
      if (broken == null) {
        f.ledger.values.remove('receipt_${_id(4)}');
      } else {
        f.ledger.values['receipt_${_id(4)}'] = broken;
      }
      expect(await f.store.findReceipt(_id(4)), isNull);
      expect(await f.secure.read(_v4Adopted), '4');
    });
  }

  test('old signed envelope cannot downgrade a v4 record', () async {
    final raw = await f.seed('v2-valid', [_receipt(_id(5))]);
    expect(await f.store.findReceipt(_id(5)), isNotNull);
    f.ledger.values['receipt_${_id(5)}'] = raw;
    expect(await f.store.findReceipt(_id(5)), isNull);
  });

  for (final conflict in [false, true]) {
    test(
      'failed import cannot publish adoption and remains retryable (CAS=$conflict)',
      () async {
        final raw = await f.seed('v2-valid', [_receipt(_id(6))]);
        f.ledger.fail = !conflict;
        f.ledger.reject = conflict;
        final store = f.store;
        await expectLater(store.findReceipt(_id(6)), throwsStateError);
        expect(await f.secure.read(_v4Adopted), isNull);
        expect(f.ledger.values['migration_v4'], isNull);
        expect(f.preferences.getString(_legacy), raw);
        f.ledger.fail = false;
        f.ledger.reject = false;
        expect((await store.findReceipt(_id(6)))?.integrityVerified, isTrue);
      },
    );
    test(
      'failed completion keeps the durable pending outcome (CAS=$conflict)',
      () async {
        final store = f.store;
        await _begin(store, _id(7));
        final original = f.ledger.values['receipt_${_id(7)}'];
        f.ledger.fail = !conflict;
        f.ledger.reject = conflict;
        await expectLater(
          store.completeReceipt(
            clientEventId: _id(7),
            outcome: 'success',
            completedAt: DateTime.now().toUtc(),
            statusCode: 200,
          ),
          throwsStateError,
        );
        expect(f.ledger.values['receipt_${_id(7)}'], original);
        expect((await f.store.findReceipt(_id(7)))?.outcome, 'pending');
        f.ledger.fail = false;
        f.ledger.reject = false;
        await store.completeReceipt(
          clientEventId: _id(7),
          outcome: 'success',
          completedAt: DateTime.now().toUtc(),
          statusCode: 200,
        );
        expect((await f.store.findReceipt(_id(7)))?.outcome, 'success');
        expect(f.ledger.history.values, contains(original));
      },
    );
  }

  test(
    'marker failure uses the completed import instead of newer laundered legacy input',
    () async {
      await f.seed('v2-invalid', [_receipt(_id(8))]);
      f.secure.failAdoption = true;
      final store = f.store;
      await expectLater(store.findReceipt(_id(8)), throwsStateError);
      expect(f.ledger.values['migration_v4'], isNotNull);
      await f.seed('v2-valid', [_receipt(_id(8))]);
      f.secure.failAdoption = false;
      expect((await store.findReceipt(_id(8)))?.integrityVerified, isFalse);
    },
  );

  test(
    'two first importers serialize and do not reread a newer legacy source',
    () async {
      await f.seed('v2-invalid', [_receipt(_id(9))]);
      f.ledger.pauseFirstReceipt = true;
      addTearDown(() {
        if (!f.ledger.release.isCompleted) f.ledger.release.complete();
      });
      final first = f.store.findReceipt(_id(9));
      await f.ledger.entered.future;
      await f.seed('v2-valid', [_receipt(_id(9))]);
      final second = f.store.findReceipt(_id(9));
      f.ledger.release.complete();
      expect((await first)?.integrityVerified, isFalse);
      expect((await second)?.integrityVerified, isFalse);
    },
  );

  test(
    'tampering and a later real retry never authenticate altered prior history',
    () async {
      await _begin(f.store, _id(10), path: '/api/original');
      final key = 'receipt_${_id(10)}';
      final raw = f.ledger.values[key]!;
      f.ledger.values[key] = raw.replaceFirst('/api/original', '/api/tampered');
      final store = f.store;
      expect((await store.findReceipt(_id(10)))?.integrityVerified, isFalse);
      await _begin(store, _id(11));
      await _begin(store, _id(10), path: '/api/retry');
      await store.completeReceipt(
        clientEventId: _id(10),
        outcome: 'success',
        completedAt: DateTime.now().toUtc(),
      );
      final retained = await f.store.findReceipt(_id(10));
      expect(retained?.integrityVerified, isFalse);
      expect(retained?.previousAttempts.single.path, '/api/tampered');
      expect((await f.store.findReceipt(_id(11)))?.integrityVerified, isTrue);
      expect(
        f.ledger.history.values.any((value) => value.contains('/api/tampered')),
        isTrue,
      );
    },
  );

  test(
    'an unreadable prior record is retained and cannot be blessed by a new attempt',
    () async {
      final store = f.store;
      await _begin(store, _id(12));
      f.ledger.values['receipt_${_id(12)}'] = '{damaged-original';
      await _begin(store, _id(12));
      expect((await f.store.findReceipt(_id(12)))?.integrityVerified, isFalse);
      expect(f.ledger.history.values, contains('{damaged-original'));
    },
  );

  test('signed content is bound to the requested operation ID', () async {
    await _begin(f.store, _id(13));
    f.ledger.values['receipt_${_id(14)}'] =
        f.ledger.values['receipt_${_id(13)}']!;
    expect(await f.store.findReceipt(_id(14)), isNull);
  });

  test(
    'separate instances retain concurrent writes and all attempts on one ID',
    () async {
      final first = f.store;
      final second = f.store;
      await Future.wait([_begin(first, _id(15)), _begin(second, _id(16))]);
      expect(await first.findReceipt(_id(16)), isNotNull);
      expect(await second.findReceipt(_id(15)), isNotNull);
      await Future.wait([
        _begin(first, _id(15), path: '/api/a'),
        _begin(second, _id(15), path: '/api/b'),
      ]);
      final result = await first.findReceipt(_id(15));
      expect(result?.allAttempts.length, 3);
      expect(
        result?.allAttempts.map((row) => row.path),
        containsAll(['/api/a', '/api/b']),
      );
    },
  );

  test(
    'a burst shares one completion future but persists only the touched IDs',
    () async {
      final store = f.store;
      final writes = <Future<void>>[];
      for (var i = 100; i < 250; i++) {
        writes.add(_begin(store, _id(i)));
        writes.add(
          store.completeReceipt(
            clientEventId: _id(i),
            outcome: 'success',
            completedAt: DateTime.now().toUtc(),
            statusCode: 200,
          ),
        );
      }
      expect(writes.every((value) => identical(value, writes.first)), isTrue);
      await Future.wait(writes);
      final reopened = f.store;
      for (var i = 100; i < 250; i++) {
        final row = await reopened.findReceipt(_id(i));
        expect(row?.outcome, 'success');
        expect(row?.integrityVerified, isTrue);
      }
    },
  );

  test(
    'age and more than 300 entries do not delete records; reads and updates stay per ID',
    () async {
      final store = f.store;
      await store.updateRetentionMonths(1);
      final writes = <Future<void>>[];
      for (var i = 1000; i < 1501; i++) {
        writes.add(_begin(store, _id(i), startedAt: DateTime.utc(1990)));
      }
      await Future.wait(writes);
      final reopened = f.store;
      expect(await reopened.findReceipt(_id(1000)), isNotNull);
      expect(await reopened.findReceipt(_id(1500)), isNotNull);
      f.ledger.reads.clear();
      final writesBefore = f.ledger.writes;
      await reopened.completeReceipt(
        clientEventId: _id(1000),
        outcome: 'success',
        completedAt: DateTime.now().toUtc(),
      );
      expect(f.ledger.reads, ['receipt_${_id(1000)}']);
      expect(f.ledger.writes - writesBefore, 1);
      f.ledger.reads.clear();
      expect(await reopened.findReceipt(_id(1001)), isNotNull);
      expect(f.ledger.reads, ['receipt_${_id(1001)}']);
    },
  );

  test(
    'legacy rows with unknown dates and damaged rows retain their exact source envelope',
    () async {
      final row = _receipt(_id(17)).toJson()..['startedAt'] = '';
      final raw = jsonEncode([
        row,
        {'unknown': 'keep the exact malformed row'},
      ]);
      await f.preferences.setString(_legacy, raw);
      final found = await f.store.findReceipt(_id(17));
      expect(found?.startedAt, '');
      expect(found?.integrityVerified, isFalse);
      expect(f.ledger.values.values, contains(raw));
    },
  );

  test(
    'retries retain request IDs, time and results with verified persistence',
    () async {
      final store = f.store;
      await _begin(
        store,
        _id(18),
        path: '/api/first',
        startedAt: DateTime.utc(1990),
      );
      await store.completeReceipt(
        clientEventId: _id(18),
        outcome: 'unknown',
        completedAt: DateTime.utc(1990, 1, 2),
        serverRequestId: _id(19),
      );
      await _begin(
        store,
        _id(18),
        path: '/api/retry',
        startedAt: DateTime.utc(2026),
      );
      await store.completeReceipt(
        clientEventId: _id(18),
        outcome: 'success',
        completedAt: DateTime.utc(2026, 1, 2),
        statusCode: 200,
        serverRequestId: _id(20),
      );
      final row = await f.store.findReceipt(_id(18));
      expect(row?.previousAttempts.single.serverRequestId, _id(19));
      expect(row?.previousAttempts.single.outcome, 'unknown');
      expect(row?.serverRequestId, _id(20));
      expect(row?.integrityVerified, isTrue);
    },
  );

  for (final mode in ['read', 'write', 'drop']) {
    test(
      'signing key $mode failure never publishes a trusted receipt and retries safely',
      () async {
        f.secure.keyFailure = mode;
        final store = f.store;
        await expectLater(_begin(store, _id(30)), throwsStateError);
        expect(f.ledger.values['receipt_${_id(30)}'], isNull);
        expect(f.ledger.values['migration_v4'], isNull);
        expect(await f.secure.read(_v4Adopted), isNull);
        f.secure.keyFailure = null;
        await _begin(store, _id(30));
        expect((await f.store.findReceipt(_id(30)))?.integrityVerified, isTrue);
      },
    );
  }
  for (final invalid in ['not base64!', base64UrlEncode(List.filled(31, 0))]) {
    test(
      'invalid existing signing key is preserved without silent rotation ($invalid)',
      () async {
        await f.secure.write(_integrityKey, invalid);
        await expectLater(_begin(f.store, _id(31)), throwsStateError);
        expect(f.secure.values[_integrityKey], invalid);
        expect(f.ledger.values['receipt_${_id(31)}'], isNull);
      },
    );
  }
  test(
    'an adopted ledger with a missing key refuses rotation and can use its restored original key',
    () async {
      await _begin(f.store, _id(32));
      final originalKey = f.secure.values.remove(_integrityKey)!;
      final original = Map<String, String>.of(f.ledger.values);
      final reopened = f.store;
      await expectLater(reopened.findReceipt(_id(32)), throwsStateError);
      expect(f.secure.values[_integrityKey], isNull);
      expect(f.ledger.values, original);
      await f.secure.write(_integrityKey, originalKey);
      expect((await reopened.findReceipt(_id(32)))?.integrityVerified, isTrue);
    },
  );
  test(
    'an intact v3 keeps older distinct IDs discoverable as unverified without replacing v3 facts',
    () async {
      final currentId = _id(33), olderId = _id(34);
      await f.seed('v3-valid', [_receipt(currentId)]);
      final replaced = LocalAuditReceipt.fromJson(
        _receipt(currentId).toJson()..['path'] = '/api/older-conflict',
      );
      await f.seed('v2-valid', [_receipt(olderId), replaced]);
      final store = f.store;
      expect((await store.findReceipt(currentId))?.path, '/api/legacy');
      expect((await store.findReceipt(currentId))?.integrityVerified, isTrue);
      expect((await store.findReceipt(olderId))?.integrityVerified, isFalse);
      await f.seed('v2-valid', [_receipt(_id(35))]);
      expect(await f.store.findReceipt(_id(35)), isNull);
    },
  );

  test(
    'a rolling old writer cannot invalidate migrated v4 receipts by replacing its v1 key',
    () async {
      final id = _id(36);
      await f.seed('v3-valid', [_receipt(id)]);
      await f.secure.write(_v3Adopted, '3');
      expect((await f.store.findReceipt(id))?.integrityVerified, isTrue);
      final retainedKey = f.secure.values[_integrityKey];
      await f.secure.write(
        _legacyIntegrityKey,
        base64UrlEncode(List.filled(32, 7)),
      );
      final changed = LocalAuditReceipt.fromJson(
        _receipt(id).toJson()..['path'] = '/api/new-old-writer',
      );
      await f.seed('v3-valid', [changed]);
      final reopened = f.store;
      expect((await reopened.findReceipt(id))?.path, '/api/legacy');
      expect((await reopened.findReceipt(id))?.integrityVerified, isTrue);
      await reopened.completeReceipt(
        clientEventId: id,
        outcome: 'success',
        completedAt: DateTime.now().toUtc(),
      );
      expect((await f.store.findReceipt(id))?.integrityVerified, isTrue);
      expect(f.secure.values[_integrityKey], retainedKey);
    },
  );
  for (final badLegacy in [null, 'broken-old-key']) {
    test(
      'adopted v3 with unavailable legacy key refuses migration ($badLegacy)',
      () async {
        await f.seed('v3-valid', [_receipt(_id(37))]);
        await f.secure.write(_v3Adopted, '3');
        if (badLegacy == null) {
          f.secure.values.remove(_legacyIntegrityKey);
        } else {
          await f.secure.write(_legacyIntegrityKey, badLegacy);
        }
        await expectLater(f.store.findReceipt(_id(37)), throwsStateError);
        expect(f.ledger.values['migration_v4'], isNull);
        expect(await f.secure.read(_v4Adopted), isNull);
        expect(f.secure.values[_legacyIntegrityKey], badLegacy);
      },
    );
  }
  test(
    'a transient legacy key read failure remains retryable without downgrading provenance',
    () async {
      await f.seed('v3-valid', [_receipt(_id(38))]);
      final store = f.store;
      f.secure.failLegacyRead = true;
      await expectLater(store.findReceipt(_id(38)), throwsStateError);
      expect(f.ledger.values['migration_v4'], isNull);
      f.secure.failLegacyRead = false;
      expect((await store.findReceipt(_id(38)))?.integrityVerified, isTrue);
    },
  );

  test(
    'an installation identity is rotated when only the keychain anchor survives',
    () async {
      final previous = _id(21);
      await f.secure.write('audit.device.installation_id', previous);
      final installed = (await f.store.profile()).installationId;
      expect(installed, isNot(previous));
      expect(await f.secure.read('audit.device.installation_id'), installed);
      expect(
        f.preferences.getString('audit.device.installation_marker.v1'),
        installed,
      );
      expect((await f.store.profile()).installationId, installed);
    },
  );
}

const _integrityKey = 'audit.device.receipt_integrity_key.v4';
const _legacyIntegrityKey = 'audit.device.receipt_integrity_key.v1';
const _legacy = 'audit.device.local_receipts.v1';
const _v3 = 'audit.device.local_receipts.v3';
const _v3Adopted = 'audit.device.local_receipts.v3.adopted';
const _v4Adopted = 'audit.device.local_receipts.v4.adopted';
const _profile = DeviceAuditProfile(
  installationId: '123e4567-e89b-42d3-a456-426614174000',
  deviceName: 'Test device',
  manufacturer: 'Test',
  model: 'QA-1',
  platform: 'windows',
  osVersion: 'Windows Test',
  appVersion: '1.0.0',
  appBuild: 'test',
  formFactor: 'desktop',
);
String _id(int value) =>
    '123e4567-e89b-42d3-a456-${value.toString().padLeft(12, '0')}';
LocalAuditReceipt _receipt(String id) => LocalAuditReceipt(
  clientEventId: id,
  installationId: _profile.installationId,
  method: 'GET',
  path: '/api/legacy',
  startedAt: DateTime.utc(1990).toIso8601String(),
  outcome: 'success',
  device: _profile,
);
Future<void> _begin(
  DeviceAuditStore store,
  String id, {
  String path = '/api/test',
  DateTime? startedAt,
}) => store.beginReceipt(
  clientEventId: id,
  method: 'GET',
  path: path,
  startedAt: startedAt ?? DateTime.now().toUtc(),
  device: _profile,
);

class _Fixture {
  _Fixture(this.preferences);
  final SharedPreferences preferences;
  final secure = _MemorySecureStorage();
  final ledger = _MemoryReceipts();
  DefaultDeviceAuditStore get store => DefaultDeviceAuditStore(
    secure,
    preferences: preferences,
    receiptStorage: ledger,
  );
  Future<String> seed(String kind, List<LocalAuditReceipt> rows) async {
    if (kind == 'plain') {
      final raw = jsonEncode(rows.map((row) => row.toJson()).toList());
      await preferences.setString(_legacy, raw);
      return raw;
    }
    const keyName = 'audit.device.receipt_integrity_key.v1';
    var encoded = await secure.read(keyName);
    if (encoded == null) {
      encoded = base64UrlEncode(List<int>.generate(32, (i) => i));
      await secure.write(keyName, encoded);
    }
    final isV3 = kind.startsWith('v3');
    final payload = jsonEncode(
      isV3
          ? {
              'format': 3,
              'receipts': rows
                  .map(
                    (row) => {
                      ...row.toJson(),
                      'verifiedOrigin': kind != 'v3-unverified',
                    },
                  )
                  .toList(),
            }
          : rows.map((row) => row.toJson()).toList(),
    );
    final signature = kind.endsWith('-invalid')
        ? 'bad-signature'
        : base64UrlEncode(
            Hmac(
              sha256,
              base64Url.decode(encoded),
            ).convert(utf8.encode(payload)).bytes,
          );
    final raw = jsonEncode({
      'version': isV3 ? 3 : 2,
      'payload': payload,
      'signature': signature,
    });
    await preferences.setString(isV3 ? _v3 : _legacy, raw);
    return raw;
  }
}

class _MemorySecureStorage extends SecureStorage {
  _MemorySecureStorage() : super(const FlutterSecureStorage());
  final values = <String, String>{};
  bool failAdoption = false;
  String? keyFailure;
  bool failLegacyRead = false;
  @override
  Future<String?> read(String key) async {
    if (key == _legacyIntegrityKey && failLegacyRead) {
      throw StateError('legacy key read unavailable');
    }
    if (key == _integrityKey && keyFailure == 'read') {
      throw StateError('key read unavailable');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == _integrityKey && keyFailure == 'write') {
      throw StateError('key write unavailable');
    }
    if (key == _integrityKey && keyFailure == 'drop') return;
    if (failAdoption && key == _v4Adopted) {
      throw StateError('adoption unavailable');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _MemoryReceipts implements DeviceAuditReceiptStorage {
  final values = <String, String>{};
  final history = <String, String>{};
  final reads = <String>[];
  int writes = 0;
  bool fail = false;
  bool reject = false;
  bool pauseFirstReceipt = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<T> initialize<T>(Future<T> Function() action) => action();
  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String value,
  }) async {
    if (pauseFirstReceipt &&
        key.startsWith('receipt_') &&
        !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    if (fail) throw StateError('write unavailable');
    if (reject || values[key] != expectedValue) return false;
    final prior = values[key];
    if (prior != null) {
      history.putIfAbsent(
        '$key-${sha256.convert(utf8.encode(prior))}',
        () => prior,
      );
    }
    values[key] = value;
    writes++;
    return true;
  }
}

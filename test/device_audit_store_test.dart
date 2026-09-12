import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final signed in [false, true]) {
    test(
      'legacy import keeps unverified history isolated from an older v2 writer (signed=$signed)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final secure = _MemorySecureStorage();
        const oldId = '123e4567-e89b-42d3-a456-426614174110';
        const newId = '123e4567-e89b-42d3-a456-426614174111';
        final altered = _receipt(oldId, '/api/altered-history');
        if (signed) {
          await _writeLegacyV2(preferences, secure, [
            altered,
          ], validSignature: false);
        } else {
          await preferences.setString(
            _legacyKey,
            jsonEncode([altered.toJson()]),
          );
        }
        final store = DefaultDeviceAuditStore(secure, preferences: preferences);
        expect((await store.findReceipt(oldId))?.integrityVerified, isFalse);
        await store.beginReceipt(
          clientEventId: newId,
          method: 'GET',
          path: '/api/new',
          startedAt: DateTime.now().toUtc(),
          device: _profile,
        );
        final v3Before = preferences.getString(_v3Key);
        // Reproduce the old binary's writer: it signs a plain v2 list, which has
        // no per-row provenance and would previously bless the altered history.
        await _writeLegacyV2(preferences, secure, [altered]);
        expect(preferences.getString(_v3Key), v3Before);
        final current = DefaultDeviceAuditStore(
          secure,
          preferences: preferences,
        );
        expect((await current.findReceipt(oldId))?.integrityVerified, isFalse);
        expect((await current.findReceipt(newId))?.integrityVerified, isTrue);
      },
    );
  }

  for (final broken in [null, '', '{broken-json']) {
    test(
      'a missing or corrupt adopted v3 ledger never falls back to v2 ($broken)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final secure = _MemorySecureStorage();
        const id = '123e4567-e89b-42d3-a456-426614174112';
        await _writeLegacyV2(preferences, secure, [
          _receipt(id, '/api/legacy'),
        ]);
        final imported = DefaultDeviceAuditStore(
          secure,
          preferences: preferences,
        );
        expect((await imported.findReceipt(id))?.integrityVerified, isTrue);
        if (broken == null) {
          await preferences.remove(_v3Key);
        } else {
          await preferences.setString(_v3Key, broken);
        }
        final reopened = DefaultDeviceAuditStore(
          secure,
          preferences: preferences,
        );
        expect(await reopened.findReceipt(id), isNull);
        expect(preferences.getString(_legacyKey), isNotNull);
      },
    );
  }

  test(
    'a valid old envelope copied into the v3 key is not a format downgrade',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final secure = _MemorySecureStorage();
      const id = '123e4567-e89b-42d3-a456-426614174113';
      await _writeLegacyV2(preferences, secure, [_receipt(id, '/api/legacy')]);
      final imported = DefaultDeviceAuditStore(
        secure,
        preferences: preferences,
      );
      expect((await imported.findReceipt(id))?.integrityVerified, isTrue);
      await preferences.setString(_v3Key, preferences.getString(_legacyKey)!);
      expect(
        await DefaultDeviceAuditStore(
          secure,
          preferences: preferences,
        ).findReceipt(id),
        isNull,
      );
    },
  );

  for (final throwsOnWrite in [false, true]) {
    test(
      'failed v3 import is not trusted or cached and can retry (throws=$throwsOnWrite)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final shared = await SharedPreferences.getInstance();
        final preferences = _FailingPreferences(shared, throwsOnWrite)
          ..failReceipts = true;
        final secure = _MemorySecureStorage();
        const id = '123e4567-e89b-42d3-a456-426614174114';
        await _writeLegacyV2(shared, secure, [_receipt(id, '/api/legacy')]);
        final store = DefaultDeviceAuditStore(secure, preferences: preferences);
        await expectLater(store.findReceipt(id), throwsStateError);
        expect(shared.getString(_v3Key), isNull);
        expect(await secure.read(_adoptedKey), isNull);
        preferences.failReceipts = false;
        expect((await store.findReceipt(id))?.integrityVerified, isTrue);
        expect(shared.getString(_v3Key), isNotNull);
        expect(await secure.read(_adoptedKey), isNotNull);
      },
    );
  }

  test(
    'adoption marker failure retries the stored v3 snapshot without reading newer v2',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final secure = _MemorySecureStorage()..failAdoptionWrites = true;
      const id = '123e4567-e89b-42d3-a456-426614174115';
      final altered = _receipt(id, '/api/altered-history');
      await _writeLegacyV2(preferences, secure, [
        altered,
      ], validSignature: false);
      final store = DefaultDeviceAuditStore(secure, preferences: preferences);
      await expectLater(store.findReceipt(id), throwsStateError);
      expect(preferences.getString(_v3Key), isNotNull);
      await _writeLegacyV2(preferences, secure, [altered]);
      secure.failAdoptionWrites = false;
      expect((await store.findReceipt(id))?.integrityVerified, isFalse);
    },
  );

  test(
    'two first importers serialize and the second cannot reimport a newer laundered v2 snapshot',
    () async {
      SharedPreferences.setMockInitialValues({});
      final shared = await SharedPreferences.getInstance();
      final blocked = _BlockingPreferences(shared);
      addTearDown(() {
        if (!blocked.release.isCompleted) blocked.release.complete();
      });
      final secure = _MemorySecureStorage();
      const id = '123e4567-e89b-42d3-a456-426614174116';
      final altered = _receipt(id, '/api/altered-history');
      await _writeLegacyV2(shared, secure, [altered], validSignature: false);
      final first = DefaultDeviceAuditStore(secure, preferences: blocked);
      final second = DefaultDeviceAuditStore(secure, preferences: shared);
      final firstRead = first.findReceipt(id);
      await blocked.entered.future;
      await _writeLegacyV2(shared, secure, [altered]);
      final secondRead = second.findReceipt(id);
      blocked.release.complete();
      expect((await firstRead)?.integrityVerified, isFalse);
      expect((await secondRead)?.integrityVerified, isFalse);
    },
  );

  test(
    'separate new store instances merge writes against the latest signed ledger',
    () async {
      SharedPreferences.setMockInitialValues({});
      final shared = await SharedPreferences.getInstance();
      final secure = _MemorySecureStorage();
      final first = DefaultDeviceAuditStore(secure, preferences: shared);
      final second = DefaultDeviceAuditStore(secure, preferences: shared);
      const firstId = '123e4567-e89b-42d3-a456-426614174117';
      const secondId = '123e4567-e89b-42d3-a456-426614174118';
      await Future.wait([
        first.beginReceipt(
          clientEventId: firstId,
          method: 'GET',
          path: '/api/a',
          startedAt: DateTime.now().toUtc(),
          device: _profile,
        ),
        second.beginReceipt(
          clientEventId: secondId,
          method: 'GET',
          path: '/api/b',
          startedAt: DateTime.now().toUtc(),
          device: _profile,
        ),
      ]);
      expect((await first.findReceipt(secondId))?.integrityVerified, isTrue);
      expect((await second.findReceipt(firstId))?.integrityVerified, isTrue);
    },
  );

  test(
    'writing a new receipt never authenticates previously tampered history',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final secure = _MemorySecureStorage();
      final original = DefaultDeviceAuditStore(
        secure,
        preferences: preferences,
      );
      const oldId = '123e4567-e89b-42d3-a456-426614174080';
      const newId = '123e4567-e89b-42d3-a456-426614174081';
      final now = DateTime.now().toUtc();
      await original.beginReceipt(
        clientEventId: oldId,
        method: 'GET',
        path: '/api/original',
        startedAt: now,
        device: _profile,
      );
      const storageKey = 'audit.device.local_receipts.v3';
      final raw = preferences.getString(storageKey)!;
      await preferences.setString(
        storageKey,
        raw.replaceFirst('/api/original', '/api/tampered'),
      );
      final reloaded = DefaultDeviceAuditStore(
        secure,
        preferences: preferences,
      );
      expect((await reloaded.findReceipt(oldId))?.integrityVerified, isFalse);
      await reloaded.beginReceipt(
        clientEventId: newId,
        method: 'GET',
        path: '/api/new',
        startedAt: now,
        device: _profile,
      );
      // Even a genuine retry of the old ID cannot bless its altered prior attempt.
      await reloaded.beginReceipt(
        clientEventId: oldId,
        method: 'GET',
        path: '/api/retry',
        startedAt: now,
        device: _profile,
      );
      await reloaded.completeReceipt(
        clientEventId: oldId,
        outcome: 'success',
        completedAt: now,
        statusCode: 200,
      );
      final persisted = DefaultDeviceAuditStore(
        secure,
        preferences: preferences,
      );
      final previous = await persisted.findReceipt(oldId);
      expect(previous?.integrityVerified, isFalse);
      expect(previous?.previousAttempts.single.path, '/api/tampered');
      expect((await persisted.findReceipt(newId))?.integrityVerified, isTrue);
      final envelope =
          jsonDecode(preferences.getString(storageKey)!)
              as Map<String, dynamic>;
      envelope['version'] = 2;
      await preferences.setString(storageKey, jsonEncode(envelope));
      final downgraded = DefaultDeviceAuditStore(
        secure,
        preferences: preferences,
      );
      expect((await downgraded.findReceipt(oldId))?.integrityVerified, isFalse);
    },
  );

  test(
    'valid signed v2 receipts remain verifiable during the v3 upgrade',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final secure = _MemorySecureStorage();
      final key = List<int>.generate(32, (index) => index);
      await secure.write(
        'audit.device.receipt_integrity_key.v1',
        base64UrlEncode(key),
      );
      const id = '123e4567-e89b-42d3-a456-426614174082';
      final receipt = LocalAuditReceipt(
        clientEventId: id,
        installationId: _profile.installationId,
        method: 'GET',
        path: '/api/legacy',
        startedAt: DateTime.now().toUtc().toIso8601String(),
        outcome: 'success',
        device: _profile,
      );
      final payload = jsonEncode([receipt.toJson()]);
      final signature = base64UrlEncode(
        Hmac(sha256, key).convert(utf8.encode(payload)).bytes,
      );
      await preferences.setString(
        'audit.device.local_receipts.v1',
        jsonEncode({'version': 2, 'payload': payload, 'signature': signature}),
      );
      final store = DefaultDeviceAuditStore(secure, preferences: preferences);
      expect((await store.findReceipt(id))?.integrityVerified, isTrue);
      await store.updateRetentionMonths(36);
      final updated = DefaultDeviceAuditStore(secure, preferences: preferences);
      expect((await updated.findReceipt(id))?.integrityVerified, isTrue);
      expect(
        (jsonDecode(preferences.getString('audit.device.local_receipts.v3')!)
            as Map)['version'],
        3,
      );
    },
  );

  for (final throwsOnWrite in [false, true]) {
    test(
      'failed receipt persistence keeps the last durable state (throws=$throwsOnWrite)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = _FailingPreferences(
          await SharedPreferences.getInstance(),
          throwsOnWrite,
        );
        final secure = _MemorySecureStorage();
        final store = DefaultDeviceAuditStore(secure, preferences: preferences);
        const id = '123e4567-e89b-42d3-a456-426614174099';
        final now = DateTime.now().toUtc();
        await store.beginReceipt(
          clientEventId: id,
          method: 'POST',
          path: '/api/command',
          startedAt: now,
          device: _profile,
        );
        preferences.failReceipts = true;
        await expectLater(
          store.completeReceipt(
            clientEventId: id,
            outcome: 'success',
            completedAt: now,
            statusCode: 200,
          ),
          throwsStateError,
        );
        final previous = await store.findReceipt(id);
        expect(previous?.outcome, 'pending');
        expect(previous?.integrityVerified, isTrue);
        final disk = DefaultDeviceAuditStore(secure, preferences: preferences);
        expect((await disk.findReceipt(id))?.outcome, 'pending');
        preferences.failReceipts = false;
        await store.completeReceipt(
          clientEventId: id,
          outcome: 'success',
          completedAt: now,
          statusCode: 200,
        );
        expect((await store.findReceipt(id))?.outcome, 'success');
        final recovered = DefaultDeviceAuditStore(
          secure,
          preferences: preferences,
        );
        expect((await recovered.findReceipt(id))?.outcome, 'success');
        expect((await recovered.findReceipt(id))?.integrityVerified, isTrue);
      },
    );
  }

  test(
    'concurrent request receipts share persistence and retain ordered attempts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final secure = _MemorySecureStorage();
      final store = DefaultDeviceAuditStore(secure, preferences: preferences);
      final writes = <Future<void>>[];
      final now = DateTime.now().toUtc();
      for (var index = 0; index < 150; index++) {
        final id =
            '123e4567-e89b-42d3-a456-${index.toString().padLeft(12, '0')}';
        writes.add(
          store.beginReceipt(
            clientEventId: id,
            method: 'GET',
            path: '/api/list/$index',
            startedAt: now,
            device: _profile,
          ),
        );
        writes.add(
          store.completeReceipt(
            clientEventId: id,
            outcome: 'success',
            completedAt: now,
            statusCode: 200,
          ),
        );
      }
      // The entire synchronous burst has one durability boundary. Awaiting any
      // receipt still waits for the actual signed local-store write.
      expect(writes.every((write) => identical(write, writes.first)), isTrue);
      await Future.wait(writes);
      final reloaded = DefaultDeviceAuditStore(
        secure,
        preferences: preferences,
      );
      for (var index = 0; index < 150; index++) {
        final receipt = await reloaded.findReceipt(
          '123e4567-e89b-42d3-a456-${index.toString().padLeft(12, '0')}',
        );
        expect(receipt?.outcome, 'success');
        expect(receipt?.integrityVerified, isTrue);
      }
    },
  );

  test('preserves retry attempts and verifies the persisted HMAC', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final secure = _MemorySecureStorage();
    final store = DefaultDeviceAuditStore(secure, preferences: preferences);
    const eventId = '123e4567-e89b-42d3-a456-426614174020';
    const firstRequest = '123e4567-e89b-42d3-a456-426614174021';
    const secondRequest = '123e4567-e89b-42d3-a456-426614174022';
    final startedAt = DateTime.utc(2026, 7, 31, 2);

    await store.beginReceipt(
      clientEventId: eventId,
      method: 'GET',
      path: '/api/orders',
      startedAt: startedAt,
      device: _profile,
    );
    await store.completeReceipt(
      clientEventId: eventId,
      outcome: 'failure',
      completedAt: startedAt.add(const Duration(milliseconds: 100)),
      statusCode: 503,
      serverRequestId: firstRequest,
    );
    await store.beginReceipt(
      clientEventId: eventId,
      method: 'GET',
      path: '/api/orders',
      startedAt: startedAt,
      device: _profile,
    );
    await store.completeReceipt(
      clientEventId: eventId,
      outcome: 'success',
      completedAt: startedAt.add(const Duration(milliseconds: 250)),
      statusCode: 200,
      serverRequestId: secondRequest,
    );

    final receipt = await store.findReceipt(eventId);
    expect(receipt, isNotNull);
    expect(receipt!.integrityVerified, isTrue);
    expect(receipt.allAttempts, hasLength(2));
    expect(receipt.attemptForRequest(firstRequest)?.statusCode, 503);
    expect(receipt.attemptForRequest(secondRequest)?.statusCode, 200);

    final reloaded = DefaultDeviceAuditStore(secure, preferences: preferences);
    expect((await reloaded.findReceipt(eventId))?.integrityVerified, isTrue);
  });

  test('marks locally edited receipt data as unverified', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final secure = _MemorySecureStorage();
    final store = DefaultDeviceAuditStore(secure, preferences: preferences);
    const eventId = '123e4567-e89b-42d3-a456-426614174030';

    await store.beginReceipt(
      clientEventId: eventId,
      method: 'POST',
      path: '/api/orders',
      startedAt: DateTime.now().toUtc(),
      device: _profile,
    );
    await store.completeReceipt(
      clientEventId: eventId,
      outcome: 'success',
      completedAt: DateTime.now().toUtc(),
      statusCode: 200,
      serverRequestId: '123e4567-e89b-42d3-a456-426614174031',
    );

    const key = 'audit.device.local_receipts.v3';
    final raw = preferences.getString(key)!;
    await preferences.setString(key, raw.replaceFirst('success', 'failure'));
    final reloaded = DefaultDeviceAuditStore(secure, preferences: preferences);

    expect((await reloaded.findReceipt(eventId))?.integrityVerified, isFalse);
  });

  test('purges receipts older than the configured local retention', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = DefaultDeviceAuditStore(
      _MemorySecureStorage(),
      preferences: preferences,
    );
    const eventId = '123e4567-e89b-42d3-a456-426614174040';

    await store.updateRetentionMonths(1);
    await store.beginReceipt(
      clientEventId: eventId,
      method: 'GET',
      path: '/api/old',
      startedAt: DateTime.now().toUtc().subtract(const Duration(days: 70)),
      device: _profile,
    );

    expect(await store.findReceipt(eventId), isNull);
  });

  test(
    'rotates a keychain id when the app-local install marker is absent',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final secure = _MemorySecureStorage();
      const previousInstallationId = '123e4567-e89b-42d3-a456-426614174060';
      await secure.write(
        'audit.device.installation_id',
        previousInstallationId,
      );

      final store = DefaultDeviceAuditStore(secure, preferences: preferences);
      final currentInstallationId = (await store.profile()).installationId;

      expect(currentInstallationId, isNot(previousInstallationId));
      expect(
        await secure.read('audit.device.installation_id'),
        currentInstallationId,
      );
      expect(
        preferences.getString('audit.device.installation_marker.v1'),
        currentInstallationId,
      );
      final reloaded = DefaultDeviceAuditStore(
        secure,
        preferences: preferences,
      );
      expect((await reloaded.profile()).installationId, currentInstallationId);
    },
  );
}

const _profile = DeviceAuditProfile(
  installationId: '123e4567-e89b-42d3-a456-426614174001',
  deviceName: '测试电脑',
  manufacturer: 'Uten',
  model: 'QA-1',
  platform: 'windows',
  osVersion: 'Windows Test',
  appVersion: '1.0.0',
  appBuild: 'test',
  formFactor: 'desktop',
);

class _MemorySecureStorage extends SecureStorage {
  _MemorySecureStorage() : super(const FlutterSecureStorage());

  final _values = <String, String>{};
  bool failAdoptionWrites = false;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failAdoptionWrites && key == 'audit.device.local_receipts.v3.adopted') {
      throw StateError('adoption marker unavailable');
    }
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

class _FailingPreferences implements SharedPreferences {
  _FailingPreferences(this.delegate, this.throwsOnWrite);
  final SharedPreferences delegate;
  final bool throwsOnWrite;
  bool failReceipts = false;
  @override
  Future<void> reload() => delegate.reload();
  @override
  String? getString(String key) => delegate.getString(key);
  @override
  int? getInt(String key) => delegate.getInt(key);
  @override
  Future<bool> setInt(String key, int value) => delegate.setInt(key, value);
  @override
  Future<bool> setString(String key, String value) async {
    if (failReceipts && key == 'audit.device.local_receipts.v3') {
      if (throwsOnWrite) throw StateError('storage unavailable');
      return false;
    }
    return delegate.setString(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _legacyKey = 'audit.device.local_receipts.v1';
const _v3Key = 'audit.device.local_receipts.v3';
const _adoptedKey = 'audit.device.local_receipts.v3.adopted';

LocalAuditReceipt _receipt(String id, String path) => LocalAuditReceipt(
  clientEventId: id,
  installationId: _profile.installationId,
  method: 'GET',
  path: path,
  startedAt: DateTime.now().toUtc().toIso8601String(),
  outcome: 'success',
  device: _profile,
);

Future<void> _writeLegacyV2(
  SharedPreferences preferences,
  SecureStorage secure,
  List<LocalAuditReceipt> rows, {
  bool validSignature = true,
}) async {
  const keyName = 'audit.device.receipt_integrity_key.v1';
  var encoded = await secure.read(keyName);
  if (encoded == null) {
    encoded = base64UrlEncode(List<int>.generate(32, (index) => index));
    await secure.write(keyName, encoded);
  }
  final payload = jsonEncode(rows.map((row) => row.toJson()).toList());
  final signature = validSignature
      ? base64UrlEncode(
          Hmac(
            sha256,
            base64Url.decode(encoded),
          ).convert(utf8.encode(payload)).bytes,
        )
      : 'bad-signature';
  await preferences.setString(
    _legacyKey,
    jsonEncode({'version': 2, 'payload': payload, 'signature': signature}),
  );
}

class _BlockingPreferences extends _FailingPreferences {
  _BlockingPreferences(SharedPreferences delegate) : super(delegate, false);
  final entered = Completer<void>();
  final release = Completer<void>();
  bool _blocked = false;
  @override
  Future<bool> setString(String key, String value) async {
    if (key == _v3Key && !_blocked) {
      _blocked = true;
      entered.complete();
      await release.future;
    }
    return super.setString(key, value);
  }
}

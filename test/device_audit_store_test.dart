import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

    const key = 'audit.device.local_receipts.v1';
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

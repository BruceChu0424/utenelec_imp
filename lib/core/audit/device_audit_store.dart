// 设备审计上下文与本机回执。
//
// 设备名称、型号等均是客户端声明，只用于调查线索；本机安装标识是随机 UUID，
// 不是 IMEI、MAC、硬盘序列号或不可伪造的硬件身份。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../constants/app_info.dart';
import '../security/secure_storage.dart';
import '../security/auth_refresh_lock.dart';
import 'device_audit_receipt_storage.dart';

abstract final class DeviceAuditHeaders {
  static const operationId = 'X-Uten-Operation-Id';
  static const context = 'X-Uten-Audit-Context';
  static const serverRequestId = 'X-Uten-Audit-Request-Id';
}

class DeviceAuditProfile {
  const DeviceAuditProfile({
    required this.installationId,
    required this.platform,
    required this.appVersion,
    required this.appBuild,
    this.deviceName,
    this.manufacturer,
    this.model,
    this.osVersion,
    this.formFactor,
    this.browserName,
    this.locale,
    this.timeZone,
    this.timeZoneOffsetMinutes,
    this.isPhysicalDevice,
  });

  final String installationId;
  final String platform;
  final String appVersion;
  final String appBuild;
  final String? deviceName;
  final String? manufacturer;
  final String? model;
  final String? osVersion;
  final String? formFactor;
  final String? browserName;
  final String? locale;
  final String? timeZone;
  final int? timeZoneOffsetMinutes;
  final bool? isPhysicalDevice;

  String get displayLabel {
    final name = deviceName?.trim();
    final deviceModel = model?.trim();
    if (name != null &&
        name.isNotEmpty &&
        deviceModel != null &&
        deviceModel.isNotEmpty &&
        name.toLowerCase() != deviceModel.toLowerCase()) {
      return '$name · $deviceModel';
    }
    if (name != null && name.isNotEmpty) return name;
    if (deviceModel != null && deviceModel.isNotEmpty) return deviceModel;
    return platform;
  }

  Map<String, dynamic> toAuditContext(DateTime clientEventAt) => {
    'version': 1,
    'installationId': installationId,
    'deviceName': ?deviceName,
    'manufacturer': ?manufacturer,
    'model': ?model,
    'platform': platform,
    'osVersion': ?osVersion,
    'appVersion': appVersion,
    'appBuild': appBuild,
    'formFactor': ?formFactor,
    'browserName': ?browserName,
    'locale': ?locale,
    'timeZone': ?timeZone,
    'timeZoneOffsetMinutes': ?timeZoneOffsetMinutes,
    'isPhysicalDevice': ?isPhysicalDevice,
    'clientEventAt': clientEventAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toJson() => {
    'installationId': installationId,
    'deviceName': ?deviceName,
    'manufacturer': ?manufacturer,
    'model': ?model,
    'platform': platform,
    'osVersion': ?osVersion,
    'appVersion': appVersion,
    'appBuild': appBuild,
    'formFactor': ?formFactor,
    'browserName': ?browserName,
    'locale': ?locale,
    'timeZone': ?timeZone,
    'timeZoneOffsetMinutes': ?timeZoneOffsetMinutes,
    'isPhysicalDevice': ?isPhysicalDevice,
  };

  factory DeviceAuditProfile.fromJson(Map<String, dynamic> json) =>
      DeviceAuditProfile(
        installationId: json['installationId'] as String? ?? '',
        deviceName: json['deviceName'] as String?,
        manufacturer: json['manufacturer'] as String?,
        model: json['model'] as String?,
        platform: json['platform'] as String? ?? 'unknown',
        osVersion: json['osVersion'] as String?,
        appVersion: json['appVersion'] as String? ?? '',
        appBuild: json['appBuild'] as String? ?? '',
        formFactor: json['formFactor'] as String?,
        browserName: json['browserName'] as String?,
        locale: json['locale'] as String?,
        timeZone: json['timeZone'] as String?,
        timeZoneOffsetMinutes: _asInt(json['timeZoneOffsetMinutes']),
        isPhysicalDevice: json['isPhysicalDevice'] as bool?,
      );
}

class LocalAuditAttempt {
  const LocalAuditAttempt({
    required this.method,
    required this.path,
    required this.startedAt,
    required this.outcome,
    this.completedAt,
    this.statusCode,
    this.serverRequestId,
  });

  final String method;
  final String path;
  final String startedAt;
  final String outcome;
  final String? completedAt;
  final int? statusCode;
  final String? serverRequestId;

  Map<String, dynamic> toJson() => {
    'method': method,
    'path': path,
    'startedAt': startedAt,
    'completedAt': ?completedAt,
    'statusCode': ?statusCode,
    'serverRequestId': ?serverRequestId,
    'outcome': outcome,
  };

  factory LocalAuditAttempt.fromJson(Map<String, dynamic> json) =>
      LocalAuditAttempt(
        method: json['method'] as String? ?? '',
        path: json['path'] as String? ?? '',
        startedAt: json['startedAt'] as String? ?? '',
        completedAt: json['completedAt'] as String?,
        statusCode: _asInt(json['statusCode']),
        serverRequestId: json['serverRequestId'] as String?,
        outcome: json['outcome'] as String? ?? 'unknown',
      );
}

class LocalAuditReceipt {
  const LocalAuditReceipt({
    required this.clientEventId,
    required this.installationId,
    required this.method,
    required this.path,
    required this.startedAt,
    required this.outcome,
    required this.device,
    this.completedAt,
    this.statusCode,
    this.serverRequestId,
    this.previousAttempts = const [],
    this.integrityVerified = false,
  });

  final String clientEventId;
  final String installationId;
  final String method;
  final String path;
  final String startedAt;
  final String outcome;
  final DeviceAuditProfile device;
  final String? completedAt;
  final int? statusCode;
  final String? serverRequestId;
  final List<LocalAuditAttempt> previousAttempts;

  /// HMAC verified with a random key kept in platform secure storage.
  /// This detects ordinary local edits; it is not hardware attestation.
  final bool integrityVerified;

  LocalAuditAttempt get latestAttempt => LocalAuditAttempt(
    method: method,
    path: path,
    startedAt: startedAt,
    outcome: outcome,
    completedAt: completedAt,
    statusCode: statusCode,
    serverRequestId: serverRequestId,
  );

  List<LocalAuditAttempt> get allAttempts => [
    ...previousAttempts,
    latestAttempt,
  ];

  LocalAuditAttempt? attemptForRequest(String? requestId) {
    if (requestId == null || requestId.isEmpty) return latestAttempt;
    for (final attempt in allAttempts.reversed) {
      if (attempt.serverRequestId == requestId) return attempt;
    }
    return null;
  }

  LocalAuditReceipt startNextAttempt({
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  }) => LocalAuditReceipt(
    clientEventId: clientEventId,
    installationId: device.installationId,
    method: method,
    path: path,
    startedAt: startedAt.toUtc().toIso8601String(),
    outcome: 'pending',
    device: device,
    previousAttempts: [...previousAttempts, latestAttempt],
    integrityVerified: integrityVerified,
  );

  LocalAuditReceipt complete({
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  }) => LocalAuditReceipt(
    clientEventId: clientEventId,
    installationId: installationId,
    method: method,
    path: path,
    startedAt: startedAt,
    outcome: outcome,
    device: device,
    completedAt: completedAt.toUtc().toIso8601String(),
    statusCode: statusCode,
    serverRequestId: serverRequestId,
    previousAttempts: previousAttempts,
    integrityVerified: integrityVerified,
  );

  LocalAuditReceipt withIntegrity(bool verified) => LocalAuditReceipt(
    clientEventId: clientEventId,
    installationId: installationId,
    method: method,
    path: path,
    startedAt: startedAt,
    outcome: outcome,
    device: device,
    completedAt: completedAt,
    statusCode: statusCode,
    serverRequestId: serverRequestId,
    previousAttempts: previousAttempts,
    integrityVerified: verified,
  );

  Map<String, dynamic> toJson() => {
    'clientEventId': clientEventId,
    'installationId': installationId,
    'method': method,
    'path': path,
    'startedAt': startedAt,
    'completedAt': ?completedAt,
    'statusCode': ?statusCode,
    'serverRequestId': ?serverRequestId,
    'outcome': outcome,
    'device': device.toJson(),
    'previousAttempts': previousAttempts
        .map((attempt) => attempt.toJson())
        .toList(growable: false),
  };

  factory LocalAuditReceipt.fromJson(
    Map<String, dynamic> json,
  ) => LocalAuditReceipt(
    clientEventId: json['clientEventId'] as String? ?? '',
    installationId: json['installationId'] as String? ?? '',
    method: json['method'] as String? ?? '',
    path: json['path'] as String? ?? '',
    startedAt: json['startedAt'] as String? ?? '',
    completedAt: json['completedAt'] as String?,
    statusCode: _asInt(json['statusCode']),
    serverRequestId: json['serverRequestId'] as String?,
    outcome: json['outcome'] as String? ?? 'unknown',
    device: DeviceAuditProfile.fromJson(
      Map<String, dynamic>.from(json['device'] as Map? ?? const {}),
    ),
    previousAttempts: (json['previousAttempts'] as List<dynamic>? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(
          (value) =>
              LocalAuditAttempt.fromJson(Map<String, dynamic>.from(value)),
        )
        .toList(growable: false),
  );
}

abstract interface class DeviceAuditStore {
  Future<DeviceAuditProfile> profile();

  Future<void> beginReceipt({
    required String clientEventId,
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  });

  Future<void> completeReceipt({
    required String clientEventId,
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  });

  Future<LocalAuditReceipt?> findReceipt(String clientEventId);

  Future<void> updateRetentionMonths(int months);
}

typedef _ReceiptChange = LocalAuditReceipt? Function(LocalAuditReceipt?);

class DefaultDeviceAuditStore implements DeviceAuditStore {
  DefaultDeviceAuditStore(
    this._storage, {
    DeviceInfoPlugin? deviceInfo,
    SharedPreferences? preferences,
    Uuid? uuid,
    DeviceAuditReceiptStorage? receiptStorage,
  }) : _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
       _preferences = preferences == null
           ? SharedPreferences.getInstance()
           : Future<SharedPreferences>.value(preferences),
       _uuid = uuid ?? const Uuid(),
       _receiptStorage = receiptStorage ?? createDeviceAuditReceiptStorage();

  static const _installationKey = 'audit.device.installation_id';
  static const _installationMarkerKey = 'audit.device.installation_marker.v1';
  static const _legacyReceiptsKey = 'audit.device.local_receipts.v1';
  static const _receiptsKey = 'audit.device.local_receipts.v3';
  static const _receiptAdoptedKey = 'audit.device.local_receipts.v3.adopted';
  static const _receiptIntegrityKey = 'audit.device.receipt_integrity_key.v4';
  static const _legacyIntegrityKey = 'audit.device.receipt_integrity_key.v1';
  static const _permanentAdoptedKey = 'audit.device.local_receipts.v4.adopted';
  static const _migrationKey = 'migration_v4';

  final SecureStorage _storage;
  final DeviceInfoPlugin _deviceInfo;
  final Future<SharedPreferences> _preferences;
  final Uuid _uuid;
  final DeviceAuditReceiptStorage _receiptStorage;

  Future<DeviceAuditProfile>? _profileFuture;
  final _receiptLock = AuthRefreshLock('audit-device-receipts.v3');
  bool _migrationReady = false;
  Future<List<int>>? _integrityKeyFuture;
  Future<void> _writes = Future<void>.value();
  List<MapEntry<String, _ReceiptChange>>? _pendingMutations;
  Future<void>? _pendingReceiptWrite;

  @override
  Future<DeviceAuditProfile> profile() => _profileFuture ??= _buildProfile();

  @override
  Future<void> beginReceipt({
    required String clientEventId,
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  }) => _mutateReceipt(
    clientEventId,
    (previous) => previous == null
        ? LocalAuditReceipt(
            clientEventId: clientEventId,
            installationId: device.installationId,
            method: _clean(method, 10) ?? 'UNKNOWN',
            path: _clean(path, 1000) ?? '/',
            startedAt: startedAt.toUtc().toIso8601String(),
            outcome: 'pending',
            device: device,
            integrityVerified: true,
          )
        : previous.startNextAttempt(
            method: _clean(method, 10) ?? 'UNKNOWN',
            path: _clean(path, 1000) ?? '/',
            startedAt: startedAt,
            device: device,
          ),
  );

  @override
  Future<void> completeReceipt({
    required String clientEventId,
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  }) => _mutateReceipt(
    clientEventId,
    (previous) => previous?.complete(
      outcome: outcome,
      completedAt: completedAt,
      statusCode: statusCode,
      serverRequestId: _validUuid(serverRequestId) ? serverRequestId : null,
    ),
  );

  @override
  Future<LocalAuditReceipt?> findReceipt(String clientEventId) async {
    if (!_validUuid(clientEventId)) return null;
    await _writes.catchError((_) {});
    await _ensurePermanentStorage();
    return _decodeRecord(
      await _receiptStorage.read('receipt_$clientEventId'),
      clientEventId,
    );
  }

  /// Kept for older server header compatibility. Age never destroys receipts.
  @override
  Future<void> updateRetentionMonths(int months) async {}

  Future<void> _mutateReceipt(String id, _ReceiptChange mutation) {
    if (!_validUuid(id)) return Future.error(const FormatException('本机操作标识无效'));
    final entry = MapEntry(id, mutation);
    final pending = _pendingMutations;
    if (pending != null) {
      pending.add(entry);
      return _pendingReceiptWrite!;
    }
    final mutations = <MapEntry<String, _ReceiptChange>>[entry];
    _pendingMutations = mutations;
    final next = _writes
        .catchError((_) {})
        .then(
          (_) => Future<void>(() async {
            _pendingMutations = null;
            _pendingReceiptWrite = null;
            await _ensurePermanentStorage();
            final byId = <String, List<_ReceiptChange>>{};
            for (final entry in mutations) {
              (byId[entry.key] ??= []).add(entry.value);
            }
            // Only the IDs in this burst are read, signed and persisted. A bounded
            // worker set avoids both an all-history rewrite and a filesystem flood.
            final entries = byId.entries.toList();
            var nextIndex = 0;
            await Future.wait(
              List.generate(min(4, entries.length), (_) async {
                while (nextIndex < entries.length) {
                  final entry = entries[nextIndex++];
                  await _applyChanges(entry.key, entry.value);
                }
              }),
            );
          }),
        );
    _writes = next;
    _pendingReceiptWrite = next;
    return next;
  }

  Future<void> _applyChanges(String id, List<_ReceiptChange> changes) async {
    final key = 'receipt_$id';
    for (var attempt = 0; attempt < 20; attempt++) {
      final raw = await _receiptStorage.read(key);
      final previous = await _decodeRecord(raw, id);
      var result = previous;
      for (final change in changes) {
        result = change(result);
      }
      if (result == null) return;
      // An unreadable previous record cannot become trusted by a later retry.
      if (raw != null && previous == null) result = result.withIntegrity(false);
      final value = await _encodeRecord(result);
      if (await _receiptStorage.compareAndSet(
        key,
        expectedValue: raw,
        value: value,
      )) {
        return;
      }
    }
    throw StateError('本机回执并发更新未完成，已有历史仍保留');
  }

  Future<void> _ensurePermanentStorage() async {
    if (_migrationReady) return;
    await _receiptLock.synchronized(
      () => _receiptStorage.initialize(() async {
        if (_migrationReady) return;
        // All instances establish the signing key under the same lock, including
        // an empty legacy ledger, before concurrent point writes can start.
        await _signingKey();
        final marker = await _receiptStorage.read(_migrationKey);
        final adopted = await _storage.read(_permanentAdoptedKey) != null;
        if (marker != null || adopted) {
          if (!adopted) await _storage.write(_permanentAdoptedKey, '4');
          _migrationReady = true;
          return;
        }
        final preferences = await _preferences;
        await preferences.reload();
        final v3 = preferences.getString(_receiptsKey);
        final legacy = preferences.getString(_legacyReceiptsKey);
        final oldAdopted = await _storage.read(_receiptAdoptedKey) != null;
        final legacyKey = await _readLegacyKey(mustExist: oldAdopted);
        // Preserve exact source envelopes, including malformed rows and unknown
        // timestamps. An older binary may still write its separate legacy key.
        for (final source in {'v3': v3, 'legacy': legacy}.entries) {
          final raw = source.value;
          if (raw == null) continue;
          final key =
              'legacy_${source.key}_${sha256.convert(utf8.encode(raw))}';
          final existing = await _receiptStorage.read(key);
          if (existing != null && existing != raw) {
            throw StateError('本机旧回执原件校验失败');
          }
          if (existing == null) {
            await _storeMigrationValue(key, raw);
          }
        }
        final records = _decodeReceipts(
          v3 != null || oldAdopted ? v3 : legacy,
          allowLegacy: v3 == null && !oldAdopted,
          legacyKey: legacyKey,
        );
        // An intact current envelope may coexist with older distinct receipts
        // outside its former 300-entry window. Keep those IDs discoverable as
        // unverified history, without overriding current v3 provenance. A
        // missing/corrupt adopted v3 never falls back to an older writer.
        if (_hasV3Envelope(v3)) {
          final present = records.map((row) => row.clientEventId).toSet();
          for (final older in _decodeReceipts(
            legacy,
            allowLegacy: true,
            legacyKey: legacyKey,
          )) {
            if (present.add(older.clientEventId)) {
              records.add(older.withIntegrity(false));
            }
          }
        }
        for (final record in records) {
          await _storeMigrationValue(
            'receipt_${record.clientEventId}',
            await _encodeRecord(record),
            keepExisting: true,
          );
        }
        // Commit marker last: interrupted imports can retry, but can never
        // overwrite an already imported or newer receipt with an old snapshot.
        await _storeMigrationValue(
          _migrationKey,
          jsonEncode({'version': 4, 'sourceRows': records.length}),
          keepExisting: true,
        );
        await _storage.write(_permanentAdoptedKey, '4');
        _migrationReady = true;
      }),
    );
  }

  bool _hasV3Envelope(String? raw) {
    try {
      final envelope = raw == null ? null : jsonDecode(raw);
      if (envelope is! Map ||
          envelope['version'] != 3 ||
          envelope['payload'] is! String) {
        return false;
      }
      final payload = jsonDecode(envelope['payload'] as String);
      return payload is Map &&
          payload['format'] == 3 &&
          payload['receipts'] is List;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    }
  }

  Future<void> _storeMigrationValue(
    String key,
    String value, {
    bool keepExisting = false,
  }) async {
    if (await _receiptStorage.compareAndSet(
      key,
      expectedValue: null,
      value: value,
    )) {
      return;
    }
    final existing = await _receiptStorage.read(key);
    if (existing == null || (!keepExisting && existing != value)) {
      throw StateError('本机历史回执尚未完整保存，迁移没有完成');
    }
  }

  Future<String> _encodeRecord(LocalAuditReceipt receipt) async {
    final payload = jsonEncode({
      'format': 4,
      'receipt': {
        ...receipt.toJson(),
        'verifiedOrigin': receipt.integrityVerified,
      },
    });
    return jsonEncode({
      'version': 4,
      'payload': payload,
      'signature': await _signature(payload),
    });
  }

  Future<LocalAuditReceipt?> _decodeRecord(String? raw, String id) async {
    if (raw == null) return null;
    try {
      final envelope = jsonDecode(raw);
      if (envelope is! Map ||
          envelope['version'] != 4 ||
          envelope['payload'] is! String ||
          envelope['signature'] is! String) {
        return null;
      }
      final payload = envelope['payload'] as String;
      final data = jsonDecode(payload);
      if (data is! Map || data['format'] != 4 || data['receipt'] is! Map) {
        return null;
      }
      final row = Map<String, dynamic>.from(data['receipt'] as Map);
      final receipt = LocalAuditReceipt.fromJson(row);
      if (receipt.clientEventId != id) return null;
      final verified = _constantTimeEquals(
        envelope['signature'] as String,
        await _signature(payload),
      );
      return receipt.withIntegrity(verified && row['verifiedOrigin'] == true);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  List<LocalAuditReceipt> _decodeReceipts(
    String? raw, {
    required bool allowLegacy,
    required List<int>? legacyKey,
  }) {
    try {
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      var verified = false;
      var perReceiptOrigin = false;
      dynamic rows = allowLegacy ? decoded : null;
      if (decoded is Map) {
        final envelope = Map<String, dynamic>.from(decoded);
        final payload = envelope['payload'];
        final signature = envelope['signature'];
        if ((envelope['version'] == 2 || envelope['version'] == 3) &&
            payload is String &&
            signature is String) {
          verified =
              legacyKey != null &&
              _constantTimeEquals(
                signature,
                base64UrlEncode(
                  Hmac(sha256, legacyKey).convert(utf8.encode(payload)).bytes,
                ),
              );
          final signed = jsonDecode(payload);
          if (signed is Map &&
              signed['format'] == 3 &&
              signed['receipts'] is List) {
            perReceiptOrigin = true;
            rows = signed['receipts'];
          } else if (allowLegacy &&
              envelope['version'] == 2 &&
              signed is List) {
            rows = signed;
          } else {
            return <LocalAuditReceipt>[];
          }
        }
      }
      if (rows is! List) return <LocalAuditReceipt>[];
      final receipts = <LocalAuditReceipt>[];
      for (final value in rows.whereType<Map<Object?, Object?>>()) {
        try {
          final receipt =
              LocalAuditReceipt.fromJson(
                Map<String, dynamic>.from(value),
              ).withIntegrity(
                verified &&
                    (!perReceiptOrigin || value['verifiedOrigin'] == true),
              );
          if (_validUuid(receipt.clientEventId)) receipts.add(receipt);
        } catch (_) {
          // One damaged row must not hide all other local receipts.
        }
      }
      return receipts;
    } on FormatException {
      return <LocalAuditReceipt>[];
    } on TypeError {
      return <LocalAuditReceipt>[];
    }
  }

  Future<String> _signature(String payload) async {
    final key = await _signingKey();
    return base64UrlEncode(
      Hmac(sha256, key).convert(utf8.encode(payload)).bytes,
    );
  }

  Future<List<int>?> _readLegacyKey({required bool mustExist}) async {
    // Never create or repair the old writer's key. Freeze only what its exact
    // original signature proves, then seal that provenance with the v4 key.
    final encoded = await _storage.read(_legacyIntegrityKey);
    if (encoded != null) {
      try {
        final bytes = base64Url.decode(encoded);
        if (bytes.length == 32) return bytes;
      } on FormatException {
        /* Keep malformed legacy key bytes unchanged. */
      }
    }
    if (mustExist) {
      throw StateError('旧回执校验密钥缺失或无效，历史迁移尚未完成');
    }
    return null;
  }

  Future<List<int>> _signingKey() {
    final current = _integrityKeyFuture;
    if (current != null) return current;
    late final Future<List<int>> pending;
    pending = _integrityKey().catchError((Object error, StackTrace stack) {
      if (identical(_integrityKeyFuture, pending)) _integrityKeyFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
    _integrityKeyFuture = pending;
    return pending;
  }

  Future<List<int>> _integrityKey() async {
    // A permanent receipt is trusted only after its key is durably stored.
    // Never replace an unreadable key or silently rotate an adopted ledger.
    final existing = await _storage.read(_receiptIntegrityKey);
    if (existing != null) {
      try {
        final decoded = base64Url.decode(existing);
        if (decoded.length == 32) return decoded;
      } on FormatException {
        /* Preserve the original bytes for recovery. */
      }
      throw StateError('本机回执校验密钥无效，已有记录未修改');
    }
    if (await _receiptStorage.read(_migrationKey) != null ||
        await _storage.read(_permanentAdoptedKey) != null) {
      throw StateError('本机回执校验密钥缺失，已有记录未修改');
    }
    final random = Random.secure();
    final generated = List<int>.generate(32, (_) => random.nextInt(256));
    final encoded = base64UrlEncode(generated);
    await _storage.write(_receiptIntegrityKey, encoded);
    final stored = await _storage.read(_receiptIntegrityKey);
    if (stored == null || !_constantTimeEquals(stored, encoded)) {
      throw StateError('本机回执校验密钥未安全保存，本次回执未发布');
    }
    return generated;
  }

  Future<DeviceAuditProfile> _buildProfile() async {
    final installationId = await _installationId();
    final now = DateTime.now();
    var platform = kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();
    String? deviceName;
    String? manufacturer;
    String? model;
    String? osVersion;
    String? browserName;
    String? locale;
    bool? physical;
    var formFactor = kIsWeb ? 'web' : 'desktop';

    try {
      if (kIsWeb) {
        final info = await _deviceInfo.webBrowserInfo;
        browserName = info.browserName.name;
        deviceName = '${_browserLabel(browserName)} 浏览器';
        manufacturer = _clean(info.vendor, 120);
        // Browsers cannot truthfully expose a computer model or OS build.
        model = null;
        osVersion = null;
        locale = _clean(info.language, 64);
      } else if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        platform = 'android';
        formFactor = 'mobile';
        deviceName = _firstNonBlank([info.name, info.model]);
        manufacturer = _clean(info.manufacturer, 120);
        model = _clean(info.model, 160);
        osVersion = _clean(
          'Android ${info.version.release} (API ${info.version.sdkInt})',
          200,
        );
        physical = info.isPhysicalDevice;
        locale = _clean(Platform.localeName, 64);
      } else if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        platform = 'ios';
        formFactor = 'mobile';
        deviceName = _clean(info.name, 200);
        manufacturer = 'Apple';
        model = _firstNonBlank([info.modelName, info.model]);
        osVersion = _clean('${info.systemName} ${info.systemVersion}', 200);
        physical = info.isPhysicalDevice;
        locale = _clean(Platform.localeName, 64);
      } else if (Platform.isWindows) {
        final info = await _deviceInfo.windowsInfo;
        platform = 'windows';
        deviceName = _clean(info.computerName, 200);
        // productName is the Windows edition, not an OEM hardware model.
        model = null;
        osVersion = _clean(
          '${info.productName} ${info.displayVersion} (Build ${info.buildNumber})',
          200,
        );
        locale = _clean(Platform.localeName, 64);
      } else if (Platform.isMacOS) {
        final info = await _deviceInfo.macOsInfo;
        platform = 'macos';
        deviceName = _clean(info.computerName, 200);
        manufacturer = 'Apple';
        model = _firstNonBlank([info.modelName, info.model]);
        osVersion = _clean(
          'macOS ${info.majorVersion}.${info.minorVersion}.${info.patchVersion}',
          200,
        );
        locale = _clean(Platform.localeName, 64);
      } else if (Platform.isLinux) {
        final info = await _deviceInfo.linuxInfo;
        platform = 'linux';
        deviceName = _clean(Platform.localHostname, 200);
        osVersion = _clean(info.prettyName, 200);
        locale = _clean(Platform.localeName, 64);
      }
    } catch (_) {
      // 设备插件在不支持的平台或权限受限时可能失败；审计元数据不能阻断业务。
    }

    return DeviceAuditProfile(
      installationId: installationId,
      deviceName: _clean(deviceName, 200),
      manufacturer: _clean(manufacturer, 120),
      model: _clean(model, 160),
      platform: _clean(platform, 32) ?? 'unknown',
      osVersion: _clean(osVersion, 200),
      appVersion: _clean(AppInfo.version, 64) ?? 'unknown',
      appBuild: _clean(AppInfo.buildId, 64) ?? 'unknown',
      formFactor: formFactor,
      browserName: _clean(browserName, 80),
      locale: _clean(locale, 64),
      timeZone: _clean(now.timeZoneName, 80),
      timeZoneOffsetMinutes: now.timeZoneOffset.inMinutes,
      isPhysicalDevice: physical,
    );
  }

  Future<String> _installationId() async {
    String? secureId;
    try {
      secureId = await _storage.read(_installationKey);
    } catch (_) {
      // Both anchors must agree before an installation identity is reused.
    }

    String? installationMarker;
    try {
      installationMarker = (await _preferences).getString(
        _installationMarkerKey,
      );
    } catch (_) {
      // A missing/unreadable app-local marker is treated as a fresh install.
    }

    if (_validUuid(secureId) &&
        _validUuid(installationMarker) &&
        secureId == installationMarker) {
      return secureId!;
    }

    // iOS Keychain may survive uninstall. SharedPreferences is the app-local
    // installation anchor: when it is missing or disagrees, rotate the UUID so
    // a reinstall cannot inherit the previous installation's audit identity.
    final generated = _uuid.v4();
    try {
      await _storage.write(_installationKey, generated);
    } catch (_) {
      // The cached profile keeps this ID stable for the current process.
    }
    try {
      await (await _preferences).setString(_installationMarkerKey, generated);
    } catch (_) {
      // Without both durable anchors the next process deliberately rotates.
    }
    return generated;
  }
}

final deviceAuditStoreProvider = Provider<DeviceAuditStore>(
  (ref) => DefaultDeviceAuditStore(ref.watch(secureStorageProvider)),
);

final currentDeviceAuditProfileProvider = FutureProvider<DeviceAuditProfile>((
  ref,
) {
  return ref.watch(deviceAuditStoreProvider).profile();
});

final localAuditReceiptProvider = FutureProvider.autoDispose
    .family<LocalAuditReceipt?, String>((ref, clientEventId) {
      return ref.watch(deviceAuditStoreProvider).findReceipt(clientEventId);
    });

bool _constantTimeEquals(String left, String right) {
  var difference = left.length ^ right.length;
  final length = max(left.length, right.length);
  for (var index = 0; index < length; index++) {
    final leftUnit = index < left.length ? left.codeUnitAt(index) : 0;
    final rightUnit = index < right.length ? right.codeUnitAt(index) : 0;
    difference |= leftUnit ^ rightUnit;
  }
  return difference == 0;
}

String? _clean(String? value, int maxLength) {
  if (value == null) return null;
  final cleaned = value
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= maxLength
      ? cleaned
      : cleaned.substring(0, maxLength);
}

String? _firstNonBlank(List<String?> values) {
  for (final value in values) {
    final cleaned = _clean(value, 200);
    if (cleaned != null) return cleaned;
  }
  return null;
}

bool _validUuid(String? value) {
  if (value == null) return false;
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String _browserLabel(String name) => switch (name) {
  'chrome' => 'Chrome',
  'edge' => 'Edge',
  'firefox' => 'Firefox',
  'safari' => 'Safari',
  'opera' => 'Opera',
  'samsungInternet' => 'Samsung Internet',
  _ => 'Web',
};

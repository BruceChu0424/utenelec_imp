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

class DefaultDeviceAuditStore implements DeviceAuditStore {
  DefaultDeviceAuditStore(
    this._storage, {
    DeviceInfoPlugin? deviceInfo,
    SharedPreferences? preferences,
    Uuid? uuid,
  }) : _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
       _preferences = preferences == null
           ? SharedPreferences.getInstance()
           : Future<SharedPreferences>.value(preferences),
       _uuid = uuid ?? const Uuid();

  static const _installationKey = 'audit.device.installation_id';
  static const _installationMarkerKey = 'audit.device.installation_marker.v1';
  static const _receiptsKey = 'audit.device.local_receipts.v1';
  static const _receiptIntegrityKey = 'audit.device.receipt_integrity_key.v1';
  static const _retentionMonthsKey = 'audit.device.receipt_retention_months';
  static const _maxReceipts = 300;
  static const _defaultRetentionMonths = 36;

  final SecureStorage _storage;
  final DeviceInfoPlugin _deviceInfo;
  final Future<SharedPreferences> _preferences;
  final Uuid _uuid;

  Future<DeviceAuditProfile>? _profileFuture;
  Future<List<LocalAuditReceipt>>? _receiptsFuture;
  Future<List<int>>? _integrityKeyFuture;
  int? _retentionMonths;
  Future<void> _writes = Future<void>.value();

  @override
  Future<DeviceAuditProfile> profile() => _profileFuture ??= _buildProfile();

  @override
  Future<void> beginReceipt({
    required String clientEventId,
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  }) => _mutateReceipts((receipts) {
    final index = receipts.indexWhere(
      (receipt) => receipt.clientEventId == clientEventId,
    );
    if (index < 0) {
      receipts.add(
        LocalAuditReceipt(
          clientEventId: clientEventId,
          installationId: device.installationId,
          method: _clean(method, 10) ?? 'UNKNOWN',
          path: _clean(path, 1000) ?? '/',
          startedAt: startedAt.toUtc().toIso8601String(),
          outcome: 'pending',
          device: device,
        ),
      );
      return;
    }
    final previous = receipts.removeAt(index);
    receipts.add(
      previous.startNextAttempt(
        method: _clean(method, 10) ?? 'UNKNOWN',
        path: _clean(path, 1000) ?? '/',
        startedAt: startedAt,
        device: device,
      ),
    );
  });

  @override
  Future<void> completeReceipt({
    required String clientEventId,
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  }) => _mutateReceipts((receipts) {
    final index = receipts.indexWhere(
      (receipt) => receipt.clientEventId == clientEventId,
    );
    if (index < 0) return;
    receipts[index] = receipts[index].complete(
      outcome: outcome,
      completedAt: completedAt,
      statusCode: statusCode,
      serverRequestId: _validUuid(serverRequestId) ? serverRequestId : null,
    );
  });

  @override
  Future<LocalAuditReceipt?> findReceipt(String clientEventId) async {
    await _writes.catchError((_) {});
    final receipts = await _loadReceipts();
    for (final receipt in receipts.reversed) {
      if (receipt.clientEventId == clientEventId) return receipt;
    }
    return null;
  }

  @override
  Future<void> updateRetentionMonths(int months) async {
    if (months < 1 || months > 360) return;
    _retentionMonths = months;
    final preferences = await _preferences;
    await preferences.setInt(_retentionMonthsKey, months);
    await _mutateReceipts((_) {});
  }

  Future<void> _mutateReceipts(
    void Function(List<LocalAuditReceipt>) mutation,
  ) {
    final next = _writes.catchError((_) {}).then((_) async {
      final receipts = await _loadReceipts();
      mutation(receipts);
      await _purgeExpired(receipts);
      if (receipts.length > _maxReceipts) {
        receipts.removeRange(0, receipts.length - _maxReceipts);
      }
      final preferences = await _preferences;
      final payload = jsonEncode(
        receipts.map((receipt) => receipt.toJson()).toList(),
      );
      final signature = await _signature(payload);
      final stored = await preferences.setString(
        _receiptsKey,
        jsonEncode({'version': 2, 'payload': payload, 'signature': signature}),
      );
      if (!stored) throw StateError('Local audit receipt write failed');
      for (var index = 0; index < receipts.length; index++) {
        receipts[index] = receipts[index].withIntegrity(true);
      }
    });
    _writes = next;
    return next;
  }

  Future<List<LocalAuditReceipt>> _loadReceipts() =>
      _receiptsFuture ??= _readReceipts();

  Future<List<LocalAuditReceipt>> _readReceipts() async {
    try {
      final preferences = await _preferences;
      final raw = preferences.getString(_receiptsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      var verified = false;
      dynamic rows = decoded;
      if (decoded is Map) {
        final envelope = Map<String, dynamic>.from(decoded);
        final payload = envelope['payload'];
        final signature = envelope['signature'];
        if (envelope['version'] == 2 &&
            payload is String &&
            signature is String) {
          verified = _constantTimeEquals(signature, await _signature(payload));
          rows = jsonDecode(payload);
        }
      }
      if (rows is! List) return <LocalAuditReceipt>[];
      final receipts = <LocalAuditReceipt>[];
      for (final value in rows.whereType<Map<Object?, Object?>>()) {
        try {
          final receipt = LocalAuditReceipt.fromJson(
            Map<String, dynamic>.from(value),
          ).withIntegrity(verified);
          if (_validUuid(receipt.clientEventId)) receipts.add(receipt);
        } catch (_) {
          // One damaged row must not hide all other local receipts.
        }
      }
      await _purgeExpired(receipts);
      return receipts;
    } catch (_) {
      return <LocalAuditReceipt>[];
    }
  }

  Future<void> _purgeExpired(List<LocalAuditReceipt> receipts) async {
    final preferences = await _preferences;
    final months = _retentionMonths ??=
        preferences.getInt(_retentionMonthsKey) ?? _defaultRetentionMonths;
    final cutoff = _subtractMonths(DateTime.now().toUtc(), months);
    receipts.removeWhere((receipt) {
      final started = DateTime.tryParse(receipt.startedAt)?.toUtc();
      return started == null || started.isBefore(cutoff);
    });
  }

  Future<String> _signature(String payload) async {
    final key = await (_integrityKeyFuture ??= _integrityKey());
    return base64UrlEncode(
      Hmac(sha256, key).convert(utf8.encode(payload)).bytes,
    );
  }

  Future<List<int>> _integrityKey() async {
    try {
      final existing = await _storage.read(_receiptIntegrityKey);
      if (existing != null) {
        final decoded = base64Url.decode(existing);
        if (decoded.length == 32) return decoded;
      }
    } catch (_) {
      // Fall through to a process-local key if secure storage is unavailable.
    }
    final random = Random.secure();
    final generated = List<int>.generate(32, (_) => random.nextInt(256));
    try {
      await _storage.write(_receiptIntegrityKey, base64UrlEncode(generated));
    } catch (_) {
      // A later process will flag these best-effort receipts as unverified.
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

DateTime _subtractMonths(DateTime value, int months) {
  final monthIndex = value.year * 12 + value.month - 1 - months;
  final year = monthIndex ~/ 12;
  final month = monthIndex % 12 + 1;
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  return DateTime.utc(
    year,
    month,
    min(value.day, lastDay),
    value.hour,
    value.minute,
    value.second,
    value.millisecond,
    value.microsecond,
  );
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

enum ServerHealthStatus {
  normal,
  warning,
  critical,
  unknown;

  static ServerHealthStatus fromWire(Object? value) => switch (value) {
    'NORMAL' => normal,
    'WARNING' => warning,
    'CRITICAL' => critical,
    _ => unknown,
  };
}

class ServerStatusSnapshot {
  const ServerStatusSnapshot({
    required this.status,
    required this.sampledAt,
    required this.refreshAfterSeconds,
    required this.environment,
    required this.applicationVersion,
    required this.uptimeSeconds,
    required this.metrics,
    required this.disks,
    required this.database,
    required this.backup,
    required this.alerts,
  });

  final ServerHealthStatus status;
  final DateTime? sampledAt;
  final int refreshAfterSeconds;
  final String environment;
  final String applicationVersion;
  final double? uptimeSeconds;
  final List<ServerMetric> metrics;
  final List<ServerDisk> disks;
  final ServerDatabase database;
  final ServerBackup backup;
  final List<ServerAlert> alerts;

  int get pollSeconds => refreshAfterSeconds.clamp(10, 15);
  bool isStale(DateTime now) =>
      sampledAt == null ||
      now.toUtc().difference(sampledAt!.toUtc()) >
          Duration(seconds: pollSeconds * 2);

  factory ServerStatusSnapshot.fromJson(Map<String, dynamic> json) =>
      ServerStatusSnapshot(
        status: ServerHealthStatus.fromWire(json['status']),
        sampledAt: _date(json['sampledAt']),
        refreshAfterSeconds:
            _number(json['refreshAfterSeconds'])?.toInt() ?? 15,
        environment: _text(json['environment']),
        applicationVersion: _text(json['applicationVersion']),
        uptimeSeconds: _number(json['uptimeSeconds']),
        metrics: _rows(
          json['metrics'],
        ).map(ServerMetric.fromJson).toList(growable: false),
        disks: _rows(
          json['disks'],
        ).map(ServerDisk.fromJson).toList(growable: false),
        database: ServerDatabase.fromJson(_object(json['database'])),
        backup: ServerBackup.fromJson(_object(json['backup'])),
        alerts: _rows(
          json['alerts'],
        ).map(ServerAlert.fromJson).toList(growable: false),
      );
}

class ServerMetric {
  const ServerMetric({
    required this.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.warningThreshold,
    required this.criticalThreshold,
    required this.status,
    required this.detail,
    this.totalBytes,
    this.usedBytes,
    this.freeBytes,
  });
  final String key, label, unit, detail;
  final double? value, warningThreshold, criticalThreshold;
  final double? totalBytes, usedBytes, freeBytes;
  final ServerHealthStatus status;
  factory ServerMetric.fromJson(Map<String, dynamic> json) => ServerMetric(
    key: _text(json['key']),
    label: _text(json['label']),
    value: _number(json['value']),
    unit: _text(json['unit']),
    warningThreshold: _number(json['warningThreshold']),
    criticalThreshold: _number(json['criticalThreshold']),
    status: ServerHealthStatus.fromWire(json['status']),
    detail: _text(json['detail']),
    totalBytes: _number(json['totalBytes']),
    usedBytes: _number(json['usedBytes']),
    freeBytes: _number(json['freeBytes']),
  );
}

class ServerDisk {
  const ServerDisk({
    required this.key,
    required this.label,
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
    required this.usedPercent,
    required this.warningThreshold,
    required this.criticalThreshold,
    required this.status,
    required this.detail,
  });
  final String key, label, detail;
  final double? totalBytes, usedBytes, freeBytes, usedPercent;
  final double? warningThreshold, criticalThreshold;
  final ServerHealthStatus status;
  factory ServerDisk.fromJson(Map<String, dynamic> json) => ServerDisk(
    key: _text(json['key']),
    label: _text(json['label']),
    totalBytes: _number(json['totalBytes']),
    usedBytes: _number(json['usedBytes']),
    freeBytes: _number(json['freeBytes']),
    usedPercent: _number(json['usedPercent']),
    warningThreshold: _number(json['warningThreshold']),
    criticalThreshold: _number(json['criticalThreshold']),
    status: ServerHealthStatus.fromWire(json['status']),
    detail: _text(json['detail']),
  );
}

class ServerDatabase {
  const ServerDatabase({
    required this.status,
    required this.responseMs,
    required this.connections,
    required this.maxConnections,
    required this.detail,
  });
  final ServerHealthStatus status;
  final double? responseMs, connections, maxConnections;
  final String detail;
  factory ServerDatabase.fromJson(Map<String, dynamic> json) => ServerDatabase(
    status: ServerHealthStatus.fromWire(json['status']),
    responseMs: _number(json['responseMs']),
    connections: _number(json['connections']),
    maxConnections: _number(json['maxConnections']),
    detail: _text(json['detail']),
  );
}

class ServerBackup {
  const ServerBackup({
    required this.status,
    required this.lastSuccessAt,
    required this.ageHours,
    required this.warningAfterHours,
    required this.criticalAfterHours,
    required this.detail,
  });
  final ServerHealthStatus status;
  final DateTime? lastSuccessAt;
  final double? ageHours, warningAfterHours, criticalAfterHours;
  final String detail;
  factory ServerBackup.fromJson(Map<String, dynamic> json) => ServerBackup(
    status: ServerHealthStatus.fromWire(json['status']),
    lastSuccessAt: _date(json['lastSuccessAt']),
    ageHours: _number(json['ageHours']),
    warningAfterHours: _number(json['warningAfterHours']),
    criticalAfterHours: _number(json['criticalAfterHours']),
    detail: _text(json['detail']),
  );
}

class ServerAlert {
  const ServerAlert({
    required this.key,
    required this.status,
    required this.message,
    required this.suggestion,
  });
  final String key, message, suggestion;
  final ServerHealthStatus status;
  factory ServerAlert.fromJson(Map<String, dynamic> json) => ServerAlert(
    key: _text(json['key']),
    status: ServerHealthStatus.fromWire(json['status']),
    message: _text(json['message']),
    suggestion: _text(json['suggestion']),
  );
}

double? _number(Object? value) {
  final number = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  return number?.isFinite == true ? number : null;
}

String _text(Object? value) => value is String ? value : '';
DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
Map<String, dynamic> _object(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const {};
Iterable<Map<String, dynamic>> _rows(Object? value) => value is List
    ? value.whereType<Map<dynamic, dynamic>>().map(
        (row) => row.cast<String, dynamic>(),
      )
    : const [];

class ServerOperationsStatus {
  ServerOperationsStatus.fromJson(Map<String, dynamic> json)
    : available = json['available'] == true,
      manualOnly = json['manualOnly'] is bool
          ? json['manualOnly'] as bool
          : null,
      timerActive = json['timerActive'] is bool
          ? json['timerActive'] as bool
          : null,
      currentVersion = _text(json['currentVersion']),
      sourceRevision = _text(json['sourceRevision']),
      latestVersion = _text(json['latestVersion']),
      serverTimeZone = _text(json['serverTimeZone']),
      serverTime = _text(json['serverTime']),
      lastCheckedAt = _date(json['lastCheckedAt']),
      updateAvailable = json['updateAvailable'] == true,
      sourceConfigured = json['sourceConfigured'] is bool
          ? json['sourceConfigured'] as bool
          : null,
      latestJob = json['latestJob'] is Map<String, dynamic>
          ? ServerUpdateJob.fromJson(json['latestJob'] as Map<String, dynamic>)
          : null,
      message = _text(json['message']),
      canUpdate = json['canUpdate'] == true,
      canCleanup = json['canCleanup'] == true,
      canConfigureSource = json['canConfigureSource'] == true;

  final bool available, canUpdate, canCleanup, canConfigureSource;
  final bool updateAvailable;
  final bool? manualOnly, timerActive, sourceConfigured;
  final String? currentVersion, sourceRevision, message;
  final String? latestVersion, serverTimeZone, serverTime;
  final DateTime? lastCheckedAt;
  final ServerUpdateJob? latestJob;
}

class ServerUpdateJob {
  ServerUpdateJob.fromJson(Map<String, dynamic> json)
    : id = _required(json['id']),
      requestId = _required(json['requestId']),
      actorId = _text(json['actorId']),
      state = _required(json['state']),
      phase = _required(json['phase']),
      mode = _text(json['mode']),
      scheduledAt = _date(json['scheduledAt']),
      displayLocalTime = _text(json['displayLocalTime']),
      startedAt = _date(json['startedAt']),
      finishedAt = _date(json['finishedAt']),
      currentVersion = _text(json['currentVersion']),
      targetVersion = _text(json['targetVersion']),
      message = _text(json['message']),
      migrationRequired = json['migrationRequired'] is bool
          ? json['migrationRequired'] as bool
          : null,
      health = json['health'];

  final String id, requestId, state, phase;
  final String? mode;
  final String? actorId, displayLocalTime;
  final DateTime? scheduledAt;
  final DateTime? startedAt, finishedAt;
  final String? currentVersion, targetVersion, message;
  final bool? migrationRequired;
  final Object? health;
  bool get running => const {'QUEUED', 'RUNNING', 'SCHEDULED'}.contains(state);
  bool get succeeded => state == 'SUCCEEDED';
  bool get recoveryRequired => state == 'RECOVERY_REQUIRED';
  bool get terminal => const {
    'SUCCEEDED',
    'FAILED',
    'RECOVERY_REQUIRED',
    'CANCELLED',
  }.contains(state);
}

class ServerUpdateSchedulePreview {
  ServerUpdateSchedulePreview.fromJson(Map<String, dynamic> json)
    : scheduledAt = _required(json['scheduledAt']),
      serverTimeZone = _required(json['serverTimeZone']),
      displayLocalTime = _required(json['displayLocalTime']) {
    if (DateTime.tryParse(scheduledAt)?.isUtc != true ||
        displayLocalTime.isEmpty ||
        serverTimeZone.isEmpty) {
      throw const FormatException('Invalid server-local schedule preview');
    }
  }
  final String scheduledAt, serverTimeZone, displayLocalTime;
}

class ServerUpdateSource {
  ServerUpdateSource.fromJson(Map<String, dynamic> json)
    : revision = _required(json['revision']),
      endpoint = _required(json['endpoint']),
      bucket = _required(json['bucket']),
      objectPrefix = _required(json['objectPrefix']),
      accessKeyConfigured = json['accessKeyConfigured'] == true,
      accessKeyIdHint = _text(json['accessKeyIdHint']),
      signingPublicKey = _text(json['signingPublicKey']),
      signingKeyFingerprint = _text(json['signingKeyFingerprint']),
      sourceUrl = _text(json['sourceUrl']),
      applied = json['applied'] == true;

  final String revision, endpoint, bucket, objectPrefix;
  final bool accessKeyConfigured, applied;
  final String? accessKeyIdHint,
      signingPublicKey,
      signingKeyFingerprint,
      sourceUrl;
}

String _required(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid server operation response');
  }
  return value;
}

String? _text(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

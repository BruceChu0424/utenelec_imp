/// Local host inventory. Unknown sizes stay null rather than implying zero use.
class ServerStorageSummary {
  const ServerStorageSummary({
    required this.revision,
    required this.status,
    required this.available,
    required this.canCleanup,
    required this.volumes,
    required this.categories,
    this.sampledAt,
    this.unavailableReason,
    this.rssBytes,
    this.heapUsedBytes,
    this.heapMaxBytes,
    this.databaseBytes,
    this.databaseStatus,
    this.uploadCount,
    this.uploadLogicalBytes,
    this.uploadStoredBytes,
    this.uploadStatus,
    this.processDetail,
    this.uploadDetail,
  });

  factory ServerStorageSummary.fromJson(Map<String, dynamic> json) {
    final capabilities = _map(json['capabilities']);
    final process = _map(json['process']);
    final database = _map(json['database']);
    final uploads = _map(json['uploads']);
    return ServerStorageSummary(
      revision: _text(json['revision']),
      status: _text(json['status']),
      available: capabilities['available'] == true,
      canCleanup: capabilities['canCleanup'] == true,
      unavailableReason: _optionalText(capabilities['unavailableReason']),
      sampledAt: _date(json['sampledAt']),
      volumes: _rows(
        json['volumes'],
      ).map(ServerStorageVolume.fromJson).toList(),
      categories: _rows(
        json['categories'],
      ).map(ServerStorageCategory.fromJson).toList(),
      rssBytes: _size(process['rssBytes']),
      heapUsedBytes: _size(process['heapUsedBytes']),
      heapMaxBytes: _size(process['heapMaxBytes']),
      databaseBytes: _size(database['sizeBytes']),
      databaseStatus: _optionalText(database['status']),
      uploadCount: _size(uploads['count']),
      uploadLogicalBytes: _size(uploads['logicalBytes']),
      uploadStoredBytes: _size(uploads['storedBytes']),
      uploadStatus: _optionalText(uploads['status']),
      processDetail: _optionalText(process['detail']),
      uploadDetail: _optionalText(uploads['detail']),
    );
  }

  final String revision, status;
  final bool available, canCleanup;
  final DateTime? sampledAt;
  final String? unavailableReason;
  final List<ServerStorageVolume> volumes;
  final List<ServerStorageCategory> categories;
  final int? rssBytes, heapUsedBytes, heapMaxBytes, databaseBytes;
  final int? uploadCount, uploadLogicalBytes, uploadStoredBytes;
  final String? databaseStatus, uploadStatus;
  final String? processDetail, uploadDetail;
}

class ServerStorageVolume {
  ServerStorageVolume.fromJson(Map<String, dynamic> json)
    : id = _text(json['id']),
      label = _text(json['label']),
      totalBytes = _size(json['totalBytes']),
      usedBytes = _size(json['usedBytes']),
      freeBytes = _size(json['freeBytes']);

  final String id, label;
  final int? totalBytes, usedBytes, freeBytes;
}

class ServerStorageCategory {
  ServerStorageCategory.fromJson(Map<String, dynamic> json)
    : kind = _text(json['kind']),
      label = _text(json['label']),
      status = _text(json['status']),
      logicalBytes = _size(json['logicalBytes']),
      allocatedBytes = _size(json['allocatedBytes']),
      reclaimableBytes = _size(json['reclaimableBytes']),
      count = _size(json['count']),
      detail = _optionalText(json['detail']),
      volumeId = _optionalText(json['volumeId']),
      canList = json['canList'] == true;

  final String kind, label, status;
  final int? logicalBytes, allocatedBytes, reclaimableBytes, count;
  final String? detail;
  final String? volumeId;
  final bool canList;

  String get displayLabel => switch (kind) {
    'UPLOADS' => '当前上传目录',
    'LEGACY_UPLOADS' => '兼容旧上传目录',
    _ => label.isEmpty ? kind : label,
  };
}

class ServerStorageResource {
  ServerStorageResource.fromJson(Map<String, dynamic> json)
    : id = _text(json['id']),
      label = _text(json['label']),
      kind = _text(json['kind']),
      logicalBytes = _size(json['logicalBytes']),
      allocatedBytes = _size(json['allocatedBytes']),
      reclaimableBytes = _size(json['reclaimableBytes']),
      modifiedAt = _date(json['modifiedAt']),
      canDelete = json['canDelete'] == true,
      protectionReasons = (json['protectionReasons'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      detail = _optionalText(json['detail']);

  final String id, label, kind;
  final int? logicalBytes, allocatedBytes, reclaimableBytes;
  final DateTime? modifiedAt;
  final bool canDelete;
  final List<String> protectionReasons;
  final String? detail;
}

class ServerStorageResources {
  ServerStorageResources._({
    required this.revision,
    required this.kind,
    required this.sampledAt,
    required this.items,
    required this.nextCursor,
    required this.total,
  });
  ServerStorageResources.fromJson(Map<String, dynamic> json)
    : revision = _text(json['revision']),
      kind = _text(json['kind']),
      sampledAt = _date(json['sampledAt']),
      items = _rows(json['items']).map(ServerStorageResource.fromJson).toList(),
      nextCursor = _optionalText(json['nextCursor']),
      total = _size(json['total']);

  final String revision, kind;
  final DateTime? sampledAt;
  final List<ServerStorageResource> items;
  final String? nextCursor;
  final int? total;

  ServerStorageResources withItems(List<ServerStorageResource> rows) =>
      ServerStorageResources._(
        revision: revision,
        kind: kind,
        sampledAt: sampledAt,
        items: rows,
        nextCursor: nextCursor,
        total: total,
      );
}

class ServerStoragePreview {
  ServerStoragePreview.fromJson(Map<String, dynamic> json)
    : previewId = _text(json['previewId']),
      revision = _text(json['revision']),
      expiresAt = _date(json['expiresAt']),
      resources = _rows(
        json['resources'],
      ).map(ServerStorageResource.fromJson).toList(),
      totalReclaimableBytes = _size(json['totalReclaimableBytes']),
      confirmationText = _text(json['confirmationText']),
      warnings = (json['warnings'] as List? ?? const [])
          .whereType<String>()
          .toList();

  final String previewId, revision, confirmationText;
  final DateTime? expiresAt;
  final List<ServerStorageResource> resources;
  final int? totalReclaimableBytes;
  final List<String> warnings;
}

class ServerStorageCleanupReceipt {
  ServerStorageCleanupReceipt.fromJson(Map<String, dynamic> json)
    : requestId = _text(json['requestId']),
      status = _text(json['status']),
      deletedCount = _size(json['deletedCount']),
      reclaimedBytes = _size(json['reclaimedBytes']),
      detail = _optionalText(json['detail']);

  final String requestId, status;
  final int? deletedCount, reclaimedBytes;
  final String? detail;
}

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};
List<Map<String, dynamic>> _rows(Object? value) =>
    (value is List ? value : const <Object?>[])
        .whereType<Map<String, dynamic>>()
        .toList();
String _text(Object? value) => value is String ? value : '';
String? _optionalText(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;
int? _size(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toInt() : null;

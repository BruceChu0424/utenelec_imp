/// Server-owned undo/redo capabilities. Never infer reversibility from state.
class GoodsOperationHistory {
  const GoodsOperationHistory({
    this.entries = const [],
    this.events = const [],
  });

  final List<GoodsOperationEntry> entries;
  final List<GoodsOperationEvent> events;

  factory GoodsOperationHistory.fromJson(Map<String, dynamic> json) =>
      GoodsOperationHistory(
        entries: _maps(
          json['entries'],
        ).map(GoodsOperationEntry.fromJson).toList(growable: false),
        events: _maps(
          json['events'],
        ).map(GoodsOperationEvent.fromJson).toList(growable: false),
      );
}

Iterable<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map<Object?, Object?>>().map(
        (item) => Map<String, dynamic>.from(item),
      )
    : const [];

class GoodsOperationEntry {
  const GoodsOperationEntry({
    required this.id,
    required this.operationType,
    required this.label,
    this.summary = '',
    required this.createdAt,
    required this.state,
    required this.version,
    required this.affectedCount,
    required this.canUndo,
    required this.canRedo,
    this.blockedReason,
  });

  final String id;
  final String operationType;
  final String label;
  final String summary;
  final String createdAt;
  final String state;
  final int version;
  final int affectedCount;
  final bool canUndo;
  final bool canRedo;
  final String? blockedReason;

  bool get isUndone => state == 'UNDONE';

  factory GoodsOperationEntry.fromJson(Map<String, dynamic> json) =>
      GoodsOperationEntry(
        id: json['id'] as String,
        operationType: json['operationType'] as String? ?? '',
        label: json['label'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        createdAt: json['createdAt'] as String? ?? '',
        state: json['state'] as String? ?? '',
        version: (json['version'] as num).toInt(),
        affectedCount: (json['affectedCount'] as num?)?.toInt() ?? 0,
        canUndo: json['canUndo'] == true,
        canRedo: json['canRedo'] == true,
        blockedReason: json['blockedReason'] as String?,
      );
}

class GoodsOperationEvent {
  const GoodsOperationEvent({
    required this.id,
    required this.operationId,
    required this.action,
    required this.label,
    required this.createdAt,
    this.operationType = '',
    this.summary = '',
  });

  final String id;
  final String operationId;
  final String action;
  final String label;
  final String createdAt;
  final String operationType;
  final String summary;

  factory GoodsOperationEvent.fromJson(Map<String, dynamic> json) =>
      GoodsOperationEvent(
        id: json['id'] as String,
        operationId: json['operationId'] as String,
        action: json['action'] as String,
        label: json['label'] as String? ?? '',
        createdAt: json['createdAt'] as String? ?? '',
        operationType: json['operationType'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
      );
}

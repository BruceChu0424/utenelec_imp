import '../../basic_data/models/master_facet.dart';
import '../../../components/data_display/uten_status_badge.dart';

/// A warehouse projection keeps the original business object and its next action.
/// A number shared by an order, receipt and exception is never a row identity.
class WarehouseTaskCenterRecord {
  const WarehouseTaskCenterRecord({
    required this.rowKey,
    required this.id,
    required this.sourceType,
    required this.recordType,
    required this.status,
    required this.statusLabel,
    this.tone = 'neutral',
    this.billNo,
    this.sourceDocNo,
    this.businessDate,
    this.partyName,
    this.warehouseName,
    this.responsibleName,
    this.lineCount,
    this.action = 'NONE',
    this.targetId,
    this.canHandle = false,
    this.actionData = const {},
  });

  final String rowKey;
  final String id;
  final String sourceType;
  final String recordType;
  final String status;
  final String statusLabel;
  final String tone;
  final String? billNo;
  final String? sourceDocNo;
  final String? businessDate;
  final String? partyName;
  final String? warehouseName;
  final String? responsibleName;
  final int? lineCount;
  final String action;
  final String? targetId;
  final bool canHandle;
  final Map<String, dynamic> actionData;

  UtenStatusBadgeType get statusType => UtenStatusBadgeType.values.firstWhere(
    (type) => type.name == tone,
    orElse: () => UtenStatusBadgeType.neutral,
  );

  int? get expectedVersion => switch (actionData['expectedVersion']) {
    final num value => value.toInt(),
    final String value => int.tryParse(value),
    _ => null,
  };

  String? dataId(String key) {
    final value = actionData[key]?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  List<String> dataIds(String key) => switch (actionData[key]) {
    final List<Object?> values =>
      values.whereType<String>().where((id) => id.isNotEmpty).toList(),
    _ => const [],
  };

  factory WarehouseTaskCenterRecord.fromJson(Map<String, dynamic> json) {
    String requiredText(String key) {
      final value = json[key]?.toString().trim() ?? '';
      if (value.isEmpty) throw FormatException('仓库任务缺少 $key');
      return value;
    }

    String? optionalText(String key) => json[key]?.toString();
    return WarehouseTaskCenterRecord(
      rowKey: requiredText('rowKey'),
      id: requiredText('id'),
      sourceType: requiredText('sourceType'),
      recordType: requiredText('recordType'),
      status: requiredText('status'),
      statusLabel: requiredText('statusLabel'),
      tone: optionalText('tone') ?? 'neutral',
      billNo: optionalText('billNo'),
      sourceDocNo: optionalText('sourceDocNo'),
      businessDate: optionalText('businessDate'),
      partyName: optionalText('partyName'),
      warehouseName: optionalText('warehouseName'),
      responsibleName: optionalText('responsibleName'),
      lineCount: (json['lineCount'] as num?)?.toInt(),
      action: optionalText('action') ?? 'NONE',
      targetId: optionalText('targetId'),
      canHandle: json['canHandle'] == true,
      actionData: Map<String, dynamic>.unmodifiable(
        json['actionData'] is Map
            ? Map<String, dynamic>.from(json['actionData'] as Map)
            : const {},
      ),
    );
  }
}

class WarehouseTaskCenterPageResult {
  const WarehouseTaskCenterPageResult({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
    this.facets = const {},
  });
  final List<WarehouseTaskCenterRecord> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;
  final Map<String, List<MasterFacetBucket>> facets;
  List<MasterFacetBucket> get statusFacets => facets['status'] ?? const [];

  factory WarehouseTaskCenterPageResult.fromJson(Map<String, dynamic> json) {
    final Map<Object?, Object?> facets = json['facets'] is Map
        ? json['facets'] as Map<Object?, Object?>
        : const {};
    return WarehouseTaskCenterPageResult(
      items: (json['items'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(WarehouseTaskCenterRecord.fromJson)
          .toList(growable: false),
      page: (json['page'] as num?)?.toInt() ?? 1,
      size: (json['size'] as num?)?.toInt() ?? 20,
      total: (json['total'] as num?)?.toInt() ?? 0,
      totalPages: (json['totalPages'] as num?)?.toInt() ?? 0,
      facets: {
        for (final key in const ['status', 'billNo'])
          key: (facets[key] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(
                (bucket) => MasterFacetBucket(
                  value: bucket['value']?.toString() ?? '',
                  label: bucket['label']?.toString(),
                  count: (bucket['count'] as num?)?.toInt() ?? 0,
                ),
              )
              .toList(growable: false),
      },
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/product_category_node.dart';

class MasterRecordChange {
  const MasterRecordChange(this.label, this.before, this.after);
  final String label;
  final String before;
  final String after;
  factory MasterRecordChange.fromJson(Map<String, dynamic> json) =>
      MasterRecordChange(
        json['label'] as String? ?? '',
        json['beforeValue'] as String? ?? '',
        json['afterValue'] as String? ?? '',
      );
}

class MasterRecordRevision {
  const MasterRecordRevision({
    required this.id,
    required this.recordLabel,
    required this.action,
    required this.actorName,
    required this.recordedAt,
    required this.expectedHead,
    required this.affectedCount,
    required this.changes,
    required this.canRestoreBefore,
    required this.canRestoreAfter,
    this.blockedReason,
    this.entityType = '',
    this.sourceType = 'RECORD',
    this.recordId = '',
    this.recordCode = '',
    this.recordName = '',
    this.categoryId,
    this.categoryName = '',
    this.summary = '',
    this.actorId,
  });
  final String id;
  final String recordLabel;
  final String action;
  final String actorName;
  final String recordedAt;
  final String expectedHead;
  final int affectedCount;
  final List<MasterRecordChange> changes;
  final bool canRestoreBefore;
  final bool canRestoreAfter;
  final String? blockedReason;
  final String entityType;
  final String sourceType;
  final String recordId;
  final String recordCode;
  final String recordName;
  final String? categoryId;
  final String categoryName;
  final String summary;
  final String? actorId;

  factory MasterRecordRevision.fromJson(Map<String, dynamic> json) =>
      MasterRecordRevision(
        id: json['id'].toString(),
        recordLabel: json['recordLabel'] as String? ?? '',
        action: json['action'] as String? ?? '',
        actorName: json['actorName'] as String? ?? '',
        recordedAt: json['recordedAt'] as String? ?? '',
        expectedHead: json['expectedHead'].toString(),
        affectedCount: (json['affectedCount'] as num?)?.toInt() ?? 0,
        changes: [
          for (final row in json['changes'] as List? ?? const [])
            MasterRecordChange.fromJson(Map<String, dynamic>.from(row as Map)),
        ],
        canRestoreBefore: json['canRestoreBefore'] == true,
        canRestoreAfter: json['canRestoreAfter'] == true,
        blockedReason: json['blockedReason'] as String?,
        entityType: json['entityType'] as String? ?? '',
        sourceType: json['sourceType'] as String? ?? 'RECORD',
        recordId: json['recordId'] as String? ?? '',
        recordCode: json['recordCode'] as String? ?? '',
        recordName:
            json['recordName'] as String? ??
            json['recordLabel'] as String? ??
            '',
        categoryId: json['categoryId'] as String?,
        categoryName: json['categoryName'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        actorId: json['actorId'] as String?,
      );
}

class MasterRecordHistoryPage {
  const MasterRecordHistoryPage(this.entries, this.nextCursor);
  final List<MasterRecordRevision> entries;
  final String? nextCursor;
  factory MasterRecordHistoryPage.fromJson(Map<String, dynamic> json) =>
      MasterRecordHistoryPage([
        for (final entry in json['entries'] as List? ?? const [])
          MasterRecordRevision.fromJson(
            Map<String, dynamic>.from(entry as Map),
          ),
      ], json['nextCursor'] as String?);
}

class MasterRecordHistoryRepository {
  const MasterRecordHistoryRepository(this.api);
  final ApiClient api;
  Future<MasterRecordRevision> detail({
    required String entityType,
    required String id,
  }) async => MasterRecordRevision.fromJson(
    await api.get(
      '/master/record-history/${Uri.encodeComponent(id)}',
      query: {'entityType': entityType},
    ),
  );
  Future<MasterRecordHistoryPage> list({
    String? entityType,
    String? recordId,
    String? categoryId,
    String? cursor,
    String? action,
    String? actorId,
    String? actorKeyword,
    String? keyword,
    String? dateFrom,
    String? dateTo,
    String? sourceType,
    String? summaryKeyword,
    int size = 50,
  }) async => MasterRecordHistoryPage.fromJson(
    await api.get(
      '/master/record-history',
      query: {
        'entityType': ?entityType,
        'recordId': ?recordId,
        'categoryId': ?categoryId,
        'cursor': ?cursor,
        'action': ?action,
        'actorId': ?actorId,
        'actorKeyword': ?actorKeyword,
        'keyword': ?keyword,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        'sourceType': ?sourceType,
        'summaryKeyword': ?summaryKeyword,
        'size': size,
      },
    ),
  );
  Future<List<ProductCategoryNode>> categories({
    required String entityType,
  }) async => [
    for (final row in await api.getList(
      '/master/record-history/categories',
      query: {'entityType': entityType},
    ))
      ProductCategoryNode.fromJson(row),
  ];

  Future<void> restore({
    required String entityType,
    required MasterRecordRevision revision,
    required bool before,
  }) async {
    await api.post(
      '/master/record-history/${Uri.encodeComponent(revision.id)}/restore'
      '?entityType=${Uri.encodeQueryComponent(entityType)}',
      body: {'expectedHead': revision.expectedHead, 'before': before},
    );
  }
}

final masterRecordHistoryRepositoryProvider = Provider(
  (ref) => MasterRecordHistoryRepository(ref.watch(apiClientProvider)),
);

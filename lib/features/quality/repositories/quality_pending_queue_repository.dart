import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../basic_data/models/master_facet.dart';

class QualityPendingEntry {
  const QualityPendingEntry({
    required this.source,
    required this.identity,
    required this.kind,
    required this.status,
    required this.values,
    required this.payload,
  });
  final String source, identity, kind, status;
  final Map<String, dynamic> values, payload;
  factory QualityPendingEntry.fromJson(Map<String, dynamic> json) =>
      QualityPendingEntry(
        source: json['source'] as String,
        identity: json['identity'] as String,
        kind: json['kind'] as String,
        status: json['status'] as String,
        values: Map<String, dynamic>.from(json['values'] as Map),
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );
}

class QualityPendingPage {
  const QualityPendingPage({
    required this.items,
    required this.page,
    required this.total,
    required this.totalPages,
    required this.facets,
    required this.sourceCounts,
  });
  final List<QualityPendingEntry> items;
  final int page, total, totalPages;
  final Map<String, List<MasterFacetBucket>> facets;
  final Map<String, int> sourceCounts;
  factory QualityPendingPage.fromJson(
    Map<String, dynamic> json,
  ) => QualityPendingPage(
    items: [
      for (final item in json['items'] as List)
        QualityPendingEntry.fromJson(Map<String, dynamic>.from(item as Map)),
    ],
    page: (json['page'] as num).toInt(),
    total: (json['total'] as num).toInt(),
    totalPages: (json['totalPages'] as num).toInt(),
    facets: {
      for (final entry in (json['facets'] as Map).entries)
        entry.key as String: [
          for (final value in entry.value as List)
            MasterFacetBucket.fromJson(Map<String, dynamic>.from(value as Map)),
        ],
    },
    sourceCounts: {
      for (final entry in (json['sourceCounts'] as Map).entries)
        entry.key as String: (entry.value as num).toInt(),
    },
  );
}

class QualityPendingQueueRepository {
  const QualityPendingQueueRepository(this.api);
  final ApiClient api;
  Future<QualityPendingPage> query({
    int page = 1,
    int size = 10,
    String keyword = '',
    String? docType,
    String? status,
    Map<String, String?> columns = const {},
    String? sort,
    bool ascending = true,
    Map<String, String> draftStatuses = const {},
  }) async {
    final response = await api.post(
      '/quality/pending-disposals/query',
      body: {
        'page': page,
        'size': size,
        'keyword': keyword,
        'docType': docType,
        'status': status,
        'columns': {
          for (final entry in columns.entries)
            if (entry.key.startsWith('search.') &&
                entry.value?.trim().isNotEmpty == true)
              entry.key.substring(7): entry.value!.trim(),
        },
        'sort': sort,
        'order': ascending ? 'asc' : 'desc',
        'draftStatuses': draftStatuses,
      },
    );
    return QualityPendingPage.fromJson(response);
  }
}

final qualityPendingQueueRepositoryProvider =
    Provider<QualityPendingQueueRepository>(
      (ref) => QualityPendingQueueRepository(ref.watch(apiClientProvider)),
    );

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../models/paged_result.dart';
import '../search/table_column_query.dart';
import 'material_trace_models.dart';

class MaterialTraceRepository {
  MaterialTraceRepository(this.api);
  final ApiClient api;

  static const _base = '/production/reports/where-used';

  Future<PagedResult<MaterialTraceSubject>> subjects({
    required String kind,
    required String keyword,
    bool exact = false,
    int page = 1,
  }) async => PagedResult.fromJson(
    await api.get(
      '$_base/subjects',
      query: {
        'kind': kind,
        'keyword': keyword.trim(),
        'exact': exact,
        'page': page,
        'size': 30,
      },
    ),
    MaterialTraceSubject.fromJson,
  );

  Future<MaterialTraceResult> trace({
    required MaterialTraceSubject subject,
    required String direction,
    String? dateFrom,
    String? dateTo,
    int page = 1,
    Map<String, String?> columns = const {},
    String? sort,
    bool ascending = true,
  }) async => MaterialTraceResult.fromJson(
    await api.get(
      '$_base/trace',
      query: {
        'subjectType': subject.type,
        'subjectId': subject.id,
        'direction': direction,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        'page': page,
        'size': 50,
        ...tableColumnParameters(columns, sort, ascending),
      },
    ),
  );
}

final materialTraceRepositoryProvider = Provider<MaterialTraceRepository>(
  (ref) => MaterialTraceRepository(ref.watch(apiClientProvider)),
);

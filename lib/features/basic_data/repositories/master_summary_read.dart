import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/paged_read_intent.dart';
import '../../../shared/paging/versioned_summary_read.dart';
import '../models/master_facet.dart';
import '../models/master_search_context.dart';

Map<String, dynamic> masterSummaryFilter({
  String? categoryId,
  String? keyword,
  Map<String, String?> filters = const {},
  Map<String, dynamic> flags = const {},
}) {
  final result = <String, dynamic>{}, columns = <String, String>{};
  final nulls = <String>[];
  for (final entry in filters.entries) {
    final value = entry.value;
    if (value == null) {
      continue;
    }
    final search = entry.key.startsWith('search.');
    final field = search ? entry.key.substring(7) : entry.key;
    if (value == kMasterFilterNullValue) {
      nulls.add(field);
    } else if (search) {
      columns[field] = value;
    } else {
      result[field] = value;
    }
  }
  return {
    ...result,
    'categoryId': ?categoryId,
    if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
    if (nulls.isNotEmpty) 'nullFields': nulls,
    if (columns.isNotEmpty) 'columnSearch': columns,
    ...flags,
  };
}

Future<PagedResult<T>> readCompleteMasterSummary<T>(
  ApiClient api, {
  required String path,
  required Map<String, dynamic> filter,
  String? sort,
  String? order,
  required T Function(Map<String, dynamic>) decode,
  required Object? Function(T) idOf,
}) async {
  final parent = PagedReadIntent.currentRead;
  final owner = await api.captureRequestScope(
    isCurrent: () => parent?.call() ?? true,
  );
  final captured = Map<String, dynamic>.unmodifiable(filter);
  return owner.run(() async {
    final result = await readVersionedSummarySnapshot<T>(
      isCurrent: () => owner.isCurrent,
      maxConcurrentPages: 4,
      decode: decode,
      idOf: idOf,
      loadPage: (page, size, revision) => api.post(
        path,
        query: {'readSnapshotRevision': ?revision},
        body: {
          'filter': captured,
          'page': page,
          'size': size,
          if (sort?.isNotEmpty == true) 'sort': sort,
          if (order?.isNotEmpty == true) 'order': order,
        },
      ),
    );
    return result.page;
  });
}

/// Navigation metadata has an authorization proof, not a data-snapshot claim.
Future<Set<String?>> readCompleteMasterSearchCategories({
  required Future<MasterSearchContext> Function(int) loadPage,
  required bool Function() isCurrent,
}) async {
  final ids = <String?>{};
  var page = 1, pages = 1;
  int? count, matches;
  String? scope;
  while (page <= pages) {
    if (!isCurrent() || !(PagedReadIntent.currentActivity?.call() ?? true)) {
      throw const UiWorkCancelled();
    }
    final value = await PagedReadIntent.scopedRead(
      isCurrent,
      () => loadPage(page),
    );
    if (!isCurrent()) {
      throw const UiWorkCancelled();
    }
    if (page > 1 &&
        (value.totalPages != pages || value.readScopeVersion != scope)) {
      throw ApiException('SNAPSHOT_CHANGED', '分类定位范围已变化，请重试');
    }
    count ??= value.totalCategories;
    matches ??= value.totalMatches;
    if (value.page != page ||
        value.totalCategories != count ||
        value.totalMatches != matches ||
        value.totalPages < 0 ||
        value.categoryIds.any((id) => ids.contains(id))) {
      throw ApiException('INCOMPLETE_READ_PROTOCOL', '分类定位未完整读取');
    }
    ids.addAll(value.categoryIds);
    pages = value.totalPages;
    scope = value.readScopeVersion;
    page++;
  }
  if (ids.length != count) {
    throw ApiException('INCOMPLETE_READ_PROTOCOL', '分类定位未完整读取');
  }
  return ids;
}

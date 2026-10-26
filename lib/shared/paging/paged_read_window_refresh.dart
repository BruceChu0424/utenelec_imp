import 'package:collection/collection.dart';

import '../../components/data_display/paged_read_cache.dart';
import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import 'paged_read_window_binding.dart';

/// The original typed responses and one complete, bounded replacement window.
class RefreshedReadWindow<T> {
  RefreshedReadWindow(this.results);
  final Map<int, PagedResult<T>> results;
  Map<int, List<T>> get rows => {
    for (final entry in results.entries) entry.key: entry.value.items,
  };
  PagedResult<T> select(int? visiblePage) =>
      results[visiblePage] ?? results.values.last;
}

/// Fresh reads form a private transaction. No page is published until every
/// retained page has been checked against the same dataset/schema proof.
Future<RefreshedReadWindow<T>> refreshReadWindow<T>(
  ReadWindowPlan plan, {
  required Future<PagedResult<T>> Function(int) fetch,
  required bool Function() isCurrent,
  required void Function() retry,
}) async {
  const equality = DeepCollectionEquality();
  for (var attempt = 0; attempt < 2; attempt++) {
    final results = <int, PagedResult<T>>{};
    PagedResult<T>? first;
    var changed = false;
    int? lastPage;
    final visible = plan.visiblePage;
    final targets = <int>[
      if (visible != null && plan.pages.contains(visible)) visible,
      ...plan.pages.where((page) => page != visible),
    ];
    for (final target in targets) {
      if (!isCurrent()) throw StateError('Paged read owner changed');
      if (lastPage != null && target > lastPage) continue;
      final result = await fetch(target);
      if (!isCurrent()) throw StateError('Paged read owner changed');
      lastPage = result.totalPages;
      if (first != null) {
        if (first.readScopeVersion != result.readScopeVersion) {
          throw ApiException('READ_SCOPE_CHANGED', '读取范围已变化，请刷新后重试');
        }
        Object? revision(PagedResult<T> page) => page is PagedReadCacheRevision
            ? (page as PagedReadCacheRevision).pageCacheRevision
            : page.readScopeVersion;
        if (first.total != result.total ||
            first.totalPages != result.totalPages ||
            !equality.equals(revision(first), revision(result))) {
          changed = true;
          break;
        }
      }
      first ??= result;
      if (result.totalPages == 0) {
        results[result.page] = result;
        break;
      }
      if (result.page <= result.totalPages) results[result.page] = result;
    }
    if (!changed && results.isEmpty) {
      if (!isCurrent()) throw StateError('Paged read owner changed');
      final result = await fetch(
        lastPage != null && lastPage > 0 ? lastPage : 1,
      );
      if (!isCurrent()) throw StateError('Paged read owner changed');
      results[result.page] = result;
    }
    if (!changed) return RefreshedReadWindow(Map.unmodifiable(results));
    retry();
  }
  throw ApiException('READ_WINDOW_CHANGED', '列表数据正在变化，请重试刷新');
}

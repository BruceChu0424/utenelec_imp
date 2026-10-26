import '../../core/network/api_exception.dart';
import '../../core/performance/ui_work_budget.dart';
import '../models/paged_result.dart';

/// One complete, authorized page sequence. Progress consumers may retain a
/// partial view, but a returned snapshot always has every advertised identity.
Future<List<T>> loadCompletePagedSnapshot<T>({
  required Future<PagedResult<T>> Function(int page, int size) loadPage,
  required String Function(T row) idOf,
  required bool Function() isCurrent,
  void Function(List<T> rows, int total, bool hasMore)? onBatch,
  bool requireStableTotal = true,
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget(isCurrent: isCurrent);
  final rows = <String, T>{};
  int? firstTotal;
  var page = 1;
  while (isCurrent()) {
    work.ensureCurrent();
    final result = await loadPage(page, 100);
    if (!isCurrent()) throw const UiWorkCancelled();
    final hasMore = result.page < result.totalPages;
    if (result.page != page ||
        result.total < 0 ||
        (hasMore && result.items.isEmpty)) {
      throw ApiException('INVALID_PAGINATION', '分页信息异常，请刷新后重新读取完整结果');
    }
    firstTotal ??= result.total;
    if (requireStableTotal && firstTotal != result.total) {
      throw ApiException('SNAPSHOT_CHANGED', '数据在读取期间已变化，请刷新后重新读取完整结果');
    }
    for (final row in result.items) {
      final id = idOf(row);
      if (id.isEmpty) throw const FormatException('结果缺少真实记录编号，不能发布完整快照');
      rows[id] = row;
      await work.checkpoint();
    }
    final incomplete = !hasMore && rows.length != result.total;
    if (!isCurrent()) throw const UiWorkCancelled();
    onBatch?.call(
      List<T>.unmodifiable(rows.values),
      result.total,
      hasMore || incomplete,
    );
    if (incomplete) {
      throw ApiException('SNAPSHOT_CHANGED', '数据在读取期间已变化，请刷新后重新读取完整结果');
    }
    if (!hasMore) return List<T>.unmodifiable(rows.values);
    page++;
  }
  throw const UiWorkCancelled();
}

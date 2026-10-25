// 单据/档案列表页共享的分页状态机（审计 §4.1 第 2 批）。
//
// 收敛各 *_list_page 手写的 _page/_pageNum/_loading/_error/_keyword/_sortKey/
// _sortAsc + LatestRequestGuard 竞态防护样板：
//  - load(page)：代际守卫（旧响应不回写）、ApiException 优先展示、兜底文案；
//  - silent（返回即刷新）：已有数据时使用独立 refreshing/refreshError，
//    保留原页、分页和滚动；没有数据时仍正常展示首屏加载/错误；
//  - 关键字/排序的常用归一（trim 空→null、sortKey 空→order null）。
//
// 页面专属筛选（状态/类型/日期等）留在页面本地状态，组装进 fetch 闭包；
// 控制器只拥有分页/加载/错误/排序与竞态语义。宿主在 build 里用
// ListenableBuilder(listenable: controller) 订阅重建，本地筛选仍走 setState。
import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/latest_request_guard.dart';
import '../../shared/models/paged_result.dart';

class PagedListController<T> extends ChangeNotifier {
  PagedResult<T>? page;
  int pageNum = 1;
  bool loading = false;
  String? error;

  /// The current page stays usable while a return/reconnect checks for updates.
  /// Kept separate from [loading] so table pagination does not interpret it as
  /// an explicit page/query change and reset its retained window or scroll.
  bool refreshing = false;

  /// A background update failed; the accepted page is still available.
  /// Hosts show this near their refresh control instead of replacing the rows.
  String? refreshError;
  String keyword = '';

  int _paginationRevision = 0;
  int _readRevision = 0;
  List<int> _retainedPages = const [];

  /// One complete revalidation result. The table replaces this whole window
  /// together, so deletions/page shifts cannot leave rows from older pages.
  Map<int, List<T>> refreshedPages = const {};

  void retainPages(Iterable<int> pages) {
    final sorted = pages.where((page) => page > 0).toSet().toList()..sort();
    _retainedPages = sorted.take(5).toList(growable: false);
  }

  /// Resume scheduling needs to observe failure even though ordinary UI loads
  /// publish their own errors. A superseding query owns its own result.
  Future<void> revalidate(Future<void> pending) async {
    final revision = _readRevision;
    await pending;
    if (_disposed || revision != _readRevision) return;
    final failure = refreshError ?? error;
    if (failure != null) throw StateError(failure);
  }

  /// Starts a new table window for foreground queries or an access boundary.
  /// A background response replaces its page in place, so the response object
  /// itself must not be used as the table's pagination revision.
  int get paginationRevision => _paginationRevision;

  /// 列排序态：sortKey=null 不排序（走后端默认，如 billDate DESC）。
  String? sortKey;
  bool sortAsc = true;

  final LatestRequestGuard _requests = LatestRequestGuard();
  bool _disposed = false;

  /// 首屏加载（无数据时的转圈）与翻页/筛选加载（表格 loadingMore）区分。
  bool get isLoadingFirst => loading && page == null;
  bool get isLoadingMore => loading && page != null;
  int get currentPage => page?.page ?? 1;
  int get totalPages => page?.totalPages ?? 1;
  int get total => page?.total ?? 0;

  /// trim 后为空返回 null（后端空串/全空白等价不过滤）。
  String? get normalizedKeyword {
    final trimmed = keyword.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 未选排序列时不传 order；选了按升/降序映射后端参数。
  String? get sortOrder => sortKey == null ? null : (sortAsc ? 'asc' : 'desc');

  /// A different document or reader cannot inherit either accepted data or an
  /// in-flight response. Unlike load, reset also works in an unselected view.
  void reset({bool notify = true}) {
    invalidateReadOwner(notify: false);
    keyword = '';
    sortKey = null;
    sortAsc = true;
    if (notify) _notify();
  }

  /// Retire private data and pending callbacks without changing the query that
  /// the user is typing or the page's existing search-reset lifecycle.
  void invalidateReadOwner({bool notify = true}) {
    _readRevision = _requests.begin();
    _paginationRevision++;
    _retainedPages = const [];
    refreshedPages = const {};
    page = null;
    pageNum = 1;
    loading = false;
    error = null;
    refreshing = false;
    refreshError = null;
    if (notify) _notify();
  }

  /// 表头排序回调：column=null 取消排序回后端默认。只更新状态不重查，
  /// 宿主随后自行 load(1)。
  void onSortChange(String? column, bool ascending) {
    sortKey = column;
    sortAsc = ascending;
  }

  /// 拉一页。[fetch] 由宿主用当前筛选组装（异步执行，读取的是调用时快照）；
  /// [silent] 见类注释。dispose 后静默忽略（页面已销毁）。
  Future<void> load(
    int page, {
    bool silent = false,
    required Future<PagedResult<T>> Function() fetch,
    Future<PagedResult<T>> Function(int page)? fetchPage,
    bool Function()? isCurrent,
  }) async {
    if (_disposed || isCurrent?.call() == false) return;
    final generation = _requests.begin();
    _readRevision = generation;
    bool current() =>
        !_disposed &&
        _requests.isCurrent(generation) &&
        (isCurrent?.call() ?? true);
    final background = silent && this.page != null;
    final retained = _retainedPages.isEmpty ? [page] : List.of(_retainedPages);
    if (!background) {
      _paginationRevision++;
      refreshedPages = const {};
    }
    pageNum = page;
    loading = !background;
    refreshing = background;
    error = null;
    refreshError = null;
    _notify();
    try {
      PagedResult<T> r;
      final window = <int, List<T>>{};
      if (background && fetchPage != null) {
        final results = <int, PagedResult<T>>{};
        int? lastPage;
        for (final target in retained) {
          if (!current()) return;
          if (lastPage != null && target > lastPage) break;
          final result = await fetchPage(target);
          if (!current()) return;
          lastPage = result.totalPages;
          if (result.totalPages == 0) {
            results[1] = PagedResult<T>(
              items: const [],
              page: 1,
              size: result.size,
              total: result.total,
              totalPages: 0,
              totals: result.totals,
              facets: result.facets,
              facetNullCounts: result.facetNullCounts,
            );
            window[1] = const [];
            break;
          }
          if (result.page <= result.totalPages) {
            results[result.page] = result;
            window[result.page] = result.items;
          }
        }
        // The retained window can lie entirely beyond the new last page after
        // deletions. Fetch that valid page instead of preserving invalid rows.
        if (results.isEmpty) {
          if (!current()) return;
          final target = lastPage != null && lastPage > 0 ? lastPage : 1;
          final result = await fetchPage(target);
          if (!current()) return;
          results[result.page] = result;
          window[result.page] = result.items;
        }
        r = results[page] ?? results.values.last;
        // A later response may report a smaller dataset than an earlier one.
        // Invalid page slots must disappear in the same atomic publication.
        window.removeWhere((page, _) => page > r.totalPages && page != 1);
      } else {
        r = await fetch();
        if (background) window[r.page] = r.items;
      }
      if (!current()) return;
      this.page = r;
      if (background) {
        pageNum = r.page;
        refreshedPages = Map.unmodifiable({
          for (final entry in window.entries)
            entry.key: List<T>.unmodifiable(entry.value),
        });
      }
      loading = false;
      error = null;
      refreshing = false;
      refreshError = null;
      _notify();
    } on ApiException catch (e) {
      if (!current()) return;
      // These are the same confirmed access failures emitted by
      // ApiExceptionFactory. A denied list must not leave private rows visible.
      final accessDenied =
          e.httpStatus == 401 ||
          e.httpStatus == 403 ||
          e.code == 'UNAUTHORIZED' ||
          e.code == 'FORBIDDEN';
      if (accessDenied) {
        this.page = null;
        refreshedPages = const {};
        _retainedPages = const [];
        _paginationRevision++;
      }
      _fail(e.message, background: background && !accessDenied);
    } catch (_) {
      if (!current()) return;
      _fail('加载列表失败', background: background); // TODO(l10n): 补 arb
    }
  }

  void _fail(String message, {required bool background}) {
    loading = false;
    refreshing = false;
    if (background) {
      refreshError = message;
    } else {
      error = message;
    }
    _notify();
  }

  @override
  void dispose() {
    _readRevision = _requests.begin();
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

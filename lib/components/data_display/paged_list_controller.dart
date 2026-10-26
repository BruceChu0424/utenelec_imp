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
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/latest_request_guard.dart';
import '../../shared/models/paged_result.dart';
import '../../shared/paging/scoped_paged_read.dart' show pagedReadAccessDenied;
import '../../shared/paging/paged_read_intent.dart';
import '../../shared/paging/paged_read_window_binding.dart';
import '../../shared/paging/paged_read_window_refresh.dart';
import 'paged_read_cache.dart';

class PagedListController<T> extends ChangeNotifier {
  final _cache = PagedReadCache<T>();
  bool Function()? _cacheOwnerCheck;
  int? _acceptedForegroundPage;
  PagedReadWindowSession<T>? _window;
  Future<RefreshedReadWindow<T>>? _windowRefresh;
  int _windowEpoch = 0;
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
    _cache.clear();
    _window?.invalidate();
    _window = null;
    _windowRefresh = null;
    ++_windowEpoch;
    _cacheOwnerCheck = null;
    _acceptedForegroundPage = null;
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
    // Opt in only with a complete immutable business-query snapshot. Keyword
    // and sort are included here; page number is deliberately excluded. The
    // owner predicate must remain valid across same-query page navigation.
    Object? queryScope,
    // Only an explicit pagination action may reuse a cached page. Ordinary
    // reloads (including writes that relocate to another page) stay fresh.
    bool useCachedPage = false,
    bool Function()? canPrefetch,
  }) async {
    final bufferSeed = PagedReadIntent.isBufferSeed;
    final readingPage = PagedReadIntent.readingPage;
    if (_disposed || isCurrent?.call() == false) return;
    final cacheEnabled = queryScope != null && fetchPage != null;
    var changedCacheScope = false;
    if (_cacheOwnerCheck?.call() == false) {
      _cache.clear();
      _window?.invalidate();
      _window = null;
      _windowRefresh = null;
      ++_windowEpoch;
    }
    if (cacheEnabled) {
      changedCacheScope = _cache.bind([
        queryScope,
        normalizedKeyword,
        sortKey,
        sortAsc,
      ]);
      if (changedCacheScope) {
        _acceptedForegroundPage = null;
        _window?.invalidate();
        _window = null;
        _windowRefresh = null;
        ++_windowEpoch;
      }
    } else {
      _cache.clear();
    }
    if (!bufferSeed || changedCacheScope || _cacheOwnerCheck == null) {
      _cacheOwnerCheck = isCurrent;
    }
    final session = cacheEnabled
        ? (_window ??= PagedReadWindowSession<T>(
            isCurrent: () => !_disposed && (_cacheOwnerCheck?.call() ?? true),
          ))
        : null;
    final fresh =
        !bufferSeed &&
        (silent ||
            !useCachedPage ||
            (readingPage ?? _acceptedForegroundPage) == page);
    final explicit = PagedReadIntent.replaceWindow;
    final plan = fresh && !silent && !explicit ? session?.capture() : null;
    final preserveWindow = plan != null && plan.visiblePage == page;
    final previousRefresh = !fresh && !explicit ? _windowRefresh : null;
    if (fresh || (explicit && _windowRefresh != null)) {
      ++_windowEpoch;
      _windowRefresh = null;
    }
    final windowEpoch = _windowEpoch;
    bool windowCurrent() =>
        !_disposed &&
        windowEpoch == _windowEpoch &&
        (isCurrent?.call() ?? true);
    if (preserveWindow && this.page != null) {
      session!.bindResult(this.page!, pending: true);
    }
    // Ordinary loads mean refresh, including writes that relocate to another
    // page. A background refresh also retires all speculative reads.
    if (!bufferSeed &&
        (silent ||
            !useCachedPage ||
            (readingPage ?? _acceptedForegroundPage) == page)) {
      _cache.clear();
    }
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
            results[1] = result.page == 1 && result.items.isEmpty
                ? result
                : PagedResult<T>(
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
      } else if (preserveWindow) {
        final transaction = refreshReadWindow<T>(
          plan,
          fetch: (target) => _cache.read(target, () => fetchPage!(target)),
          isCurrent: windowCurrent,
          retry: _cache.clear,
        );
        _windowRefresh = transaction;
        final refreshed = await transaction;
        if (identical(_windowRefresh, transaction)) _windowRefresh = null;
        r = refreshed.select(plan.visiblePage);
        window.addAll(refreshed.rows);
      } else {
        final previous = previousRefresh == null ? null : await previousRefresh;
        r = cacheEnabled && !background
            ? await _cache.read(page, fetch)
            : await fetch();
        if (previous != null) {
          window.addAll(previous.rows);
          window[r.page] = r.items;
          window.removeWhere((key, _) => key > r.totalPages && key != 1);
          if (window.length > 5) {
            final keys = window.keys.toList()
              ..sort(
                (a, b) => (a - r.page).abs().compareTo((b - r.page).abs()),
              );
            final keep = keys.take(5).toSet();
            window.removeWhere((key, _) => !keep.contains(key));
          }
        }
        if (background) window[r.page] = r.items;
      }
      if (!current()) return;
      if (session != null) {
        session.bindResult(r, replacementPages: window.isEmpty ? null : window);
      }
      this.page = r;
      if (!bufferSeed && !background) {
        _acceptedForegroundPage = r.page;
        PagedReadIntent.accepted(r.page);
      }
      if (cacheEnabled) _cache.accept(r);
      if (preserveWindow || previousRefresh != null) pageNum = r.page;
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
      if (cacheEnabled && !bufferSeed) {
        unawaited(
          _cache.prefetchAdjacent(
            r,
            fetch: fetchPage,
            isCurrent: () =>
                !_disposed &&
                identical(_cacheOwnerCheck, isCurrent) &&
                (isCurrent?.call() ?? true) &&
                (canPrefetch?.call() ?? true),
            onError: (error) {
              if (error is ApiException && _accessDenied(error)) {
                invalidateReadOwner(notify: false);
                _fail(error.message, background: false);
              }
            },
          ),
        );
      }
    } on ApiException catch (e) {
      if (!current()) return;
      // These are the same confirmed access failures emitted by
      // ApiExceptionFactory. A denied list must not leave private rows visible.
      final accessDenied = _accessDenied(e);
      if (preserveWindow || previousRefresh != null) _cache.clear();
      session?.fail(accessDenied: accessDenied);
      _windowRefresh = null;
      if (accessDenied) {
        _cache.clear();
        this.page = null;
        refreshedPages = const {};
        _retainedPages = const [];
        _paginationRevision++;
      }
      _fail(e.message, background: background && !accessDenied);
    } catch (_) {
      if (!current()) return;
      if (preserveWindow || previousRefresh != null) _cache.clear();
      session?.fail();
      _windowRefresh = null;
      _fail('加载列表失败', background: background); // TODO(l10n): 补 arb
    }
  }

  static bool _accessDenied(ApiException error) => pagedReadAccessDenied(error);

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
    _cache.clear();
    _window?.invalidate();
    _window = null;
    _windowRefresh = null;
    ++_windowEpoch;
    _cacheOwnerCheck = null;
    _readRevision = _requests.begin();
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

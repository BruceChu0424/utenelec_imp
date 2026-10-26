import 'dart:async';

import '../../components/data_display/paged_read_cache.dart';
import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import 'paged_read_intent.dart';
import 'paged_read_window_binding.dart';
import 'paged_read_window_refresh.dart';

/// Confirmed read rejection retires accepted private rows and cached reads.
/// Network/parse failures keep the existing snapshot available for retry.
bool pagedReadAccessDenied(Object error) =>
    error is ApiException &&
    (error.httpStatus == 401 ||
        error.httpStatus == 403 ||
        const {
          'UNAUTHORIZED',
          'FORBIDDEN',
          'READ_SCOPE_CHANGED',
        }.contains(error.code));

/// Keeps a complete typed response together with the real rows used for cache
/// budgeting. Cached hits restore the same metadata and authority as its rows.
class PagedReadSnapshot<RowT, SnapshotT> extends PagedResult<RowT>
    implements PagedReadCacheRevision {
  PagedReadSnapshot({
    required PagedResult<RowT> page,
    required this.snapshot,
    Object? revision,
  }) : pageCacheRevision = revision ?? page.readScopeVersion,
       super(
         items: page.items,
         page: page.page,
         size: page.size,
         total: page.total,
         totalPages: page.totalPages,
         totals: page.totals,
         facets: page.facets,
         facetNullCounts: page.facetNullCounts,
         readScopeVersion: page.readScopeVersion,
       );

  final SnapshotT snapshot;
  @override
  final Object? pageCacheRevision;
}

/// Owns data reads for a manual pager without owning its UI loading/selection.
/// [read] receives a complete immutable query and monotonic reader scope.
/// The caller separately guards its latest UI request; [isCurrent] must remain
/// valid across same-query page navigation so a foreground read can adopt an
/// in-flight speculative page. No business commands are retried here.
class ScopedPagedRead<T> {
  ScopedPagedRead({int maximumPages = 12, int maximumRows = 5000})
    : _cache = PagedReadCache<T>(
        maximumPages: maximumPages,
        maximumRows: maximumRows,
      );

  final PagedReadCache<T> _cache;
  bool Function()? _ownerCurrent;
  int _generation = 0;
  int _foregroundRead = 0;
  int? _acceptedForegroundPage;
  _ForegroundPagedRead<T>? _foreground;
  bool _disposed = false;
  PagedReadWindowSession<T>? _window;
  PagedResult<T>? _latestResult;
  _WindowRefresh<T>? _windowRefresh;

  void invalidate() {
    _generation++;
    _foregroundRead++;
    _acceptedForegroundPage = null;
    _foreground = null;
    _ownerCurrent = null;
    _cache.clear();
    _window?.invalidate();
    _window = null;
    _latestResult = null;
    _windowRefresh = null;
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }

  /// Prepare a visible page's successor from the last accepted frozen source.
  /// This publishes no UI data and never changes the foreground reading page.
  Future<void> prepareNext(int visiblePage, {bool Function()? canPrepare}) {
    if (PagedReadIntent.isBufferSeed) return Future.value();
    final source = _foreground;
    if (source == null ||
        !source.isCurrent() ||
        visiblePage < 1 ||
        visiblePage >= source.page.totalPages) {
      return Future.value();
    }
    return _cache.prefetchPages(
      source.page,
      [visiblePage + 1],
      fetch: source.fetch,
      isCurrent: () =>
          source.isCurrent() &&
          (canPrepare?.call() ?? source.canPrefetch?.call() ?? true),
      onError: source.onError,
    );
  }

  Future<PagedResult<T>> read(
    int page, {
    required Object scope,
    required Future<PagedResult<T>> Function(int) fetchPage,
    required bool Function() isCurrent,
    bool useCache = false,
    bool Function()? canPrefetch,
    void Function(Object)? onPrefetchError,
    bool revalidateWindow = true,
  }) async {
    final bufferSeed = PagedReadIntent.isBufferSeed;
    final readingPage = PagedReadIntent.readingPage;
    if (_disposed || !isCurrent()) throw StateError('Paged read owner changed');
    if (_ownerCurrent?.call() == false) invalidate();
    if (_cache.bind(scope)) {
      _generation++;
      _acceptedForegroundPage = null;
      _window?.invalidate();
      _window = null;
      _latestResult = null;
      _windowRefresh = null;
    }
    _ownerCurrent = isCurrent;
    final session = _window ??= PagedReadWindowSession<T>(
      isCurrent: () => !_disposed && (_ownerCurrent?.call() ?? false),
    );
    final fresh =
        !bufferSeed &&
        (!useCache || (readingPage ?? _acceptedForegroundPage) == page);
    final explicit = PagedReadIntent.replaceWindow;
    final plan = fresh && revalidateWindow && !explicit
        ? session.capture()
        : null;
    final preserveWindow = plan != null && plan.visiblePage == page;
    final previousRefresh = !fresh && !explicit ? _windowRefresh : null;
    if (fresh || (explicit && _windowRefresh != null)) {
      _cache.clear();
      _generation++;
      _acceptedForegroundPage = null;
      _windowRefresh = null;
    }
    final foregroundRead = bufferSeed ? _foregroundRead : ++_foregroundRead;
    final generation = _generation;
    bool current() => !_disposed && generation == _generation && isCurrent();
    Future<PagedResult<T>> fetch(int target) async {
      if (!current()) throw StateError('Paged read owner changed');
      final result = await fetchPage(target);
      if (!current()) throw StateError('Paged read owner changed');
      return result;
    }

    late final PagedResult<T> result;
    Map<int, List<T>>? replacement;
    try {
      if (preserveWindow) {
        if (_latestResult != null) {
          session.bindResult(_latestResult!, pending: true);
        }
        final transaction = _WindowRefresh<T>();
        _windowRefresh = transaction;
        transaction.result = refreshReadWindow<T>(
          plan,
          fetch: (target) => _cache.read(target, () => fetch(target)),
          isCurrent: current,
          retry: _cache.clear,
        );
        final window = await transaction.result;
        if (identical(_windowRefresh, transaction)) _windowRefresh = null;
        result = window.select(plan.visiblePage);
        replacement = window.rows;
      } else {
        final previous = previousRefresh == null
            ? null
            : await previousRefresh.result;
        result = await _cache.read(page, () => fetch(page));
        if (previous != null) {
          final combined = <int, List<T>>{
            ...previous.rows,
            result.page: result.items,
          };
          combined.removeWhere((key, _) => key > result.totalPages && key != 1);
          if (combined.length > 5) {
            final keys = combined.keys.toList()
              ..sort(
                (a, b) =>
                    (a - result.page).abs().compareTo((b - result.page).abs()),
              );
            final keep = keys.take(5).toSet();
            combined.removeWhere((key, _) => !keep.contains(key));
          }
          replacement = combined;
        }
      }
      if (current()) {
        session.bindResult(result, replacementPages: replacement);
        _latestResult = result;
      }
    } catch (error) {
      if (current()) {
        if (identical(_windowRefresh, previousRefresh) || preserveWindow) {
          _windowRefresh = null;
        }
        if (preserveWindow || previousRefresh != null) _cache.clear();
        session.fail(accessDenied: pagedReadAccessDenied(error));
        if (pagedReadAccessDenied(error)) invalidate();
      }
      rethrow;
    }
    if (!current()) throw StateError('Paged read owner changed');
    if (!bufferSeed && foregroundRead == _foregroundRead) {
      _acceptedForegroundPage = result.page;
      PagedReadIntent.accepted(result.page);
      void onError(Object error) {
        if (pagedReadAccessDenied(error)) invalidate();
        onPrefetchError?.call(error);
      }

      _foreground = _ForegroundPagedRead<T>(
        result,
        fetch,
        current,
        canPrefetch,
        onError,
      );
      unawaited(
        _cache.prefetchAdjacent(
          result,
          fetch: fetch,
          isCurrent: () => current() && (canPrefetch?.call() ?? true),
          onError: onError,
        ),
      );
    }
    return result;
  }
}

class _ForegroundPagedRead<T> {
  _ForegroundPagedRead(
    this.page,
    this.fetch,
    this.isCurrent,
    this.canPrefetch,
    this.onError,
  );
  final PagedResult<T> page;
  final Future<PagedResult<T>> Function(int) fetch;
  final bool Function() isCurrent;
  final bool Function()? canPrefetch;
  final void Function(Object) onError;
}

class _WindowRefresh<T> {
  late final Future<RefreshedReadWindow<T>> result;
}

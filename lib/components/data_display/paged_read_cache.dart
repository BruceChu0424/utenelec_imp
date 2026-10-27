import 'dart:async';

import 'package:collection/collection.dart';

import '../../shared/models/paged_result.dart';
import 'paged_read_ahead_policy.dart';

/// Complete response adapters may retire cached pages when their schema or
/// authorization/statistics proof changes without changing the row count.
abstract interface class PagedReadCacheRevision {
  Object? get pageCacheRevision;
}

/// A page-local read cache. It retains data, never widgets, selection or edits.
/// Bind an immutable query/reader snapshot before reading; a changed scope or
/// [clear] retires both accepted pages and in-flight cache publications.
class PagedReadCache<T> {
  PagedReadCache({this.maximumPages = 12, this.maximumRows = 5000})
    : assert(maximumPages > 0),
      assert(maximumRows > 0);

  final int maximumPages;
  final int maximumRows;
  static const _equality = DeepCollectionEquality();
  final _pages = <int, PagedResult<T>>{};
  final _pending = <int, Future<PagedResult<T>>>{};
  Object? _scope;
  bool _bound = false;
  int _generation = 0;
  int _rows = 0;
  int? _total;
  Object? _revision;
  bool _hasRevision = false;
  bool _prefetchRunning = false;
  _PagedPrefetchJob<T>? _queuedPrefetch;

  int get length => _pages.length;
  int get retainedRows => _rows;

  bool bind(Object scope) {
    if (_bound && _equality.equals(_scope, scope)) return false;
    clear();
    _bound = true;
    _scope = scope;
    return true;
  }

  void clear() {
    _generation++;
    _queuedPrefetch?.complete();
    _queuedPrefetch = null;
    _pages.clear();
    _pending.clear();
    _rows = 0;
    _total = null;
    _revision = null;
    _hasRevision = false;
  }

  PagedResult<T>? peek(int page) {
    final result = _pages.remove(page);
    if (result != null) _pages[page] = result;
    return result;
  }

  void accept(PagedResult<T> result) {
    // A changed count can shift every page boundary. Do not mix the previous
    // dataset's cached pages with a response that already observes the change.
    final revision = result is PagedReadCacheRevision
        ? (result as PagedReadCacheRevision).pageCacheRevision
        : result.readScopeVersion;
    if ((_total != null && _total != result.total) ||
        (_hasRevision && !_equality.equals(_revision, revision))) {
      clear();
    }
    _total = result.total;
    _revision = revision;
    _hasRevision = true;
    final previous = _pages.remove(result.page);
    _rows -= previous?.items.length ?? 0;
    if (result.items.length > maximumRows) return;
    _pages[result.page] = result;
    _rows += result.items.length;
    while (_pages.length > maximumPages || _rows > maximumRows) {
      _rows -= _pages.remove(_pages.keys.first)!.items.length;
    }
  }

  /// A foreground read can adopt an already running adjacent-page read. A late
  /// response remains usable by its original waiter, but cannot enter a newer
  /// query's cache; callers still guard their own UI publication.
  Future<PagedResult<T>> read(
    int page,
    Future<PagedResult<T>> Function() fetch,
  ) {
    final cached = peek(page);
    if (cached != null) return Future.value(cached);
    final pending = _pending[page];
    if (pending != null) return pending;
    final generation = _generation;
    late final Future<PagedResult<T>> request;
    request = Future<PagedResult<T>>.sync(fetch)
        .then((result) {
          if (generation == _generation) accept(result);
          return result;
        })
        .whenComplete(() {
          if (generation == _generation && identical(_pending[page], request)) {
            _pending.remove(page);
          }
        });
    _pending[page] = request;
    return request;
  }

  /// One speculative transport per cache, including across rapid navigation or
  /// scope retirement. Only the latest waiting center survives. Foreground
  /// [read] remains independent and may adopt the same in-flight Future.
  Future<void> prefetchAdjacent(
    PagedResult<T> page, {
    required Future<PagedResult<T>> Function(int) fetch,
    required bool Function() isCurrent,
    void Function(Object)? onError,
  }) => prefetchPages(
    page,
    PagedReadAheadPolicy.around(page.page),
    fetch: fetch,
    isCurrent: isCurrent,
    onError: onError,
  );

  /// A bounded target selection shares the same physical speculative worker.
  /// Read hosts share this queue for their two-page reading buffer.
  Future<void> prefetchPages(
    PagedResult<T> page,
    Iterable<int> pages, {
    required Future<PagedResult<T>> Function(int) fetch,
    required bool Function() isCurrent,
    void Function(Object)? onError,
  }) {
    final job = _PagedPrefetchJob<T>(
      page,
      _generation,
      fetch,
      isCurrent,
      onError,
      pages.take(PagedReadAheadPolicy.maximumTargets).toList(growable: false),
    );
    _queuedPrefetch?.complete();
    _queuedPrefetch = job;
    if (!_prefetchRunning) {
      _prefetchRunning = true;
      unawaited(_drainPrefetch());
    }
    return job.done.future;
  }

  Future<void> _drainPrefetch() async {
    try {
      while (_queuedPrefetch != null) {
        final job = _queuedPrefetch!;
        _queuedPrefetch = null;
        try {
          var yielded = false;
          for (final target in job.pages) {
            if (_queuedPrefetch != null ||
                job.generation != _generation ||
                !job.isCurrent()) {
              break;
            }
            if (target < 1 ||
                target > job.page.totalPages ||
                _pages.containsKey(target)) {
              continue;
            }
            if (!yielded) {
              // Let accepted rows paint before transport/decoding. A fully
              // cached window needs no timer or follow-up layout work.
              await Future<void>.delayed(Duration.zero);
              yielded = true;
              if (_queuedPrefetch != null ||
                  job.generation != _generation ||
                  !job.isCurrent()) {
                break;
              }
              if (_pages.containsKey(target)) continue;
            }
            try {
              await read(target, () => job.fetch(target));
            } catch (error) {
              if (job.generation == _generation && job.isCurrent()) {
                job.onError?.call(error);
              }
              // Ordinary navigation retries failures. Never continue a
              // speculative chain after its source has failed.
              break;
            }
          }
        } finally {
          job.complete();
        }
      }
    } finally {
      _prefetchRunning = false;
    }
  }
}

class _PagedPrefetchJob<T> {
  _PagedPrefetchJob(
    this.page,
    this.generation,
    this.fetch,
    this.isCurrent,
    this.onError,
    this.pages,
  );

  final PagedResult<T> page;
  final int generation;
  final Future<PagedResult<T>> Function(int) fetch;
  final bool Function() isCurrent;
  final void Function(Object)? onError;
  final List<int> pages;
  final done = Completer<void>();

  void complete() {
    if (!done.isCompleted) done.complete();
  }
}

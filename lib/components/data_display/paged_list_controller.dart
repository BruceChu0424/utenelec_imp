import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/latest_request_guard.dart';
import '../../shared/models/paged_result.dart';
import '../../shared/paging/scoped_paged_read.dart';
import '../../shared/paging/read_view_activity.dart';

/// One continuous authorized list. The view owns its search/selection; this
/// controller owns complete reads and explicit refresh/error publication.
class PagedListController<T> extends ChangeNotifier {
  PagedListController({Object? Function(T row)? idOf})
    : _reader = ScopedPagedRead<T>(idOf: idOf);
  final ScopedPagedRead<T> _reader;
  final LatestRequestGuard _requests = LatestRequestGuard();
  final Object _unscopedQuery = Object();
  FutureOr<void> Function()? _onViewResume;
  late final _activity = ReadViewActivity(
    onResume: () => _onViewResume?.call(),
  );

  /// Call in build/didChangeDependencies, before observing this table's value.
  void bindView(BuildContext context, {FutureOr<void> Function()? onResume}) {
    if (onResume != null) _onViewResume = onResume;
    _activity.bindView(context);
  }

  bool Function()? _ownerCurrent;
  int _owner = 0;
  bool _disposed = false;
  int _paginationRevision = 0;
  int _readRevision = 0;
  PagedResult<T>? page;
  int pageNum = 1;
  bool loading = false;
  String? error;
  bool refreshing = false;
  String? refreshError;
  String keyword = '';
  String? sortKey;
  bool sortAsc = true;

  /// Compatibility for complete-result consumers during a silent refresh.
  /// The only slot is the same full row list, never a remote page window.
  Map<int, List<T>> refreshedPages = const {};
  int get paginationRevision => _paginationRevision;
  bool get isLoadingFirst => loading && page == null;
  bool get isLoadingMore => loading && page != null;
  int get currentPage => 1;
  int get totalPages => page?.totalPages ?? 1;
  int get total => page?.total ?? 0;
  String? get normalizedKeyword =>
      keyword.trim().isEmpty ? null : keyword.trim();
  String? get sortOrder => sortKey == null ? null : (sortAsc ? 'asc' : 'desc');

  Future<void> revalidate(Future<void> pending) async {
    final revision = _readRevision;
    await pending;
    if (_disposed || revision != _readRevision) return;
    final failure = refreshError ?? error;
    if (failure != null) throw StateError(failure);
  }

  void reset({bool notify = true}) {
    invalidateReadOwner(notify: false);
    keyword = '';
    sortKey = null;
    sortAsc = true;
    if (notify) _notify();
  }

  void invalidateReadOwner({bool notify = true}) {
    _owner++;
    _reader.invalidate();
    _ownerCurrent = null;
    _readRevision = _requests.begin();
    _paginationRevision++;
    refreshedPages = const {};
    page = null;
    pageNum = 1;
    loading = false;
    error = null;
    refreshing = false;
    refreshError = null;
    if (notify) _notify();
  }

  void onSortChange(String? column, bool ascending) {
    sortKey = column;
    sortAsc = ascending;
  }

  Future<void> load(
    int requestedPage, {
    bool silent = false,
    required Future<PagedResult<T>> Function() fetch,
    Future<PagedResult<T>> Function(int page)? fetchPage,
    Future<PagedResult<T>> Function(int page, int size)? fetchPageSized,
    // A nested complete reader (reports) returns the whole result itself and
    // publishes its own batches through the shared progressive slot.
    Future<PagedResult<T>> Function()? fetchComplete,
    bool Function()? isCurrent,
    // Stable accepted-data ownership, excluding a single request generation.
    // Existing callers retain their original ownership when this is omitted.
    bool Function()? ownerIsCurrent,
    Object? queryScope,
    bool useCachedPage = false,
    bool Function()? canPrefetch,
  }) async {
    if (!_disposed &&
        ownerIsCurrent != null &&
        _ownerCurrent?.call() == false) {
      invalidateReadOwner();
    }
    if (_disposed ||
        isCurrent?.call() == false ||
        ownerIsCurrent?.call() == false) {
      return;
    }
    if (_ownerCurrent?.call() == false) invalidateReadOwner(notify: false);
    _ownerCurrent = ownerIsCurrent ?? isCurrent;
    final owner = _owner;
    final generation = _requests.begin();
    _readRevision = generation;
    bool current() =>
        !_disposed &&
        owner == _owner &&
        _requests.isCurrent(generation) &&
        (isCurrent?.call() ?? true) &&
        (ownerIsCurrent?.call() ?? true);
    bool owned() =>
        !_disposed &&
        owner == _owner &&
        (isCurrent?.call() ?? true) &&
        (ownerIsCurrent?.call() ?? true);
    bool dataOwned() =>
        !_disposed && owner == _owner && (ownerIsCurrent?.call() ?? true);
    void retireLostOwner() {
      if (ownerIsCurrent != null &&
          !_disposed &&
          owner == _owner &&
          _requests.isCurrent(generation) &&
          !ownerIsCurrent()) {
        invalidateReadOwner();
      }
    }

    final background = silent && page != null;
    if (!background) {
      _paginationRevision++;
      refreshedPages = const {};
    }
    pageNum = 1;
    loading = !background;
    refreshing = background;
    error = null;
    refreshError = null;
    _notify();
    // A fresh read shows each validated batch while it continues (rows only;
    // loading stays true). A silent refresh keeps the accepted rows instead.
    // Any failure or retirement takes the growing rows down as a whole.
    var showedProgressive = false;
    void retireProgressive() {
      if (showedProgressive) page = null;
    }

    try {
      final result = await _activity.runRead(
        owned,
        () => _reader.read(
          1,
          scope: [
            queryScope ?? _unscopedQuery,
            normalizedKeyword,
            sortKey,
            sortAsc,
          ],
          fetchPage: (batch) {
            if (fetchPage != null) return fetchPage(batch);
            if (batch == 1) return fetch();
            throw ApiException('INCOMPLETE_LIST_LOADER', '该列表尚未提供完整读取，请刷新后重试');
          },
          isCurrent: owned,
          isOwnerCurrent: ownerIsCurrent == null ? null : dataOwned,
          fetchPageSized: fetchPageSized,
          fetchComplete: fetchComplete,
          onProgressiveBatch: background
              ? null
              : (partial) {
                  if (!current()) return;
                  showedProgressive = true;
                  page = partial;
                  _notify();
                },
          useCache:
              useCachedPage &&
              queryScope != null &&
              (fetchPage != null ||
                  fetchPageSized != null ||
                  fetchComplete != null),
        ),
      );
      retireLostOwner();
      if (!current()) return;
      page = result;
      pageNum = 1;
      if (background) refreshedPages = Map.unmodifiable({1: result.items});
      loading = false;
      refreshing = false;
      error = null;
      refreshError = null;
      _notify();
    } on ApiException catch (failure) {
      retireLostOwner();
      if (!current()) return;
      retireProgressive();
      if (isRetiredViewRead(failure)) {
        loading = false;
        refreshing = false;
        _notify();
        return;
      }
      final denied = pagedReadAccessDenied(failure);
      if (denied) invalidateReadOwner(notify: false);
      _fail(failure.message, background: background && !denied);
    } catch (failure) {
      retireLostOwner();
      if (!current()) return;
      retireProgressive();
      if (isRetiredViewRead(failure)) {
        loading = false;
        refreshing = false;
        _notify();
        return;
      }
      _fail('加载列表失败', background: background);
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
    _disposed = true;
    _owner++;
    _readRevision = _requests.begin();
    _reader.dispose();
    _activity.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

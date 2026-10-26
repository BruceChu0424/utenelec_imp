import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import '../providers/export_context_epoch_provider.dart';
import 'scoped_paged_read.dart';
import 'paged_query_identity.dart';

/// Lifecycle adapter for manual pagers. The shared reader owns cache and
/// transport scheduling; the view continues to own loading, selection and its
/// latest UI request. Query maps/lists are snapshotted before asynchronous work.
mixin ScopedPagedReadViewMixin<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  final _scopedPageReads = <(Type, Object), _ScopedReadLifecycle>{};
  ProviderSubscription<int>? _scopedOwnerSubscription;
  int _scopedOwner = 0;
  bool _scopedDisposed = false;
  ApiException? _scopedReadCause;

  /// Synchronous cause for the retirement hook. Keep the server's rejection
  /// visible even when that hook invalidates the caller's UI request token.
  ApiException? get scopedPagedReadRejection => _scopedReadCause;

  void _scopedOwnerChanged([Object? error]) {
    _scopedReadCause = error is ApiException ? error : null;
    try {
      scopedPagedReadOwnerChanged();
    } finally {
      _scopedReadCause = null;
    }
  }

  /// Existing native/inline owners may keep their own accepted-row retirement.
  /// Views without one override this to clear private rows and pending UI work.
  void scopedPagedReadOwnerChanged() {}

  @override
  void initState() {
    super.initState();
    _scopedOwnerSubscription = ref.listenManual(exportContextEpochProvider, (
      previous,
      next,
    ) {
      if (previous != next && mounted) {
        invalidateScopedPageReads();
        _scopedOwnerChanged();
      }
    });
  }

  /// Explicit refresh/write handlers normally call their fresh load. This is
  /// also available when retiring a query before a debounced load is started.
  void invalidateScopedPageReads() {
    _scopedOwner++;
    for (final entry in _scopedPageReads.values) {
      entry.invalidate();
    }
  }

  bool get _scopedViewActive =>
      mounted &&
      !_scopedDisposed &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  /// Prepare a successor through an existing reader without accepting a page
  /// or rebuilding the view. Completion does not guarantee a cached result.
  Future<void> prepareScopedNext<R>(
    int visiblePage, {
    Object slot = 'page',
    bool Function()? canPrepare,
  }) {
    if (!mounted || _scopedDisposed) return Future.value();
    final entry = _scopedPageReads[(R, slot)];
    if (entry is! _ScopedReadEntry<R>) return Future.value();
    return entry.reader.prepareNext(
      visiblePage,
      canPrepare: () => _scopedViewActive && (canPrepare?.call() ?? true),
    );
  }

  /// [query] and [currentQuery] include every filter, sort, resource and the
  /// repository/source instance. Use maps/lists for nested collections; page
  /// number and the caller's single-page request generation are excluded.
  /// Only actual pagination passes [useCache]; refresh and writes stay fresh.
  Future<PagedResult<R>> readScopedPage<R>(
    int page, {
    Object slot = 'page',
    required Object query,
    required Object Function() currentQuery,
    required Future<PagedResult<R>> Function(int page) fetchPage,
    bool useCache = false,
    bool Function()? isCurrent,
    bool Function()? canPrefetch,
    void Function(Object)? onPrefetchError,
  }) {
    final key = (R, slot);
    final entry =
        _scopedPageReads.putIfAbsent(key, () => _ScopedReadEntry<R>())
            as _ScopedReadEntry<R>;
    final owner = _scopedOwner;
    final epoch = ref.read(exportContextEpochProvider);
    final snapshot = freezePagedReadQuery(query);
    bool current() =>
        mounted &&
        !_scopedDisposed &&
        owner == _scopedOwner &&
        epoch == ref.read(exportContextEpochProvider) &&
        samePagedReadQuery(snapshot, currentQuery()) &&
        (isCurrent?.call() ?? true);
    return entry.reader
        .read(
          page,
          scope: [owner, epoch, snapshot],
          fetchPage: fetchPage,
          isCurrent: current,
          useCache: useCache,
          canPrefetch: () =>
              current() && (canPrefetch?.call() ?? _scopedViewActive),
          onPrefetchError: (error) {
            if (!current()) return;
            if (pagedReadAccessDenied(error)) {
              invalidateScopedPageReads();
              _scopedOwnerChanged(error);
            }
            onPrefetchError?.call(error);
          },
        )
        .onError((Object error, StackTrace stack) {
          if (current() && pagedReadAccessDenied(error)) {
            invalidateScopedPageReads();
            _scopedOwnerChanged(error);
          }
          Error.throwWithStackTrace(error, stack);
        });
  }

  @override
  void dispose() {
    _scopedDisposed = true;
    _scopedOwnerSubscription?.close();
    for (final entry in _scopedPageReads.values) {
      entry.dispose();
    }
    _scopedPageReads.clear();
    super.dispose();
  }
}

abstract interface class _ScopedReadLifecycle {
  void invalidate();
  void dispose();
}

class _ScopedReadEntry<R> implements _ScopedReadLifecycle {
  final reader = ScopedPagedRead<R>();
  @override
  void invalidate() => reader.invalidate();
  @override
  void dispose() => reader.dispose();
}

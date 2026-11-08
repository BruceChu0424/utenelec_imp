import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import '../providers/export_context_epoch_provider.dart';
import 'scoped_paged_read.dart';
import 'paged_query_identity.dart';
import 'read_view_activity.dart';

export 'read_view_activity.dart' show isRetiredViewRead;

/// Lifecycle adapter for complete query lists. The shared reader owns bounded
/// transport and the accepted result; the view owns loading, selection and its
/// latest UI request. Query maps/lists are snapshotted before asynchronous work.
mixin ScopedPagedReadViewMixin<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  final _scopedPageReads = <(Type, Object), _ScopedReadLifecycle>{};
  ProviderSubscription<int>? _scopedOwnerSubscription;
  int _scopedOwner = 0;
  bool _scopedDisposed = false;
  ApiException? _scopedReadCause;
  late final readViewActivity = ReadViewActivity(onResume: onReadViewResumed);

  /// Existing PageResume callbacks get the first fresh attempt. Direct retained
  /// panels may supply their complete load pipeline here as an idle fallback.
  FutureOr<void> onReadViewResumed() {}

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    readViewActivity.bindView(context);
  }

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
        if (_scopedPageReads.isNotEmpty) {
          readViewActivity.requestResume(_scopedPageReads.keys);
        }
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
    Future<PagedResult<R>> Function(int page, int size)? fetchPageSized,
    Future<PagedResult<R>> Function()? fetchComplete,
    Object? Function(R row)? idOf,
    bool useCache = false,
    bool Function()? isCurrent,
    bool Function()? canPrefetch,
    void Function(Object)? onPrefetchError,
    void Function(PagedResult<R> provisional)? onProvisionalBatch,
    int maxConcurrentPages = 1,
  }) {
    final key = (R, slot);
    final entry =
        _scopedPageReads.putIfAbsent(key, () => _ScopedReadEntry<R>())
            as _ScopedReadEntry<R>;
    final owner = _scopedOwner;
    final epoch = ref.read(exportContextEpochProvider);
    final snapshot = freezePagedReadQuery(query);
    bool ownerCurrent() =>
        mounted &&
        !_scopedDisposed &&
        owner == _scopedOwner &&
        epoch == ref.read(exportContextEpochProvider) &&
        samePagedReadQuery(snapshot, currentQuery());
    bool current() => ownerCurrent() && (isCurrent?.call() ?? true);
    return readViewActivity.runRead(
      current,
      () => entry.reader
          .read(
            page,
            scope: [owner, epoch, snapshot],
            fetchPage: fetchPage,
            fetchPageSized: fetchPageSized,
            fetchComplete: fetchComplete,
            idOf: idOf,
            isCurrent: current,
            isOwnerCurrent: ownerCurrent,
            useCache: useCache,
            maxConcurrentPages: maxConcurrentPages,
            onProvisionalBatch: onProvisionalBatch == null
                ? null
                : (partial) {
                    if (current()) onProvisionalBatch(partial);
                  },
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
          }),
      slot: key,
    );
  }

  @override
  void dispose() {
    _scopedDisposed = true;
    readViewActivity.dispose();
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

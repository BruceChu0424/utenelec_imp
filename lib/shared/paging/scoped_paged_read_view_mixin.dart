import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/performance/ui_work_budget.dart';
import '../models/paged_result.dart';
import '../providers/export_context_epoch_provider.dart';
import 'complete_paged_snapshot.dart';
import 'scoped_paged_read.dart';
import 'paged_query_identity.dart';
import 'read_view_activity.dart';
import 'complete_output_guard.dart';

export 'complete_paged_snapshot.dart' show CompleteReadBatchPlan;
export 'read_view_activity.dart' show isRetiredViewRead;

/// Lifecycle adapter for complete query lists. The shared reader owns bounded
/// transport and the accepted result; the view owns loading, selection and its
/// latest UI request. Query maps/lists are snapshotted before asynchronous work.
mixin ScopedPagedReadViewMixin<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  final _scopedPageReads = <(Type, Object), _ScopedReadLifecycle>{};
  final _scopedOutputGuards = <CompleteOutputGuard>{};
  // Pending query-answer expiry timers of the live read closures; disposed
  // with the view so a check in the last moment leaves no pending timer.
  final _scopedAnswerTimers = <Timer>{};
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
    for (final guard in _scopedOutputGuards) {
      guard.retire();
    }
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
  ///
  /// [fetchPageSized] forwards the reader's batch size to the endpoint (first
  /// batch 50, then 50/100/200 aligned). [onProgressiveBatch] receives every
  /// validated accumulated prefix while the read continues: render it as rows
  /// only, and keep totals/export/batch/write entries waiting for the awaited
  /// complete result.
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
    void Function(PagedResult<R> partial)? onProgressiveBatch,
    int maxConcurrentPages = 1,
    CompleteReadBatchPlan? plan,
    CompleteOutputGuard? outputGuard,
  }) {
    if (outputGuard != null) _scopedOutputGuards.add(outputGuard);
    final key = (R, slot);
    final entry =
        _scopedPageReads.putIfAbsent(key, () => _ScopedReadEntry<R>())
            as _ScopedReadEntry<R>;
    final owner = _scopedOwner;
    final epoch = ref.read(exportContextEpochProvider);
    final snapshot = freezePagedReadQuery(query);
    // Row-validation loops re-check ownership several times per row. Reuse
    // their deep query check within an event turn, but never treat that memo
    // as a publication proof: synchronous code and microtasks can still change
    // the live query. Fetch/response and publication boundaries below force a
    // fresh check; owner/disposed/mounted gates always stay outside the memo.
    var queryAnswerValid = false;
    var queryAnswerCurrent = false;
    Timer? queryAnswerExpiry;
    void expireQueryAnswer() => queryAnswerValid = false;
    bool ownerCurrent() {
      final stats = debugScopedReadCheckStats;
      if (stats != null) stats.ownerChecks++;
      if (!mounted || _scopedDisposed || owner != _scopedOwner) return false;
      if (queryAnswerValid) return queryAnswerCurrent;
      if (stats != null) {
        stats.epochReads++;
        stats.queryCompares++;
      }
      queryAnswerCurrent =
          epoch == ref.read(exportContextEpochProvider) &&
          samePagedReadQuery(snapshot, currentQuery());
      queryAnswerValid = true;
      if (queryAnswerExpiry == null) {
        final timer = Timer(Duration.zero, () {
          _scopedAnswerTimers.remove(queryAnswerExpiry);
          queryAnswerExpiry = null;
          expireQueryAnswer();
        });
        queryAnswerExpiry = timer;
        _scopedAnswerTimers.add(timer);
      }
      return queryAnswerCurrent;
    }

    bool current() => ownerCurrent() && (isCurrent?.call() ?? true);
    bool publicationCurrent() {
      expireQueryAnswer();
      return current();
    }

    Future<PagedResult<R>> checkedFetch(
      Future<PagedResult<R>> Function() fetch,
    ) async {
      try {
        final result = await fetch();
        if (!publicationCurrent()) throw PagedReadOwnerChanged();
        return result;
      } finally {
        // The reader resumes in another microtask. Its first check must not
        // borrow the answer from the fetch completion microtask, even on error.
        expireQueryAnswer();
      }
    }

    final pending = readViewActivity.runRead(
      current,
      () => entry.reader
          .read(
            page,
            scope: [owner, epoch, snapshot],
            fetchPage: (page) => checkedFetch(() => fetchPage(page)),
            fetchPageSized: fetchPageSized == null
                ? null
                : (page, size) =>
                      checkedFetch(() => fetchPageSized(page, size)),
            fetchComplete: fetchComplete == null
                ? null
                : () => checkedFetch(fetchComplete),
            idOf: idOf,
            isCurrent: current,
            isOwnerCurrent: ownerCurrent,
            useCache: useCache,
            maxConcurrentPages: maxConcurrentPages,
            plan: plan,
            onProgressiveBatch: onProgressiveBatch == null
                ? null
                : (partial) {
                    if (!publicationCurrent()) {
                      throw PagedReadOwnerChanged();
                    }
                    try {
                      onProgressiveBatch(partial);
                    } finally {
                      // A prefix consumer may synchronously change its query.
                      expireQueryAnswer();
                    }
                  },
            canPrefetch: () =>
                current() && (canPrefetch?.call() ?? _scopedViewActive),
            onPrefetchError: (error) {
              if (!publicationCurrent()) return;
              if (pagedReadAccessDenied(error)) {
                invalidateScopedPageReads();
                _scopedOwnerChanged(error);
              }
              onPrefetchError?.call(error);
            },
          )
          .onError((Object error, StackTrace stack) {
            if (publicationCurrent() && pagedReadAccessDenied(error)) {
              invalidateScopedPageReads();
              _scopedOwnerChanged(error);
            }
            if (!current() && isRetiredViewRead(error)) {
              // A retired old owner is not the current request's failure:
              // translate every retirement shape (owner change, REQUEST_STALE,
              // cancellation) into the one canonical quiet signal, so no page
              // handler can mistake a query switch for a failed load.
              Error.throwWithStackTrace(const UiWorkCancelled(), stack);
            }
            Error.throwWithStackTrace(error, stack);
          }),
      slot: key,
    );
    return pending.then((result) {
      // Includes cache hits and fetchComplete. Fence the public result after
      // the activity wrapper's awaits, before the caller can accept/output it.
      if (!publicationCurrent()) throw const UiWorkCancelled();
      return result;
    });
  }

  @override
  void dispose() {
    _scopedDisposed = true;
    readViewActivity.dispose();
    _scopedOwnerSubscription?.close();
    for (final timer in _scopedAnswerTimers) {
      timer.cancel();
    }
    _scopedAnswerTimers.clear();
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

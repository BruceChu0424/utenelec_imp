import 'dart:async';

import '../../core/network/api_exception.dart';
import '../../core/performance/ui_work_budget.dart';
import '../models/immutable_paged_rows.dart';
import '../models/paged_result.dart';
import 'complete_read_progress.dart';
import 'paged_read_intent.dart';
import 'paged_query_identity.dart';

/// 2026-11-08 user decision: a complete read starts with a small batch so the
/// first screen appears at once, then keeps reading in larger bounded batches
/// until the whole result is loaded. Every batch is an exact server page of
/// its own size (offset == (page - 1) * size), aligned as 50 → 50 → 100 →
/// 200 → 200 …, so no row is read twice and none is skipped.
class CompleteReadBatchPlan {
  const CompleteReadBatchPlan({
    this.firstBatchSize = 50,
    // 2026-11-09: raised 200→1000 with the user; totals ≤1000 keep the same
    // request sequence as the previous 200 cap, so small fixtures are unchanged.
    this.maxBatchSize = 1000,
  });

  /// Every batch has one size: metadata readers and explicit legacy callers.
  const CompleteReadBatchPlan.fixed(int size)
    : firstBatchSize = size,
      maxBatchSize = size;

  static const progressive = CompleteReadBatchPlan();

  final int firstBatchSize;
  final int maxBatchSize;

  /// The size of the batch that starts exactly at [offset]. [cap] is a smaller
  /// server maximum discovered during this read.
  int sizeAt(int offset, {int? cap}) {
    final maximum = cap != null && cap < maxBatchSize ? cap : maxBatchSize;
    if (offset == 0) {
      return firstBatchSize < maximum ? firstBatchSize : maximum;
    }
    return offset % maximum == 0
        ? maximum
        : _greatestCommonDivisor(offset, maximum);
  }

  void _validate() {
    if (firstBatchSize < 1 ||
        maxBatchSize > 1000 ||
        firstBatchSize > maxBatchSize) {
      throw RangeError('Invalid complete read batch plan');
    }
  }
}

int _greatestCommonDivisor(int a, int b) {
  while (b != 0) {
    final rest = a % b;
    a = b;
    b = rest;
  }
  return a;
}

/// Progressive rows reach the view at most this often; the first validated
/// batch is published at once.
const kProgressiveBatchInterval = Duration(milliseconds: 200);

ApiException _invalidPagination() =>
    ApiException('INVALID_PAGINATION', '分页信息异常，请刷新后重新读取完整结果');

ApiException _snapshotChanged() =>
    ApiException('SNAPSHOT_CHANGED', '数据在读取期间已变化，请刷新后重新读取完整结果');

/// Reads one authorized query in bounded internal batches, then publishes one
/// continuous result. Scrolling the accepted result needs no further reads.
Future<PagedResult<T>> loadCompletePagedResult<T>({
  required Future<PagedResult<T>> Function(int page, int size) loadPage,
  required bool Function() isCurrent,
  // An explicit size keeps one fixed batch (metadata/legacy readers).
  int? batchSize,
  // Without an explicit size the progressive plan applies; readers whose total
  // may be unknown or unstable keep their original fixed 100 batches.
  CompleteReadBatchPlan? plan,
  int maxConcurrentPages = 1,
  Object? Function(T row)? idOf,
  void Function(List<T> rows, int total, bool hasMore)? onBatch,
  FutureOr<void> Function(PagedResult<T> page)? onPage,
  // Progressive display (2026-11-08 user decision): every validated batch may
  // render as accumulated pending rows while the read continues. Totals and
  // every total-dependent action still wait for the complete result; a failed
  // or retired read takes the progressive rows down with it.
  void Function(PagedResult<T> partial)? onProgressiveBatch,
  Duration progressiveInterval = kProgressiveBatchInterval,
  bool requireStableTotal = true,
  bool allowUnknownTotal = false,
  bool unknownPageCountIsHorizon = false,
  bool deduplicateOverlaps = false,
  UiWorkBudget? budget,
  // The reader identity that owns this complete read (a ScopedPagedRead).
  // Retiring that owner cancels the progress task at once; direct callers
  // without an owner still finish through the read's own error path.
  Object? progressOwner,
}) async {
  if (batchSize != null && (batchSize < 1 || batchSize > 1000)) {
    throw RangeError.range(batchSize, 1, 1000, 'batchSize');
  }
  if (maxConcurrentPages < 1 || maxConcurrentPages > 4) {
    throw RangeError.range(maxConcurrentPages, 1, 4, 'maxConcurrentPages');
  }
  if (maxConcurrentPages > 1 &&
      (idOf == null ||
          !requireStableTotal ||
          allowUnknownTotal ||
          deduplicateOverlaps)) {
    throw ArgumentError(
      'Concurrent complete reads require one exact stable offset snapshot',
    );
  }
  final batches = batchSize != null
      ? CompleteReadBatchPlan.fixed(batchSize)
      : plan ??
            (allowUnknownTotal || !requireStableTotal
                ? const CompleteReadBatchPlan.fixed(100)
                : CompleteReadBatchPlan.progressive);
  batches._validate();
  final parent = PagedReadIntent.currentRead;
  final activity = PagedReadIntent.currentActivity;
  final bootstrapAllowed = PagedReadIntent.allowsInactiveBootstrap;
  bool logicalCurrent() {
    debugScopedReadCheckStats?.loopChecks++;
    return isCurrent() && (parent?.call() ?? true);
  }

  bool current() => logicalCurrent() && (activity?.call() ?? true);
  final pipeline = maxConcurrentPages == 1
      ? null
      : _CompletePagePipeline<T>(
          isCurrent: current,
          loadPage: loadPage,
          plan: batches,
          maximum: maxConcurrentPages,
          idOf: idOf!,
        );
  final progressive = onProgressiveBatch == null
      ? null
      : _ProgressiveBatches<T>(
          onProgressiveBatch,
          progressiveInterval,
          current,
        );
  // The top progress notice follows exactly the reads that publish validated
  // batches to their view (a fresh main-table read); auxiliary complete reads
  // without a progressive slot never report, and silent rereads of an accepted
  // result have no batches to publish either.
  final progress =
      progressive == null || !CompleteReadProgressReporter.hasListeners
      ? null
      : CompleteReadProgressReporter.start(owner: progressOwner);
  final work = budget ?? UiWorkBudget(isCurrent: current);
  // Overlap readers may replace an earlier row: they keep the original mutable
  // accumulator and deliberately offer no append proof. Exact readers seal
  // only each new batch, never copying the already published prefix again.
  final overlapRows = deduplicateOverlaps ? <T>[] : null;
  ImmutablePagedRowsBuilder<T>? rowBuilder;
  int rowCount() => overlapRows?.length ?? rowBuilder?.length ?? 0;
  final identities = <Object, int>{};
  PagedResult<T>? first;
  Object? firstRevision;
  // Server rows consumed so far: the exact offset of the next batch.
  var offset = 0;
  var batch = 0;
  // A smaller maximum the server reported during this read.
  int? cap;
  // A loader that keeps its own page size continues on exactly that size.
  int? serverSize;
  try {
    while (logicalCurrent()) {
      // current() == logicalCurrent() && activity, and logical already holds
      // here, so one activity evaluation answers both the activity gate and
      // the budget fence below — nothing runs between them that could retire.
      final active = activity?.call() ?? true;
      if (!active && !(batch == 0 && bootstrapAllowed)) {
        throw const UiWorkCancelled();
      }
      if (active) work.ensureCurrent();
      progressive?.throwIfFailed();
      final size = serverSize ?? batches.sizeAt(offset, cap: cap);
      // One fixed size keeps the original page-by-page sequence; the ladder
      // places each batch by its exact offset (every earlier batch was full).
      final fixedSize =
          serverSize != null ||
          (cap == null && batches.firstBatchSize == batches.maxBatchSize);
      final page = fixedSize ? batch + 1 : offset ~/ size + 1;
      final queued = pipeline != null && batch > 0
          ? await pipeline.take(batch)
          : null;
      final PagedResult<T> result = queued != null
          ? queued.value!
          : await PagedReadIntent.scopedRead<Future<PagedResult<T>>>(
              logicalCurrent,
              () => loadPage(page, size),
              bootstrap: batch == 0,
            );
      if (!current()) throw const UiWorkCancelled();
      progressive?.throwIfFailed();
      // Network/model callers can reuse a mutable page list. Freeze this
      // bounded batch before the first UI yield, not the whole read prefix.
      final pageRows =
          queued?.rows ?? List<T>.of(result.items, growable: false);
      pipeline?.validate(result, batch, pageRows);
      final knownTotal = result.total >= 0;
      final exactTotal = knownTotal && requireStableTotal;
      if (batch == 0 && !exactTotal) {
        // Without an exact stable total no offset can be proven: continue
        // page by page on the first batch's size. This includes fixed plans:
        // recomputing their size from the rows read so far would turn a short
        // server page (40 of 100) into an offset-aligned (2, 20) request.
        serverSize = size;
      }
      final hasMore = exactTotal
          ? offset + pageRows.length < result.total
          : result.page < result.totalPages;
      if (pipeline == null && serverSize == null && result.page == page) {
        final expectedRows = exactTotal
            ? (result.total - offset).clamp(0, size)
            : null;
        // A server may echo another size on a correct final page; its page
        // count in the requested size still proves the batch was honored.
        final honored =
            (result.size == size ||
                (exactTotal &&
                    result.totalPages == (result.total + size - 1) ~/ size)) &&
            pageRows.length <= size &&
            (expectedRows == null || pageRows.length == expectedRows);
        if (!honored) {
          if (batch == 0) {
            // The first page starts at row 0 whatever its size: a smaller
            // server maximum, a loader with its own page size or one complete
            // nested result. Any continuation keeps exactly that size.
            final own = result.size >= pageRows.length
                ? result.size
                : pageRows.length;
            if (own < 1 && hasMore) throw _invalidPagination();
            serverSize = own < 1 ? size : own;
          } else if (result.size >= 1 &&
              result.size < size &&
              (cap == null || result.size < cap)) {
            // A smaller server maximum: these rows belong to another offset.
            // Read the same offset again on the smaller aligned size.
            cap = result.size;
            continue;
          } else {
            throw _invalidPagination();
          }
        }
      }
      final effectiveSize = serverSize ?? size;
      if (result.page != page ||
          result.totalPages < 0 ||
          (!knownTotal && (!allowUnknownTotal || result.total != -1)) ||
          (!knownTotal &&
              unknownPageCountIsHorizon &&
              result.totalPages != page &&
              result.totalPages != page + 1) ||
          (hasMore && pageRows.isEmpty) ||
          (exactTotal &&
              pageRows.length !=
                  (result.total - offset).clamp(0, effectiveSize)) ||
          (result.totalPages == 0 && pageRows.isNotEmpty)) {
        throw _invalidPagination();
      }
      if (first case final initial?) {
        final revision = result is PagedResultRevision
            ? (result as PagedResultRevision).snapshotRevision
            : null;
        if (initial.readScopeVersion != result.readScopeVersion ||
            !samePagedReadQuery(firstRevision, revision) ||
            (initial.total >= 0) != knownTotal ||
            (requireStableTotal && initial.total != result.total) ||
            ((requireStableTotal || !knownTotal) &&
                !(!knownTotal && unknownPageCountIsHorizon) &&
                initial.size == result.size &&
                initial.totalPages != result.totalPages)) {
          throw _snapshotChanged();
        }
      } else {
        first = result;
        if (overlapRows == null) rowBuilder = result.createRowsBuilder();
        firstRevision = freezePagedReadQuery(
          result is PagedResultRevision
              ? (result as PagedResultRevision).snapshotRevision
              : null,
        );
      }
      for (final row in pageRows) {
        if (pipeline == null && idOf != null) {
          final identity = idOf(row);
          if (identity == null || identity == '') {
            throw ApiException('SNAPSHOT_CHANGED', '记录身份缺失或分页发生变化，请刷新后核对完整结果');
          }
          final previous = identities[identity];
          if (previous != null) {
            if (!deduplicateOverlaps) {
              throw ApiException(
                'SNAPSHOT_CHANGED',
                '记录身份重复或分页发生变化，请刷新后核对完整结果',
              );
            }
            overlapRows![previous] = row;
            await work.checkpoint();
            if (!current()) throw const UiWorkCancelled();
            continue;
          }
          identities[identity] = rowCount();
        }
        if (overlapRows != null) {
          overlapRows.add(row);
        } else {
          rowBuilder!.add(row);
        }
        await work.checkpoint();
        if (!current()) throw const UiWorkCancelled();
      }
      offset += pageRows.length;
      batch++;
      if (knownTotal && rowCount() > result.total) throw _snapshotChanged();
      final incomplete = !hasMore && knownTotal && rowCount() != result.total;
      if (!current()) throw const UiWorkCancelled();
      pipeline?.throwIfFailed();
      final sealedRows = rowBuilder?.snapshot();
      if (onPage != null) await onPage(result);
      if (!current()) throw const UiWorkCancelled();
      onBatch?.call(
        sealedRows ?? List<T>.unmodifiable(overlapRows!),
        result.total,
        hasMore || incomplete,
      );
      progress?.update(
        loaded: rowCount(),
        total: knownTotal ? result.total : null,
      );
      if (incomplete) throw _snapshotChanged();
      pipeline?.accepted();
      if (hasMore && progressive != null) {
        // The accumulated validated prefix; the server's exact total rides
        // along unchanged and the complete result replaces it.
        final initial = first;
        final boundary = rowCount();
        final total = knownTotal ? result.total : boundary;
        // Capture an immutable prefix, never the builder or a mutable list
        // whose previous rows a later overlap could replace during the timer.
        final prefix = sealedRows ?? freezePagedRows<T>(overlapRows!);
        progressive.offer(
          () => initial.withRowsFrom(
            prefix,
            page: 1,
            size: boundary,
            total: total,
            totalPages: 1,
          ),
        );
        if (!current()) throw const UiWorkCancelled();
      }
      if (!hasMore) {
        progressive?.close();
        work.ensureCurrent();
        final combined = await first.withRowsFromResponsive(
          sealedRows ?? overlapRows!,
          total: knownTotal ? result.total : rowCount(),
          totalPages: rowCount() == 0 ? 0 : 1,
          budget: work,
        );
        if (!current()) throw const UiWorkCancelled();
        progress?.finish(succeeded: true);
        return combined;
      }
    }
    throw const UiWorkCancelled();
  } finally {
    // finish is idempotent: a succeeded task ignores this, and every failure
    // or retirement path (UiWorkCancelled included) ends its progress here.
    progress?.finish(succeeded: false);
    progressive?.close();
    pipeline?.close();
  }
}

/// Coalesces progressive publications: the first batch goes out at once,
/// later batches at most once per interval, always the latest prefix. Nothing
/// is published after completion, failure or retirement.
class _ProgressiveBatches<T> {
  _ProgressiveBatches(this._publish, this._interval, this._current);

  final void Function(PagedResult<T> partial) _publish;
  final Duration _interval;
  final bool Function() _current;
  // Closed while a publication is younger than the interval.
  Timer? _gate;
  PagedResult<T> Function()? _pending;
  Object? _error;
  StackTrace? _stack;
  bool _closed = false;

  void offer(PagedResult<T> Function() build) {
    if (_closed || !_current()) return;
    if (_gate == null) {
      _emit(build);
    } else {
      _pending = build;
    }
  }

  void throwIfFailed() {
    if (_error case final error?) Error.throwWithStackTrace(error, _stack!);
  }

  void _emit(PagedResult<T> Function() build) {
    if (_interval > Duration.zero) _gate = Timer(_interval, _reopen);
    _publish(build());
  }

  void _reopen() {
    _gate = null;
    final build = _pending;
    _pending = null;
    if (build == null || _closed || !_current()) return;
    try {
      _emit(build);
    } catch (error, stack) {
      // Surfaced on the reader's next step instead of escaping the timer.
      _error ??= error;
      _stack ??= stack;
    }
  }

  void close() {
    _closed = true;
    _gate?.cancel();
    _gate = null;
    _pending = null;
  }
}

/// Existing printing, roster and exact-category consumers retain their list API.
Future<List<T>> loadCompletePagedSnapshot<T>({
  required Future<PagedResult<T>> Function(int page, int size) loadPage,
  required String Function(T row) idOf,
  required bool Function() isCurrent,
  void Function(List<T> rows, int total, bool hasMore)? onBatch,
  bool requireStableTotal = true,
  UiWorkBudget? budget,
}) async => (await loadCompletePagedResult(
  loadPage: loadPage,
  idOf: idOf,
  isCurrent: isCurrent,
  onBatch: onBatch,
  requireStableTotal: requireStableTotal,
  deduplicateOverlaps: true,
  budget: budget,
)).items;

/// Complete cursor history uses its real termination token, never a made-up
/// count or advancing page horizon. The typed first response owns metadata.
/// A cursor continues from its token, so the first batch is small and every
/// later batch takes the bounded maximum.
Future<S> loadCompleteCursorSnapshot<R, S, C>({
  required Future<S> Function(C? cursor, int size) loadPage,
  required List<R> Function(S response) rowsOf,
  required C? Function(S response) nextCursorOf,
  required S Function(S first, List<R> rows) rebuildSnapshot,
  required bool Function() isCurrent,
  Object? Function(R row)? idOf,
  Object? Function(S response)? revisionOf,
  bool deduplicateOverlaps = false,
  void Function(List<R> rows, bool hasMore)? onBatch,
  CompleteReadBatchPlan plan = CompleteReadBatchPlan.progressive,
  UiWorkBudget? budget,
}) async {
  plan._validate();
  final parent = PagedReadIntent.currentRead;
  final activity = PagedReadIntent.currentActivity;
  final bootstrapAllowed = PagedReadIntent.allowsInactiveBootstrap;
  bool logicalCurrent() {
    debugScopedReadCheckStats?.loopChecks++;
    return isCurrent() && (parent?.call() ?? true);
  }

  bool current() => logicalCurrent() && (activity?.call() ?? true);
  final work = budget ?? UiWorkBudget(isCurrent: current);
  // Cursor history has no total semantics: the top notice follows these reads
  // with an indeterminate sweep (total=null), never a made-up percentage.
  final progress = onBatch == null || !CompleteReadProgressReporter.hasListeners
      ? null
      : CompleteReadProgressReporter.start();
  final rows = ImmutablePagedRowsBuilder<R>();
  final identities = <Object>{};
  final cursors = <PagedReadQueryKey>{};
  try {
    return await _cursorBatches(
      loadPage: loadPage,
      rowsOf: rowsOf,
      nextCursorOf: nextCursorOf,
      logicalCurrent: logicalCurrent,
      current: current,
      activity: activity,
      work: work,
      plan: plan,
      progress: progress,
      bootstrapAllowed: bootstrapAllowed,
      onBatch: onBatch,
      idOf: idOf,
      revisionOf: revisionOf,
      deduplicateOverlaps: deduplicateOverlaps,
      rebuildSnapshot: rebuildSnapshot,
      state: _CursorReadState<R, S, C>(
        rows: rows,
        identities: identities,
        cursors: cursors,
      ),
    );
  } finally {
    // finish is idempotent: a succeeded task ignores this; every failure or
    // retirement ends its progress here.
    progress?.finish(succeeded: false);
  }
}

/// 可变读取状态：主函数与批处理助手共享同一份行/身份/游标集合。
class _CursorReadState<R, S, C> {
  _CursorReadState({
    required this.rows,
    required this.identities,
    required this.cursors,
  });
  final ImmutablePagedRowsBuilder<R> rows;
  final Set<Object> identities;
  final Set<PagedReadQueryKey> cursors;
  C? cursor;
  S? first;
  bool hasFirst = false;
  Object? firstRevision;
}

Future<S> _cursorBatches<R, S, C>({
  required Future<S> Function(C? cursor, int size) loadPage,
  required List<R> Function(S response) rowsOf,
  required C? Function(S response) nextCursorOf,
  required bool Function() logicalCurrent,
  required bool Function() current,
  bool Function()? activity,
  required UiWorkBudget work,
  required CompleteReadBatchPlan plan,
  required CompleteReadProgressHandle? progress,
  required bool bootstrapAllowed,
  required void Function(List<R> rows, bool hasMore)? onBatch,
  required Object? Function(R row)? idOf,
  required Object? Function(S response)? revisionOf,
  required bool deduplicateOverlaps,
  required S Function(S first, List<R> rows) rebuildSnapshot,
  required _CursorReadState<R, S, C> state,
}) async {
  while (logicalCurrent()) {
    // current() == logicalCurrent() && activity, and logical already holds
    // here, so one activity evaluation answers both the activity gate and
    // the budget fence below — nothing runs between them that could retire.
    final active = activity?.call() ?? true;
    if (!active && !(!state.hasFirst && bootstrapAllowed)) {
      throw const UiWorkCancelled();
    }
    if (active) work.ensureCurrent();
    final size = state.hasFirst ? plan.maxBatchSize : plan.firstBatchSize;
    final response = await PagedReadIntent.scopedRead(
      logicalCurrent,
      () => loadPage(state.cursor, size),
      bootstrap: !state.hasFirst,
    );
    if (!current()) throw const UiWorkCancelled();
    if (!state.hasFirst) {
      state.first = response;
      state.hasFirst = true;
      state.firstRevision = freezePagedReadQuery(revisionOf?.call(response));
    } else if (revisionOf != null &&
        !samePagedReadQuery(state.firstRevision, revisionOf(response))) {
      throw ApiException('SNAPSHOT_CHANGED', '历史读取范围已变化，请刷新后重新核对');
    }
    final batch = List<R>.of(rowsOf(response), growable: false);
    final next = nextCursorOf(response);
    if (next != null &&
        (batch.isEmpty ||
            samePagedReadQuery(next, state.cursor) ||
            !state.cursors.add(PagedReadQueryKey(next)))) {
      throw ApiException('INVALID_PAGINATION', '历史游标未前进，请刷新后重新读取完整记录');
    }
    for (final row in batch) {
      if (idOf != null) {
        final identity = idOf(row);
        if (identity == null || identity == '') {
          throw ApiException('SNAPSHOT_CHANGED', '历史记录身份缺失或重复，请刷新后重新核对');
        }
        if (!state.identities.add(identity)) {
          if (!deduplicateOverlaps) {
            throw ApiException('SNAPSHOT_CHANGED', '历史记录身份缺失或重复，请刷新后重新核对');
          }
          await work.checkpoint();
          if (!current()) throw const UiWorkCancelled();
          continue;
        }
      }
      state.rows.add(row);
      await work.checkpoint();
      if (!current()) throw const UiWorkCancelled();
    }
    if (!current()) throw const UiWorkCancelled();
    final sealedRows = state.rows.snapshot();
    onBatch?.call(sealedRows, next != null);
    // total 省缺即 null：游标读取无总量语义，卡片走不定进度。
    progress?.update(loaded: state.rows.length);
    if (next == null) {
      final combined = rebuildSnapshot(state.first as S, sealedRows);
      if (!current()) throw const UiWorkCancelled();
      progress?.finish(succeeded: true);
      return combined;
    }
    state.cursor = next;
  }
  throw const UiWorkCancelled();
}

/// One planned batch of a stable-total snapshot.
class _PlannedBatch {
  const _PlannedBatch(this.offset, this.size);
  final int offset;
  final int size;
  int get page => offset ~/ size + 1;
}

/// At most four active/completed batches are retained. Scheduling is
/// independent of scroll; batches are accepted and published in plan order by
/// the original complete validator.
class _CompletePagePipeline<T> {
  _CompletePagePipeline({
    required this.isCurrent,
    required this.loadPage,
    required this.plan,
    required this.maximum,
    required this.idOf,
  });
  final bool Function() isCurrent;
  final Future<PagedResult<T>> Function(int page, int size) loadPage;
  final CompleteReadBatchPlan plan;
  final int maximum;
  final Object? Function(T row) idOf;
  final _waiting = <int, Future<_CompletePageReply<T>>>{};
  final _identityBatches = <Object, int>{};
  final _validatedIdentityBatches = <int>{};
  final _batches = <_PlannedBatch>[];
  PagedResult<T>? _first;
  VersionedPagedResultProof? _firstProof;
  _CompletePageReply<T>? _failure;
  Completer<_CompletePageReply<T>>? _reader;
  int _next = 1;
  bool _closed = false;
  bool _networkCurrent() => !_closed && _failure == null && isCurrent();

  _PlannedBatch _planned(int batch) => batch == 0
      ? _PlannedBatch(0, plan.sizeAt(0))
      : batch < _batches.length
      ? _batches[batch]
      : throw ApiException('INVALID_PAGINATION', '完整列表并发批次不完整，请重新读取');

  void validate(PagedResult<T> value, int batch, List<T> rows) {
    final proof = value is VersionedPagedResultProof
        ? value as VersionedPagedResultProof
        : null;
    if (proof == null ||
        value.readScopeVersion?.isNotEmpty != true ||
        value.readScopeVersion!.length > 256 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(proof.readSnapshotRevision) ||
        proof.readDataVersion == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(proof.readDataVersion!)) {
      throw ApiException('INCOMPLETE_READ_PROTOCOL', '完整列表并发读取缺少稳定凭据');
    }
    final planned = _planned(batch);
    final pages = value.total <= 0 ? 0 : 1 + (value.total - 1) ~/ planned.size;
    final remaining = value.total - planned.offset;
    final expectedRows = remaining <= 0
        ? 0
        : remaining < planned.size
        ? remaining
        : planned.size;
    if (value.total < 0 ||
        value.page != planned.page ||
        value.size != planned.size ||
        value.totalPages != pages ||
        rows.length != expectedRows) {
      throw ApiException('INVALID_PAGINATION', '完整列表并发批次不完整，请重新读取');
    }
    final first = _first;
    if (first == null) {
      _first = value;
      _firstProof = proof;
      var offset = planned.size;
      while (offset < value.total) {
        final size = plan.sizeAt(offset);
        _batches.add(_PlannedBatch(offset, size));
        offset += size;
      }
      _batches.insert(0, planned);
    } else {
      if (first.readScopeVersion != value.readScopeVersion) {
        throw ApiException(
          'READ_SCOPE_CHANGED',
          '数据访问范围已变化，请重新读取',
          httpStatus: 403,
        );
      }
      if (first.total != value.total ||
          _firstProof!.readSnapshotRevision != proof.readSnapshotRevision ||
          _firstProof!.readDataVersion != proof.readDataVersion) {
        throw ApiException('SNAPSHOT_CHANGED', '数据已变化，请重新读取完整列表');
      }
    }
    if (_validatedIdentityBatches.add(batch)) {
      final batchIdentities = <Object>{};
      for (final row in rows) {
        final identity = idOf(row);
        if (identity == null ||
            identity is String && identity.trim().isEmpty ||
            !batchIdentities.add(identity) ||
            _identityBatches.containsKey(identity)) {
          throw ApiException('SNAPSHOT_CHANGED', '记录身份缺失或重复，请重新读取完整列表');
        }
      }
      for (final identity in batchIdentities) {
        _identityBatches[identity] = batch;
      }
    }
  }

  void throwIfFailed() {
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error!, failure.stack!);
    }
  }

  void accepted() {
    throwIfFailed();
    while (_networkCurrent() &&
        _waiting.length < maximum &&
        _next < _batches.length) {
      final batch = _next++;
      _waiting[batch] = _read(batch);
    }
  }

  Future<_CompletePageReply<T>> _read(int batch) async {
    try {
      if (!_networkCurrent()) throw const UiWorkCancelled();
      final planned = _batches[batch];
      final result = await PagedReadIntent.scopedRead(
        _networkCurrent,
        () => loadPage(planned.page, planned.size),
      );
      throwIfFailed();
      if (!_networkCurrent()) throw const UiWorkCancelled();
      // A completed tail can wait behind an earlier batch. Retain the exact
      // membership validated now, even if its producer later reuses its list.
      final rows = List<T>.of(result.items, growable: false);
      validate(result, batch, rows);
      return _CompletePageReply.value(result, rows);
    } catch (error, stack) {
      final reply = _CompletePageReply<T>.error(error, stack);
      if (!_closed && _failure == null) {
        _failure = reply;
        final reader = _reader;
        if (reader != null && !reader.isCompleted) reader.complete(reply);
      }
      return reply;
    }
  }

  Future<_CompletePageReply<T>> take(int batch) async {
    throwIfFailed();
    final pending = _waiting.remove(batch);
    if (pending == null) throw StateError('Complete batch was not scheduled');
    final reader = Completer<_CompletePageReply<T>>();
    _reader = reader;
    unawaited(
      pending.then((reply) {
        if (!reader.isCompleted) reader.complete(reply);
      }),
    );
    try {
      final reply = await reader.future;
      if (reply.error != null) {
        Error.throwWithStackTrace(reply.error!, reply.stack!);
      }
      throwIfFailed();
      return reply;
    } finally {
      if (identical(_reader, reader)) _reader = null;
    }
  }

  void close() {
    _closed = true;
  }
}

class _CompletePageReply<T> {
  _CompletePageReply.value(this.value, this.rows) : error = null, stack = null;
  _CompletePageReply.error(this.error, this.stack) : value = null, rows = null;
  final PagedResult<T>? value;
  final List<T>? rows;
  final Object? error;
  final StackTrace? stack;
}

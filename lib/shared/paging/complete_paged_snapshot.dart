import 'dart:async';

import '../../core/network/api_exception.dart';
import '../../core/performance/ui_work_budget.dart';
import '../models/paged_result.dart';
import 'paged_read_intent.dart';
import 'paged_query_identity.dart';

/// Reads one authorized query in bounded internal batches, then publishes one
/// continuous result. Scrolling the accepted result needs no further reads.
Future<PagedResult<T>> loadCompletePagedResult<T>({
  required Future<PagedResult<T>> Function(int page, int size) loadPage,
  required bool Function() isCurrent,
  // Production lean summaries may negotiate a larger bounded read batch.
  // Existing readers and all original stress bodies retain their exact100.
  int batchSize = 100,
  int maxConcurrentPages = 1,
  Object? Function(T row)? idOf,
  void Function(List<T> rows, int total, bool hasMore)? onBatch,
  FutureOr<void> Function(PagedResult<T> page)? onPage,
  // Provisional first-batch display (2026-11-07 user decision): rows already
  // validated may render while the same response keeps streaming. Totals and
  // every total-dependent action still wait for the complete frame; a failed
  // or retired read takes the provisional rows down with it.
  void Function(PagedResult<T> provisional)? onProvisionalBatch,
  bool requireStableTotal = true,
  bool allowUnknownTotal = false,
  bool unknownPageCountIsHorizon = false,
  bool deduplicateOverlaps = false,
  UiWorkBudget? budget,
}) async {
  if (batchSize < 1 || batchSize > 1000) {
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
  final parent = PagedReadIntent.currentRead;
  final activity = PagedReadIntent.currentActivity;
  final bootstrapAllowed = PagedReadIntent.allowsInactiveBootstrap;
  var provisionalPublished = false;
  bool logicalCurrent() => isCurrent() && (parent?.call() ?? true);
  bool current() => logicalCurrent() && (activity?.call() ?? true);
  final pipeline = maxConcurrentPages == 1
      ? null
      : _CompletePagePipeline<T>(
          isCurrent: current,
          loadPage: (page) => loadPage(page, batchSize),
          batchSize: batchSize,
          maximum: maxConcurrentPages,
          idOf: idOf!,
        );
  final work = budget ?? UiWorkBudget(isCurrent: current);
  final rows = <T>[];
  final identities = <Object, int>{};
  PagedResult<T>? first;
  Object? firstRevision;
  var page = 1;
  try {
    while (logicalCurrent()) {
      if (!current() && !(page == 1 && bootstrapAllowed)) {
        throw const UiWorkCancelled();
      }
      if (current()) work.ensureCurrent();
      final result = pipeline != null && page > 1
          ? await pipeline.take(page)
          : await PagedReadIntent.scopedRead(
              logicalCurrent,
              () => loadPage(page, batchSize),
              bootstrap: page == 1,
            );
      pipeline?.validate(result, page);
      if (!current()) throw const UiWorkCancelled();
      final knownTotal = result.total >= 0;
      final hasMore = result.page < result.totalPages;
      if (result.page != page ||
          result.totalPages < 0 ||
          (!knownTotal && (!allowUnknownTotal || result.total != -1)) ||
          (!knownTotal &&
              unknownPageCountIsHorizon &&
              result.totalPages != page &&
              result.totalPages != page + 1) ||
          (hasMore && result.items.isEmpty) ||
          (result.totalPages == 0 && result.items.isNotEmpty)) {
        throw ApiException('INVALID_PAGINATION', '分页信息异常，请刷新后重新读取完整结果');
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
                initial.totalPages != result.totalPages)) {
          throw ApiException('SNAPSHOT_CHANGED', '数据在读取期间已变化，请刷新后重新读取完整结果');
        }
      } else {
        first = result;
        firstRevision = freezePagedReadQuery(
          result is PagedResultRevision
              ? (result as PagedResultRevision).snapshotRevision
              : null,
        );
      }
      for (final row in result.items) {
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
            rows[previous] = row;
            await work.checkpoint();
            if (!current()) throw const UiWorkCancelled();
            continue;
          }
          identities[identity] = rows.length;
        }
        rows.add(row);
        await work.checkpoint();
        if (!current()) throw const UiWorkCancelled();
      }
      if (knownTotal && rows.length > result.total) {
        throw ApiException('SNAPSHOT_CHANGED', '数据在读取期间已变化，请刷新后重新读取完整结果');
      }
      final incomplete = !hasMore && knownTotal && rows.length != result.total;
      if (!current()) throw const UiWorkCancelled();
      pipeline?.throwIfFailed();
      if (onPage != null) await onPage(result);
      if (!current()) throw const UiWorkCancelled();
      onBatch?.call(
        List<T>.unmodifiable(rows),
        result.total,
        hasMore || incomplete,
      );
      if (incomplete) {
        throw ApiException('SNAPSHOT_CHANGED', '数据在读取期间已变化，请刷新后重新读取完整结果');
      }
      pipeline?.accepted();
      if (hasMore && !provisionalPublished && onProvisionalBatch != null) {
        // Only the first validated batch is published; the complete result
        // replaces it. The server's exact total rides along unchanged.
        provisionalPublished = true;
        onProvisionalBatch(
          first.withRows(
            List<T>.of(rows),
            page: 1,
            size: rows.length,
            total: knownTotal ? result.total : rows.length,
            totalPages: 1,
          ),
        );
        if (!current()) throw const UiWorkCancelled();
      }
      if (!hasMore) {
        work.ensureCurrent();
        final combined = await first.withRowsFromResponsive(
          rows,
          total: knownTotal ? result.total : rows.length,
          totalPages: rows.isEmpty ? 0 : 1,
          budget: work,
        );
        if (!current()) throw const UiWorkCancelled();
        return combined;
      }
      page++;
    }
    throw const UiWorkCancelled();
  } finally {
    pipeline?.close();
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
  UiWorkBudget? budget,
}) async {
  final parent = PagedReadIntent.currentRead;
  final activity = PagedReadIntent.currentActivity;
  final bootstrapAllowed = PagedReadIntent.allowsInactiveBootstrap;
  bool logicalCurrent() => isCurrent() && (parent?.call() ?? true);
  bool current() => logicalCurrent() && (activity?.call() ?? true);
  final work = budget ?? UiWorkBudget(isCurrent: current);
  final rows = <R>[];
  final identities = <Object>{};
  final cursors = <PagedReadQueryKey>{};
  C? cursor;
  late S first;
  var hasFirst = false;
  Object? firstRevision;
  while (logicalCurrent()) {
    if (!current() && !(!hasFirst && bootstrapAllowed)) {
      throw const UiWorkCancelled();
    }
    if (current()) work.ensureCurrent();
    final response = await PagedReadIntent.scopedRead(
      logicalCurrent,
      () => loadPage(cursor, 100),
      bootstrap: !hasFirst,
    );
    if (!current()) throw const UiWorkCancelled();
    if (!hasFirst) {
      first = response;
      hasFirst = true;
      firstRevision = freezePagedReadQuery(revisionOf?.call(response));
    } else if (revisionOf != null &&
        !samePagedReadQuery(firstRevision, revisionOf(response))) {
      throw ApiException('SNAPSHOT_CHANGED', '历史读取范围已变化，请刷新后重新核对');
    }
    final batch = rowsOf(response);
    final next = nextCursorOf(response);
    if (next != null &&
        (batch.isEmpty ||
            samePagedReadQuery(next, cursor) ||
            !cursors.add(PagedReadQueryKey(next)))) {
      throw ApiException('INVALID_PAGINATION', '历史游标未前进，请刷新后重新读取完整记录');
    }
    for (final row in batch) {
      if (idOf != null) {
        final identity = idOf(row);
        if (identity == null || identity == '') {
          throw ApiException('SNAPSHOT_CHANGED', '历史记录身份缺失或重复，请刷新后重新核对');
        }
        if (!identities.add(identity)) {
          if (!deduplicateOverlaps) {
            throw ApiException('SNAPSHOT_CHANGED', '历史记录身份缺失或重复，请刷新后重新核对');
          }
          await work.checkpoint();
          if (!current()) throw const UiWorkCancelled();
          continue;
        }
      }
      rows.add(row);
      await work.checkpoint();
      if (!current()) throw const UiWorkCancelled();
    }
    if (!current()) throw const UiWorkCancelled();
    onBatch?.call(List<R>.unmodifiable(rows), next != null);
    if (next == null) {
      final combined = rebuildSnapshot(first, List<R>.unmodifiable(rows));
      if (!current()) throw const UiWorkCancelled();
      return combined;
    }
    cursor = next;
  }
  throw const UiWorkCancelled();
}

/// At most four active/completed pages are retained. Scheduling is independent
/// of scroll and publishes no rows; the original complete validator owns order.
class _CompletePagePipeline<T> {
  _CompletePagePipeline({
    required this.isCurrent,
    required this.loadPage,
    required this.batchSize,
    required this.maximum,
    required this.idOf,
  });
  final bool Function() isCurrent;
  final Future<PagedResult<T>> Function(int) loadPage;
  final int batchSize, maximum;
  final Object? Function(T row) idOf;
  final _waiting = <int, Future<_CompletePageReply<T>>>{};
  final _identityPages = <Object, int>{};
  final _validatedIdentityPages = <int>{};
  PagedResult<T>? _first;
  VersionedPagedResultProof? _firstProof;
  _CompletePageReply<T>? _failure;
  Completer<_CompletePageReply<T>>? _reader;
  int _next = 2, _last = 0;
  bool _closed = false;
  bool _networkCurrent() => !_closed && _failure == null && isCurrent();

  void validate(PagedResult<T> value, int expectedPage) {
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
    final pages = value.total == 0 ? 0 : 1 + (value.total - 1) ~/ batchSize;
    final remaining = value.total - (expectedPage - 1) * batchSize;
    final expectedRows = remaining <= 0
        ? 0
        : remaining < batchSize
        ? remaining
        : batchSize;
    if (value.total < 0 ||
        value.page != expectedPage ||
        value.size != batchSize ||
        value.totalPages != pages ||
        value.items.length != expectedRows) {
      throw ApiException('INVALID_PAGINATION', '完整列表并发批次不完整，请重新读取');
    }
    final first = _first;
    if (first == null) {
      _first = value;
      _firstProof = proof;
      _last = value.totalPages;
    } else {
      if (first.readScopeVersion != value.readScopeVersion) {
        throw ApiException(
          'READ_SCOPE_CHANGED',
          '数据访问范围已变化，请重新读取',
          httpStatus: 403,
        );
      }
      if (first.total != value.total ||
          first.totalPages != value.totalPages ||
          _firstProof!.readSnapshotRevision != proof.readSnapshotRevision ||
          _firstProof!.readDataVersion != proof.readDataVersion) {
        throw ApiException('SNAPSHOT_CHANGED', '数据已变化，请重新读取完整列表');
      }
    }
    if (_validatedIdentityPages.add(expectedPage)) {
      final pageIdentities = <Object>{};
      for (final row in value.items) {
        final identity = idOf(row);
        if (identity == null ||
            identity is String && identity.trim().isEmpty ||
            !pageIdentities.add(identity) ||
            _identityPages.containsKey(identity)) {
          throw ApiException('SNAPSHOT_CHANGED', '记录身份缺失或重复，请重新读取完整列表');
        }
      }
      for (final identity in pageIdentities) {
        _identityPages[identity] = expectedPage;
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
    while (_networkCurrent() && _waiting.length < maximum && _next <= _last) {
      final page = _next++;
      _waiting[page] = _read(page);
    }
  }

  Future<_CompletePageReply<T>> _read(int page) async {
    try {
      if (!_networkCurrent()) throw const UiWorkCancelled();
      final result = await PagedReadIntent.scopedRead(
        _networkCurrent,
        () => loadPage(page),
      );
      throwIfFailed();
      if (!_networkCurrent()) throw const UiWorkCancelled();
      validate(result, page);
      return _CompletePageReply.value(result);
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

  Future<PagedResult<T>> take(int page) async {
    throwIfFailed();
    final pending = _waiting.remove(page);
    if (pending == null) throw StateError('Complete page was not scheduled');
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
      return reply.value!;
    } finally {
      if (identical(_reader, reader)) _reader = null;
    }
  }

  void close() {
    _closed = true;
  }
}

class _CompletePageReply<T> {
  _CompletePageReply.value(this.value) : error = null, stack = null;
  _CompletePageReply.error(this.error, this.stack) : value = null;
  final PagedResult<T>? value;
  final Object? error;
  final StackTrace? stack;
}

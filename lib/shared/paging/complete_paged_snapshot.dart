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
  Object? Function(T row)? idOf,
  void Function(List<T> rows, int total, bool hasMore)? onBatch,
  FutureOr<void> Function(PagedResult<T> page)? onPage,
  bool requireStableTotal = true,
  bool allowUnknownTotal = false,
  bool unknownPageCountIsHorizon = false,
  bool deduplicateOverlaps = false,
  UiWorkBudget? budget,
}) async {
  if (batchSize < 1 || batchSize > 1000) {
    throw RangeError.range(batchSize, 1, 1000, 'batchSize');
  }
  final parent = PagedReadIntent.currentRead;
  final activity = PagedReadIntent.currentActivity;
  final bootstrapAllowed = PagedReadIntent.allowsInactiveBootstrap;
  bool logicalCurrent() => isCurrent() && (parent?.call() ?? true);
  bool current() => logicalCurrent() && (activity?.call() ?? true);
  final work = budget ?? UiWorkBudget(isCurrent: current);
  final rows = <T>[];
  final identities = <Object, int>{};
  PagedResult<T>? first;
  Object? firstRevision;
  var page = 1;
  while (logicalCurrent()) {
    if (!current() && !(page == 1 && bootstrapAllowed)) {
      throw const UiWorkCancelled();
    }
    if (current()) work.ensureCurrent();
    final result = await PagedReadIntent.scopedRead(
      logicalCurrent,
      () => loadPage(page, batchSize),
      bootstrap: page == 1,
    );
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
      if (idOf != null) {
        final identity = idOf(row);
        if (identity == null || identity == '') {
          throw ApiException('SNAPSHOT_CHANGED', '记录身份缺失或分页发生变化，请刷新后核对完整结果');
        }
        final previous = identities[identity];
        if (previous != null) {
          if (!deduplicateOverlaps) {
            throw ApiException('SNAPSHOT_CHANGED', '记录身份重复或分页发生变化，请刷新后核对完整结果');
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

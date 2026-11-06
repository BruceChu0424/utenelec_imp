import 'dart:async';

import '../../core/network/api_exception.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/performance/ui_work_budget.dart';
import '../models/paged_result.dart';
import '../paging/complete_paged_snapshot.dart';
import '../paging/paged_read_intent.dart';
import '../paging/read_view_activity.dart';
import 'package:flutter/widgets.dart';

class DraftReadSnapshot<T> {
  const DraftReadSnapshot({
    this.rows = const [],
    this.complete = false,
    this.error,
  });

  final List<T> rows;
  final bool complete;
  final Object? error;
  bool get loading => !complete && error == null;
}

/// One provider-owned read supplies both progressive rows and full completion.
/// No other consumer drains pages or maintains a second result cache.
class DraftWorkspaceRead<T> {
  DraftWorkspaceRead(
    this._load, {
    this.keyOf,
    this.ownerCurrent,
    void Function()? onResume,
  }) : _activity = ReadViewActivity(onResume: onResume) {
    // A table may consume snapshots without awaiting these two futures.
    unawaited(
      firstPage.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(
      _completion.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  factory DraftWorkspaceRead.fromRows(List<T> rows) {
    final read = DraftWorkspaceRead<T>((owner) async => owner.addRows(rows));
    read.start();
    return read;
  }

  final Future<void> Function(DraftWorkspaceRead<T> owner) _load;
  final Object Function(T row)? keyOf;
  final bool Function()? ownerCurrent;
  final ReadViewActivity _activity;
  DraftWorkspaceRead<T>? _backgroundRecovery;
  Future<List<T>>? _backgroundCompletion;
  bool _backgroundPending = false;
  int _readGeneration = 0;
  bool Function()? _lastReadActivity;
  final _keys = <Object>{};
  final _updates = StreamController<DraftReadSnapshot<T>>.broadcast();
  final _firstPage = Completer<void>();
  final _completion = Completer<List<T>>();
  DraftReadSnapshot<T> _snapshot = DraftReadSnapshot<T>();
  bool _started = false;
  bool _disposed = false;

  DraftReadSnapshot<T> get snapshot => _snapshot;
  Future<void> get firstPage => _firstPage.future;
  Future<List<T>> get completion {
    if (!current) {
      return Future.error(ApiException('READ_SCOPE_CHANGED', '草稿读取范围已变化'));
    }
    final previous = _backgroundCompletion;
    if (previous != null &&
        (_backgroundPending || (_lastReadActivity?.call() ?? true))) {
      return previous;
    }
    final release = _activity.retainBackground();
    _backgroundPending = true;
    final future = () async {
      try {
        if (_lastReadActivity?.call() != false) {
          try {
            return await _completion.future;
          } catch (error) {
            if (!isRetiredViewRead(error) || !current) rethrow;
          }
        }
        // Background demand acquired after departure cannot revive an old
        // visibility ticket. Start a fresh bounded read under this same
        // logical family owner, with no abandoned UI request attached.
        _readGeneration++;
        return await AuthenticatedRequestScope.sharedRead(
          () => current,
          () => _activity.runRead(() => current, () async {
            _lastReadActivity = PagedReadIntent.currentActivity;
            final fresh = DraftWorkspaceRead<T>(
              _load,
              keyOf: keyOf,
              ownerCurrent: () => current,
            );
            _backgroundRecovery = fresh;
            fresh.start();
            try {
              final rows = await fresh._completion.future;
              _requireCurrent();
              _keys.clear();
              if (keyOf case final identify?) _keys.addAll(rows.map(identify));
              _publish(DraftReadSnapshot(rows: rows, complete: true));
              return rows;
            } finally {
              fresh.dispose();
              if (identical(_backgroundRecovery, fresh)) {
                _backgroundRecovery = null;
              }
            }
          }),
        );
      } finally {
        _backgroundPending = false;
        release();
      }
    }();
    _backgroundCompletion = future;
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  bool get current {
    if (_disposed) return false;
    try {
      return ownerCurrent?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  void bindView(BuildContext context) => _activity.bindView(context);

  Stream<DraftReadSnapshot<T>> get snapshots => Stream.multi((events) {
    // Subscribe before reading the current snapshot, so a completed first page
    // can never be lost between the initial value and the live subscription.
    final subscription = _updates.stream.listen(
      events.add,
      onError: events.addError,
      onDone: events.close,
    );
    events.add(_snapshot);
    events.onCancel = subscription.cancel;
  });

  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    final generation = ++_readGeneration;
    try {
      await AuthenticatedRequestScope.sharedRead(
        () => current,
        () => _activity.runRead(() => current, () async {
          _lastReadActivity = PagedReadIntent.currentActivity;
          await _load(this);
          _requireCurrent();
          _publish(DraftReadSnapshot(rows: _snapshot.rows, complete: true));
          if (!_firstPage.isCompleted) _firstPage.complete();
          _completion.complete(_snapshot.rows);
        }),
      );
    } catch (error, stack) {
      if (!_disposed && generation == _readGeneration) {
        _publish(DraftReadSnapshot(rows: _snapshot.rows, error: error));
      }
      if (!_firstPage.isCompleted) _firstPage.completeError(error, stack);
      if (!_completion.isCompleted) _completion.completeError(error, stack);
    }
  }

  /// The server's page identity and completeness checks remain authoritative.
  /// Each validated page is projected before requesting the next one.
  Future<void> loadPages<R>(
    Future<PagedResult<R>> Function(int page) fetch,
    Future<List<T>> Function(List<R> rows) project,
  ) async {
    await loadCompletePagedResult<R>(
      loadPage: (page, size) => fetch(page),
      isCurrent: () => current,
      onPage: (response) async {
        _requireCurrent();
        final projected = await project(response.items);
        _requireCurrent();
        addRows(projected);
        if (!_firstPage.isCompleted) _firstPage.complete();
      },
    );
  }

  void addRows(List<T> rows) {
    _requireCurrent();
    if (keyOf case final identify?) {
      final keys = rows.map(identify).toList();
      if (keys.toSet().length != keys.length || keys.any(_keys.contains)) {
        throw ApiException('INCOMPLETE_DRAFT_LIST', '草稿分页发生变化，请刷新后核对完整列表');
      }
      _keys.addAll(keys);
    }
    _publish(
      DraftReadSnapshot(rows: List.unmodifiable([..._snapshot.rows, ...rows])),
    );
  }

  void _publish(DraftReadSnapshot<T> value) {
    _snapshot = value;
    _updates.add(value);
  }

  void _requireCurrent() {
    if (!current) throw ApiException('READ_SCOPE_CHANGED', '草稿读取范围已变化');
    if (PagedReadIntent.currentActivity?.call() == false) {
      throw const UiWorkCancelled();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activity.dispose();
    _backgroundRecovery?.dispose();
    final error = ApiException('READ_SCOPE_CHANGED', '草稿读取范围已变化');
    if (!_firstPage.isCompleted) _firstPage.completeError(error);
    if (!_completion.isCompleted) _completion.completeError(error);
    unawaited(_updates.close());
  }
}

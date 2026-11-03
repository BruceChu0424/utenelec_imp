import 'dart:async';

import 'paged_query_identity.dart';
import 'prepared_page_read.dart';

/// Schedules a category's explicit first-page preparations without owning rows,
/// widgets or business filters. Keep this coordinator alive while an old
/// transport is running; retire only its waiting jobs on a reader/write change.
class PagePreparationCoordinator {
  PagePreparationCoordinator({
    this.maximumConcurrent = 2,
    this.freshFor = PreparedPageRead.defaultFreshFor,
    PagePreparationBudget? budget,
  }) : assert(maximumConcurrent > 0),
       _budget =
           budget ??
           PagePreparationBudget(maximumConcurrent: maximumConcurrent);

  final int maximumConcurrent;
  final Duration freshFor;
  final PagePreparationBudget _budget;
  PagedReadQueryKey? _scope;
  int _active = 0;
  bool _disposed = false;
  final _waiting = <Future<void> Function()>[];
  bool Function()? _canPrepare;
  final _batchAge = Stopwatch();
  int _generation = 0;

  bool get _visible {
    try {
      return _canPrepare?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  void prepare(
    Object scope,
    Iterable<Future<void> Function()> jobs, {
    required bool Function() canPrepare,
  }) {
    _canPrepare = canPrepare;
    if (_disposed) return;
    final key = PagedReadQueryKey(scope);
    if (_scope == key &&
        (_active > 0 || _waiting.isNotEmpty || _batchAge.elapsed < freshFor)) {
      _drain();
      return;
    }
    _scope = key;
    _generation++;
    _batchAge
      ..reset()
      ..start();
    _waiting
      ..clear()
      ..addAll(jobs);
    // Register in-flight handoffs before post-frame badge auto-selection.
    _drain();
  }

  void _drain() {
    while (!_disposed &&
        _active < maximumConcurrent &&
        _waiting.isNotEmpty &&
        _visible) {
      final job = _waiting.removeAt(0);
      final generation = _generation;
      _active++;
      unawaited(
        _budget
            .run(
              job,
              isCurrent: () =>
                  !_disposed && generation == _generation && _visible,
            )
            .then((dispatched) {
              if (!dispatched &&
                  !_disposed &&
                  !_budget._disposed &&
                  generation == _generation) {
                // Visibility may change while this job waits for another
                // module's transport. Keep it available for same-category resume.
                _waiting.insert(0, job);
              }
            })
            .catchError((Object _) {})
            .whenComplete(() {
              _active--;
              _drain();
            }),
      );
    }
  }

  void retire() {
    _generation++;
    _scope = null;
    _waiting.clear();
  }

  void dispose() {
    _disposed = true;
    retire();
  }
}

/// A physical budget shared by category coordinators in the same app scope.
/// Stale waiting jobs are skipped; already dispatched transports keep their
/// slot until completion even when the user navigates to another module.
class PagePreparationBudget {
  PagePreparationBudget({this.maximumConcurrent = 2})
    : assert(maximumConcurrent > 0);
  final int maximumConcurrent;
  final _waiting = <_PreparationJob>[];
  int _active = 0;
  bool _disposed = false;

  Future<bool> run(
    Future<void> Function() fetch, {
    required bool Function() isCurrent,
  }) {
    if (_disposed) return Future.value(false);
    // Repeated open/close cycles must not accumulate closures behind a slow
    // transport. Complete retired waiters before adding the successor batch.
    _waiting.removeWhere((job) {
      if (job.current) return false;
      job.done.complete(false);
      return true;
    });
    final job = _PreparationJob(fetch, isCurrent);
    _waiting.add(job);
    _drain();
    return job.done.future;
  }

  void _drain() {
    while (!_disposed && _active < maximumConcurrent && _waiting.isNotEmpty) {
      final job = _waiting.removeAt(0);
      if (!job.current) {
        job.done.complete(false);
        continue;
      }
      _active++;
      unawaited(
        Future<void>.sync(job.fetch)
            .then(
              (_) => job.done.complete(true),
              onError: job.done.completeError,
            )
            .whenComplete(() {
              _active--;
              _drain();
            }),
      );
    }
  }

  void dispose() {
    _disposed = true;
    for (final job in _waiting) {
      job.done.complete(false);
    }
    _waiting.clear();
  }
}

class _PreparationJob {
  _PreparationJob(this.fetch, this.isCurrent);
  final Future<void> Function() fetch;
  final bool Function() isCurrent;
  final done = Completer<bool>();
  bool get current {
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }
}

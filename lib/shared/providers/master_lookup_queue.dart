import 'dart:async';
import 'dart:collection';

/// Bounded auxiliary reads shared by all callers of one session's dictionary.
/// Repeated IDs join an in-flight request; failures leave them retryable.
class MasterLookupQueue {
  MasterLookupQueue({
    required this.fetch,
    required this.batchSize,
    this.maxConcurrent = 4,
  }) : assert(batchSize > 0),
       assert(maxConcurrent > 0);

  final Future<void> Function(List<String>) fetch;
  final int batchSize;
  final int maxConcurrent;
  final _pending = <String, Future<void>>{};
  final _queue = Queue<(List<String>, Completer<void>)>();
  final _running = <Completer<void>>{};
  int _active = 0;
  bool _disposed = false;

  Future<void> load(Iterable<String> ids) {
    if (_disposed) return Future.error(StateError('名称读取作用域已结束'));
    final waits = <Future<void>>{};
    final missing = <String>[];
    for (final id in ids.toSet()) {
      final pending = _pending[id];
      if (pending != null) {
        waits.add(pending);
      } else {
        missing.add(id);
      }
    }
    for (var start = 0; start < missing.length; start += batchSize) {
      final batch = missing.sublist(
        start,
        (start + batchSize).clamp(0, missing.length),
      );
      final completion = Completer<void>();
      for (final id in batch) {
        _pending[id] = completion.future;
      }
      waits.add(completion.future);
      _queue.add((batch, completion));
    }
    final result = Future.wait(waits);
    _drain();
    return result;
  }

  void _drain() {
    while (!_disposed && _active < maxConcurrent && _queue.isNotEmpty) {
      final (batch, completion) = _queue.removeFirst();
      _active++;
      _running.add(completion);
      unawaited(_run(batch, completion));
    }
  }

  Future<void> _run(List<String> batch, Completer<void> completion) async {
    try {
      await fetch(batch);
      if (!completion.isCompleted) completion.complete();
    } catch (error, stack) {
      if (!completion.isCompleted) completion.completeError(error, stack);
    } finally {
      for (final id in batch) {
        _pending.remove(id);
      }
      _active--;
      _running.remove(completion);
      _drain();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final completions = {..._running, ..._queue.map((item) => item.$2)};
    _queue.clear();
    _pending.clear();
    for (final completion in completions) {
      if (!completion.isCompleted) {
        completion.completeError(StateError('名称读取作用域已结束'));
      }
    }
  }
}

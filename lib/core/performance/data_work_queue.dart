import 'dart:async';
import 'dart:collection';
import 'ui_work_budget.dart';

/// One CPU-work admission point shared by large JSON and data codecs. Bursts
/// must not spawn an isolate per response and trigger isolate-group GC stalls.
/// Valid work is FIFO and never dropped; only its owning caller can retire it.
class DataWorkQueue {
  DataWorkQueue({this.parallelism = 2}) : assert(parallelism > 0);
  final int parallelism;
  final _pending = LinkedList<_WorkNode>();
  _WorkNode? _pruneCursor;
  Timer? _pruner;
  int _active = 0;
  bool _scheduled = false;
  void Function(int active, int pending)? onPressure;
  final _clock = Stopwatch()..start();
  int _lastPressure = -1000;
  int get active => _active;
  int get pending => _pending.length;

  Future<T> run<T>(
    Future<T> Function() operation, {
    bool Function()? isCurrent,
  }) {
    final job = _TypedWork<T>(operation, isCurrent);
    _pending.add(_WorkNode(job));
    if (_pending.length >= 16 &&
        _clock.elapsedMilliseconds - _lastPressure >= 1000) {
      _lastPressure = _clock.elapsedMilliseconds;
      try {
        onPressure?.call(_active, _pending.length);
      } catch (_) {
        /* Telemetry must not alter work. */
      }
    }
    _schedule();
    _ensurePruner();
    return job.completion.future;
  }

  void _schedule({bool yieldToInput = false}) {
    if (_scheduled) return;
    _scheduled = true;
    if (yieldToInput) {
      Timer.run(_pump);
    } else {
      scheduleMicrotask(_pump);
    }
  }

  void _pump() {
    _scheduled = false;
    var retired = 0;
    while (_active < parallelism && _pending.isNotEmpty) {
      final node = _pending.first;
      final job = node.work;
      _remove(node);
      if (!job.admit()) {
        if (++retired >= 64) {
          _schedule(yieldToInput: true);
          break;
        }
        continue;
      }
      _active++;
      unawaited(
        job.perform().whenComplete(() {
          _active--;
          _schedule();
        }),
      );
    }
    _ensurePruner();
  }

  void _remove(_WorkNode node) {
    if (identical(_pruneCursor, node)) _pruneCursor = node.next;
    node.unlink();
    if (_pending.isEmpty) {
      _pruner?.cancel();
      _pruner = null;
      _pruneCursor = null;
    }
  }

  void _ensurePruner() {
    if (_pending.isEmpty || _active < parallelism) {
      _pruner?.cancel();
      _pruner = null;
      return;
    }
    if (_pruner != null) return;
    _pruner = Timer(Duration.zero, _pruneRetired);
  }

  void _pruneRetired() {
    _pruner = null;
    var node = _pruneCursor ?? (_pending.isEmpty ? null : _pending.first);
    for (var i = 0; i < 64 && node != null; i++) {
      final next = node.next;
      if (!node.work.admit()) _remove(node);
      node = next;
    }
    _pruneCursor = node;
    if (_pending.isNotEmpty && _active >= parallelism) {
      _pruner = Timer(
        node == null ? const Duration(milliseconds: 16) : Duration.zero,
        _pruneRetired,
      );
    }
  }
}

final class _WorkNode extends LinkedListEntry<_WorkNode> {
  _WorkNode(this.work);
  final _Work work;
}

abstract class _Work {
  bool admit();
  Future<void> perform();
}

class _TypedWork<T> implements _Work {
  _TypedWork(this.operation, this.isCurrent);
  final Future<T> Function() operation;
  final bool Function()? isCurrent;
  final completion = Completer<T>();
  @override
  bool admit() {
    try {
      if (isCurrent?.call() == false) throw const UiWorkCancelled();
      return true;
    } catch (error, stack) {
      completion.completeError(error, stack);
      return false;
    }
  }

  @override
  Future<void> perform() async {
    try {
      final result = await operation();
      if (isCurrent?.call() == false) throw const UiWorkCancelled();
      completion.complete(result);
    } catch (error, stack) {
      completion.completeError(error, stack);
    }
  }
}

final dataWorkQueue = DataWorkQueue();

import 'dart:async';

/// Runs tasks in arrival order without retaining a completed caller's zone.
///
/// The pending tail is a release signal, so a failed task cannot poison the
/// next one. An idle queue retains no Future from a retired execution context.
class SerialTaskQueue {
  Future<void>? _tail;

  Future<T> run<T>(Future<T> Function() action) async {
    final predecessor = _tail;
    final release = Completer<void>();
    _tail = release.future;
    try {
      // Keep the established asynchronous admission boundary. For an idle
      // queue this signal belongs to this invocation's live zone.
      await (predecessor ?? Future<void>.value());
      return await action();
    } finally {
      // A later waiter owns the tail until its own turn finishes.
      if (identical(_tail, release.future)) _tail = null;
      release.complete();
    }
  }
}

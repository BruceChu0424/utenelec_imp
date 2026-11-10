import '../async/serial_task_queue.dart';

/// Serializes staff token refreshes inside a non-Web process.
///
/// Instances are shared by scope so multiple Dio/AuthInterceptor instances use
/// the same queue. Web uses the same API with cross-tab coordination.
class AuthRefreshLock {
  // The Web-only capability requirement does not apply to a native process.
  // ignore: avoid_unused_constructor_parameters
  factory AuthRefreshLock(String scope, {bool requireWebLocks = false}) =>
      _locks.putIfAbsent(scope, AuthRefreshLock._);

  AuthRefreshLock._();

  static final Map<String, AuthRefreshLock> _locks =
      <String, AuthRefreshLock>{};

  final _operations = SerialTaskQueue();

  static final _scoped = <String, _ScopedRefreshLock>{};

  /// Dynamic owners borrow a lock only until all their queued operations finish.
  /// Fixed staff/record owners continue using the existing cached factory.
  static Future<T> runScoped<T>(
    String scope,
    Future<T> Function() action, {
    bool requireWebLocks = false,
  }) async {
    final entry = _scoped.putIfAbsent(
      scope,
      () => _ScopedRefreshLock(AuthRefreshLock._()),
    );
    entry.users++;
    try {
      return await entry.lock.synchronized(action);
    } finally {
      if (--entry.users == 0 && identical(_scoped[scope], entry)) {
        _scoped.remove(scope);
      }
    }
  }

  Future<T> synchronized<T>(Future<T> Function() action) =>
      _operations.run(action);
}

class _ScopedRefreshLock {
  _ScopedRefreshLock(this.lock);
  final AuthRefreshLock lock;
  int users = 0;
}

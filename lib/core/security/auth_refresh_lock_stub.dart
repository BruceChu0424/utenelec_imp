import 'dart:async';

/// Serializes staff token refreshes inside a non-Web process.
///
/// Instances are shared by scope so multiple Dio/AuthInterceptor instances use
/// the same queue. Web uses the same API with cross-tab coordination.
class AuthRefreshLock {
  factory AuthRefreshLock(String scope) =>
      _locks.putIfAbsent(scope, AuthRefreshLock._);

  AuthRefreshLock._();

  static final Map<String, AuthRefreshLock> _locks =
      <String, AuthRefreshLock>{};

  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) async {
    final predecessor = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await predecessor;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }
}

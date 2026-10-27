import '../async/serial_task_queue.dart';

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

  final _operations = SerialTaskQueue();

  Future<T> synchronized<T>(Future<T> Function() action) =>
      _operations.run(action);
}

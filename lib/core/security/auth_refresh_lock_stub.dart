import 'dart:async';

/// Non-sensitive notification that the authoritative staff token record moved
/// to another generation. Tokens are deliberately never included.
class AuthTokenChangeNotice {
  const AuthTokenChangeNotice({
    required this.origin,
    required this.generation,
    required this.intentGeneration,
    required this.sessionLineage,
    required this.hasTokens,
  });

  final String origin;
  final int generation;
  final int intentGeneration;
  final String? sessionLineage;
  final bool hasTokens;
}

/// Same-isolate counterpart of the Web BroadcastChannel change bus.
class AuthTokenChangeBus {
  factory AuthTokenChangeBus(String scope) =>
      _buses.putIfAbsent(scope, AuthTokenChangeBus._);

  AuthTokenChangeBus._();

  static final Map<String, AuthTokenChangeBus> _buses =
      <String, AuthTokenChangeBus>{};

  final StreamController<AuthTokenChangeNotice> _controller =
      StreamController<AuthTokenChangeNotice>.broadcast();

  Stream<AuthTokenChangeNotice> get changes => _controller.stream;

  void publish(AuthTokenChangeNotice notice) {
    if (!_controller.isClosed) _controller.add(notice);
  }
}

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

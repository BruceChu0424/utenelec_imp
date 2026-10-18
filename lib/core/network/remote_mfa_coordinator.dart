typedef RemoteMfaPrompter = Future<String?> Function();

/// Concurrent failures share one prompt. It never owns/replays a request.
class RemoteMfaCoordinator {
  RemoteMfaCoordinator({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  static final instance = RemoteMfaCoordinator();
  final DateTime Function() _clock;
  RemoteMfaPrompter? _prompter;
  Object? Function()? _context;
  Future<String?>? _pending;
  DateTime? _dismissedAt;
  Object? _dismissedContext;
  void Function() register(
    RemoteMfaPrompter prompter, {
    Object? Function()? context,
  }) {
    _prompter = prompter;
    _context = context;
    return () {
      if (identical(_prompter, prompter)) {
        _prompter = null;
        _context = null;
      }
    };
  }

  Object? captureContext() => _context?.call();
  bool matchesContext(Object? context) =>
      _context == null || context == _context?.call();

  Future<String?> obtain() {
    if (_pending != null) return _pending!;
    final prompt = _prompter;
    if (prompt == null) return Future.value();
    final context = captureContext();
    if (_dismissedAt != null &&
        _dismissedContext == context &&
        _clock().difference(_dismissedAt!) < const Duration(seconds: 30)) {
      return Future.value();
    }
    late final Future<String?> next;
    next = Future<String?>.sync(prompt)
        .then((message) {
          if (message == null) {
            _dismissedAt = _clock();
            _dismissedContext = context;
          } else {
            _dismissedAt = null;
            _dismissedContext = null;
          }
          return message;
        })
        .whenComplete(() {
          if (identical(_pending, next)) _pending = null;
        });
    _pending = next;
    return next;
  }
}

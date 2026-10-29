import 'dart:async';

import 'package:dio/dio.dart';

import '../web_update/web_update_safety.dart';
import 'api_exception.dart';

/// One application-wide fence, including overlapping calls and auth/step-up retries.
/// An ambiguous command stays blocked for this app instance; an unrelated success
/// cannot prove that the earlier command did or did not commit.
final apiMutationReloadSafety = ApiMutationReloadSafety();

class ApiMutationReloadSafety {
  ApiMutationReloadSafety({WebUpdateSafetyRegistry? registry})
    : _registry = registry ?? webUpdateSafety;

  final WebUpdateSafetyRegistry _registry;
  int _pending = 0;
  int _reads = 0;
  bool _uncertain = false;

  int get pendingCount => _pending;
  int get pendingReadCount => _reads;
  bool get hasUncertainCommit => _uncertain;

  WebUpdateSafetyState get state => WebUpdateSafetyState(
    busy: _pending > 0 || _reads > 0,
    blocked: _uncertain,
  );

  Future<T> track<T>(Future<T> Function() command) async {
    _pending++;
    // Re-registering also preserves protection after a registry host is replaced.
    _registry.register(this, () => state);
    _registry.changed();
    try {
      return await command();
    } catch (error) {
      if (!_definiteRejection(error)) _uncertain = true;
      rethrow;
    } finally {
      _pending--;
      _registry.changed();
    }
  }

  Future<T> trackRead<T>(Future<T> Function() read) async {
    final lease = beginRead();
    try {
      return await read();
    } finally {
      lease.complete();
    }
  }

  Stream<T> trackReadStream<T>(Stream<T> Function() read) async* {
    final lease = beginRead();
    try {
      yield* read();
    } finally {
      lease.complete();
    }
  }

  ApiReloadReadLease beginRead() {
    _reads++;
    _registry.register(this, () => state);
    _registry.changed();
    return ApiReloadReadLease._(() {
      _reads--;
      _registry.changed();
    });
  }

  static bool _definiteRejection(Object error) {
    if (error is ApiException &&
        const {
          'READ_SCOPE_CHANGED',
          'SESSION_CHANGED',
          'SESSION_STATE_UNAVAILABLE',
        }.contains(error.code)) {
      // These fences may reject a late response after the server committed.
      return false;
    }
    final status = switch (error) {
      ApiException() => error.httpStatus,
      DioException() => error.response?.statusCode,
      _ => null,
    };
    // Transport aborts, gateway failures, parsing errors and request timeouts
    // cannot establish the server transaction's outcome, even after disposal.
    return status != null &&
        status >= 400 &&
        status < 500 &&
        status != 408 &&
        status != 499;
  }
}

/// Response headers are not completion of an artifact download. Keep the read
/// owned until its body finishes/cancels; a pre-listen cancellation also retires it.
class ApiReloadReadLease {
  ApiReloadReadLease._(this._finish);
  final void Function() _finish;
  bool _completed = false;
  bool _listened = false;

  void complete() {
    if (_completed) return;
    _completed = true;
    _finish();
  }

  Stream<T> hold<T>(Stream<T> source, {Future<Object?>? cancelled}) {
    if (cancelled != null) {
      unawaited(
        cancelled.then((_) {
          if (!_listened) complete();
        }),
      );
    }
    return _hold(source);
  }

  Stream<T> _hold<T>(Stream<T> source) async* {
    _listened = true;
    try {
      yield* source;
    } finally {
      complete();
    }
  }
}

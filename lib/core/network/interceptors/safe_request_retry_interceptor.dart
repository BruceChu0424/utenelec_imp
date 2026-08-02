// The public `recovery` parameter intentionally initializes a private field.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:dio/dio.dart';

import '../connection_recovery.dart';

const _retryCountKey = 'utenSafeRetryCount';

typedef RetryDelay = Future<void> Function(Duration duration);

/// Only retries transient failures for GET/HEAD/OPTIONS.
///
/// Business writes are never replayed here, even if they carry an idempotency
/// key. This prevents a weak connection from duplicating an order, approval or
/// payment. Read retries keep the same request/audit operation id.
class SafeRequestRetryInterceptor extends Interceptor {
  SafeRequestRetryInterceptor(
    this._dio, {
    this.maxRetries = 2,
    ConnectionRecoveryController? recovery,
    RetryDelay? delay,
  }) : _recovery = recovery,
       _delay = delay ?? Future<void>.delayed;

  final Dio _dio;
  final int maxRetries;
  final ConnectionRecoveryController? _recovery;
  final RetryDelay _delay;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _recovery?.markConnected();
    handler.next(response);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (!shouldRetrySafeRequest(err, maxRetries: maxRetries)) {
      _recordFinalReachability(err);
      handler.next(err);
      return;
    }

    final options = err.requestOptions;
    final attempts = (options.extra[_retryCountKey] as int?) ?? 0;
    options.extra[_retryCountKey] = attempts + 1;
    if (isTransientConnectivityFailure(err)) {
      _recovery?.markRetrying(attempts + 1);
    }
    await _delay(retryDelayForAttempt(attempts));

    if (options.cancelToken?.isCancelled == true) {
      handler.next(err);
      return;
    }

    try {
      handler.resolve(await _dio.fetch<dynamic>(options));
    } on DioException catch (retryError) {
      _recordFinalReachability(retryError);
      handler.next(retryError);
    } catch (_) {
      _recordFinalReachability(err);
      handler.next(err);
    }
  }

  void _recordFinalReachability(DioException error) {
    if (isStructuredServiceUnavailable(error)) {
      // The HTTP service is reachable. Do not turn an auth/permission resolver
      // outage into the global health-probe/recoveryEpoch loop.
      _recovery?.markConnected();
      return;
    }
    if (isTransientConnectivityFailure(error)) {
      _recovery?.markDisconnected();
    } else if (error.response != null) {
      _recovery?.markConnected();
    }
  }
}

Duration retryDelayForAttempt(int completedRetries) =>
    switch (completedRetries) {
      0 => const Duration(milliseconds: 400),
      _ => const Duration(milliseconds: 1200),
    };

bool shouldRetrySafeRequest(DioException error, {int maxRetries = 2}) {
  final options = error.requestOptions;
  final attempts = (options.extra[_retryCountKey] as int?) ?? 0;
  if (attempts >= maxRetries || options.cancelToken?.isCancelled == true) {
    return false;
  }

  final method = options.method.toUpperCase();
  if (method != 'GET' && method != 'HEAD' && method != 'OPTIONS') return false;

  return isTransientConnectivityFailure(error) ||
      isStructuredServiceUnavailable(error);
}

/// A backend-generated resolver outage is retriable for safe reads, but it is
/// not evidence that the host or network is unreachable.
bool isStructuredServiceUnavailable(DioException error) {
  if (error.response?.statusCode != 503) return false;
  final data = error.response?.data;
  return data is Map && data['code'] == 'SERVICE_UNAVAILABLE';
}

bool isTransientConnectivityFailure(DioException error) {
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.connectionError) {
    return true;
  }

  final status = error.response?.statusCode;
  if (status == 503 && isStructuredServiceUnavailable(error)) return false;
  return status == 408 || status == 502 || status == 503 || status == 504;
}

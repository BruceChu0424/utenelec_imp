// The public `recovery` parameter intentionally initializes a private field.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../connection_recovery.dart';

const _retryCountKey = 'utenSafeRetryCount';
const safeRequestRetryDisabledKey = 'utenSafeRetryDisabled';

typedef RetryDelay = Future<void> Function(Duration duration);

/// Only retries unreachable-server failures for GET/HEAD/OPTIONS.
///
/// Business writes are never replayed here, even if they carry an idempotency
/// key. This prevents a weak connection from duplicating an order, approval or
/// payment. Read retries keep the same request/audit operation id.
///
/// 慢不等于断(ADR-108): 收发超时不重试、也不判定断网——重试只会把慢查询的
/// 服务端负载放大, 判断网还会触发整站恢复。只有连不上(连接失败; 原生端还有建连超时,
/// 见 [isTransientConnectivityFailure])与网关 502/503/504 才重试; 重试耗尽后只有这几类
/// 才标记断网并交给健康探针。
class SafeRequestRetryInterceptor extends Interceptor {
  SafeRequestRetryInterceptor(
    this._dio, {
    this.maxRetries = 2,
    ConnectionRecoveryController? recovery,
    RetryDelay? delay,
    this.web = kIsWeb,
  }) : _recovery = recovery,
       _delay = delay ?? Future<void>.delayed;

  final Dio _dio;
  final int maxRetries;
  final ConnectionRecoveryController? _recovery;
  final RetryDelay _delay;

  /// 运行在浏览器里(建连超时的含义不同, 见 [isTransientConnectivityFailure])。
  final bool web;

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
    if (!shouldRetrySafeRequest(err, maxRetries: maxRetries, web: web)) {
      _recordFinalReachability(err);
      handler.next(err);
      return;
    }

    final options = err.requestOptions;
    final attempts = (options.extra[_retryCountKey] as int?) ?? 0;
    options.extra[_retryCountKey] = attempts + 1;
    if (isTransientConnectivityFailure(err, web: web)) {
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
    if (isTransientConnectivityFailure(error, web: web)) {
      _recovery?.markDisconnected();
    } else if (error.response != null) {
      _recovery?.markConnected();
    }
    // 超时只让这一次请求失败(页面提示重试), 不代表断网, 不动全局连接状态。
  }
}

Duration retryDelayForAttempt(int completedRetries) =>
    switch (completedRetries) {
      0 => const Duration(milliseconds: 400),
      _ => const Duration(milliseconds: 1200),
    };

bool shouldRetrySafeRequest(
  DioException error, {
  int maxRetries = 2,
  bool web = kIsWeb,
}) {
  final options = error.requestOptions;
  if (options.extra[safeRequestRetryDisabledKey] == true) {
    return false;
  }
  final attempts = (options.extra[_retryCountKey] as int?) ?? 0;
  if (attempts >= maxRetries || options.cancelToken?.isCancelled == true) {
    return false;
  }

  final method = options.method.toUpperCase();
  if (method != 'GET' && method != 'HEAD' && method != 'OPTIONS') return false;

  return isTransientConnectivityFailure(error, web: web) ||
      isStructuredServiceUnavailable(error);
}

/// A backend-generated resolver outage is retriable for safe reads, but it is
/// not evidence that the host or network is unreachable.
bool isStructuredServiceUnavailable(DioException error) {
  if (error.response?.statusCode != 503) return false;
  final data = error.response?.data;
  return data is Map && data['code'] == 'SERVICE_UNAVAILABLE';
}

/// 服务端不可达的证据: 连接失败, 或网关报后端不可用(502/503/504)。
///
/// 收发超时刻意不算: 请求已发出、服务端可能正在处理或已提交, 重试会放大负载,
/// 判断网会触发整站恢复重拉(ADR-108)。建连超时分平台: 原生端(Windows 等桌面包)
/// 它是真实的 TCP 建连超时——局域网服务器宕机、网线断开时就是它, 请求根本没发出去,
/// 算连不上; Web 端它只是浏览器请求的计时器(请求可能早已到达服务端), 不算。
bool isTransientConnectivityFailure(DioException error, {bool web = kIsWeb}) {
  if (error.type == DioExceptionType.connectionError) return true;
  if (error.type == DioExceptionType.connectionTimeout && !web) return true;
  final status = error.response?.statusCode;
  if (status == 503 && isStructuredServiceUnavailable(error)) return false;
  return status == 502 || status == 503 || status == 504;
}

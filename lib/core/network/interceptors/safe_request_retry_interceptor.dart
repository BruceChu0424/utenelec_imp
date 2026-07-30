import 'dart:async';

import 'package:dio/dio.dart';

const _retryCountKey = 'utenSafeRetryCount';

/// 仅对 GET/HEAD/OPTIONS 的瞬时网络故障做一次短延迟重试。
///
/// 写请求即使携带幂等键也不在客户端自动重放，避免弱网下重复建单、付款或审批。
class SafeRequestRetryInterceptor extends Interceptor {
  SafeRequestRetryInterceptor(this._dio, {this.maxRetries = 1});

  final Dio _dio;
  final int maxRetries;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (!shouldRetrySafeRequest(err, maxRetries: maxRetries)) {
      handler.next(err);
      return;
    }

    final options = err.requestOptions;
    final attempts = (options.extra[_retryCountKey] as int?) ?? 0;
    options.extra[_retryCountKey] = attempts + 1;
    await Future<void>.delayed(Duration(milliseconds: 350 * (attempts + 1)));

    if (options.cancelToken?.isCancelled == true) {
      handler.next(err);
      return;
    }

    try {
      handler.resolve(await _dio.fetch<dynamic>(options));
    } on DioException catch (retryError) {
      handler.next(retryError);
    } catch (_) {
      handler.next(err);
    }
  }
}

bool shouldRetrySafeRequest(DioException error, {int maxRetries = 1}) {
  final options = error.requestOptions;
  final attempts = (options.extra[_retryCountKey] as int?) ?? 0;
  if (attempts >= maxRetries || options.cancelToken?.isCancelled == true) {
    return false;
  }

  final method = options.method.toUpperCase();
  if (method != 'GET' && method != 'HEAD' && method != 'OPTIONS') return false;

  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.connectionError) {
    return true;
  }

  final status = error.response?.statusCode;
  return status == 408 || status == 502 || status == 503 || status == 504;
}

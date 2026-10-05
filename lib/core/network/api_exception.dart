// 统一 API 异常（对应后端 ApiError：{code,message,fieldErrors}）。
// 文档：docs/05-架构/网络层与拦截器.md §8
import 'api_error.dart';

class ApiException implements Exception {
  ApiException(
    this.code,
    this.message, {
    this.fieldErrors,
    this.httpStatus,
    this.hasResponseCode = false,
  });

  /// 后端错误码（BAD_CREDENTIALS / ACCOUNT_LOCKED / ...）
  final String code;
  final String message;
  final List<ApiFieldError>? fieldErrors;

  /// Transport status is optional metadata; business codes retain their existing
  /// meaning. Long destructive commands need to distinguish gateway failures
  /// from a server response that explicitly rejected their transaction.
  final int? httpStatus;

  /// 错误码是否来自响应体里的统一错误格式 {code, message}。为假表示错误码是本端按
  /// 连接失败或 HTTP 状态兜底补的(例如网关 502/503/504 的错误页)：这类响应说明不了
  /// 服务端对这次请求做了什么。
  final bool hasResponseCode;

  factory ApiException.fromApiError(ApiError err, {int? httpStatus}) =>
      ApiException(
        err.code,
        err.message,
        fieldErrors: err.fieldErrors,
        httpStatus: httpStatus,
        hasResponseCode: err.hasCode,
      );

  @override
  String toString() => 'ApiException($code): $message';
}

class NetworkException extends ApiException {
  NetworkException([String? message])
    : super('NETWORK', message ?? '网络连接失败，请检查后重试');
}

class NetworkTimeoutException extends ApiException {
  NetworkTimeoutException() : super('NETWORK_TIMEOUT', '网络连接超时，请检查网络后重试');
}

class ApiExceptionFactory {
  static ApiException fromDioStatusCode(int? status, ApiError? body) {
    if (body != null) {
      return ApiException.fromApiError(body, httpStatus: status);
    }
    switch (status) {
      case null:
        return NetworkException();
      case 401:
        return ApiException('UNAUTHORIZED', '会话已过期，请重新登录', httpStatus: status);
      case 403:
        return ApiException('FORBIDDEN', '无权限访问', httpStatus: status);
      case 404:
        return ApiException('NOT_FOUND', '资源不存在', httpStatus: status);
      case 429:
        return ApiException('RATE_LIMITED', '请求过于频繁，请稍后再试', httpStatus: status);
      case >= 500:
        return ApiException('INTERNAL', '服务器繁忙，请稍后再试', httpStatus: status);
      default:
        return ApiException('UNKNOWN', '请求失败($status)', httpStatus: status);
    }
  }
}

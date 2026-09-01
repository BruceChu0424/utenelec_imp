// 统一 API 异常（对应后端 ApiError：{code,message,fieldErrors}）。
// 文档：docs/05-架构/网络层与拦截器.md §8
import 'api_error.dart';

class ApiException implements Exception {
  ApiException(this.code, this.message, {this.fieldErrors});

  /// 后端错误码（BAD_CREDENTIALS / ACCOUNT_LOCKED / ...）
  final String code;
  final String message;
  final List<ApiFieldError>? fieldErrors;

  factory ApiException.fromApiError(ApiError err) =>
      ApiException(err.code, err.message, fieldErrors: err.fieldErrors);

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
    if (body != null) return ApiException.fromApiError(body);
    switch (status) {
      case null:
        return NetworkException();
      case 401:
        return ApiException('UNAUTHORIZED', '会话已过期，请重新登录');
      case 403:
        return ApiException('FORBIDDEN', '无权限访问');
      case 404:
        return ApiException('NOT_FOUND', '资源不存在');
      case 429:
        return ApiException('RATE_LIMITED', '请求过于频繁，请稍后再试');
      case >= 500:
        return ApiException('INTERNAL', '服务器繁忙，请稍后再试');
      default:
        return ApiException('UNKNOWN', '请求失败($status)');
    }
  }
}

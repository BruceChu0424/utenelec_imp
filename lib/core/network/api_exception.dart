// 统一 API 异常（对应后端 ApiError：{code,message,fieldErrors}）。
// 文档：docs/05-架构/网络层与拦截器.md §8
import 'api_error.dart';
import 'api_error_message.dart';

class ApiException implements Exception {
  ApiException(
    this.code,
    String message, {
    this.fieldErrors,
    this.httpStatus,
    this.hasResponseCode = false,
    this.details,
  }) : message = apiErrorMessage(code, message, httpStatus: httpStatus);

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
  final Map<String, dynamic>? details;

  factory ApiException.fromApiError(ApiError err, {int? httpStatus}) =>
      ApiException(
        err.code,
        err.message,
        fieldErrors: err.fieldErrors,
        httpStatus: httpStatus,
        hasResponseCode: err.hasCode,
        details: err.details,
      );

  @override
  String toString() => 'ApiException($code): $message';
}

class NetworkException extends ApiException {
  NetworkException([String? message])
    : super('NETWORK', message ?? '无法连接服务器，请检查网络或服务器状态');
}

class NetworkTimeoutException extends ApiException {
  NetworkTimeoutException() : super('NETWORK_TIMEOUT', '服务器未及时响应，请先核对操作结果');
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
        return ApiException('UNAUTHORIZED', '', httpStatus: status);
      case 403:
        return ApiException('FORBIDDEN', '', httpStatus: status);
      case 404:
        return ApiException('NOT_FOUND', '', httpStatus: status);
      case 429:
        return ApiException('RATE_LIMITED', '', httpStatus: status);
      case >= 500:
        return ApiException('INTERNAL', '', httpStatus: status);
      default:
        return ApiException('UNKNOWN', '', httpStatus: status);
    }
  }
}

import 'package:dio/dio.dart';

/// 刷新令牌的结果必须区分“凭据明确失效”和“服务暂时不可用”。
///
/// 只有 [rejected] 才允许调用方清理本地令牌；网络错误、5xx、限流和异常响应
/// 都属于 [unavailable]，避免一次短暂故障把仍然有效的用户会话破坏掉。
enum TokenRefreshDisposition { refreshed, rejected, unavailable }

class TokenRefreshResult {
  const TokenRefreshResult._(this.disposition, {this.token, this.error});

  const TokenRefreshResult.refreshed(String token)
    : this._(TokenRefreshDisposition.refreshed, token: token);

  const TokenRefreshResult.rejected([DioException? error])
    : this._(TokenRefreshDisposition.rejected, error: error);

  const TokenRefreshResult.unavailable([DioException? error])
    : this._(TokenRefreshDisposition.unavailable, error: error);

  final TokenRefreshDisposition disposition;
  final String? token;
  final DioException? error;
}

/// A refresh rejection is destructive only when both HTTP status and the
/// structured application error code match the live backend contract. Proxy,
/// servlet-container and WAF HTML/empty responses are service failures.
const Map<String, int> _definitiveRefreshRejections = <String, int>{
  'UNAUTHORIZED': 401,
  'ACCOUNT_LOCKED': 401,
  'ACCOUNT_DISABLED': 401,
  'VALIDATION_FAILED': 422,
  'VISITOR_BLOCKED': 403,
  // 远程授权被撤销是明确的员工会话边界；不能把 403 当临时网络故障永久保留旧令牌。
  'REMOTE_ACCESS_DENIED': 403,
};

bool isDefinitiveRefreshRejection(Response<dynamic>? response) {
  final data = response?.data;
  if (data is! Map) return false;
  final code = data['code'];
  return code is String &&
      _definitiveRefreshRejections[code] == response?.statusCode;
}

DioException invalidRefreshResponse(Response<dynamic> response) => DioException(
  requestOptions: response.requestOptions,
  response: response,
  type: DioExceptionType.badResponse,
  message: '刷新接口响应缺少有效的 accessToken',
);

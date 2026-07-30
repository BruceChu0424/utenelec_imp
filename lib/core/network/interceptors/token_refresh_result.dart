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

/// 后端刷新接口的契约：
/// - 400/422：本地 refresh token 请求已损坏；
/// - 401：refresh token 无效、过期、已撤销或账号已不可用。
///
/// 403、429、5xx 和网络异常不代表 refresh token 已失效，不能据此退出用户。
bool isDefinitiveRefreshRejection(int? statusCode) =>
    statusCode == 400 || statusCode == 401 || statusCode == 422;

DioException invalidRefreshResponse(Response<dynamic> response) => DioException(
  requestOptions: response.requestOptions,
  response: response,
  type: DioExceptionType.badResponse,
  message: '刷新接口响应缺少有效的 accessToken',
);

// 共享的健康探针工具：把 API base URL 归约为 actuator origin，并判定 /actuator/health 响应。
// connection_recovery（探「当前生效」服务器）与 server_selection（探「本地」服务器以决定本地/云端）
// 共用同一套判定，避免两处各写一份漂移。
import 'dart:convert';

import 'package:dio/dio.dart';

typedef HealthProbeDioFactory = Dio Function(BaseOptions options);

/// Actuator 位于 /api 之外。Web release 探同源；绝对 API URL 归约为 origin，
/// 避免客户端卡在探测不存在的 /api/actuator 路由上。
String healthProbeBaseUrl(String apiBase) {
  if (apiBase.startsWith('/')) return '';
  final uri = Uri.parse(apiBase);
  return uri.replace(path: '').toString().replaceFirst(RegExp(r'/$'), '');
}

/// /actuator/health 健康判定：HTTP 200 + JSON {status: "UP"}。
bool isHealthyProbeResponse(int? statusCode, Object? data) =>
    statusCode == 200 && data is Map && data['status'] == 'UP';

/// 用独立短超时 Dio 探某个 origin 的 /actuator/health 是否健康。
/// 仅做可达性判定，不带鉴权头（/actuator/health 在 SecurityConfig 中为 permitAll）。
/// 每次调用自建自毁一个 Dio，避免跨调用共享状态；调用方无需关心释放。
Future<bool> probeHealth(
  String origin, {
  Duration? timeout,
  HealthProbeDioFactory? dioFactory,
}) async {
  final response = await _probeServer(
    origin,
    timeout: timeout,
    dioFactory: dioFactory,
  );
  if (response == null) return false;
  var data = response.data;
  if (data is String) {
    try {
      data = jsonDecode(data);
    } on FormatException {
      return false;
    }
  }
  return isHealthyProbeResponse(response.statusCode, data);
}

/// Any HTTP reply from the configured local origin proves network reachability.
/// A degraded service, rejected health request or redirect must not send a login
/// password to the cloud. This is distinct from the recovery UP health contract.
Future<bool> probeServerReachability(
  String origin, {
  Duration? timeout,
  HealthProbeDioFactory? dioFactory,
}) async {
  final response = await _probeServer(
    origin,
    timeout: timeout,
    dioFactory: dioFactory,
  );
  final status = response?.statusCode;
  return status != null && status >= 100 && status < 600;
}

Future<Response<dynamic>?> _probeServer(
  String origin, {
  Duration? timeout,
  HealthProbeDioFactory? dioFactory,
}) async {
  final t = timeout ?? const Duration(milliseconds: 1500);
  final options = BaseOptions(
    connectTimeout: t,
    sendTimeout: t,
    receiveTimeout: t,
    // Do not visit another origin to decide whether the local one responded.
    followRedirects: false,
    responseType: ResponseType.plain,
    validateStatus: (status) => status != null && status >= 100 && status < 600,
  );
  final dio = dioFactory?.call(options) ?? Dio(options);
  try {
    return await dio.get<dynamic>('$origin/actuator/health');
  } on DioException catch (error) {
    return error.response;
  } finally {
    dio.close(force: true);
  }
}

// API 客户端：基于 Dio，注入 AuthInterceptor；统一把 DioException 转成 ApiException。
// 基址由 api_base_url.dart 统一校验：Web release 默认同源 /api，
// 移动/桌面 release 必须显式传 HTTPS，避免误请求用户设备 localhost。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audit/device_audit_store.dart';
import '../security/secure_storage.dart';
import 'api_base_url.dart';
import 'server_config.dart';
import 'connection_recovery.dart';
import 'api_error.dart';
import 'api_exception.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/device_audit_interceptor.dart';
import 'interceptors/safe_request_retry_interceptor.dart';
import 'network_policy.dart';

class ApiClient {
  ApiClient(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.get<dynamic>(path, queryParameters: query);
      return _asMap(r.data);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// 用于后端直接返回 JSON 数组的接口（如部门树）。
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.get<dynamic>(path, queryParameters: query);
      final data = r.data;
      if (data is List) {
        return data.cast<Map<String, dynamic>>();
      }
      if (data is Map && data['data'] is List) {
        return (data['data'] as List).cast<Map<String, dynamic>>();
      }
      return const [];
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// Reads endpoints that return a JSON string array, such as UUID/code lists.
  ///
  /// This stays separate from the object-array contract in [getList] so a
  /// `List<String>` cannot be silently converted or unsafely cast by callers.
  Future<List<String>> getStringList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.get<dynamic>(path, queryParameters: query);
      final data = r.data;
      final raw = data is List
          ? data
          : data is Map && data['data'] is List
          ? data['data'] as List<dynamic>
          : null;
      if (raw == null) {
        throw const FormatException('Response is not a string array');
      }
      return raw
          .map((item) {
            if (item is! String) {
              throw const FormatException(
                'String array contains a non-string item',
              );
            }
            return item;
          })
          .toList(growable: false);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: headers == null ? null : Options(headers: headers),
      );
      return _asMap(r.data);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// POST 且响应为 JSON 数组（如批量生成结果列表）。
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    try {
      final r = await _dio.post<dynamic>(path, data: body);
      final data = r.data;
      if (data is List) {
        return data.cast<Map<String, dynamic>>();
      }
      if (data is Map && data['data'] is List) {
        return (data['data'] as List).cast<Map<String, dynamic>>();
      }
      return const [];
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// PUT 且响应为 JSON 数组（整体替换后回读列表）。
  Future<List<Map<String, dynamic>>> putList(
    String path, {
    Object? body,
  }) async {
    try {
      final r = await _dio.put<dynamic>(path, data: body);
      final data = r.data;
      if (data is List) return data.cast<Map<String, dynamic>>();
      if (data is Map && data['data'] is List) {
        return (data['data'] as List).cast<Map<String, dynamic>>();
      }
      return const [];
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    try {
      final r = await _dio.put<dynamic>(path, data: body);
      return _asMap(r.data);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// 上传原始字节（附件直传本地后端 raw 端点；OSS 由调用方用独立 Dio 直传预签名 URL）。
  Future<void> putBytes(
    String path,
    Uint8List bytes,
    String contentType, {
    Map<String, String>? headers,
  }) async {
    try {
      await _dio.put<dynamic>(
        path,
        data: bytes,
        options: Options(headers: {'Content-Type': contentType, ...?headers}),
      );
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// 上传原始字节（POST，octet-stream）并返回 JSON——货品导入 detect/commit 用。
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List bytes, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: bytes,
        queryParameters: query,
        options: Options(
          contentType: 'application/octet-stream',
          responseType: ResponseType.json,
        ),
      );
      return _asMap(r.data);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// 下载原始字节（附件本地后端 raw 端点流式下载）。
  Future<Uint8List> getBytes(String path) async {
    try {
      final r = await _dio.get<List<int>>(
        path,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(r.data ?? const []);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    try {
      final r = await _dio.patch<dynamic>(path, data: body);
      return _asMap(r.data);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// 后端 200 空体（void 接口）时 Dio 给的是 '' 而不是 null，
  /// 直接 `as Map` 会抛 TypeError —— 保存其实成功了却提示失败。
  /// 只对真正的 JSON 对象做转换，其余（null/空串/数组）一律视为空 Map。
  static Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    return <String, dynamic>{};
  }

  Future<void> delete(String path) async {
    try {
      await _dio.delete<dynamic>(path);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }

  /// 下载二进制（Excel 导出用）：POST [path]，可选密码走 [body]，过滤/排序走 [query]，
  /// 以 bytes 接收。AuthInterceptor 自动管 401 刷新。错误体（bytes）尝试解 JSON 取业务消息。
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.post<List<int>>(
        path,
        data: body,
        queryParameters: query,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: apiDownloadReceiveTimeout,
        ),
      );
      return Uint8List.fromList(r.data ?? const []);
    } on DioException catch (e) {
      throw _convertBytes(e);
    }
  }

  /// bytes 响应的错误转换：业务错误体可能是 UTF-8 JSON 字节，尝试解出 ApiError 取消息。
  ApiException _convertBytes(DioException e) {
    final connectionFailure = _connectionException(e);
    if (connectionFailure != null) return connectionFailure;
    final data = e.response?.data;
    ApiError? body;
    if (data is List<int>) {
      try {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is Map<String, dynamic>) body = ApiError.fromJson(decoded);
      } catch (_) {}
    } else if (data is Map<String, dynamic>) {
      body = ApiError.fromJson(data);
    }
    return ApiExceptionFactory.fromDioStatusCode(e.response?.statusCode, body);
  }

  /// 便捷：路径无需前导斜杠时补齐（endpoints 已带前导斜杠）。
  String get baseUrl => apiBaseUrl;

  ApiException _convert(DioException e) {
    final connectionFailure = _connectionException(e);
    if (connectionFailure != null) return connectionFailure;
    ApiError? body;
    final data = e.response?.data;
    if (data is Map<String, dynamic>) {
      body = ApiError.fromJson(data);
    }
    return ApiExceptionFactory.fromDioStatusCode(e.response?.statusCode, body);
  }

  ApiException? _connectionException(DioException e) {
    final type = e.type;
    if (type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.sendTimeout ||
        type == DioExceptionType.receiveTimeout) {
      return NetworkTimeoutException();
    }
    if (type == DioExceptionType.connectionError ||
        type == DioExceptionType.unknown && e.response == null) {
      return NetworkException();
    }
    return null;
  }
}

/// 全局 API 客户端 Provider。
final apiClientProvider = Provider<ApiClient>((ref) {
  // Rebuild watched repositories only after a fully disconnected client has
  // reached the server again. Ordinary responses do not churn the Dio graph.
  ref.watch(connectionRecoveryProvider.select((state) => state.recoveryEpoch));
  final recovery = ref.read(connectionRecoveryProvider.notifier);
  final storage = ref.watch(secureStorageProvider);
  final deviceAuditStore = ref.watch(deviceAuditStoreProvider);
  final baseUrl = ref.watch(apiBaseUrlProvider);
  Dio auditedDioFactory() {
    final client = Dio(buildApiBaseOptions(baseUrl));
    client.interceptors.add(DeviceAuditInterceptor(deviceAuditStore));
    return client;
  }

  final dio = Dio(buildApiBaseOptions(baseUrl));
  dio.interceptors.add(DeviceAuditInterceptor(deviceAuditStore));
  dio.interceptors.add(
    AuthInterceptor(
      storage: storage,
      baseUrl: baseUrl,
      dioFactory: auditedDioFactory,
    ),
  );
  dio.interceptors.add(SafeRequestRetryInterceptor(dio, recovery: recovery));
  return ApiClient(dio);
});

// API 客户端：基于 Dio，注入 AuthInterceptor；统一把 DioException 转成 ApiException。
// 基址由 --dart-define=API_BASE_URL 指定，默认本地后端。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../security/secure_storage.dart';
import 'api_error.dart';
import 'api_exception.dart';
import 'interceptors/auth_interceptor.dart';

const _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8080/api',
);

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

  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    try {
      final r = await _dio.post<dynamic>(path, data: body);
      return _asMap(r.data);
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

  /// 下载二进制（加密 Excel 导出用）：POST [path]，密码走 [body]，过滤/排序走 [query]，
  /// 以 bytes 接收。AuthInterceptor 自动管 401 刷新。错误体（bytes）尝试解 JSON 取业务消息。
  Future<Uint8List> downloadBytes(String path,
      {Object? body, Map<String, dynamic>? query}) async {
    try {
      final r = await _dio.post<List<int>>(
        path,
        data: body,
        queryParameters: query,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(r.data ?? const []);
    } on DioException catch (e) {
      throw _convertBytes(e);
    }
  }

  /// bytes 响应的错误转换：业务错误体可能是 UTF-8 JSON 字节，尝试解出 ApiError 取消息。
  ApiException _convertBytes(DioException e) {
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
  String get baseUrl => _baseUrl;

  ApiException _convert(DioException e) {
    final type = e.type;
    if (type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.receiveTimeout ||
        type == DioExceptionType.connectionError ||
        type == DioExceptionType.unknown && e.response == null) {
      return NetworkException();
    }
    ApiError? body;
    final data = e.response?.data;
    if (data is Map<String, dynamic>) {
      body = ApiError.fromJson(data);
    }
    return ApiExceptionFactory.fromDioStatusCode(e.response?.statusCode, body);
  }
}

/// 全局 API 客户端 Provider。
final apiClientProvider = Provider<ApiClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  final dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Content-Type': 'application/json'},
    ),
  );
  dio.interceptors.add(AuthInterceptor(storage: storage, baseUrl: _baseUrl));
  return ApiClient(dio);
});

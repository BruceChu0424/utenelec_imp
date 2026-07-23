// 访客 API 客户端 Provider：独立 Dio + VisitorAuthInterceptor（token 存独立 key，与员工隔离）。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/interceptors/visitor_auth_interceptor.dart';
import '../../../core/security/secure_storage.dart';

const _visitorBaseUrl =
    String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8080/api');

final visitorApiProvider = Provider<ApiClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  final dio = Dio(BaseOptions(
    baseUrl: _visitorBaseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    headers: {'Content-Type': 'application/json'},
  ));
  dio.interceptors.add(VisitorAuthInterceptor(storage: storage, baseUrl: _visitorBaseUrl));
  return ApiClient(dio);
});

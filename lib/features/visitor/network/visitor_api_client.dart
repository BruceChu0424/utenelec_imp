// 访客 API 客户端 Provider：独立 Dio + VisitorAuthInterceptor（token 存独立 key，与员工隔离）。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_base_url.dart';
import '../../../core/network/interceptors/safe_request_retry_interceptor.dart';
import '../../../core/network/interceptors/visitor_auth_interceptor.dart';
import '../../../core/network/network_policy.dart';
import '../../../core/security/secure_storage.dart';

final visitorApiProvider = Provider<ApiClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  final dio = Dio(buildApiBaseOptions(apiBaseUrl));
  dio.interceptors.add(
    VisitorAuthInterceptor(storage: storage, baseUrl: apiBaseUrl),
  );
  dio.interceptors.add(SafeRequestRetryInterceptor(dio));
  return ApiClient(dio);
});

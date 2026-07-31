// 访客 API 客户端 Provider：独立 Dio + VisitorAuthInterceptor（token 存独立 key，与员工隔离）。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audit/device_audit_store.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_base_url.dart';
import '../../../core/network/interceptors/device_audit_interceptor.dart';
import '../../../core/network/interceptors/safe_request_retry_interceptor.dart';
import '../../../core/network/interceptors/visitor_auth_interceptor.dart';
import '../../../core/network/network_policy.dart';
import '../../../core/security/secure_storage.dart';

final visitorApiProvider = Provider<ApiClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  final deviceAuditStore = ref.watch(deviceAuditStoreProvider);
  Dio auditedDioFactory() {
    final client = Dio(buildApiBaseOptions(apiBaseUrl));
    client.interceptors.add(DeviceAuditInterceptor(deviceAuditStore));
    return client;
  }

  final dio = Dio(buildApiBaseOptions(apiBaseUrl));
  dio.interceptors.add(DeviceAuditInterceptor(deviceAuditStore));
  dio.interceptors.add(
    VisitorAuthInterceptor(
      storage: storage,
      baseUrl: apiBaseUrl,
      dioFactory: auditedDioFactory,
    ),
  );
  dio.interceptors.add(SafeRequestRetryInterceptor(dio));
  return ApiClient(dio);
});

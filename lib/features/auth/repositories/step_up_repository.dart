// 敏感操作再认证仓库 (ADR-110)：POST /auth/step-up 输入当前登录密码，换取本会话专用、
// 连续操作复用、空闲 5 分钟失效的凭证。输错 422 REAUTH_FAILED；连续输错到上限 429 REAUTH_LOCKED
// (服务端同时踢掉当前会话，需要重新登录)。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/interceptors/step_up_interceptor.dart';

abstract interface class StepUpRepository {
  /// 返回仅驻留内存的会话凭证；密码错误等以 ApiException 抛出。
  Future<String> verify(String password);
}

/// 独立能力接口兼容已有只负责验证的测试/业务替身。
abstract interface class StepUpActivityRepository {
  Future<void> recordActivity(String token);
}

class DioStepUpRepository
    implements StepUpRepository, StepUpActivityRepository {
  DioStepUpRepository(this.api);
  final ApiClient api;

  @override
  Future<void> recordActivity(String token) async {
    await api.post(
      StepUpInterceptor.activityPath,
      headers: {StepUpInterceptor.header: token},
    );
  }

  @override
  Future<String> verify(String password) async {
    final json = await api.post(
      ApiEndpoints.authStepUp,
      body: <String, String>{'password': password},
    );
    final token = json['stepUpToken'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('再认证响应缺少凭证');
    }
    return token;
  }
}

final stepUpRepositoryProvider = Provider<StepUpRepository>(
  (ref) => DioStepUpRepository(ref.watch(apiClientProvider)),
);

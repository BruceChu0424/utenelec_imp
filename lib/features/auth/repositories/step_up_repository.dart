// 敏感操作再认证仓库 (ADR-110)：POST /auth/step-up 输入当前登录密码，换取本会话专用、
// 5 分钟有效、只能用一次的凭证。输错 422 REAUTH_FAILED；连续输错到上限 429 REAUTH_LOCKED
// (服务端同时踢掉当前会话，需要重新登录)。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

abstract interface class StepUpRepository {
  /// 返回一次性凭证原文；密码错误等以 ApiException 抛出。
  Future<String> verify(String password);
}

class DioStepUpRepository implements StepUpRepository {
  DioStepUpRepository(this.api);
  final ApiClient api;

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

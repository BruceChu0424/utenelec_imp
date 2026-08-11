// 模拟身份网络仓库：enter / start / end。
// enter 与 start 由 admin token 调（AuthInterceptor 把模拟管理端点定向到 admin 凭证）；
// end 由模拟 token 调（主体=目标）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/impersonation.dart';

class ImpersonationRepository {
  ImpersonationRepository(this._api);

  final ApiClient _api;

  Future<ImpersonationModeResult> enter(String password) async {
    final json = await _api.post(
      ApiEndpoints.adminImpersonationEnter,
      body: <String, String>{'password': password},
    );
    return ImpersonationModeResult.fromJson(json);
  }

  Future<ImpersonationStartResult> start({
    required String targetEmployeeId,
    required String modeToken,
  }) async {
    final json = await _api.post(
      ApiEndpoints.adminImpersonationStart,
      body: <String, String>{
        'targetEmployeeId': targetEmployeeId,
        'modeToken': modeToken,
      },
    );
    return ImpersonationStartResult.fromJson(json);
  }

  Future<void> end() async {
    await _api.post(ApiEndpoints.adminImpersonationEnd);
  }

  /// 模拟目标候选（始终以 admin 凭证加载；picker 用）。
  Future<List<ImpersonationTarget>> searchTargets(String? keyword) async {
    final list = await _api.getList(
      ApiEndpoints.adminImpersonationTargets,
      query: (keyword == null || keyword.trim().isEmpty)
          ? null
          : <String, dynamic>{'search': keyword.trim()},
    );
    return list.map(ImpersonationTarget.fromJson).toList();
  }
}

final impersonationRepositoryProvider = Provider<ImpersonationRepository>(
  (ref) => ImpersonationRepository(ref.watch(apiClientProvider)),
);

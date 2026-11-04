// 模拟身份网络仓库：enter / start / end。
// enter 与 start 由 admin token 调（AuthInterceptor 把模拟管理端点定向到 admin 凭证）；
// end 由模拟 token 调（主体=目标）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/department_node.dart';
import '../models/impersonation.dart';

class ImpersonationRepository {
  ImpersonationRepository(this._api);

  final ApiClient _api;

  /// Same management credential and minimal metadata authority as target search.
  Future<List<DepartmentNode>> targetDepartments() async {
    final rows = await _api.getList(
      '${ApiEndpoints.adminImpersonationTargets}/departments',
    );
    return rows.map(DepartmentNode.fromJson).toList(growable: false);
  }

  /// 进入切换人模式：服务端要求再认证 (统一密码框由网络层弹出，ADR-110)，
  /// 成功后签发限时模式凭证，窗口内切换不同目标不必再输密码。
  Future<ImpersonationModeResult> enter() async {
    final json = await _api.post(ApiEndpoints.adminImpersonationEnter);
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
  Future<PagedResult<ImpersonationTarget>> targetsPage(
    String? keyword, {
    int page = 1,
    int size = 100,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    final response = await _api.get(
      '${ApiEndpoints.adminImpersonationTargets}/page',
      query: {
        'page': page,
        'size': size,
        if (keyword?.trim().isNotEmpty == true) 'search': keyword!.trim(),
        'departmentId': ?departmentId,
        if (departmentId != null || includeSubtree)
          'includeSubtree': includeSubtree,
      },
    );
    return PagedResult.fromJsonResponsive(
      response,
      ImpersonationTarget.fromJson,
    );
  }
}

final impersonationRepositoryProvider = Provider<ImpersonationRepository>(
  (ref) => ImpersonationRepository(ref.watch(apiClientProvider)),
);

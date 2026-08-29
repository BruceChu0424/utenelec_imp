// 员工仓库：分页列表/详情/入职/调岗/离职/复职。
// 注：禁止删除员工——离职即终态（status='resigned' 永久留存），无 delete 能力。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/models/paged_result.dart';
import '../models/employee_api_models.dart';

abstract interface class EmployeeRepository {
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  });
  Future<EmployeeProfile> getById(String id);
  Future<EmployeeOnboardingResult> create(EmployeeOnboardingInput input);
  Future<EmployeeOnboardingResult> provisionAccount(String id);
  Future<void> lockAccount(String id);
  Future<void> unlockAccount(String id);
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body);
  Future<void> transfer(String id, Map<String, dynamic> body);
  Future<void> offboard(String id, Map<String, dynamic> body);
  Future<void> confirm(String id, {String? confirmedDate});
  Future<void> changePhone(String id, String newPhone);
  Future<void> rehire(String id);
  Future<void> renewContract(String id, Map<String, dynamic> body);
  Future<void> setAvatar(String id, String attachmentId);
}

/// 本人档案读取能力。
///
/// 单独建能力接口并通过 [EmployeeRepositorySelfProfile] 暴露，避免给只服务于员工
/// 列表/选择器的既有测试仓库强加一个无关实现；生产仓库实现该能力，调用端仍可直接在
/// [EmployeeRepository] 上调用 `getMe()`。
abstract interface class EmployeeSelfProfileRepository {
  Future<EmployeeProfile?> getMe();
}

extension EmployeeRepositorySelfProfile on EmployeeRepository {
  Future<EmployeeProfile?> getMe() {
    final repository = this;
    if (repository is EmployeeSelfProfileRepository) {
      // 显式 cast 到能力接口，避免交集类型上再次静态命中本 extension。
      return (repository as EmployeeSelfProfileRepository).getMe();
    }
    throw UnsupportedError(
      'EmployeeRepository does not support GET /profile/me',
    );
  }
}

class DioEmployeeRepository
    implements EmployeeRepository, EmployeeSelfProfileRepository {
  DioEmployeeRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (search != null && search.isNotEmpty) 'search': search,
      'departmentId': ?departmentId,
      'includeSubtree': includeSubtree,
      if (statuses != null && statuses.isNotEmpty)
        'statuses': statuses.toList(),
    };
    final json = await api.get(ApiEndpoints.employees, query: query);
    return PagedResult.fromJson(json, EmployeeSummary.fromJson);
  }

  @override
  Future<EmployeeProfile> getById(String id) async {
    final json = await api.get(ApiEndpoints.employee(id));
    return EmployeeProfile.fromJson(json);
  }

  @override
  Future<EmployeeProfile?> getMe() async {
    try {
      final json = await api.get(ApiEndpoints.myProfile);
      if (json.isEmpty) return null;
      return EmployeeProfile.fromJson(json);
    } on ApiException catch (error) {
      // 本人端点把“当前账号没有可用员工档案”视为明确空状态；网络、鉴权和服务端
      // 错误仍向上传递，交给页面展示失败与重试。
      if (error.code == 'NOT_FOUND') return null;
      rethrow;
    }
  }

  @override
  Future<EmployeeOnboardingResult> create(EmployeeOnboardingInput input) async {
    final json = await api.post(ApiEndpoints.employees, body: input.toJson());
    return _credentialResult(json, '入职响应缺少员工资料或一次性临时密码');
  }

  @override
  Future<EmployeeOnboardingResult> provisionAccount(String id) async {
    final json = await api.post(ApiEndpoints.employeeAccount(id));
    return _credentialResult(json, '开通账号响应缺少员工资料或一次性临时密码');
  }

  @override
  Future<void> lockAccount(String id) async {
    await api.post(ApiEndpoints.employeeAccountLock(id));
  }

  @override
  Future<void> unlockAccount(String id) async {
    await api.post(ApiEndpoints.employeeAccountUnlock(id));
  }

  /// 解析入职/补开账号的统一响应：{ employee, temporaryPassword, loginAccount }。
  EmployeeOnboardingResult _credentialResult(
    Map<String, dynamic> json,
    String formatError,
  ) {
    final employee = json['employee'];
    final temporaryPassword = json['temporaryPassword'];
    if (employee is! Map<String, dynamic> ||
        temporaryPassword is! String ||
        temporaryPassword.trim().isEmpty) {
      throw FormatException(formatError);
    }
    final profile = EmployeeProfile.fromJson(employee);
    // 登录账号：优先取后端返回（=手机号）；缺失时回退手机号/工号，保证弹窗总能展示。
    final loginAccountRaw = (json['loginAccount'] as String?)?.trim();
    final loginAccount = loginAccountRaw != null && loginAccountRaw.isNotEmpty
        ? loginAccountRaw
        : (profile.phone?.isNotEmpty == true ? profile.phone! : profile.code);
    return EmployeeOnboardingResult(
      employee: profile,
      temporaryPassword: temporaryPassword,
      loginAccount: loginAccount,
    );
  }

  @override
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body) async {
    final json = await api.put(ApiEndpoints.employee(id), body: body);
    return EmployeeProfile.fromJson(json);
  }

  @override
  Future<void> transfer(String id, Map<String, dynamic> body) =>
      api.post(ApiEndpoints.employeeTransfer(id), body: body);

  @override
  Future<void> offboard(String id, Map<String, dynamic> body) =>
      api.post(ApiEndpoints.employeeOffboard(id), body: body);

  @override
  Future<void> confirm(String id, {String? confirmedDate}) => api.post(
    ApiEndpoints.employeeConfirm(id),
    body: {'confirmedDate': ?confirmedDate},
  );

  @override
  Future<void> changePhone(String id, String newPhone) => api.post(
    ApiEndpoints.employeeChangePhone(id),
    body: {'newPhone': newPhone},
  );

  @override
  Future<void> rehire(String id) => api.post(ApiEndpoints.employeeRehire(id));

  @override
  Future<void> renewContract(String id, Map<String, dynamic> body) =>
      api.post(ApiEndpoints.employeeContracts(id), body: body);

  @override
  Future<void> setAvatar(String id, String attachmentId) => api.post(
    ApiEndpoints.employeeAvatar(id),
    body: {'attachmentId': attachmentId},
  );
}

final employeeRepositoryProvider = Provider<EmployeeRepository>(
  (ref) => DioEmployeeRepository(ref.watch(apiClientProvider)),
);

class EmployeeOnboardingResult {
  const EmployeeOnboardingResult({
    required this.employee,
    required this.temporaryPassword,
    required this.loginAccount,
  });

  final EmployeeProfile employee;
  final String temporaryPassword;

  /// 登录账号（默认=手机号），凭据弹窗展示给 HR。
  final String loginAccount;
}

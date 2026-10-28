// 员工仓库：分页列表/详情/入职/调岗/离职/复职。
// 正常员工离职永久留存；误建重复档案经显式核验后归档为同一人的历史身份，不删除记录。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/auth/account_write_receipt.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/models/paged_result.dart';
import '../models/employee_api_models.dart';
import '../models/employee_id_number_issue.dart';
import '../models/employee_duplicate_archive.dart';

abstract interface class EmployeeRepository {
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    // sort 白名单由后端 EmployeeListQuery#orderBy 决定：code / hireDate / workYears；
    // order 取 asc / desc。缺省时后端按「负责人优先 + 工号」排序。
    String? sort,
    String? order,
  });

  /// 「类似人员」：精确搜索 0 命中时前端追加调用，逐字符评分返回最接近的员工。
  Future<List<EmployeeSummary>> similar(String search, {int limit = 20});
  Future<EmployeeProfile> getById(String id);
  Future<EmployeeOnboardingResult> create(EmployeeOnboardingInput input);
  Future<EmployeeOnboardingResult> provisionAccount(String id);

  /// 开号前就绪检查：确认弹窗一打开就读，在确认前提示缺手机号 / 证件问题。
  Future<EmployeeAccountReadiness> accountReadiness(String id);
  Future<void> lockAccount(String id);
  Future<void> unlockAccount(String id);
  Future<String> resetPassword(String id);
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body);
  Future<List<EmployeeSecondaryDepartment>> listSecondaryDepartments(String id);
  Future<void> replaceSecondaryDepartments(
    String id,
    List<String> departmentIds,
  );
  Future<void> transfer(String id, Map<String, dynamic> body);
  Future<void> offboard(String id, Map<String, dynamic> body);
  Future<void> confirm(String id, {String? confirmedDate});
  Future<void> changePhone(String id, String newPhone);

  /// 修改证件类型与号码(证件信息唯一写入口；身份证不合法时服务端返回具体原因)。
  Future<void> changeIdentity(
    String id, {
    required String idType,
    required String idNumber,
  });
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

abstract interface class EmployeeDuplicateArchiveRepository {
  Future<EmployeeDuplicateArchivePreview> previewDuplicateArchive(
    String id,
    String retainedCode,
  );
  Future<String> archiveDuplicate(
    String id,
    EmployeeDuplicateArchivePreview preview,
    String reason, {
    bool documentConflictVerified = false,
  });
}

/// Optional server-column reads keep ordinary roster clients on the same list
/// contract while allowing a paged relationship picker to query all candidates.
abstract interface class EmployeeHeaderQueryRepository {
  Future<PagedResult<EmployeeSummary>> listWithColumnQuery({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
    Map<String, String?> columnQuery = const {},
  });
}

extension EmployeeRepositoryColumnQuery on EmployeeRepository {
  Future<PagedResult<EmployeeSummary>> listWithColumnQuery({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
    Map<String, String?> columnQuery = const {},
  }) {
    final repository = this;
    if (repository is EmployeeHeaderQueryRepository) {
      return (repository as EmployeeHeaderQueryRepository).listWithColumnQuery(
        page: page,
        size: size,
        search: search,
        statuses: statuses,
        departmentId: departmentId,
        includeSubtree: includeSubtree,
        sort: sort,
        order: order,
        columnQuery: columnQuery,
      );
    }
    if (columnQuery.isNotEmpty) {
      throw UnsupportedError(
        'Employee repository does not support server column conditions',
      );
    }
    return repository.list(
      page: page,
      size: size,
      search: search,
      statuses: statuses,
      departmentId: departmentId,
      includeSubtree: includeSubtree,
      sort: sort,
      order: order,
    );
  }
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
    implements
        EmployeeRepository,
        EmployeeSelfProfileRepository,
        EmployeeDuplicateArchiveRepository,
        EmployeeHeaderQueryRepository {
  DioEmployeeRepository(this.api);
  final ApiClient api;

  @override
  Future<EmployeeDuplicateArchivePreview> previewDuplicateArchive(
    String id,
    String retainedCode,
  ) async => EmployeeDuplicateArchivePreview.fromJson(
    await api.get(
      '${ApiEndpoints.employee(id)}/duplicate-archive/preview',
      query: {'retainedCode': retainedCode.trim()},
    ),
  );

  @override
  Future<String> archiveDuplicate(
    String id,
    EmployeeDuplicateArchivePreview preview,
    String reason, {
    bool documentConflictVerified = false,
  }) async {
    final json = await api.post(
      '${ApiEndpoints.employee(id)}/duplicate-archive',
      body: {
        'retainedEmployeeId': preview.retainedId,
        'sourceVersion': preview.sourceVersion,
        'retainedVersion': preview.retainedVersion,
        'reason': reason.trim(),
        'identityVerified': true,
        'documentConflictVerified': documentConflictVerified,
      },
    );
    return json['retainedEmployeeId'] as String;
  }

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) => listWithColumnQuery(
    page: page,
    size: size,
    search: search,
    statuses: statuses,
    departmentId: departmentId,
    includeSubtree: includeSubtree,
    sort: sort,
    order: order,
  );

  @override
  Future<PagedResult<EmployeeSummary>> listWithColumnQuery({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
    Map<String, String?> columnQuery = const {},
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (search != null && search.isNotEmpty) 'search': search,
      'departmentId': ?departmentId,
      'includeSubtree': includeSubtree,
      if (statuses != null && statuses.isNotEmpty)
        'statuses': statuses.toList(),
      'sort': ?sort,
      'order': ?order,
      for (final entry in columnQuery.entries)
        if ((entry.key.startsWith('search.') ||
                const {
                  'accountStatus',
                  'employmentStatus',
                }.contains(entry.key)) &&
            entry.value?.trim().isNotEmpty == true)
          entry.key: entry.value!.trim(),
    };
    final json = await api.get(ApiEndpoints.employees, query: query);
    return PagedResult.fromJsonResponsive(json, EmployeeSummary.fromJson);
  }

  @override
  Future<List<EmployeeSummary>> similar(String search, {int limit = 20}) async {
    final json = await api.get(
      ApiEndpoints.employeesSimilar,
      query: {'search': search, 'limit': limit},
    );
    return [
      for (final item in (json as List).cast<Map<String, dynamic>>())
        EmployeeSummary.fromJson(item),
    ];
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
    return _credentialResult(
      json,
      expectAccount: input.account.openAccount != false,
    );
  }

  @override
  Future<EmployeeOnboardingResult> provisionAccount(String id) async {
    final json = await api.post(ApiEndpoints.employeeAccount(id));
    return _credentialResult(json, expectedEmployeeId: id);
  }

  @override
  Future<EmployeeAccountReadiness> accountReadiness(String id) async {
    final json = await api.get(ApiEndpoints.employeeAccountReadiness(id));
    return EmployeeAccountReadiness.fromJson(json);
  }

  @override
  Future<void> lockAccount(String id) async {
    await api.post(ApiEndpoints.employeeAccountLock(id));
  }

  @override
  Future<String> resetPassword(String id) async {
    final json = await api.post(ApiEndpoints.employeeAccountResetPassword(id));
    final issued = json['temporaryPassword'];
    if (issued is! String || issued.trim().isEmpty) {
      throw const FormatException('重置密码响应缺少 temporaryPassword');
    }
    return issued;
  }

  @override
  Future<List<EmployeeSecondaryDepartment>> listSecondaryDepartments(
    String id,
  ) async {
    final json = await api.get(ApiEndpoints.employeeSecondaryDepartments(id));
    final rows = json['items'];
    if (rows is! List) {
      throw const FormatException('兼职部门响应缺少 items 列表');
    }
    return rows
        .whereType<Map<String, dynamic>>()
        .map(EmployeeSecondaryDepartment.fromJson)
        .toList();
  }

  @override
  Future<void> replaceSecondaryDepartments(
    String id,
    List<String> departmentIds,
  ) async {
    await api.put(
      ApiEndpoints.employeeSecondaryDepartments(id),
      body: [
        for (final departmentId in departmentIds)
          {'departmentId': departmentId},
      ],
    );
  }

  @override
  Future<void> unlockAccount(String id) async {
    await api.post(ApiEndpoints.employeeAccountUnlock(id));
  }

  /// 解析入职/补开账号的统一响应：{ employee, temporaryPassword, loginAccount }。
  EmployeeOnboardingResult _credentialResult(
    Map<String, dynamic> json, {
    bool expectAccount = true,
    String? expectedEmployeeId,
  }) {
    final employee = json['employee'];
    final temporaryPassword = json['temporaryPassword'];
    if (employee is! Map<String, dynamic>) {
      throw const AccountWriteReceiptException();
    }
    final profile = EmployeeProfile.fromJson(employee);
    if (expectedEmployeeId != null && profile.id != expectedEmployeeId) {
      throw const AccountWriteReceiptException();
    }
    if (!expectAccount) {
      if (temporaryPassword != null ||
          json['loginAccount'] != null ||
          (!profile.accountDeleted && profile.accountStatus != null)) {
        throw const AccountWriteReceiptException();
      }
      return EmployeeOnboardingResult(
        employee: profile,
        temporaryPassword: null,
        loginAccount: null,
      );
    }
    final loginAccount = json['loginAccount'];
    if (temporaryPassword is! String ||
        temporaryPassword.trim().isEmpty ||
        loginAccount is! String ||
        loginAccount.trim().isEmpty) {
      throw const AccountWriteReceiptException();
    }
    return EmployeeOnboardingResult(
      employee: profile,
      temporaryPassword: temporaryPassword,
      loginAccount: loginAccount.trim(),
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
  Future<void> changeIdentity(
    String id, {
    required String idType,
    required String idNumber,
  }) => api.post(
    ApiEndpoints.employeeChangeIdentity(id),
    body: {'idType': idType, 'idNumber': idNumber},
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
  final String? temporaryPassword;

  /// 登录账号（默认=手机号），凭据弹窗展示给 HR。
  final String? loginAccount;

  bool get hasAccountCredentials =>
      temporaryPassword?.trim().isNotEmpty == true &&
      loginAccount?.trim().isNotEmpty == true;
}

/// 开号前就绪检查结果(GET /org/employees/{id}/account/readiness)。
///
/// 只回答「能不能开、开了有什么要提醒」：没有手机号就开不了(登录账号就是手机号)；
/// 证件问题只提醒、不阻塞开号。不含任何号码。
class EmployeeAccountReadiness {
  const EmployeeAccountReadiness({required this.hasPhone, this.idNumberIssue});

  final bool hasPhone;
  final EmployeeIdNumberIssue? idNumberIssue;

  factory EmployeeAccountReadiness.fromJson(Map<String, dynamic> json) {
    final hasPhone = json['hasPhone'];
    if (hasPhone is! bool) {
      throw const FormatException('开号就绪检查响应缺少 hasPhone');
    }
    return EmployeeAccountReadiness(
      hasPhone: hasPhone,
      idNumberIssue: EmployeeIdNumberIssue.fromJson(json['idNumberIssue']),
    );
  }
}

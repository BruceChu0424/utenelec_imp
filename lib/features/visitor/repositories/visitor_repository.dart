// 访客 Repository（Dio 实现，对接后端 visitor 接口；不走 Mock）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/security/secure_storage.dart';
import '../../../shared/models/paged_result.dart';
import '../models/visitor.dart';
import '../models/visitor_application.dart';
import '../network/visitor_api_client.dart';

class VisitorLoginResult {
  const VisitorLoginResult({
    required this.accessToken,
    required this.refreshToken,
    required this.visitorId,
    required this.visitorNo,
    required this.name,
    this.avatarSeed,
  });

  final String accessToken;
  final String refreshToken;
  final String visitorId;
  final String visitorNo;
  final String name;
  final String? avatarSeed;

  factory VisitorLoginResult.fromJson(Map<String, dynamic> j) =>
      VisitorLoginResult(
        accessToken: (j['accessToken'] ?? '').toString(),
        refreshToken: (j['refreshToken'] ?? '').toString(),
        visitorId: (j['visitorId'] ?? '').toString(),
        visitorNo: (j['visitorNo'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        avatarSeed: j['avatarSeed'] as String?,
      );
}

class VisitorApplicationDetail {
  const VisitorApplicationDetail({
    required this.application,
    required this.steps,
  });
  final VisitorApplication application;
  final List<VisitorApprovalStep> steps;
}

/// 访客可选的接待人：服务端只下发可对外接待员工的 id 和姓名，不带部门(security-08)。
class EmployeeDirItem {
  const EmployeeDirItem({required this.id, required this.name});
  final String id;
  final String name;
  factory EmployeeDirItem.fromJson(Map<String, dynamic> j) => EmployeeDirItem(
    id: (j['id'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
  );
}

abstract class VisitorRepository {
  Future<String?> sendCode(String phone);
  Future<VisitorLoginResult> login(String phone, String code);

  /// 冷启动会话校验：令牌/账号有效返回当前资料，401（刷新也被拒）抛
  /// ApiException，由会话层结束本地恢复的会话。
  Future<Visitor> me();
  Future<void> logout();
  Future<PagedResult<VisitorApplication>> myApplications({
    String? status,
    int page = 1,
    int size = 20,
  });
  Future<List<VisitorApplication>> activeApplications();
  Future<VisitorApplicationDetail> getApplication(String id);
  Future<VisitorApplication> submit(Map<String, dynamic> body);

  /// 按姓名搜接待人(先搜再选)：至少 2 个字，服务端最多回 5 人；不提供部门树或按部门列举。
  Future<List<EmployeeDirItem>> searchHosts(String keyword);
}

class DioVisitorRepository implements VisitorRepository {
  DioVisitorRepository(this._api, this._storage);

  final ApiClient _api;
  final SecureStorage _storage;

  @override
  Future<String?> sendCode(String phone) async {
    final r = await _api.post(
      ApiEndpoints.visitorSendCode,
      body: {'phone': phone},
    );
    return r['devCode'] as String?;
  }

  @override
  Future<VisitorLoginResult> login(String phone, String code) async {
    final r = await _api.post(
      ApiEndpoints.visitorLogin,
      body: {'phone': phone, 'code': code},
    );
    final res = VisitorLoginResult.fromJson(r);
    await _storage.saveVisitorTokens(
      accessToken: res.accessToken,
      refreshToken: res.refreshToken,
    );
    return res;
  }

  @override
  Future<Visitor> me() async {
    final r = await _api.get(ApiEndpoints.visitorMe);
    return Visitor.fromJson(r);
  }

  @override
  Future<void> logout() async {
    final refresh = await _storage.getVisitorRefreshToken();
    if (refresh != null && refresh.isNotEmpty) {
      try {
        await _api.post(
          ApiEndpoints.visitorLogout,
          body: {'refreshToken': refresh},
        );
      } catch (_) {}
    }
    await _storage.clearVisitorTokens();
  }

  @override
  Future<PagedResult<VisitorApplication>> myApplications({
    String? status,
    int page = 1,
    int size = 20,
  }) async {
    final query = <String, dynamic>{'page': page, 'size': size};
    if (status != null) query['status'] = status;
    final response = await _api.get(
      ApiEndpoints.visitorApplicationsMine,
      query: query,
    );
    return PagedResult.fromJson(response, VisitorApplication.fromJson);
  }

  @override
  Future<List<VisitorApplication>> activeApplications() async {
    // 后端 status 支持逗号分隔多状态：一次分页请求取全活跃集
    //（pending/hostReviewing/approved/checkedIn；rejected/cancelled 不算）。
    const status = 'pending,hostReviewing,approved,checkedIn';
    const size = 100;
    final items = <VisitorApplication>[];
    var page = 1;
    while (true) {
      final result = await myApplications(
        status: status,
        page: page,
        size: size,
      );
      items.addAll(result.items);
      if (page >= result.totalPages) break;
      page += 1;
    }
    return items;
  }

  @override
  Future<VisitorApplicationDetail> getApplication(String id) async {
    final r = await _api.get(ApiEndpoints.visitorApplication(id));
    final app = VisitorApplication.fromJson(r);
    final steps =
        (r['steps'] as List?)
            ?.map(
              (e) => VisitorApprovalStep.fromJson(e as Map<String, dynamic>),
            )
            .toList() ??
        const [];
    return VisitorApplicationDetail(application: app, steps: steps);
  }

  @override
  Future<VisitorApplication> submit(Map<String, dynamic> body) async {
    final r = await _api.post(ApiEndpoints.visitorApplications, body: body);
    return VisitorApplication.fromJson(r);
  }

  @override
  Future<List<EmployeeDirItem>> searchHosts(String keyword) async {
    final text = keyword.trim();
    // 不足 2 个字不发请求(服务端同样拒绝)，避免空关键字翻出名册。
    if (text.runes.length < minHostKeywordLength) return const [];
    final list = await _api.getList(
      ApiEndpoints.visitorDirectoryEmployees,
      query: {'keyword': text},
    );
    return list.map(EmployeeDirItem.fromJson).toList();
  }
}

/// 搜接待人的最少字数(与服务端同口径)。
const minHostKeywordLength = 2;

final visitorRepositoryProvider = Provider<VisitorRepository>((ref) {
  return DioVisitorRepository(
    ref.watch(visitorApiProvider),
    ref.watch(secureStorageProvider),
  );
});

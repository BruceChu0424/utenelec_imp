// 访客 Repository（Dio 实现，对接后端 visitor 接口；不走 Mock）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/security/secure_storage.dart';
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

  factory VisitorLoginResult.fromJson(Map<String, dynamic> j) => VisitorLoginResult(
        accessToken: (j['accessToken'] ?? '').toString(),
        refreshToken: (j['refreshToken'] ?? '').toString(),
        visitorId: (j['visitorId'] ?? '').toString(),
        visitorNo: (j['visitorNo'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        avatarSeed: j['avatarSeed'] as String?,
      );
}

class VisitorApplicationDetail {
  const VisitorApplicationDetail({required this.application, required this.steps});
  final VisitorApplication application;
  final List<VisitorApprovalStep> steps;
}

class EmployeeDirItem {
  const EmployeeDirItem({required this.id, required this.name, this.departmentName});
  final String id;
  final String name;
  final String? departmentName;
  factory EmployeeDirItem.fromJson(Map<String, dynamic> j) => EmployeeDirItem(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        departmentName: j['departmentName'] as String?,
      );
}

class DeptDirItem {
  const DeptDirItem({required this.id, required this.name, this.level, this.parentId});
  final String id;
  final String name;
  final String? level;
  final String? parentId;
  factory DeptDirItem.fromJson(Map<String, dynamic> j) => DeptDirItem(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        level: j['level'] as String?,
        parentId: j['parentId'] == null ? null : (j['parentId']).toString(),
      );
}

abstract class VisitorRepository {
  Future<String?> sendCode(String phone);
  Future<VisitorLoginResult> login(String phone, String code);
  Future<void> logout();
  Future<List<VisitorApplication>> myApplications({String? status});
  Future<VisitorApplicationDetail> getApplication(String id);
  Future<VisitorApplication> submit(Map<String, dynamic> body);
  Future<List<EmployeeDirItem>> directoryEmployees({String? departmentId, String? keyword});
  Future<List<DeptDirItem>> directoryDepartments();
}

class DioVisitorRepository implements VisitorRepository {
  DioVisitorRepository(this._api, this._storage);

  final ApiClient _api;
  final SecureStorage _storage;

  @override
  Future<String?> sendCode(String phone) async {
    final r = await _api.post(ApiEndpoints.visitorSendCode, body: {'phone': phone});
    return r['devCode'] as String?;
  }

  @override
  Future<VisitorLoginResult> login(String phone, String code) async {
    final r = await _api.post(ApiEndpoints.visitorLogin, body: {'phone': phone, 'code': code});
    final res = VisitorLoginResult.fromJson(r);
    await _storage.saveVisitorTokens(accessToken: res.accessToken, refreshToken: res.refreshToken);
    return res;
  }

  @override
  Future<void> logout() async {
    final refresh = await _storage.getVisitorRefreshToken();
    if (refresh != null && refresh.isNotEmpty) {
      try {
        await _api.post(ApiEndpoints.visitorLogout, body: {'refreshToken': refresh});
      } catch (_) {}
    }
    await _storage.clearVisitorTokens();
  }

  @override
  Future<List<VisitorApplication>> myApplications({String? status}) async {
    final list = await _api.getList(ApiEndpoints.visitorApplicationsMine,
        query: status == null ? null : {'status': status});
    return list.map(VisitorApplication.fromJson).toList();
  }

  @override
  Future<VisitorApplicationDetail> getApplication(String id) async {
    final r = await _api.get(ApiEndpoints.visitorApplication(id));
    final app = VisitorApplication.fromJson(r);
    final steps = (r['steps'] as List?)
            ?.map((e) => VisitorApprovalStep.fromJson(e as Map<String, dynamic>))
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
  Future<List<EmployeeDirItem>> directoryEmployees({String? departmentId, String? keyword}) async {
    final q = <String, dynamic>{};
    if (departmentId != null) q['departmentId'] = departmentId;
    if (keyword != null && keyword.isNotEmpty) q['keyword'] = keyword;
    final list = await _api.getList(ApiEndpoints.visitorDirectoryEmployees,
        query: q.isEmpty ? null : q);
    return list.map(EmployeeDirItem.fromJson).toList();
  }

  @override
  Future<List<DeptDirItem>> directoryDepartments() async {
    final list = await _api.getList(ApiEndpoints.visitorDirectoryDepartments);
    return list.map(DeptDirItem.fromJson).toList();
  }
}

final visitorRepositoryProvider = Provider<VisitorRepository>((ref) {
  return DioVisitorRepository(ref.watch(visitorApiProvider), ref.watch(secureStorageProvider));
});

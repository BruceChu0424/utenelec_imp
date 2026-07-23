// 鉴权仓库：登录/刷新/登出/改密/me。登录与刷新成功后把令牌写入 SecureStorage。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/security/secure_storage.dart';
import '../models/auth_session.dart';

abstract interface class AuthRepository {
  Future<AuthResult> login(String loginAccount, String password);
  Future<AuthResult> refresh(String refreshToken);
  Future<void> logout(String? refreshToken);
  Future<AuthResult> changePassword(String oldPassword, String newPassword);
  Future<UserProfile> me();
}

class DioAuthRepository implements AuthRepository {
  DioAuthRepository(this.api, this.storage);

  final ApiClient api;
  final SecureStorage storage;

  @override
  Future<AuthResult> login(String loginAccount, String password) async {
    final json = await api.post(ApiEndpoints.authLogin, body: {
      'loginAccount': loginAccount,
      'password': password,
    });
    final res = AuthResult.fromJson(json);
    await storage.saveTokens(accessToken: res.accessToken, refreshToken: res.refreshToken);
    await storage.saveLoginAccount(loginAccount);
    return res;
  }

  @override
  Future<AuthResult> refresh(String refreshToken) async {
    final json = await api.post(ApiEndpoints.authRefresh, body: {'refreshToken': refreshToken});
    final res = AuthResult.fromJson(json);
    await storage.saveTokens(accessToken: res.accessToken, refreshToken: res.refreshToken);
    return res;
  }

  @override
  Future<void> logout(String? refreshToken) async {
    try {
      await api.post(ApiEndpoints.authLogout, body: {
        if (refreshToken != null) 'refreshToken': refreshToken,
      });
    } finally {
      await storage.clear();
    }
  }

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) async {
    final json = await api.post(ApiEndpoints.authChangePassword, body: {
      'oldPassword': oldPassword,
      'newPassword': newPassword,
    });
    final res = AuthResult.fromJson(json);
    // 改密返回新令牌对：保存后当前设备保持登录（其他设备令牌已被后端撤销）
    await storage.saveTokens(accessToken: res.accessToken, refreshToken: res.refreshToken);
    return res;
  }

  @override
  Future<UserProfile> me() async {
    final json = await api.get(ApiEndpoints.authMe);
    return UserProfile.fromJson(json);
  }
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => DioAuthRepository(ref.watch(apiClientProvider), ref.watch(secureStorageProvider)),
);

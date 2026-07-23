// 安全存储：令牌（access/refresh）与登录账号。
// 文档：docs/00-项目准则/10-安全准则.md（敏感数据走 flutter_secure_storage，不进 shared_preferences）
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  SecureStorage(this._storage);

  final FlutterSecureStorage _storage;

  static const _keyAccess = 'auth.access_token';
  static const _keyRefresh = 'auth.refresh_token';
  static const _keyAccount = 'auth.login_account';

  static const _keyVisitorAccess = 'visitor.access_token';
  static const _keyVisitorRefresh = 'visitor.refresh_token';

  Future<String?> getAccessToken() => _storage.read(key: _keyAccess);
  Future<String?> getRefreshToken() => _storage.read(key: _keyRefresh);
  Future<String?> getLoginAccount() => _storage.read(key: _keyAccount);

  Future<void> saveTokens({String? accessToken, String? refreshToken}) async {
    if (accessToken != null) {
      await _storage.write(key: _keyAccess, value: accessToken);
    }
    if (refreshToken != null) {
      await _storage.write(key: _keyRefresh, value: refreshToken);
    }
  }

  Future<void> saveLoginAccount(String account) =>
      _storage.write(key: _keyAccount, value: account);

  Future<void> clear() async {
    await _storage.delete(key: _keyAccess);
    await _storage.delete(key: _keyRefresh);
  }

  // 保留账号名（记住登录），仅清令牌
  Future<void> clearTokens() => clear();

  // ===== 访客令牌（独立于员工，存独立 key） =====
  Future<String?> getVisitorAccessToken() => _storage.read(key: _keyVisitorAccess);
  Future<String?> getVisitorRefreshToken() => _storage.read(key: _keyVisitorRefresh);
  Future<void> saveVisitorTokens({String? accessToken, String? refreshToken}) async {
    if (accessToken != null) await _storage.write(key: _keyVisitorAccess, value: accessToken);
    if (refreshToken != null) await _storage.write(key: _keyVisitorRefresh, value: refreshToken);
  }
  Future<void> clearVisitorTokens() async {
    await _storage.delete(key: _keyVisitorAccess);
    await _storage.delete(key: _keyVisitorRefresh);
  }
}

final secureStorageProvider = Provider<SecureStorage>((ref) {
  return SecureStorage(const FlutterSecureStorage());
});

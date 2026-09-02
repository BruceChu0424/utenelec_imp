import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 标签页级键值存储：承载「每个标签页一份」的会话状态（员工令牌记录、
/// 模拟身份键、登出栅栏）。Web 实现为 sessionStorage——同源各标签页互不可见，
/// 随标签页关闭销毁；原生平台没有标签页概念，回退为进程级共享的安全存储
/// （与改造前行为一致）。
///
/// 设计决策：ADR-061（多账号多标签页独立会话）。
abstract interface class TabScopedStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 原生/测试回退实现：直接落在传入的安全存储上（等价于改造前的落点）。
class SecureStorageTabScopedStore implements TabScopedStore {
  const SecureStorageTabScopedStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 浏览器标签页级存储；非 Web 平台返回 null，由调用方回退到进程级实现。
TabScopedStore? createBrowserTabScopedStore() => null;

/// [SecureStorage] 员工会话记录的默认后端。
TabScopedStore defaultSessionScopeStore(FlutterSecureStorage storage) =>
    SecureStorageTabScopedStore(storage);

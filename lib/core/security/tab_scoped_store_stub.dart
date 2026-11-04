import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';

/// 标签页级键值存储：承载「每个标签页一份」的会话状态（员工令牌记录、
/// 模拟身份键、登出栅栏）。Web 实现为 sessionStorage——同源各标签页互不可见，
/// 随标签页关闭销毁；桌面端使用进程内存，关闭后必须重新登录；移动端继续
/// 使用平台安全存储，切入后台不代表用户退出登录。
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

/// Desktop credentials belong to this running application. They are never
/// restored by another process, including after a crash or forced termination.
/// Account history and the encrypted revocation queue remain durable separately.
class ProcessSessionScopedStore implements TabScopedStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

final _processSessionStore = ProcessSessionScopedStore();

bool isProcessSessionScope(TabScopedStore store) =>
    store is ProcessSessionScopedStore;

/// 浏览器标签页级存储；非 Web 平台返回 null，由调用方回退到进程级实现。
TabScopedStore? createBrowserTabScopedStore() => null;

/// [SecureStorage] 员工会话记录的默认后端。
TabScopedStore defaultSessionScopeStore(FlutterSecureStorage storage) =>
    switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => _processSessionStore,
      _ => SecureStorageTabScopedStore(storage),
    };

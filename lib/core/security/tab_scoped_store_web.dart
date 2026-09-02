import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web/web.dart' as web;

/// 与 tab_scoped_store_stub.dart 声明一致（条件导出二选一参与编译）。
/// 语义见 stub 版注释与 ADR-061。
abstract interface class TabScopedStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// sessionStorage 实现：会话记录只存在于本标签页，随标签页关闭销毁。
/// 存储被禁用（隐私模式等）/写满时自然抛错，交由上层沿既有安全存储失败路径
/// 处理（fail-closed）。键名与旧 localStorage 记录相同，便于迁移与排障。
class _SessionStorageTabScopedStore implements TabScopedStore {
  const _SessionStorageTabScopedStore();

  @override
  Future<String?> read(String key) async {
    final value = web.window.sessionStorage.getItem(key);
    return value == null || value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String key, String value) async {
    web.window.sessionStorage.setItem(key, value);
  }

  @override
  Future<void> delete(String key) async {
    web.window.sessionStorage.removeItem(key);
  }
}

TabScopedStore? createBrowserTabScopedStore() =>
    const _SessionStorageTabScopedStore();

/// Web 端会话记录一律走 sessionStorage；[storage] 参数仅为与非 Web 工厂
/// 签名一致（Web 上不参与会话记录落盘，仍承载账号历史/撤销队列等共享键）。
TabScopedStore defaultSessionScopeStore(FlutterSecureStorage storage) =>
    const _SessionStorageTabScopedStore();

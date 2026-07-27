// 登录账号历史（只记账号，绝不记密码）。
//
// 存 flutter_secure_storage（JSON 数组，加密；iOS Keychain / Android Keystore）。
// 登录成功 add；登录页默认填上次（first）；下拉可删单个 / 清除全部。
// 不存密码——安全铁律：每次登录都要输密码（即使账号被记住）。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/secure_storage.dart';

const _kAccounts = 'auth.login_accounts';
const _maxAccounts = 10;

class AccountHistoryStore {
  AccountHistoryStore(this._storage);
  final SecureStorage _storage;

  Future<List<String>> getAll() async {
    final raw = await _storage.read(_kAccounts);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list.map((e) => e.toString()).toList(growable: false);
      }
    } catch (_) {}
    return const [];
  }

  Future<String?> getLast() async {
    final all = await getAll();
    return all.isEmpty ? null : all.first;
  }

  /// 登录成功后调用：加到首位（去重，最多 _maxAccounts 个）。
  Future<void> add(String account) async {
    final a = account.trim();
    if (a.isEmpty) return;
    final list = (await getAll()).where((e) => e != a).toList();
    list.insert(0, a);
    if (list.length > _maxAccounts) {
      list.removeRange(_maxAccounts, list.length);
    }
    await _storage.write(_kAccounts, jsonEncode(list));
  }

  Future<void> remove(String account) async {
    final list = (await getAll()).where((e) => e != account).toList();
    await _storage.write(_kAccounts, jsonEncode(list));
  }

  Future<void> clear() async {
    await _storage.delete(_kAccounts);
  }
}

final accountHistoryProvider = Provider<AccountHistoryStore>(
  (ref) => AccountHistoryStore(ref.watch(secureStorageProvider)),
);

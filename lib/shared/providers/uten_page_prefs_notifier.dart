// 页面级用户偏好基类：按账号服务端持久化的通用模板。
//
// 解决什么：报表页/列表页的筛选项、开关、列显隐、布局等「上次选择」，
// 要换设备/重登自动带上。统一走 `user_preferences` 键值接口，
// 避免每个页面各写一套缓存+同步+防抖（已实现两处的模式下沉：工作台布局、即时库存开关）。
//
// 三层策略（与工作台布局同一套，实证可用）：
// 1. 冷启动先读 shared_preferences 本地缓存 → 页面即时渲染不闪烁；
// 2. 会话就绪（登录/换号）后拉 GET /user/preferences 的 prefKey 覆盖本地；
//    服务端没存过该 key → 保留本地缓存/默认值；
// 3. 写路径：乐观更新 state + 立即写缓存 + 防抖 800ms PUT /user/preferences/{prefKey}；
//    离线兜底：PUT 失败静默（本地已生效），下次登录同步自然收敛，不做重试队列。
//
// 用法（最小子类）：
// ```dart
// class MyPagePrefsNotifier extends UtenPagePrefsNotifier<bool> {
//   @override String get prefKey => 'myPage.showClosed';   // 服务端偏好 key（唯一）
//   @override bool get defaultValue => true;
//   @override bool? decode(Object? raw) => raw is bool ? raw : null;
//   @override Object? encode(bool state) => state;
// }
// final myPagePrefsProvider =
//     NotifierProvider<MyPagePrefsNotifier, bool>(MyPagePrefsNotifier.new);
// // 页面：ref.watch(myPagePrefsProvider)；改：notifier.update(v) 或改 state 后 notifier.persist()
// ```
//
// 注意：
// - decode 必须兼容「缓存 JSON 解析结果」与「服务端原始值」两种来源
//   （服务端 value 可能是 String 形态，按需 jsonDecode 后再判）。
// - prefKey 命名约定 `<页面/模块>.<含义>` 点分层（如 stock.instantInventory、workbench.layout），
//   后端校验 ≤100 字符、value ≤16KB。
// - 未登录不推服务端（_pushToServer 内部守卫）；访客模式 service 层会拒绝，静默失败即可。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import 'session_provider.dart';
import 'shared_providers.dart';

abstract class UtenPagePrefsNotifier<T> extends Notifier<T> {
  /// 服务端偏好 key（user_preferences.pref_key，全账号唯一；点分层命名）。
  String get prefKey;

  /// 本地缓存/服务端都没有时的默认值。
  T get defaultValue;

  /// 解码：缓存 JSON 解析结果 / 服务端原始 value → 状态；无法识别返回 null（保留现状）。
  T? decode(Object? raw);

  /// 编码：状态 → 可 JSON 序列化值（写缓存 jsonEncode + PUT body 共用）。
  Object? encode(T state);

  /// shared_preferences 本地缓存 key（默认派生自 prefKey；迁移期可覆盖以兼容旧缓存）。
  String get cacheKey => 'page_prefs_cache_$prefKey';

  /// 服务端推送防抖时长（合并连续操作）。
  Duration get saveDebounce => const Duration(milliseconds: 800);

  Timer? _saveTimer;

  @override
  T build() {
    ref.onDispose(() => _saveTimer?.cancel());

    // 会话就绪（登录/换号）后从服务端同步一次
    ref.listen(sessionProvider, (prev, next) {
      final user = next.user;
      if (user != null && prev?.user?.id != user.id) {
        _syncFromServer();
      }
    });
    // 兜住「先登录后建 provider」的顺序
    if (ref.read(sessionProvider).user != null) {
      Future.microtask(_syncFromServer);
    }

    // 冷启动：本地缓存优先，避免闪烁；无缓存用默认
    return _loadFromCache() ?? defaultValue;
  }

  T? _loadFromCache() {
    final raw = ref.read(sharedPreferencesProvider).getString(cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return decode(jsonDecode(raw));
    } catch (_) {
      return null; // 缓存损坏就当没有
    }
  }

  Future<void> _syncFromServer() async {
    try {
      final json = await ref
          .read(apiClientProvider)
          .get(ApiEndpoints.userPreferences);
      final prefs = json['preferences'];
      if (prefs is! Map || !prefs.containsKey(prefKey)) return;
      final decoded = decode(prefs[prefKey]);
      if (decoded == null) return; // 服务端没存过/不识别 → 保留本地
      state = decoded;
      _writeCache();
    } catch (_) {
      // 拉取失败：保留本地缓存/默认值，不打断页面
    }
  }

  /// 整体替换状态并持久化（简单偏好用这个）。
  void update(T value) {
    state = value;
    persist();
  }

  /// 子类自行变更 state 后调用：立即写缓存 + 防抖推服务端。
  void persist() {
    _writeCache();
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDebounce, _pushToServer);
  }

  void _writeCache() {
    final encoded = encode(state);
    if (encoded == null) return;
    ref
        .read(sharedPreferencesProvider)
        .setString(cacheKey, jsonEncode(encoded));
  }

  Future<void> _pushToServer() async {
    if (ref.read(sessionProvider).user == null) return; // 未登录不推
    try {
      await ref
          .read(apiClientProvider)
          .put(ApiEndpoints.userPreference(prefKey), body: encode(state));
    } catch (_) {
      // 离线兜底：失败静默，本地 state + 缓存已生效（见文件头注释）
    }
  }
}

// 页面级用户偏好基类：按账号服务端持久化的通用模板。
//
// 解决什么：报表页/列表页的筛选项、开关、列显隐、布局等「上次选择」，
// 要换设备/重登自动带上。统一走 `user_preferences` 键值接口，
// 避免每个页面各写一套缓存+同步+防抖（已实现两处的模式下沉：工作台布局、即时库存开关）。
//
// 三层策略（与工作台布局同一套，实证可用）：
// 1. 冷启动先读 shared_preferences 本地缓存 → 页面即时渲染不闪烁；
// 2. 会话就绪(登录/换号)后从会话快照(/auth/me 一次带回的偏好整表，ADR-108)取
//    prefKey 覆盖本地；服务端没存过该 key → 保留本地缓存/默认值。此前 9 个子类各自
//    GET 一整张 /user/preferences，同一会话 2 秒内重复拉取上百次；
//    推服务端成功后就地更新快照，不为此重拉。
//    只认「新加载的快照」(SessionSnapshot.generation 变了)：本端写偏好后就地派生的
//    快照不回灌——否则 A 键推送成功会把 B 键还没推上去的改动冲回旧值、再把旧值推上去；
//    同一身份重取快照(授权变化等)时，本地有未确认的改动(防抖中/推送中/推送失败)也不覆盖。
// 3. 写路径：乐观更新 state + 立即写缓存 + 防抖 800ms PUT /user/preferences/{prefKey}；
//    离线兜底：PUT 失败静默(本地已生效)，下次登录同步自然收敛(新身份/新登录以服务端为准)，
//    不做重试队列。换身份时上一个身份没推完的改动直接作废，不会推到新身份名下。
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
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../auth/session_snapshot_provider.dart';
import 'authenticated_scope_provider.dart';
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

  /// 本地改动的修订号(每次 persist 加一)；推送成功时只有修订号没再变才算「已追上服务端」。
  int _localRevision = 0;

  /// 本地有服务端还没确认的改动(防抖中 / 推送中 / 推送失败)。
  bool _localAhead = false;

  /// 已采用过的快照加载批次与其所属身份。
  int? _adoptedGeneration;
  AuthenticatedScope? _adoptedScope;

  @override
  T build() {
    ref.onDispose(() => _saveTimer?.cancel());

    // 会话快照到达(登录/换号/恢复会话)后同步一次；9 个子类共用同一份快照，
    // 整个会话只有 /auth/me 那一次请求。
    ref.listen<AsyncValue<SessionSnapshot?>>(sessionSnapshotProvider, (
      prev,
      next,
    ) {
      final snapshot = next.valueOrNull;
      if (snapshot != null) {
        _adoptSnapshot(snapshot);
      } else if (next is AsyncData) {
        // 登出：下次登录(哪怕同一账号)视为新身份，以服务端为准。
        _adoptedScope = null;
        _adoptedGeneration = null;
      }
    });
    // 兜住「快照先到、provider 后建」的顺序
    final ready = ref.read(sessionSnapshotProvider).valueOrNull;
    if (ready != null) {
      Future.microtask(() => _adoptSnapshot(ready));
    }

    // 冷启动：本地缓存优先，避免闪烁；无缓存用默认
    return _loadFromCache() ?? defaultValue;
  }

  T? _loadFromCache() {
    final prefs = _sharedPrefsOrNull();
    if (prefs == null) return null;
    final raw = prefs.getString(cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return decode(jsonDecode(raw));
    } catch (_) {
      return null; // 缓存损坏就当没有
    }
  }

  /// 采用一份快照(见文件头第 2 条)：同一批次只采用一次；换身份作废本地未推的改动；
  /// 同一身份重取时本地领先则不覆盖。
  void _adoptSnapshot(SessionSnapshot snapshot) {
    if (snapshot.generation == _adoptedGeneration) return;
    _adoptedGeneration = snapshot.generation;
    final scope = ref.read(authenticatedScopeProvider);
    if (scope != _adoptedScope) {
      _adoptedScope = scope;
      _saveTimer?.cancel();
      _saveTimer = null;
      _localAhead = false;
    } else if (_localAhead) {
      return;
    }
    _applySnapshot(snapshot);
  }

  void _applySnapshot(SessionSnapshot snapshot) {
    if (!snapshot.preferences.containsKey(prefKey)) return;
    final decoded = decode(snapshot.preferences[prefKey]);
    if (decoded == null) return; // 服务端没存过/不识别 → 保留本地
    state = decoded;
    _writeCache();
  }

  /// Explicit page-entry synchronization. Most pages can rely on the automatic
  /// snapshot listener; pages whose first request depends on a persisted default
  /// may await this method before constructing that request.
  Future<void> syncNow() async {
    try {
      final snapshot = await ref.read(sessionSnapshotProvider.future);
      if (snapshot != null) _adoptSnapshot(snapshot);
    } catch (_) {
      // 快照拉取失败：保留本地缓存/默认值，不打断页面
    }
  }

  /// 整体替换状态并持久化（简单偏好用这个）。
  void update(T value) {
    state = value;
    persist();
  }

  /// 子类自行变更 state 后调用：立即写缓存 + 防抖推服务端。
  void persist() {
    _localRevision++;
    _localAhead = true;
    _writeCache();
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDebounce, _pushToServer);
  }

  void _writeCache() {
    final encoded = encode(state);
    if (encoded == null) return;
    final prefs = _sharedPrefsOrNull();
    if (prefs == null) return;
    prefs.setString(cacheKey, jsonEncode(encoded));
  }

  /// 本地缓存层对「未注入 sharedPreferences」容错：widget 测试经常直接泵页面
  /// 而不 override 该全局 provider（main.dart 才注入）。只窄捕接线守卫抛出的
  /// UnimplementedError——跳过本地缓存层，状态回落默认值，服务端同步照常。
  SharedPreferences? _sharedPrefsOrNull() {
    try {
      return ref.read(sharedPreferencesProvider);
    } on UnimplementedError {
      return null;
    }
  }

  Future<void> _pushToServer() async {
    _saveTimer = null;
    if (ref.read(sessionProvider).user == null) return; // 未登录不推
    final revision = _localRevision;
    final scope = _adoptedScope;
    final value = encode(state);
    try {
      await ref
          .read(apiClientProvider)
          .put(ApiEndpoints.userPreference(prefKey), body: value);
      // 推送期间换了身份：这次结果与新身份无关。
      if (scope != _adoptedScope) return;
      // 推送期间又改过：仍以本地为准，等下一次推送。
      if (revision == _localRevision) _localAhead = false;
      // 就地更新会话快照(同一加载批次)：换页重建的实例读到刚存的值，不必重拉整张表；
      // 其它偏好 notifier 不会因此回灌。
      ref
          .read(sessionSnapshotProvider.notifier)
          .updatePreference(prefKey, value);
    } catch (_) {
      // 离线兜底：失败静默，本地 state + 缓存已生效（见文件头注释）
    }
  }
}

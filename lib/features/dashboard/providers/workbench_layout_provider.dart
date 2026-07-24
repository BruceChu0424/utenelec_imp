// 工作台分区布局 Provider：分组排序 + 折叠状态，服务端持久化。
//
// 数据源与合并策略：
// 1. 冷启动先用 shared_preferences 缓存（key: workbench_layout_cache）即时渲染，
//    避免等网络导致的布局闪烁；无缓存则用默认顺序、全部展开。
// 2. 会话就绪（sessionProvider 有 user）后拉 GET /user/preferences 的
//    workbench.layout，与本地默认合并：
//    - 服务端存在但代码里已删除的分组 key → 丢弃；
//    - 代码新增、服务端还没有的分组 key → 按默认顺序补到末尾。
// 3. 写路径：乐观更新本地 state + 立即写 shared_preferences 缓存，
//    再防抖 800ms PUT /user/preferences/workbench.layout。
//    离线兜底：PUT 失败静默吞掉（本地 state 与缓存已生效），
//    下次登录成功后的服务端同步会自然收敛，不做重试队列。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/shared_providers.dart';

/// 工作台布局状态
class WorkbenchLayoutState {
  const WorkbenchLayoutState({required this.order, required this.collapsed});

  /// 分组 key 的显示顺序（含当前不可见的分组，保证排序不因显隐丢失）
  final List<String> order;

  /// 已折叠的分组 key
  final Set<String> collapsed;

  WorkbenchLayoutState copyWith({List<String>? order, Set<String>? collapsed}) {
    return WorkbenchLayoutState(
      order: order ?? this.order,
      collapsed: collapsed ?? this.collapsed,
    );
  }
}

class WorkbenchLayoutNotifier extends Notifier<WorkbenchLayoutState> {
  /// 服务端偏好 key
  static const prefKey = 'workbench.layout';

  /// shared_preferences 本地缓存 key
  static const _cacheKey = 'workbench_layout_cache';

  /// 默认分组顺序（与 workbench_module_area.dart 的分组定义一一对应）
  static const defaultOrder = <String>[
    'common',
    'hr',
    'fin',
    'prod',
    'eng',
    'pmc',
    'qa',
    'sales',
    'newmedia',
    'rail',
    'security',
    'system',
  ];

  Timer? _saveTimer;

  @override
  WorkbenchLayoutState build() {
    ref.onDispose(() => _saveTimer?.cancel());

    // 会话就绪（登录/换号）后从服务端同步一次
    ref.listen(sessionProvider, (prev, next) {
      final user = next.user;
      if (user != null && prev?.user?.id != user.id) {
        _syncFromServer();
      }
    });
    // build 时已登录（如会话恢复完成晚于首次 build 由 listen 覆盖；
    // 这里兜住"先登录后建 provider"的顺序）
    if (ref.read(sessionProvider).user != null) {
      Future.microtask(_syncFromServer);
    }

    // 冷启动：本地缓存优先，避免闪烁；无缓存用默认
    final cached = _loadFromCache();
    return cached ??
        const WorkbenchLayoutState(order: defaultOrder, collapsed: <String>{});
  }

  /// 与默认分组定义合并：丢弃已删除的 key，补上新增的 key。
  WorkbenchLayoutState _merge(List<String>? order, List<String>? collapsed) {
    final known = defaultOrder.toSet();
    final incoming = (order ?? const <String>[]).where(known.contains).toSet();
    final mergedOrder = <String>[
      // 服务端顺序中仍然存在的分组
      for (final k in order ?? const <String>[])
        if (known.contains(k)) k,
      // 代码新增、服务端还没有的分组，按默认顺序补末尾
      for (final k in defaultOrder)
        if (!incoming.contains(k)) k,
    ];
    final mergedCollapsed =
        (collapsed ?? const <String>[]).where(known.contains).toSet();
    return WorkbenchLayoutState(order: mergedOrder, collapsed: mergedCollapsed);
  }

  WorkbenchLayoutState? _loadFromCache() {
    final raw = ref.read(sharedPreferencesProvider).getString(_cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      return _merge(
        (json['order'] as List?)?.cast<String>(),
        (json['collapsed'] as List?)?.cast<String>(),
      );
    } catch (_) {
      // 缓存损坏就当没有缓存
      return null;
    }
  }

  Future<void> _syncFromServer() async {
    try {
      final json = await ref.read(apiClientProvider).get(
            ApiEndpoints.userPreferences,
          );
      final prefs = json['preferences'];
      if (prefs is! Map) return;
      final value = prefs[prefKey];
      // 后端允许任意 JSON value；兼容 Map 与字符串两种落库形态
      Map<dynamic, dynamic>? map;
      if (value is Map<dynamic, dynamic>) {
        map = value;
      } else if (value is String) {
        final decoded = jsonDecode(value);
        if (decoded is Map<dynamic, dynamic>) map = decoded;
      }
      if (map == null) return;
      state = _merge(
        (map['order'] as List?)?.cast<String>(),
        (map['collapsed'] as List?)?.cast<String>(),
      );
      _writeCache();
    } catch (_) {
      // 拉取失败：保留本地缓存/默认值渲染，不打断工作台
    }
  }

  /// 切换某分组的折叠状态
  void toggleCollapsed(String key) {
    final next = Set<String>.of(state.collapsed);
    if (next.contains(key)) {
      next.remove(key);
    } else {
      next.add(key);
    }
    state = state.copyWith(collapsed: next);
    _persist();
  }

  /// 拖动排序。
  ///
  /// [visibleKeys] 为当前实际渲染的可见分组 key（按渲染顺序）；
  /// [oldIndex]/[newIndex] 是 ReorderableListView.onReorderItem 语义
  /// （newIndex 已按移除 oldIndex 后的位置调整，无需再减一）。
  /// 可见子序列重排后回填到完整 order，不可见分组保持原位，
  /// 这样超管排好的布局不会被普通账号的显隐过滤打乱。
  void reorder(List<String> visibleKeys, int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final visible = List<String>.of(visibleKeys);
    if (oldIndex < 0 || oldIndex >= visible.length) return;
    if (newIndex < 0 || newIndex >= visible.length) return;
    final moved = visible.removeAt(oldIndex);
    visible.insert(newIndex, moved);

    final visibleSet = visibleKeys.toSet();
    var vi = 0;
    final fullOrder = <String>[
      for (final k in state.order)
        visibleSet.contains(k) ? visible[vi++] : k,
    ];
    state = state.copyWith(order: fullOrder);
    _persist();
  }

  /// 乐观写：本地缓存立即落盘，服务端防抖 800ms 合并连续操作
  void _persist() {
    _writeCache();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _pushToServer);
  }

  void _writeCache() {
    ref.read(sharedPreferencesProvider).setString(
          _cacheKey,
          jsonEncode({
            'order': state.order,
            'collapsed': state.collapsed.toList(),
          }),
        );
  }

  Future<void> _pushToServer() async {
    if (ref.read(sessionProvider).user == null) return; // 未登录不推
    try {
      await ref.read(apiClientProvider).put(
            ApiEndpoints.userPreference(prefKey),
            body: {
              'order': state.order,
              'collapsed': state.collapsed.toList(),
            },
          );
    } catch (_) {
      // 离线兜底：失败静默，本地 state + 缓存已生效（见文件头注释）
    }
  }
}

final workbenchLayoutProvider =
    NotifierProvider<WorkbenchLayoutNotifier, WorkbenchLayoutState>(
  WorkbenchLayoutNotifier.new,
);

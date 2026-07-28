// 工作台分区布局 Provider：分组排序 + 折叠状态，服务端持久化。
//
// 实现：UtenPagePrefsNotifier 基类（lib/shared/providers/uten_page_prefs_notifier.dart），
// 三层策略（本地缓存即时渲染 → 登录后服务端同步 → 防抖 800ms 推送）全部继承；
// 本文件只保留布局特有的「与默认分组定义合并」逻辑与排序/折叠操作。
//
// 合并策略（服务端/缓存 → 本地时，decode 内完成）：
// - 服务端存在但代码里已删除的分组 key → 丢弃；
// - 代码新增、服务端还没有的分组 key → 按默认顺序补到末尾。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

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

class WorkbenchLayoutNotifier
    extends UtenPagePrefsNotifier<WorkbenchLayoutState> {
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

  @override
  String get prefKey => 'workbench.layout';

  /// 保留旧缓存 key（基类默认派生 key 会丢旧缓存）。
  @override
  String get cacheKey => 'workbench_layout_cache';

  @override
  WorkbenchLayoutState get defaultValue =>
      const WorkbenchLayoutState(order: defaultOrder, collapsed: <String>{});

  @override
  WorkbenchLayoutState? decode(Object? raw) {
    // 兼容两种来源：缓存 jsonDecode 后的 Map / 服务端 value（Map 或 String 形态）
    Map<dynamic, dynamic>? map;
    if (raw is Map<dynamic, dynamic>) {
      map = raw;
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<dynamic, dynamic>) map = decoded;
      } catch (_) {
        return null;
      }
    }
    if (map == null) return null;
    return _merge(
      (map['order'] as List?)?.cast<String>(),
      (map['collapsed'] as List?)?.cast<String>(),
    );
  }

  @override
  Object? encode(WorkbenchLayoutState state) => {
        'order': state.order,
        'collapsed': state.collapsed.toList(),
      };

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

  /// 切换某分组的折叠状态
  void toggleCollapsed(String key) {
    final next = Set<String>.of(state.collapsed);
    if (next.contains(key)) {
      next.remove(key);
    } else {
      next.add(key);
    }
    state = state.copyWith(collapsed: next);
    persist();
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
    persist();
  }
}

final workbenchLayoutProvider =
    NotifierProvider<WorkbenchLayoutNotifier, WorkbenchLayoutState>(
  WorkbenchLayoutNotifier.new,
);

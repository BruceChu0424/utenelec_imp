// 工作台分区布局 Provider：分组排序 + 折叠状态 + 组内卡片排序，服务端持久化。
//
// 实现：UtenPagePrefsNotifier 基类（lib/shared/providers/uten_page_prefs_notifier.dart），
// 三层策略（本地缓存即时渲染 → 登录后服务端同步 → 防抖 800ms 推送）全部继承；
// 本文件只保留布局特有的「与默认分组定义合并」逻辑与排序/折叠操作。
//
// 合并策略（服务端/缓存 → 本地时，decode 内完成）：
// - 服务端存在但代码里已删除的分组 key → 丢弃；
// - 代码新增、服务端还没有的分组 key → 按默认顺序补到末尾。
//
// 组内卡片排序（itemOrders）：
// - key = 分组 key，value = 该组内卡片 location（路由）的显示顺序；
// - 存的是「实际排过的卡片」子序列，渲染端按可见项过滤后、缺的按代码默认顺序补尾，
//   因此新卡片/权限变化不影响已保存的相对顺序；
// - 不可见卡片（无权限/comingSoon 仅超管）不参与过滤，重排时保持原位（见 reorderItem 回填）。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

/// 工作台布局状态
class WorkbenchLayoutState {
  const WorkbenchLayoutState({
    required this.order,
    required this.collapsed,
    this.itemOrders = const {},
  });

  /// 分组 key 的显示顺序（含当前不可见的分组，保证排序不因显隐丢失）
  final List<String> order;

  /// 已折叠的分组 key
  final Set<String> collapsed;

  /// 组内卡片顺序：分组 key → 卡片 location 顺序（只含排过的卡片，缺省按代码默认）
  final Map<String, List<String>> itemOrders;

  WorkbenchLayoutState copyWith({
    List<String>? order,
    Set<String>? collapsed,
    Map<String, List<String>>? itemOrders,
  }) {
    return WorkbenchLayoutState(
      order: order ?? this.order,
      collapsed: collapsed ?? this.collapsed,
      itemOrders: itemOrders ?? this.itemOrders,
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

    // 组内卡片顺序：只认已知分组的 String 列表，其余丢弃（渲染端再按可见项过滤）
    final rawItemOrders = map['itemOrders'];
    Map<String, List<String>>? itemOrders;
    if (rawItemOrders is Map<dynamic, dynamic>) {
      final knownGroups = defaultOrder.toSet();
      itemOrders = <String, List<String>>{
        for (final e in rawItemOrders.entries)
          if (e.key is String &&
              knownGroups.contains(e.key) &&
              e.value is List &&
              (e.value as List).every((it) => it is String))
            e.key as String: (e.value as List).cast<String>(),
      };
    }

    return _merge(
      (map['order'] as List?)?.cast<String>(),
      (map['collapsed'] as List?)?.cast<String>(),
      itemOrders,
    );
  }

  @override
  Object? encode(WorkbenchLayoutState state) => {
    'order': state.order,
    'collapsed': state.collapsed.toList(),
    'itemOrders': state.itemOrders,
  };

  /// 与默认分组定义合并：丢弃已删除的 key，补上新增的 key。
  WorkbenchLayoutState _merge(
    List<String>? order,
    List<String>? collapsed,
    Map<String, List<String>>? itemOrders,
  ) {
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
    final mergedCollapsed = (collapsed ?? const <String>[])
        .where(known.contains)
        .toSet();
    return WorkbenchLayoutState(
      order: mergedOrder,
      collapsed: mergedCollapsed,
      itemOrders: itemOrders ?? const {},
    );
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

    state = state.copyWith(order: _backfill(state.order, visibleKeys, visible));
    persist();
  }

  /// 组内卡片拖动排序（长按拖到另一张卡片上）。
  ///
  /// [visibleLocations] 为该组当前实际渲染的可见卡片 location（按渲染顺序）；
  /// [dragged] 被拖卡片，[target] 悬停目标卡片。
  /// 悬停语义：向下/向后拖 = 落到目标之后，向上/向前拖 = 占目标原位。
  /// 与分组 reorder 同款回填：不可见卡片保持原位，新卡片补末尾。
  void reorderItem(
    String groupKey,
    List<String> visibleLocations,
    String dragged,
    String target,
  ) {
    final oldIndex = visibleLocations.indexOf(dragged);
    final targetIndex = visibleLocations.indexOf(target);
    if (oldIndex < 0 || targetIndex < 0 || oldIndex == targetIndex) return;

    final visible = List<String>.of(visibleLocations);
    final moved = visible.removeAt(oldIndex);
    visible.insert(targetIndex, moved);

    final prev = state.itemOrders[groupKey] ?? const <String>[];
    final full = _backfill(prev, visibleLocations, visible);
    state = state.copyWith(
      itemOrders: <String, List<String>>{...state.itemOrders, groupKey: full},
    );
    persist();
  }

  /// 可见子序列重排后回填完整顺序：不可见项原位保留，prev 里没有的新可见项补末尾。
  /// [visibleKeys] 必须与 [reordered] 一一对应（同一批 key 的重排结果）。
  List<String> _backfill(
    List<String> prev,
    List<String> visibleKeys,
    List<String> reordered,
  ) {
    final visibleSet = visibleKeys.toSet();
    final prevSet = prev.toSet();
    var vi = 0;
    return <String>[
      for (final k in prev) visibleSet.contains(k) ? reordered[vi++] : k,
      for (final k in reordered)
        if (!prevSet.contains(k)) k,
    ];
  }
}

final workbenchLayoutProvider =
    NotifierProvider<WorkbenchLayoutNotifier, WorkbenchLayoutState>(
      WorkbenchLayoutNotifier.new,
    );

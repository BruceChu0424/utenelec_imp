// 仓库选择侧滑面板（V476 层级口径）——宽屏右侧滑入、窄屏底部弹层
// （复用 showUtenAdaptivePanel，与车间/负责人/货品分类选择面板同范式）。
//
// 两种口径，同一个面板：
// - 运营口径（默认，单据登记用，2026-09-05 用户口径）：先显示主仓，点主仓进入
//   其子仓，选子仓后返回「主仓名-子仓名」显示名；单据只能落叶子仓——有子仓的行
//   只导航不选定，没有子仓的主仓自身即叶子仓，可直接选定。
// - 查询口径（[allowParent]=true，2026-09-11 即时库存/货架目视化改侧滑窗时加）：
//   不钻层，整棵层级按缩进一次铺开，任意层级一点即选——主仓 = 自身 + 全部子仓
//   聚合（服务端 WarehouseScopeService 展开）；[includeAll] 再补一行「全部」
//   （= 参与核算仓库聚合，返回 [WarehousePickerResult.all]）。查询口径不做
//   可选性裁剪（禁用/不记账仓也能单独看），与旧 WarehouseHierarchyDropdown
//   allowParent 分支同口径。
import 'package:flutter/material.dart';

import '../../components/inputs/uten_search_bar.dart';
import '../../components/layout/uten_adaptive_panel.dart';
import '../providers/master_name_provider.dart';
import '../../core/theme/uten_tokens.dart';
import 'warehouse_selection.dart';

/// 面板选定结果：仓库 id + 「主仓名-子仓名」显示名（无父级时只有仓名）。
/// 查询口径下选「全部」返回 [all]（id 为空串，[isAll] 为 true）。
class WarehousePickerResult {
  const WarehousePickerResult({
    required this.id,
    required this.label,
    this.parentId,
  });

  /// 「全部」哨兵：仅查询口径（includeAll）会返回，调用方据此把筛选值置 null。
  static const WarehousePickerResult all = WarehousePickerResult(
    id: '',
    label: '全部', // TODO(l10n): 补 arb
  );

  final String id;
  final String label;
  final String? parentId;

  bool get isAll => id.isEmpty;
}

/// 仓库在层级里的完整显示名：自下而上把祖先仓名用 '-' 连接
/// （如「仓库（14年版）-成品仓」）；无父级返回仓名本身；找不到返回 null。
String? warehouseFullLabel(List<WarehouseDictEntry> hierarchy, String id) {
  final byId = {for (final entry in hierarchy) entry.id: entry};
  var current = byId[id];
  if (current == null) return null;
  final names = <String>[current.name];
  var guard = 0;
  while (current?.parentId != null &&
      byId.containsKey(current!.parentId) &&
      guard++ < 16) {
    current = byId[current.parentId];
    names.insert(0, current!.name);
  }
  return names.join('-');
}

/// Main-warehouse identity is based on UUID ancestry; missing or cyclic paths
/// never make two different physical warehouses interchangeable.
bool warehousesShareMain(
  List<WarehouseDictEntry> hierarchy,
  String? left,
  String? right,
) {
  if (left == null || right == null) return false;
  if (left == right) return true;
  final byId = {for (final entry in hierarchy) entry.id: entry};
  String? rootOf(String id) {
    final seen = <String>{};
    var current = id;
    while (seen.add(current)) {
      final entry = byId[current];
      if (entry == null) return null;
      final parent = entry.parentId;
      if (parent == null || parent.isEmpty) return current;
      current = parent;
    }
    return null;
  }

  final root = rootOf(left);
  return root != null && root == rootOf(right);
}

Future<WarehousePickerResult?> showUtenWarehousePickerPanel(
  BuildContext context, {
  required List<WarehouseDictEntry> hierarchy,
  String? initialWarehouseId,
  String title = '选择入库仓库',
  bool includeAll = false,
  bool allowParent = false,
}) {
  return showUtenAdaptivePanel<WarehousePickerResult>(
    context: context,
    builder: (_) => _WarehousePickerSheet(
      hierarchy: hierarchy,
      initialWarehouseId: initialWarehouseId,
      title: title,
      includeAll: includeAll,
      allowParent: allowParent,
    ),
  );
}

class _WarehousePickerSheet extends StatefulWidget {
  const _WarehousePickerSheet({
    required this.hierarchy,
    required this.title,
    required this.includeAll,
    required this.allowParent,
    this.initialWarehouseId,
  });

  final List<WarehouseDictEntry> hierarchy;
  final String title;
  final String? initialWarehouseId;
  final bool includeAll;
  final bool allowParent;

  @override
  State<_WarehousePickerSheet> createState() => _WarehousePickerSheetState();
}

class _WarehousePickerSheetState extends State<_WarehousePickerSheet> {
  /// 当前层级的父仓 id 栈：null = 顶层（主仓列表）。运营口径专用。
  final List<String> _drilldown = [];

  /// 查询口径的本地过滤词。
  final _searchCtl = TextEditingController();
  String _query = '';

  late final WarehouseSelection _selection;

  @override
  void initState() {
    super.initState();
    _selection = WarehouseSelection(widget.hierarchy);
    _searchCtl.addListener(() => setState(() => _query = _searchCtl.text));
    if (widget.allowParent) return; // 查询口径不钻层，无需定位父层。
    // 带初始值时直接展开其父仓层，当前仓高亮，便于对照改选。
    final initial = widget.initialWarehouseId;
    if (initial != null && _selection.selectableIds.contains(initial)) {
      final parent = widget.hierarchy
          .where((entry) => entry.id == initial)
          .map((entry) => entry.parentId)
          .firstOrNull;
      if (parent != null &&
          widget.hierarchy.any((entry) => entry.id == parent)) {
        _drilldown.add(parent);
      }
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  bool _hasChildren(String id) =>
      widget.hierarchy.any((entry) => entry.parentId == id);

  /// 层级深度（按 parentId 链上溯；悬空父级按顶层计）。
  int _depth(WarehouseDictEntry entry) {
    final byId = {for (final e in widget.hierarchy) e.id: e};
    var depth = 0;
    var current = entry;
    while (depth < 16) {
      final parent = current.parentId;
      if (parent == null || !byId.containsKey(parent)) break;
      current = byId[parent]!;
      depth++;
    }
    return depth;
  }

  /// 查询口径的可见集合：命中节点 + 其祖先链（祖先只作层级上下文）。
  Set<String>? _searchVisibleIds() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return null;
    final byId = {for (final e in widget.hierarchy) e.id: e};
    final visible = <String>{};
    for (final entry in widget.hierarchy) {
      final hit =
          entry.name.toLowerCase().contains(q) ||
          (entry.code ?? '').toLowerCase().contains(q);
      if (!hit) continue;
      visible.add(entry.id);
      var current = entry;
      var guard = 0;
      while (guard++ < 16) {
        final parent = current.parentId;
        if (parent == null || !byId.containsKey(parent)) break;
        current = byId[parent]!;
        visible.add(current.id);
      }
    }
    return visible;
  }

  List<WarehouseDictEntry> get _visibleEntries {
    // 查询口径：整棵层级按 warehouseHierarchy 的先序铺开（不裁剪可选性）。
    if (widget.allowParent) {
      final filter = _searchVisibleIds();
      return [
        for (final entry in widget.hierarchy)
          if (filter == null || filter.contains(entry.id)) entry,
      ];
    }
    final ids = widget.hierarchy.map((entry) => entry.id).toSet();
    final parentId = _drilldown.isEmpty ? null : _drilldown.last;
    return [
      // 顶层 = 无父级或父级不在字典内（parentId 悬空按顶层处理）。
      for (final entry in widget.hierarchy)
        if (_selection.visibleIds.contains(entry.id) &&
            (parentId == null
                ? entry.parentId == null || !ids.contains(entry.parentId)
                : entry.parentId == parentId))
          entry,
    ];
  }

  void _pick(WarehouseDictEntry entry) {
    Navigator.of(context).pop(
      WarehousePickerResult(
        id: entry.id,
        label: warehouseFullLabel(widget.hierarchy, entry.id) ?? entry.name,
        parentId: entry.parentId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _visibleEntries;
    final query = widget.allowParent;
    final allSelected =
        widget.initialWarehouseId == null || widget.initialWarehouseId!.isEmpty;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Row(
                children: [
                  if (_drilldown.isNotEmpty) ...[
                    IconButton(
                      tooltip: '返回上级',
                      onPressed: () => setState(() => _drilldown.removeLast()),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          query
                              ? '选主仓 = 自身 + 全部子仓聚合'
                              : _drilldown.isEmpty
                              ? '先选主仓，再选子仓'
                              : '选择 ${_parentName(_drilldown.last)} 的子仓',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (query)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  0,
                  UtenSpacing.s16,
                  UtenSpacing.s8,
                ),
                child: UtenSearchBar(
                  key: const Key('warehouse-picker-search'),
                  controller: _searchCtl,
                  hint: '搜索仓库名称 / 编号', // TODO(l10n): 补 arb
                ),
              ),
            const Divider(height: 1),
            if (widget.includeAll) ...[
              ListTile(
                key: const Key('warehouse-picker-all'),
                selected: allSelected,
                selectedTileColor: theme.colorScheme.primaryContainer,
                leading: Icon(
                  Icons.all_inbox_rounded,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('全部'), // TODO(l10n): 补 arb
                trailing: allSelected
                    ? Icon(
                        Icons.check_circle_rounded,
                        color: theme.colorScheme.primary,
                      )
                    : null,
                onTap: () =>
                    Navigator.of(context).pop(WarehousePickerResult.all),
              ),
              const Divider(height: 1),
            ],
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s24),
                        child: Text(
                          query && _query.trim().isNotEmpty
                              ? '未找到匹配「${_query.trim()}」的仓库'
                              : '没有可选仓库，请先在基础资料维护仓库',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s8,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final hasChildren = _hasChildren(entry.id);
                        final isCurrent = entry.id == widget.initialWarehouseId;
                        return ListTile(
                          key: Key('warehouse-picker-entry-${entry.id}'),
                          // 查询口径缩进表达层级（不钻层）；运营口径钻层不缩进。
                          contentPadding: EdgeInsets.only(
                            left:
                                UtenSpacing.s16 +
                                (query ? _depth(entry) * 20.0 : 0),
                            right: UtenSpacing.s16,
                          ),
                          leading: Icon(
                            hasChildren
                                ? Icons.warehouse_outlined
                                : Icons.inventory_2_outlined,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          title: Text(
                            // 查询口径靠缩进表达层级，只显本级仓名（全路径太长）。
                            query
                                ? entry.name
                                : warehouseFullLabel(
                                        widget.hierarchy,
                                        entry.id,
                                      ) ??
                                      entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: isCurrent
                              ? Icon(
                                  Icons.check_circle_rounded,
                                  color: theme.colorScheme.primary,
                                )
                              : (!query && hasChildren)
                              ? const Icon(Icons.chevron_right_rounded)
                              : null,
                          onTap: () {
                            if (!query && hasChildren) {
                              setState(() => _drilldown.add(entry.id));
                              return;
                            }
                            _pick(entry);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _parentName(String id) =>
      widget.hierarchy
          .where((entry) => entry.id == id)
          .map((entry) => entry.name)
          .firstOrNull ??
      '';
}

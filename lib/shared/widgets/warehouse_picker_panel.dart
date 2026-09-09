// 仓库主/子级联选择侧滑面板（V476 层级口径）——宽屏右侧滑入、窄屏底部弹层
// （复用 showUtenAdaptivePanel，与车间/负责人选择面板同范式）。
//
// 交互（2026-09-05 用户口径）：先显示主仓，点主仓进入其子仓，选子仓后返回
// 「主仓名-子仓名」显示名；单据只能落叶子仓——有子仓的行只导航不选定，
// 没有子仓的主仓自身即叶子仓，可直接选定。
import 'package:flutter/material.dart';

import '../../components/layout/uten_adaptive_panel.dart';
import '../providers/master_name_provider.dart';
import '../../core/theme/uten_tokens.dart';
import 'warehouse_selection.dart';

/// 面板选定结果：叶子仓 id + 「主仓名-子仓名」显示名（无父级时只有仓名）。
class WarehousePickerResult {
  const WarehousePickerResult({
    required this.id,
    required this.label,
    this.parentId,
  });

  final String id;
  final String label;
  final String? parentId;
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
}) {
  return showUtenAdaptivePanel<WarehousePickerResult>(
    context: context,
    builder: (_) => _WarehousePickerSheet(
      hierarchy: hierarchy,
      initialWarehouseId: initialWarehouseId,
      title: title,
    ),
  );
}

class _WarehousePickerSheet extends StatefulWidget {
  const _WarehousePickerSheet({
    required this.hierarchy,
    required this.title,
    this.initialWarehouseId,
  });

  final List<WarehouseDictEntry> hierarchy;
  final String title;
  final String? initialWarehouseId;

  @override
  State<_WarehousePickerSheet> createState() => _WarehousePickerSheetState();
}

class _WarehousePickerSheetState extends State<_WarehousePickerSheet> {
  /// 当前层级的父仓 id 栈：null = 顶层（主仓列表）。
  final List<String> _drilldown = [];
  late final WarehouseSelection _selection;

  @override
  void initState() {
    super.initState();
    _selection = WarehouseSelection(widget.hierarchy);
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

  bool _hasChildren(String id) =>
      widget.hierarchy.any((entry) => entry.parentId == id);

  List<WarehouseDictEntry> get _visibleEntries {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _visibleEntries;
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
                          _drilldown.isEmpty
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
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s24),
                        child: Text(
                          '没有可选仓库，请先在基础资料维护仓库',
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
                          leading: Icon(
                            hasChildren
                                ? Icons.warehouse_outlined
                                : Icons.inventory_2_outlined,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          title: Text(
                            warehouseFullLabel(widget.hierarchy, entry.id) ??
                                entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: isCurrent
                              ? Icon(
                                  Icons.check_circle_rounded,
                                  color: theme.colorScheme.primary,
                                )
                              : hasChildren
                              ? const Icon(Icons.chevron_right_rounded)
                              : null,
                          onTap: () {
                            if (hasChildren) {
                              setState(() => _drilldown.add(entry.id));
                              return;
                            }
                            Navigator.of(context).pop(
                              WarehousePickerResult(
                                id: entry.id,
                                label:
                                    warehouseFullLabel(
                                      widget.hierarchy,
                                      entry.id,
                                    ) ??
                                    entry.name,
                                parentId: entry.parentId,
                              ),
                            );
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

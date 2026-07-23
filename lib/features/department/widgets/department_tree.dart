// DepartmentTree - 部门树（feature 组件，手机抽屉/桌面分栏复用）
// 文档：docs/03-页面/部门管理页.md
// 递归渲染组织架构；选中高亮、可选删除按钮。改这里全站部门树一致。
import 'package:flutter/material.dart';

import '../models/department_node.dart';

class DepartmentTree extends StatelessWidget {
  const DepartmentTree({
    super.key,
    required this.nodes,
    required this.selectedId,
    required this.onSelect,
    this.onDelete,
    this.initiallyExpandDepth = 1,
    this.showHeader = true,
  });

  final List<DepartmentNode> nodes;
  final String? selectedId;
  final void Function(String) onSelect;
  final void Function(DepartmentNode)? onDelete;
  final int initiallyExpandDepth;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            color: theme.colorScheme.surface,
            child: Text('组织架构', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [for (final n in nodes) _buildNode(n, 0, context)],
          ),
        ),
      ],
    );
  }

  Widget _buildNode(DepartmentNode node, int depth, BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = node.id == selectedId;
    final hasChildren = node.children.isNotEmpty;
    final title = GestureDetector(
      onTap: () => onSelect(node.id),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Row(children: [
          Icon(hasChildren ? Icons.account_tree_outlined : Icons.circle_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(node.name, overflow: TextOverflow.ellipsis)),
          if (node.headcount != null && node.headcount! > 0)
            Text('${node.headcount}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          if (onDelete != null) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: () => onDelete!(node),
              child: const Icon(Icons.delete_outline, size: 16, color: Colors.grey),
            ),
          ],
        ]),
      ),
    );
    if (!hasChildren) {
      return Padding(padding: EdgeInsets.only(left: depth * 12.0, right: 8, top: 1, bottom: 1), child: title);
    }
    return ExpansionTile(
      initiallyExpanded: depth < initiallyExpandDepth,
      tilePadding: EdgeInsets.only(left: depth * 8.0, right: 8),
      dense: true,
      title: title,
      children: [for (final c in node.children) _buildNode(c, depth + 1, context)],
    );
  }
}

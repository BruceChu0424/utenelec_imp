import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/feedback/uten_context_menu.dart';
import '../../core/theme/uten_tokens.dart';
import 'uten_hierarchy_tree_view.dart' show UtenHierarchyRowSkin;

/// 一个树节点动作的唯一描述。行内按钮与右键菜单共用文案、可用性与回调。
class UtenHierarchyNodeOperation {
  const UtenHierarchyNodeOperation({
    required this.label,
    required this.icon,
    required this.onInvoke,
    this.tooltip,
    this.buttonKey,
    this.destructive = false,
    this.enabled = true,
    this.showInline = true,
  });

  final String label;
  final IconData icon;
  final FutureOr<void> Function() onInvoke;
  final String? tooltip;
  final Key? buttonKey;
  final bool destructive;
  final bool enabled;
  final bool showInline;

  UtenMenuItem get menuItem => UtenMenuItem(
    label: label,
    icon: icon,
    onTap: onInvoke,
    enabled: enabled,
    destructive: destructive,
  );
}

/// 权限与对象保护只在宿主组装这一份配置时决定，不为图标和菜单各判断一次。
/// [extra] 可放负责人、启停等动作；[UtenHierarchyNodeOperation.showInline] 为
/// false 时保留菜单入口。受保护节点的 [deleteReplacement] 同时阻止删除菜单。
class UtenHierarchyNodeOperations {
  const UtenHierarchyNodeOperations({
    this.add,
    this.edit,
    this.delete,
    this.extra = const [],
    this.deleteReplacement,
    this.trailing = const [],
  });

  final UtenHierarchyNodeOperation? add;
  final UtenHierarchyNodeOperation? edit;
  final UtenHierarchyNodeOperation? delete;
  final List<UtenHierarchyNodeOperation> extra;
  final Widget? deleteReplacement;
  final List<Widget> trailing;

  UtenHierarchyNodeOperation? get effectiveDelete =>
      deleteReplacement == null ? delete : null;

  List<UtenContextMenuEntry> get menuEntries {
    final entries = <UtenContextMenuEntry>[
      if (add case final action?) action.menuItem,
      if (edit case final action?) action.menuItem,
      for (final action in extra) action.menuItem,
    ];
    if (effectiveDelete case final action?) {
      if (entries.isNotEmpty) entries.add(const UtenMenuDivider());
      entries.add(action.menuItem);
    }
    return entries;
  }
}

/// 树行共用的新增、编辑、删除动作，颜色跟随所在层级行的皮肤。
/// 右键菜单从同一份 [operations] 的 menuEntries 生成。
class UtenHierarchyNodeActions extends StatelessWidget {
  const UtenHierarchyNodeActions({super.key, required this.operations});

  final UtenHierarchyNodeOperations operations;

  @override
  Widget build(BuildContext context) {
    final configured = operations;
    final hitExtent = UtenControlMetrics.minimumHitExtent(context, desktop: 32);
    final foreground =
        UtenHierarchyRowSkin.maybeOf(context)?.foreground ??
        Theme.of(context).colorScheme.onSurfaceVariant;

    Widget action(UtenHierarchyNodeOperation operation) => IconButton(
      key: operation.buttonKey,
      tooltip: operation.tooltip ?? operation.label,
      constraints: BoxConstraints.tightFor(width: hitExtent, height: hitExtent),
      padding: EdgeInsets.zero,
      onPressed: operation.enabled ? () => operation.onInvoke() : null,
      icon: Icon(operation.icon, size: 16, color: foreground),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (configured.add case final operation? when operation.showInline)
          action(operation),
        if (configured.edit case final operation? when operation.showInline)
          action(operation),
        if (configured.deleteReplacement case final replacement?)
          replacement
        else if (configured.effectiveDelete case final operation?
            when operation.showInline)
          action(operation),
        for (final operation in configured.extra)
          if (operation.showInline) action(operation),
        ...configured.trailing,
      ],
    );
  }
}

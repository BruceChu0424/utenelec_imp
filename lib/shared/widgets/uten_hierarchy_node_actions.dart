import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/feedback/uten_context_menu.dart';

/// 一个树节点动作的唯一描述。详情卡与右键菜单共用文案、可用性与回调。
class UtenHierarchyNodeOperation {
  const UtenHierarchyNodeOperation({
    required this.label,
    required this.icon,
    required this.onInvoke,
    this.tooltip,
    this.buttonKey,
    this.destructive = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final FutureOr<void> Function() onInvoke;
  final String? tooltip;
  final Key? buttonKey;
  final bool destructive;
  final bool enabled;

  UtenMenuItem get menuItem => UtenMenuItem(
    label: label,
    icon: icon,
    onTap: onInvoke,
    enabled: enabled,
    destructive: destructive,
  );
}

/// 权限与对象保护只在宿主组装这一份配置时决定。
/// [extra] 可放负责人、启停等动作。受保护节点的 [deleteReplacement] 阻止删除菜单。
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

/// 树行只保留保护提示和业务标记，管理动作集中在详情卡及右键菜单。
class UtenHierarchyNodeActions extends StatelessWidget {
  const UtenHierarchyNodeActions({super.key, required this.operations});

  final UtenHierarchyNodeOperations operations;

  @override
  Widget build(BuildContext context) {
    final configured = operations;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [?configured.deleteReplacement, ...configured.trailing],
    );
  }
}

import 'package:flutter/material.dart';

import '../../../components/layout/uten_split_view.dart';
import '../../../core/theme/uten_tokens.dart';

/// 页面三个模式共享拖动宽度；仅重建布局，不重挂载各模式的草稿。
class AdminPermissionWorkspaceScope
    extends InheritedNotifier<ValueNotifier<double?>> {
  const AdminPermissionWorkspaceScope({
    super.key,
    required ValueNotifier<double?> leadingWidth,
    required super.child,
  }) : super(notifier: leadingWidth);

  static ValueNotifier<double?>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AdminPermissionWorkspaceScope>()
      ?.notifier;
}

/// Three authorization modes share one navigation position and pane geometry.
/// Each mode owns its drafts above this layout, so changing the available width
/// never discards pending permission edits.
class AdminPermissionWorkspace extends StatelessWidget {
  const AdminPermissionWorkspace({
    super.key,
    required this.navigation,
    required this.leading,
    required this.trailing,
    required this.compact,
  });

  final Widget navigation;
  final Widget leading;
  final Widget trailing;
  final Widget compact;

  @override
  Widget build(BuildContext context) {
    final sharedWidth = AdminPermissionWorkspaceScope.maybeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1000) {
          return UtenSplitView(
            leadingNoun: '权限资源',
            selectedLeadingLabel: '查看权限资源',
            persistenceKey: 'admin.permissions',
            initialLeadingWidth: 320,
            controlledLeadingWidth: sharedWidth?.value,
            onWidthChanged: sharedWidth == null
                ? null
                : (value) => sharedWidth.value = value,
            leading: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                navigation,
                Expanded(child: leading),
              ],
            ),
            trailing: trailing,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            navigation,
            const SizedBox(height: UtenSpacing.s4),
            Expanded(child: compact),
          ],
        );
      },
    );
  }
}

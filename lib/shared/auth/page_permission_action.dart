import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive/breakpoint.dart';
import '../../core/router/route_names.dart';
import 'page_permission_delegation_repository.dart';
import 'page_permission_scope.dart';

/// 业务页右上角统一“权限设置”入口。
///
/// 超级管理员与普通负责人均由服务端 capability（含发布门禁）终审；普通员工
/// 是否为负责人只基于 departments.manager_id 与组织树，前端职位文字不参与授权。
class PagePermissionAction extends ConsumerWidget {
  const PagePermissionAction({super.key, this.scope});

  final PagePermissionScope? scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = scope ?? _scopeFromRouter(context);
    if (resolved == null) return const SizedBox.shrink();

    final capability = ref.watch(
      pageDelegationCapabilityProvider(resolved.surfaceKey),
    );
    return capability.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (value) => value.canManage
          ? _PagePermissionButton(scope: resolved)
          : const SizedBox.shrink(),
    );
  }
}

class _PagePermissionButton extends StatelessWidget {
  const _PagePermissionButton({required this.scope});

  final PagePermissionScope scope;

  @override
  Widget build(BuildContext context) {
    final tooltip = '设置「${scope.title}」本页权限';
    void open() => context.push(RouteName.pagePermissionsFor(scope.surfaceKey));

    if (context.breakpoint.isExpanded) {
      return TextButton.icon(
        key: const ValueKey('page-permission-action'),
        onPressed: open,
        icon: const Icon(Icons.admin_panel_settings_outlined, size: 20),
        label: const Text('权限设置'),
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      );
    }
    return IconButton(
      key: const ValueKey('page-permission-action'),
      onPressed: open,
      tooltip: tooltip,
      icon: const Icon(Icons.admin_panel_settings_outlined),
    );
  }
}

PagePermissionScope? _scopeFromRouter(BuildContext context) {
  try {
    return pagePermissionScopeFor(GoRouterState.of(context).uri.toString());
  } catch (_) {
    // 独立预览或 widget test 可能不在 go_router 下；fail closed。
    return null;
  }
}

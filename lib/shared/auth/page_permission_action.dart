import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_app_bar_action_button.dart';
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

    // 顶栏动作统一形态（深绿实心白字、固定 36 高），与「草稿(N)」同款；
    // 窄屏只收文案不改形态（此前宽屏 TextButton、窄屏 IconButton 是两种长相）。
    return UtenAppBarActionButton(
      key: const ValueKey('page-permission-action'),
      icon: Icons.admin_panel_settings_outlined,
      label: '权限设置',
      tooltip: tooltip,
      compact: !context.breakpoint.isExpanded,
      onPressed: open,
    );
  }
}

PagePermissionScope? _scopeFromRouter(BuildContext context) {
  try {
    // 只认「直接挂载本组件的 go_router 页路由」。命令式 Navigator.push 的
    // 子弹层（分桶详情、向导、抽屉页等）没有独立路由 scope，必须 fail-closed：
    // 若放任 GoRouterState.of 向上爬到宿主路由，会在 LayoutBuilder 布局期对
    // GoRouterStateRegistry（InheritedNotifier/ChangeNotifier）建立跨路由
    // inherited 依赖，go_router 14.8 下触发无限重挂载循环——真机点开分桶
    // 详情即整站卡死（栈 600+ 层直至进程栈溢出死亡）。
    final settings = ModalRoute.of(context)?.settings;
    if (settings is! Page) return null;
    return pagePermissionScopeFor(GoRouterState.of(context).uri.toString());
  } catch (_) {
    // 独立预览或 widget test 可能不在 go_router 下；fail closed。
    return null;
  }
}

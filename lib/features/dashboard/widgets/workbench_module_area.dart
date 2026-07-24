// WorkbenchModuleArea - 工作台功能模块区（原侧边栏分组迁入）
//
// 显隐规则（单一数据源）：
//   每个模块的可见性 = 用户是否拥有「目标路由所需权限点」，
//   权限点查 core/router/permission_by_path.dart 的 requiredPermFor() ——
//   与路由守卫同一份映射，超管给谁授了什么权限，这里自动出现什么模块。
//   映射为 null 的（如工资条/报销/建议箱）= 登录即可见。
//   整组不可见时组标题也不渲染。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/permission_by_path.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../hr_profile/widgets/hr_pending_badge.dart';
import '../../visitor_approval/widgets/visitor_pending_badge.dart';

class WorkbenchModuleArea extends ConsumerWidget {
  const WorkbenchModuleArea({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    final groups = <_ModuleGroup>[
      const _ModuleGroup(
        title: '常用功能',
        color: UtenColors.teal600,
        items: [
          _ModuleItem(
            icon: Icons.account_balance_wallet_outlined,
            label: '工资条',
            location: RouteName.payrollSlipList,
          ),
          _ModuleItem(
            icon: Icons.receipt_long_outlined,
            label: '我的报销',
            location: RouteName.expense,
          ),
          _ModuleItem(
            icon: Icons.lightbulb_outline_rounded,
            label: '建议箱',
            location: RouteName.suggestion,
          ),
          _ModuleItem(
            icon: Icons.person_search_outlined,
            label: '我的访客',
            location: RouteName.myVisitors,
            badge: const VisitorHostPendingBadge(),
          ),
        ],
      ),
      _ModuleGroup(
        title: l10n.navHrGroup,
        color: UtenColors.info,
        items: [
          _ModuleItem(
            icon: Icons.badge_outlined,
            label: l10n.navHrEmployees,
            location: RouteName.employee,
          ),
          _ModuleItem(
            icon: Icons.account_tree_outlined,
            label: l10n.navHrDepartments,
            location: RouteName.department,
          ),
          _ModuleItem(
            icon: Icons.person_add_outlined,
            label: l10n.navHrOnboarding,
            location: '/employee/onboarding',
          ),
          _ModuleItem(
            icon: Icons.campaign_outlined,
            label: l10n.navHrNoticePublish,
            location: '/notice/publish',
          ),
          _ModuleItem(
            icon: Icons.how_to_reg_outlined,
            label: l10n.visitorApprovalTitle,
            location: RouteName.visitorApproval,
            badge: const VisitorPendingBadge(),
          ),
          _ModuleItem(
            icon: Icons.assignment_late_outlined,
            label: l10n.profileChangeHrQueueTitle,
            location: RouteName.hrProfileChanges,
            badge: const HrPendingBadge(),
          ),
        ],
      ),
      _ModuleGroup(
        title: '财务管理',
        color: UtenColors.success,
        items: [
          const _ModuleItem(
            icon: Icons.fact_check_outlined,
            label: '报销审批',
            location: '/expense/approval',
          ),
          // 工资条生成归属财务（V26：payroll:generate 仅 finance/admin 持有）
          _ModuleItem(
            icon: Icons.request_quote_outlined,
            label: l10n.navHrPayrollGenerate,
            location: '/payroll/generate',
          ),
          const _ModuleItem(
            icon: Icons.rate_review_outlined,
            label: '工资条审核',
            location: '/payroll/review',
          ),
          const _ModuleItem(
            icon: Icons.bar_chart_outlined,
            label: '财务报表',
            location: '/finance/report',
          ),
        ],
      ),
      const _ModuleGroup(
        title: '生产管理',
        color: UtenColors.warning,
        items: [
          _ModuleItem(
            icon: Icons.science_outlined,
            label: '检测记录',
            location: '/lab/test',
          ),
          _ModuleItem(
            icon: Icons.hvac_outlined,
            label: '空调控制',
            location: '/hvac',
          ),
          _ModuleItem(
            icon: Icons.view_timeline_outlined,
            label: '流水线看板',
            location: '/production/line',
          ),
          _ModuleItem(
            icon: Icons.edit_note_outlined,
            label: '产量录入',
            location: '/production/output/entry',
          ),
          _ModuleItem(
            icon: Icons.insights_outlined,
            label: '产量统计',
            location: '/production/output',
          ),
          _ModuleItem(
            icon: Icons.inventory_2_outlined,
            label: '库存查询',
            location: '/inventory',
          ),
          _ModuleItem(
            icon: Icons.swap_vert_rounded,
            label: '出入库记录',
            location: '/inventory/movement',
          ),
        ],
      ),
      const _ModuleGroup(
        title: '决策支持',
        color: UtenColors.teal900,
        items: [
          _ModuleItem(
            icon: Icons.space_dashboard_outlined,
            label: '经营 Dashboard',
            location: '/analytics/dashboard',
          ),
          _ModuleItem(
            icon: Icons.query_stats_outlined,
            label: '多维分析',
            location: '/analytics/explore',
          ),
          _ModuleItem(
            icon: Icons.notifications_active_outlined,
            label: '异常告警',
            location: '/analytics/alerts',
          ),
        ],
      ),
      _ModuleGroup(
        title: l10n.securityTitle,
        color: UtenColors.teal600,
        items: [
          _ModuleItem(
            icon: Icons.qr_code_scanner_rounded,
            label: l10n.securityTitle,
            location: RouteName.securityScan,
          ),
        ],
      ),
      const _ModuleGroup(
        title: '系统管理',
        color: UtenColors.teal900,
        items: [
          _ModuleItem(
            icon: Icons.admin_panel_settings_outlined,
            label: '权限管理',
            location: RouteName.adminPermissions,
          ),
        ],
      ),
    ];

    // 按权限点过滤：requiredPermFor 为 null = 登录即可见；超管全量放行
    final isSuper = ref.watch(isSuperAdminProvider);
    final perms = ref.watch(currentPermissionsProvider);
    bool visible(String location) {
      final perm = requiredPermFor(location);
      if (perm == null) return true;
      return isSuper || perms.contains(perm);
    }

    final visibleGroups = [
      for (final g in groups)
        if (g.items.any((it) => visible(it.location)))
          (
            group: g,
            items: [
              for (final it in g.items)
                if (visible(it.location)) it,
            ],
          ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in visibleGroups) ...[
          // 每组可折叠：模块多时收起不常用的分组
          UtenCollapsibleSection(
            title: entry.group.title,
            accentColor: entry.group.color,
            child: UtenResponsiveGrid(
              itemCount: entry.items.length,
              spacing: UtenSpacing.s12,
              columns: const UtenResponsiveColumns(compact: 2, medium: 3),
              itemBuilder: (context, i, itemWidth) =>
                  _ModuleTile(item: entry.items[i], color: entry.group.color),
            ),
          ),
          const SizedBox(height: UtenSpacing.s24),
        ],
      ],
    );
  }
}

class _ModuleItem {
  const _ModuleItem({
    required this.icon,
    required this.label,
    required this.location,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String location;

  /// 右上角待办徽章（如 HrPendingBadge / VisitorPendingBadge；>0 自动显示）
  final Widget? badge;
}

class _ModuleGroup {
  const _ModuleGroup({
    required this.title,
    required this.color,
    required this.items,
  });

  final String title;

  /// 组主题色（组标题色点 + 模块图标底色）
  final Color color;
  final List<_ModuleItem> items;
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({required this.item, required this.color});

  final _ModuleItem item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go(item.location),
        child: Stack(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                vertical: UtenSpacing.s16,
                horizontal: UtenSpacing.s12,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: UtenRadius.lgAll,
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Icon(item.icon, color: color, size: 19),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: Text(
                      item.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            if (item.badge != null)
              Positioned(
                top: UtenSpacing.s4,
                right: UtenSpacing.s4,
                child: item.badge!,
              ),
          ],
        ),
      ),
    );
  }
}

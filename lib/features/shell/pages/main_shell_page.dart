// MainShellPage - App 响应式外壳（多角色分组导航）
// 文档：docs/03-页面/App外壳.md · docs/05-架构/全局机制.md（按角色显隐）
//
// compact (<600dp)：底部 NavigationBar（4 项：工作台/通知/我的/设置）
// medium (600-840dp)：折叠 NavigationRail（只图标）
// expanded (>840dp)：展开侧栏（分组导航 + 业务模块）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/assets.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../shared/models/role.dart';
import '../../../shared/providers/session_provider.dart';

class MainShellPage extends ConsumerWidget {
  const MainShellPage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final location = GoRouterState.of(context).matchedLocation;

    final primaryDestinations = <_NavDestination>[
      _NavDestination(
        icon: Icons.dashboard_outlined,
        selectedIcon: Icons.dashboard_rounded,
        label: l10n.navDashboard,
        location: RouteName.dashboard,
      ),
      const _NavDestination(
        icon: Icons.notifications_none_rounded,
        selectedIcon: Icons.notifications_rounded,
        label: '通知',
        location: RouteName.notice,
      ),
      _NavDestination(
        icon: Icons.person_outline_rounded,
        selectedIcon: Icons.person_rounded,
        label: l10n.navProfile,
        location: RouteName.profile,
      ),
      _NavDestination(
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings_rounded,
        label: l10n.navSettings,
        location: RouteName.settings,
      ),
    ];

    // 角色分组（按角色显隐）
    final allGroups = <_NavGroup>[
      _NavGroup(
        title: '业务模块',
        roles: null,
        items: [
          const _NavDestination(
            icon: Icons.account_balance_wallet_outlined,
            selectedIcon: Icons.account_balance_wallet_rounded,
            label: '工资条',
            location: '/payroll/slip',
          ),
          const _NavDestination(
            icon: Icons.receipt_long_outlined,
            selectedIcon: Icons.receipt_long_rounded,
            label: '我的报销',
            location: '/expense',
          ),
          const _NavDestination(
            icon: Icons.lightbulb_outline_rounded,
            selectedIcon: Icons.lightbulb_rounded,
            label: '建议箱',
            location: '/suggestion',
          ),
          _NavDestination(
            icon: Icons.person_search_outlined,
            selectedIcon: Icons.person_search_rounded,
            label: l10n.myVisitorsTitle,
            location: RouteName.myVisitors,
          ),
        ],
      ),
      _NavGroup(
        title: l10n.navHrGroup,
        roles: [Role.hr, Role.admin, Role.manager],
        items: [
          _NavDestination(
            icon: Icons.badge_outlined,
            selectedIcon: Icons.badge_rounded,
            label: l10n.navHrEmployees,
            location: '/employee',
          ),
          _NavDestination(
            icon: Icons.account_tree_outlined,
            selectedIcon: Icons.account_tree_rounded,
            label: l10n.navHrDepartments,
            location: '/department',
          ),
          _NavDestination(
            icon: Icons.person_add_outlined,
            selectedIcon: Icons.person_add_rounded,
            label: l10n.navHrOnboarding,
            location: '/employee/onboarding',
          ),
          _NavDestination(
            icon: Icons.request_quote_outlined,
            selectedIcon: Icons.request_quote_rounded,
            label: l10n.navHrPayrollGenerate,
            location: '/payroll/generate',
          ),
          _NavDestination(
            icon: Icons.campaign_outlined,
            selectedIcon: Icons.campaign_rounded,
            label: l10n.navHrNoticePublish,
            location: '/notice/publish',
          ),
          _NavDestination(
            icon: Icons.how_to_reg_outlined,
            selectedIcon: Icons.how_to_reg_rounded,
            label: l10n.visitorApprovalTitle,
            location: RouteName.visitorApproval,
          ),
        ],
      ),
      const _NavGroup(
        title: '财务管理',
        roles: [Role.finance, Role.admin, Role.manager],
        items: [
          _NavDestination(
            icon: Icons.fact_check_outlined,
            selectedIcon: Icons.fact_check_rounded,
            label: '报销审批',
            location: '/expense/approval',
          ),
          _NavDestination(
            icon: Icons.rate_review_outlined,
            selectedIcon: Icons.rate_review_rounded,
            label: '工资条审核',
            location: '/payroll/review',
          ),
          _NavDestination(
            icon: Icons.bar_chart_outlined,
            selectedIcon: Icons.bar_chart_rounded,
            label: '财务报表',
            location: '/finance/report',
          ),
        ],
      ),
      const _NavGroup(
        title: '生产管理',
        roles: [Role.production, Role.admin, Role.manager],
        items: [
          _NavDestination(
            icon: Icons.science_outlined,
            selectedIcon: Icons.science_rounded,
            label: '检测记录',
            location: '/lab/test',
          ),
          _NavDestination(
            icon: Icons.hvac_outlined,
            selectedIcon: Icons.hvac_rounded,
            label: '空调控制',
            location: '/hvac',
          ),
          _NavDestination(
            icon: Icons.view_timeline_outlined,
            selectedIcon: Icons.view_timeline_rounded,
            label: '流水线看板',
            location: '/production/line',
          ),
          _NavDestination(
            icon: Icons.edit_note_outlined,
            selectedIcon: Icons.edit_note_rounded,
            label: '产量录入',
            location: '/production/output/entry',
          ),
          _NavDestination(
            icon: Icons.insights_outlined,
            selectedIcon: Icons.insights_rounded,
            label: '产量统计',
            location: '/production/output',
          ),
          _NavDestination(
            icon: Icons.inventory_2_outlined,
            selectedIcon: Icons.inventory_2_rounded,
            label: '库存查询',
            location: '/inventory',
          ),
          _NavDestination(
            icon: Icons.swap_vert_rounded,
            selectedIcon: Icons.swap_vert_rounded,
            label: '出入库记录',
            location: '/inventory/movement',
          ),
        ],
      ),
      const _NavGroup(
        title: '决策支持',
        roles: [Role.manager, Role.admin],
        items: [
          _NavDestination(
            icon: Icons.space_dashboard_outlined,
            selectedIcon: Icons.space_dashboard_rounded,
            label: '经营 Dashboard',
            location: '/analytics/dashboard',
          ),
          _NavDestination(
            icon: Icons.query_stats_outlined,
            selectedIcon: Icons.query_stats_rounded,
            label: '多维分析',
            location: '/analytics/explore',
          ),
          _NavDestination(
            icon: Icons.notifications_active_outlined,
            selectedIcon: Icons.notifications_active_rounded,
            label: '异常告警',
            location: '/analytics/alerts',
          ),
        ],
      ),
      _NavGroup(
        title: l10n.securityTitle,
        roles: [Role.security, Role.admin],
        items: [
          _NavDestination(
            icon: Icons.qr_code_scanner_rounded,
            selectedIcon: Icons.qr_code_scanner_rounded,
            label: l10n.securityTitle,
            location: RouteName.securityScan,
          ),
        ],
      ),
    ];

    final userRoles = ref.watch(
      sessionProvider.select((s) => s.user?.roles ?? const <Role>[]),
    );
    final groups = allGroups
        .where((g) => g.roles == null || g.roles!.any(userRoles.contains))
        .toList();

    final breakpoint = context.breakpoint;

    // 所有 destination 的 location，用于 _isActive 的最长前缀匹配
    final allLocations = <String>[
      for (final d in primaryDestinations) d.location,
      for (final g in groups)
        for (final d in g.items) d.location,
    ];

    return Scaffold(
      body: switch (breakpoint) {
        UtenBreakpoint.compact => _CompactShell(
          destinations: primaryDestinations,
          currentLocation: location,
          child: child,
        ),
        UtenBreakpoint.medium || UtenBreakpoint.expanded => _ExpandedShell(
          primaryDestinations: primaryDestinations,
          groups: groups,
          currentLocation: location,
          allLocations: allLocations,
          expanded: breakpoint.isExpanded,
          child: child,
        ),
      },
    );
  }
}

class _NavDestination {
  const _NavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.location,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String location;
}

class _NavGroup {
  const _NavGroup({
    required this.title,
    required this.roles,
    required this.items,
  });
  final String title;
  final List<Role>? roles;
  final List<_NavDestination> items;
}

bool _isActive(String current, String target, List<String> allLocations) {
  // 必须自身能匹配（精确或前缀）
  final selfHit = current == target || current.startsWith('$target/');
  if (!selfHit) return false;
  // 但如果存在更具体的 sibling 也匹配，则让位给 sibling
  for (final loc in allLocations) {
    if (loc.length <= target.length) continue;
    if (current == loc || current.startsWith('$loc/')) return false;
  }
  return true;
}

int _primaryIndex(String location, List<_NavDestination> all) {
  final allLocs = [for (final d in all) d.location];
  for (var i = 0; i < all.length; i++) {
    if (_isActive(location, all[i].location, allLocs)) return i;
  }
  return 0;
}

class _CompactShell extends StatelessWidget {
  const _CompactShell({
    required this.destinations,
    required this.currentLocation,
    required this.child,
  });

  final List<_NavDestination> destinations;
  final String currentLocation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final currentIndex = _primaryIndex(currentLocation, destinations);

    return Scaffold(
      body: SafeArea(child: child),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (i) => context.go(destinations[i].location),
        destinations: [
          for (final d in destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

class _ExpandedShell extends StatelessWidget {
  const _ExpandedShell({
    required this.primaryDestinations,
    required this.groups,
    required this.currentLocation,
    required this.allLocations,
    required this.child,
    required this.expanded,
  });

  final List<_NavDestination> primaryDestinations;
  final List<_NavGroup> groups;
  final String currentLocation;
  final List<String> allLocations;
  final Widget child;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Row(
        children: [
          Container(
            width: expanded ? 240 : 72,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                right: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 24,
                    horizontal: 16,
                  ),
                  child: _Logo(expanded: expanded),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    children: [
                      for (final d in primaryDestinations)
                        _NavItem(
                          destination: d,
                          expanded: expanded,
                          isSelected: _isActive(
                            currentLocation,
                            d.location,
                            allLocations,
                          ),
                          onTap: () => context.go(d.location),
                        ),
                      for (final g in groups) ...[
                        if (expanded)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                            child: Text(
                              g.title,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                          )
                        else ...[
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Divider(
                              height: 1,
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                        for (final d in g.items)
                          _NavItem(
                            destination: d,
                            expanded: expanded,
                            isSelected: _isActive(
                              currentLocation,
                              d.location,
                              allLocations,
                            ),
                            onTap: () => context.go(d.location),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: SafeArea(left: false, child: child)),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.expanded,
    required this.isSelected,
    required this.onTap,
  });

  final _NavDestination destination;
  final bool expanded;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedColor = UtenColors.teal400;
    final iconColor = isSelected
        ? selectedColor
        : theme.colorScheme.onSurfaceVariant;
    final textColor = isSelected ? selectedColor : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: isSelected
            ? (theme.brightness == Brightness.dark
                  ? UtenColors.teal900.withValues(alpha: 0.3)
                  : UtenColors.surfaceMid)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: 10,
              horizontal: expanded ? 12 : 0,
            ),
            child: expanded
                ? Row(
                    children: [
                      Icon(
                        isSelected
                            ? destination.selectedIcon
                            : destination.icon,
                        size: 20,
                        color: iconColor,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          destination.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSelected
                            ? destination.selectedIcon
                            : destination.icon,
                        size: 22,
                        color: iconColor,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        destination.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 10,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.expanded});
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final logoSize = expanded ? 42.0 : 40.0;

    final logo = Container(
      width: logoSize,
      height: logoSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        UtenAssets.logoIp,
        fit: BoxFit.cover,
        semanticLabel: l10n.appTitle,
      ),
    );

    if (!expanded) return logo;

    return Row(
      children: [
        logo,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.appTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                l10n.appName,
                maxLines: 1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

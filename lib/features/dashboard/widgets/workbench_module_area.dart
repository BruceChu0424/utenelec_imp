// WorkbenchModuleArea - 工作台功能模块区（按部门分区，可折叠、可拖动排序）
//
// 分区重划说明：
// - 旧「决策支持」组取消，三项并入「系统管理」；
// - 旧「访客核验」组先并入行政与人力资源部，后应要求独立为「安保部」分区（访客核验）；
// - 「生产管理」拆分为 生产部 / PMC运营部 / 品质管理部；
// - 「财务管理」扩为「财税部」，新增 采购/客户/供应商/账户（占位页，权限已种子化）；
// - 工程研发部 / 综合营销部 / 新媒体事业部 / 轨道事业部 暂无卡片（空分组）。
// 组名全部硬编码中文，不引用 l10n。
//
// 显隐规则（单一数据源）：
//   每个模块的可见性 = 用户是否拥有「目标路由所需权限点」，
//   权限点查 core/router/permission_by_path.dart 的 requiredAnyPermFor() ——
//   与路由守卫同一份映射，支持"多级权限任一满足"（如客户资料 self/department/all）。
//   映射为 null 的（如工资条/报销/意见箱/基础资料）= 登录即可见。
//   普通用户：整组无可见卡片则整组不渲染；
//   超级管理员：显示全部分组（含空分组），空分组内显示「功能规划接入中」占位，
//   方便超管预先排列布局。
//
// 布局持久化：
//   分组顺序 + 折叠状态由 providers/workbench_layout_provider.dart 驱动，
//   本地 shared_preferences 缓存 + 服务端 /user/preferences 防抖同步。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/permission_by_path.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../hr_profile/widgets/hr_pending_badge.dart';
import '../../visitor_approval/widgets/visitor_pending_badge.dart';
import '../providers/workbench_layout_provider.dart';

class WorkbenchModuleArea extends ConsumerWidget {
  const WorkbenchModuleArea({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 按权限点过滤：requiredAnyPermFor 为 null = 登录即可见；超管全量放行
    final isSuper = ref.watch(isSuperAdminProvider);
    final perms = ref.watch(currentPermissionsProvider);
    final layout = ref.watch(workbenchLayoutProvider);
    final layoutNotifier = ref.read(workbenchLayoutProvider.notifier);

    bool visible(String location) {
      final required = requiredAnyPermFor(location);
      if (required == null) return true;
      return isSuper || required.any(perms.contains);
    }

    // 每组过滤出可见卡片
    final itemsOf = {
      for (final g in _allGroups)
        g.key: [for (final it in g.items) if (visible(it.location)) it],
    };

    // 分组可见性：超管全量（含空分组，便于预排布局）；普通用户只显示有可见卡片的分组
    bool groupVisible(_ModuleGroup g) =>
        isSuper || (itemsOf[g.key]?.isNotEmpty ?? false);

    final byKey = {for (final g in _allGroups) g.key: g};

    // 分区顺序 = 布局 Provider 的 order 过滤出当前可见分组；
    // 兜底补上 order 里缺失但可见的分组（理论上 merge 已保证齐全）
    final orderedKeys = <String>[
      for (final k in layout.order)
        if (byKey.containsKey(k) && groupVisible(byKey[k]!)) k,
      for (final g in _allGroups)
        if (!layout.order.contains(g.key) && groupVisible(g)) g.key,
    ];

    return ReorderableListView(
      // 外层 dashboard 已有 SingleChildScrollView：这里不自滚、按需撑高，
      // 避免嵌套滚动冲突，页面滚动手感保持正常
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // 关闭默认拖手柄，改用分区标题行右侧的自定义手柄（见 _dragHandle）
      buildDefaultDragHandles: false,
      // onReorderItem 的 newIndex 已按移除后位置调整（新版 API，替代废弃的 onReorder）
      onReorderItem: (oldIndex, newIndex) =>
          layoutNotifier.reorder(orderedKeys, oldIndex, newIndex),
      children: [
        for (var i = 0; i < orderedKeys.length; i++)
          _buildSection(
            context,
            key: ValueKey(orderedKeys[i]),
            index: i,
            group: byKey[orderedKeys[i]]!,
            items: itemsOf[orderedKeys[i]]!,
            expanded: !layout.collapsed.contains(orderedKeys[i]),
            onExpandedChanged: (_) =>
                layoutNotifier.toggleCollapsed(orderedKeys[i]),
          ),
      ],
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required Key key,
    required int index,
    required _ModuleGroup group,
    required List<_ModuleItem> items,
    required bool expanded,
    required ValueChanged<bool> onExpandedChanged,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
      child: UtenCollapsibleSection(
        title: group.title,
        accentColor: group.color,
        // 折叠状态受控：由布局 Provider 驱动（持久化到服务端）
        expanded: expanded,
        onExpandedChanged: onExpandedChanged,
        trailing: _dragHandle(context, index),
        child: items.isEmpty
            // 空分组（仅超管可见）：占位文案，功能规划接入中
            ? const _EmptyGroupPlaceholder()
            : UtenResponsiveGrid(
                itemCount: items.length,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 3),
                itemBuilder: (context, i, itemWidth) =>
                    _ModuleTile(item: items[i], color: group.color),
              ),
      ),
    );
  }

  /// 分区排序拖手柄：桌面/网页即按即拖，触屏平台长按拖动。
  /// 套一层 GestureDetector 吸收点击，避免点手柄误触折叠。
  Widget _dragHandle(BuildContext context, int index) {
    final platform = Theme.of(context).platform;
    final touch = platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.fuchsia;
    final handle = MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          Icons.drag_indicator_rounded,
          size: 20,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return GestureDetector(
      onTap: () {},
      child: touch
          ? ReorderableDelayedDragStartListener(index: index, child: handle)
          : ReorderableDragStartListener(index: index, child: handle),
    );
  }
}

/// 空分组占位（仅超管可见）：提示该部门功能尚未接入
class _EmptyGroupPlaceholder extends StatelessWidget {
  const _EmptyGroupPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        vertical: UtenSpacing.s20,
        horizontal: UtenSpacing.s16,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        '功能规划接入中',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

// ===== 分组定义（稳定 key 与 workbench_layout_provider.defaultOrder 对应）=====

const _allGroups = <_ModuleGroup>[
  _ModuleGroup(
    key: 'common',
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
        icon: Icons.person_search_outlined,
        label: '我的访客',
        location: RouteName.myVisitors,
        badge: VisitorHostPendingBadge(),
      ),
      // 基础资料 = 我的资料页（/profile 现有路由，登录即可访问）
      _ModuleItem(
        icon: Icons.person_outline_rounded,
        label: '基础资料',
        location: RouteName.profile,
      ),
      _ModuleItem(
        icon: Icons.lightbulb_outline_rounded,
        label: '意见箱',
        location: RouteName.suggestion,
      ),
    ],
  ),
  _ModuleGroup(
    key: 'hr',
    title: '行政与人力资源部',
    color: UtenColors.info,
    items: [
      _ModuleItem(
        icon: Icons.badge_outlined,
        label: '员工档案',
        location: RouteName.employee,
      ),
      _ModuleItem(
        icon: Icons.account_tree_outlined,
        label: '部门管理',
        location: RouteName.department,
      ),
      _ModuleItem(
        icon: Icons.person_add_outlined,
        label: '入职向导',
        location: '/employee/onboarding',
      ),
      _ModuleItem(
        icon: Icons.campaign_outlined,
        label: '通知发布',
        location: '/notice/publish',
      ),
      _ModuleItem(
        icon: Icons.how_to_reg_outlined,
        label: '访客审批',
        location: RouteName.visitorApproval,
        badge: VisitorPendingBadge(),
      ),
      _ModuleItem(
        icon: Icons.assignment_late_outlined,
        label: '信息变更审核',
        location: RouteName.hrProfileChanges,
        badge: HrPendingBadge(),
      ),
    ],
  ),
  _ModuleGroup(
    key: 'fin',
    title: '财税部',
    color: UtenColors.success,
    items: [
      // 以下四项为新模块（占位页），权限点已种子化
      _ModuleItem(
        icon: Icons.shopping_cart_outlined,
        label: '采购管理',
        location: RouteName.financePurchase,
      ),
      _ModuleItem(
        icon: Icons.people_alt_outlined,
        label: '客户资料',
        location: RouteName.financeCustomers,
      ),
      _ModuleItem(
        icon: Icons.local_shipping_outlined,
        label: '供应商资料',
        location: RouteName.financeSuppliers,
      ),
      _ModuleItem(
        icon: Icons.account_balance_outlined,
        label: '账户资料',
        location: RouteName.financeAccounts,
      ),
      _ModuleItem(
        icon: Icons.fact_check_outlined,
        label: '报销审批',
        location: '/expense/approval',
      ),
      // 工资条生成归属财务（payroll:generate 仅 finance/admin 持有）
      _ModuleItem(
        icon: Icons.request_quote_outlined,
        label: '工资条生成',
        location: '/payroll/generate',
      ),
      _ModuleItem(
        icon: Icons.rate_review_outlined,
        label: '工资条审核',
        location: '/payroll/review',
      ),
      _ModuleItem(
        icon: Icons.bar_chart_outlined,
        label: '财务报表',
        location: '/finance/report',
      ),
    ],
  ),
  _ModuleGroup(
    key: 'prod',
    title: '生产部',
    color: UtenColors.warning,
    items: [
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
        icon: Icons.hvac_outlined,
        label: '空调控制',
        location: '/hvac',
      ),
    ],
  ),
  // 空分组：暂无卡片，超管可见占位，功能规划接入中
  _ModuleGroup(
    key: 'eng',
    title: '工程研发部',
    color: UtenColors.teal700,
    items: [],
  ),
  _ModuleGroup(
    key: 'pmc',
    title: 'PMC运营部',
    color: UtenColors.slate700,
    items: [
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
  _ModuleGroup(
    key: 'qa',
    title: '品质管理部',
    color: UtenColors.teal500,
    items: [
      _ModuleItem(
        icon: Icons.science_outlined,
        label: '检测记录',
        location: '/lab/test',
      ),
    ],
  ),
  // 以下三个事业部暂无卡片（空分组，超管可见占位）
  _ModuleGroup(
    key: 'sales',
    title: '综合营销部',
    color: UtenColors.teal800,
    items: [],
  ),
  _ModuleGroup(
    key: 'newmedia',
    title: '新媒体事业部',
    color: UtenColors.slate500,
    items: [],
  ),
  _ModuleGroup(
    key: 'rail',
    title: '轨道事业部',
    color: UtenColors.teal700,
    items: [],
  ),
  // 安保部：门岗访客核验（对应部门树 DEPT_SECURITY 保安部）
  _ModuleGroup(
    key: 'security',
    title: '安保部',
    color: UtenColors.teal600,
    items: [
      _ModuleItem(
        icon: Icons.qr_code_scanner_rounded,
        label: '访客核验',
        location: RouteName.securityScan,
      ),
    ],
  ),
  _ModuleGroup(
    key: 'system',
    title: '系统管理',
    color: UtenColors.teal900,
    items: [
      _ModuleItem(
        icon: Icons.admin_panel_settings_outlined,
        label: '权限管理',
        location: RouteName.adminPermissions,
      ),
      // 旧「决策支持」独立分组取消，三项并入本组
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
];

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
    required this.key,
    required this.title,
    required this.color,
    required this.items,
  });

  /// 稳定 key：布局持久化（排序/折叠）以此为准，不随标题文案变化
  final String key;

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

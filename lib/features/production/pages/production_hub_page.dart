// 生产管理入口页（hub）—— 两个分组卡片（与 basic_data / purchase / warehouse hub 对齐）：
//  ① 生产管理（操作类 · 单据）：生产计划单 + 生产日报表
//  ② 生产报表（分析类）：计划明细 / 计划汇总 / 物料反查产成品
//
// 点卡片进对应列表/查询/报表页。卡片网格布局对齐采购 hub（UtenResponsiveGrid）。
//
// 路由统一使用 RouteName 常量；查看权限进入列表，新增动作由列表页按编辑权限控制。
//
// 注：原「BOM 成本展开」入口已下线（组装/BOM 数据并入 基础资料-货品资料「组装信息」页签）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/permission_by_path.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../widgets/production_pending_badge.dart';

class ProductionHubPage extends ConsumerWidget {
  const ProductionHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产管理',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            children: [
              _section(context, theme, '生产管理', const [
                // 调度+进度已合并为一个三 Tab 页面（待排产/进行中/已完成）
                _Entry(
                  icon: Icons.dashboard_customize_outlined,
                  label: '生产调度与进度',
                  description: '待排产 · 在产进度 · 已完成',
                  location: '/production/schedule',
                  badge: ProductionPendingBadge(),
                ),
                _Entry(
                  icon: Icons.assignment_outlined,
                  label: '生产计划单',
                  description: '计划单 · 明细 · 审核',
                  location: RouteName.productionPlanList,
                ),
                _Entry(
                  icon: Icons.edit_calendar_outlined,
                  label: '生产日报表',
                  description: '完工日报 · 审核 · 红冲',
                  location: RouteName.productionDailyReportList,
                ),
              ], permissions),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '生产报表', const [
                _Entry(
                  icon: Icons.list_alt_outlined,
                  label: '计划明细',
                  description: '日期 / 货品 / 状态',
                  location: '/production/reports/plan-detail',
                ),
                _Entry(
                  icon: Icons.bar_chart_outlined,
                  label: '计划汇总',
                  description: '单号 / 制单员 / 审核员',
                  location: '/production/reports/plan-summary',
                ),
                _Entry(
                  icon: Icons.find_in_page_outlined,
                  label: '物料反查产成品',
                  description: '查材料用在哪些产品',
                  location: '/production/where-used',
                ),
              ], permissions),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个分组：标题 + 卡片网格。
  Widget _section(
    BuildContext context,
    ThemeData theme,
    String title,
    List<_Entry> entries,
    Set<String> permissions,
  ) {
    final visibleEntries = entries
        .where((entry) {
          final required = requiredAnyPermFor(entry.location);
          return required == null || required.any(permissions.contains);
        })
        .toList(growable: false);
    if (visibleEntries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          UtenResponsiveGrid(
            itemCount: visibleEntries.length,
            spacing: UtenSpacing.s12,
            columns: const UtenResponsiveColumns(compact: 2, medium: 4),
            itemBuilder: (context, i, _) =>
                _EntryTile(entry: visibleEntries[i]),
          ),
        ],
      ),
    );
  }
}

class _Entry {
  const _Entry({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String description;
  final String location;

  /// 右上角待办徽章（如 ProductionPendingBadge；>0 自动显示）
  final Widget? badge;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => goFrom(context, entry.location),
        child: Stack(
          children: [
            Container(
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Icon(entry.icon, color: color, size: 22),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Text(
                    entry.label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (entry.badge != null)
              Positioned(
                top: UtenSpacing.s8,
                right: UtenSpacing.s8,
                child: entry.badge!,
              ),
          ],
        ),
      ),
    );
  }
}

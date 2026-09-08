// 生产管理入口页（hub）—— 两个分组卡片（与 basic_data / purchase / warehouse hub 对齐）：
//  ① 生产管理（操作类 · 单据）：生产计划单 + 生产日报表
//  ② 生产报表（分析类）：计划明细 / 计划汇总 / 物料反查产成品
//
// 点卡片进对应列表/查询/报表页。卡片统一用 UtenHubCard（徽章恒在右上角）。
// 路由统一使用 RouteName 常量；查看权限进入列表，新增动作由列表页按编辑权限控制。
//
// 注：原「BOM 成本展开」入口已下线（组装/BOM 数据并入 基础资料-货品资料「组装信息」页签）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
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
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final newPlanLocation = RoutePath.productionPlanNew();
    final canCreatePlan =
        requiredAnyPermFor(newPlanLocation)!.any(permissions.contains) &&
        requiredAllPermsFor(newPlanLocation).every(permissions.contains);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.productionHubTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          // 轮询页不包选择区：在产待办徽章定时刷新（结构性闪现）与拖选并发有
          // CME 风险（准则 §3.4，用户口径：轮询页不包）。
          selectable: false,
          child: ListView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s12,
              bottom: context.breakpoint.isCompact
                  ? UtenSpacing.s16
                  : UtenSpacing.s40,
            ),
            children: [
              _section(context, theme, l10n.productionHubTitle, [
                // 调度+进度已合并为一个三 Tab 页面（待排产/进行中/已完成）
                _Entry(
                  icon: Icons.dashboard_customize_outlined,
                  label: l10n.productionHubSchedule,
                  description: l10n.productionHubScheduleSub,
                  location: '/production/schedule',
                  badge: const ProductionPendingBadge(showLabel: true),
                ),
                _Entry(
                  icon: Icons.assignment_outlined,
                  label: canCreatePlan
                      ? l10n.productionHubPlan
                      : l10n.productionHubPlanHistory,
                  description: canCreatePlan
                      ? l10n.productionHubPlanSub
                      : l10n.productionHubPlanHistorySub,
                  location: canCreatePlan
                      ? RouteName.productionMaterialAnalysis
                      : RouteName.productionPlanList,
                ),
                _Entry(
                  icon: Icons.edit_calendar_outlined,
                  label: l10n.productionHubDaily,
                  description: l10n.productionHubDailySub,
                  location: RouteName.productionDailyReportList,
                ),
              ], permissions),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, l10n.productionHubSectionReports, [
                _Entry(
                  icon: Icons.list_alt_outlined,
                  label: l10n.productionHubReportPlanDetail,
                  description: l10n.productionHubReportPlanDetailSub,
                  location: '/production/reports/plan-detail',
                ),
                _Entry(
                  icon: Icons.bar_chart_outlined,
                  label: l10n.productionHubReportPlanSummary,
                  description: l10n.productionHubReportPlanSummarySub,
                  location: '/production/reports/plan-summary',
                ),
                _Entry(
                  icon: Icons.find_in_page_outlined,
                  label: l10n.productionHubWhereUsed,
                  description: l10n.productionHubWhereUsedSub,
                  location: '/production/where-used',
                ),
                // 当前是四类结构化关系的健康初筛，不宣称已覆盖整条供应/执行链。
                const _Entry(
                  icon: Icons.fact_check_outlined,
                  label: '链路健康初筛',
                  description: '销售缺口→分析→计划→DRAW 关系的只读检查',
                  location: '/production/chain-health',
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
          final requiredAny = requiredAnyPermFor(entry.location);
          final requiredAll = requiredAllPermsFor(entry.location);
          return (requiredAny == null ||
                  requiredAny.any(permissions.contains)) &&
              requiredAll.every(permissions.contains);
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
    return UtenHubCard(
      icon: entry.icon,
      label: entry.label,
      description: entry.description,
      onTap: () => goFrom(context, entry.location),
      badge: entry.badge,
    );
  }
}

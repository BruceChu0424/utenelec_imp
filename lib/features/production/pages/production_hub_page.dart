// 生产管理入口页（hub）—— 两个分组卡片（与 basic_data / purchase / warehouse hub 对齐）：
//  ① 生产管理（操作类 · 单据）：生产计划单 + 生产日报表
//  ② 生产报表（分析类）：计划明细 / 计划汇总 / 物料反查产成品
//
// 点卡片进对应列表/查询/报表页。卡片统一用 UtenHubCard, 计数按三形态口径逐卡挑
// (准则 14-徽章与计数口径 / ADR-100):
//  · 生产调度与进度卡右上角并排两枚 —— 黄色「进行中」(在办的分析/根计划批次,
//    已经排下去在跑, 此刻不用调度员动手)在左, 红色「待排产」(调度员必须清空的
//    队列)在右;
//  · 生产计划单 / 生产日报表卡只有本人草稿一种计数, 仍是红色(2026-09-11 口径反转:
//    草稿是本人开了头没交出去的活, 逐级累加); 这两种单据没有「已提交还在跑」的
//    中间态, 所以刻意不挂黄色;
//  · 报表卡无计数。
// 顶栏右上角两枚药丸同样黄左红右, 且都只汇总本页可见的这几张卡; 车间任务是另一个
// 独立入口(我的车间任务页), 红黄两条链都不把它算进本 hub。
// 路由统一使用 RouteName 常量；查看权限进入列表，新增动作由列表页按编辑权限控制。
//
// 注：原「BOM 成本展开」入口已下线（组装/BOM 数据并入 基础资料-货品资料「组装信息」页签）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_module_progress_chip.dart';
import '../../../components/feedback/uten_module_todo_chip.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/feedback/uten_draft_badge.dart';
import '../../../components/feedback/uten_in_progress_badge.dart';
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
import '../../../shared/providers/draft_counts_provider.dart';
import '../widgets/production_pending_badge.dart';
import '../../../shared/badges/badge_registry.dart';

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
        actions: [
          // 黄左红右(ADR-100), 与卡片右上角同序。两枚都是「生产管理」容器的和
          // (服务端徽章目录算好, ADR-108): 车间任务单列 workshop 容器, 有自己的
          // 入口页, 不属于本 Hub 的卡片集合 —— 「各卡之和 = 顶栏累计」由目录保证。
          // AppBar 的 actions 行是 crossAxisAlignment.stretch，故包 Center 才竖直居中。
          UtenModuleProgressChip(
            count: ref.watch(
              badgeModuleInProgressProvider(BadgeModule.production),
            ),
          ),
          UtenModuleTodoChip(
            count: ref.watch(badgeModuleTodoProvider(BadgeModule.production)),
          ),
        ],
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
                  // 黄 = 页内「进行中」段那批在办批次(计划员视角的分析/根计划),
                  // 与红色的待排产是两队互不重叠的活: 待排产还没排下去, 在办的
                  // 已经在跑。数字随徽章汇总带回, 页面里不手写加法。
                  progressBadge: UtenInProgressBadge(
                    count: ref.watch(
                      badgeEntryInProgressProvider(
                        BadgeEntry.productionBatches,
                      ),
                    ),
                    showLabel: true,
                  ),
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
                  // 本卡没有别的待办徽章，草稿徽章独占右上角浮层（badge）——
                  // 这是用户点名要的位置，行内后缀会被标题挤得看不见。
                  badge: const UtenDraftBadge(
                    kind: DraftDocKind.productionPlan,
                  ),
                ),
                _Entry(
                  icon: Icons.edit_calendar_outlined,
                  label: l10n.productionHubDaily,
                  description: l10n.productionHubDailySub,
                  location: RouteName.productionDailyReportList,
                  // 同上：日报卡也只有草稿一种计数，直接占 badge 槽。
                  badge: const UtenDraftBadge(
                    kind: DraftDocKind.productionDailyReport,
                  ),
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
    this.progressBadge,
  });

  final IconData icon;
  final String label;
  final String description;
  final String location;

  /// 右上角红色徽章（待排产 / 本人草稿；>0 自动显示）。
  ///
  /// 本页每张卡最多一种计数，故只留这一个槽——若将来某卡既有待办又有草稿，
  /// 再把草稿挪到 UtenHubCard.labelSuffix（标题右侧行内），别往 badge 里塞两个。
  ///
  /// 「最多一种」说的是红色: 黄色的在办数另有 [progressBadge] 一个槽, 两者并存
  /// 不算往一个槽里塞两个红圆点。
  final Widget? badge;

  /// 右上角黄色「进行中」徽章, 渲染在 [badge] 左边(ADR-100)。
  ///
  /// 放「已经在办、还没完、现在不用我动手」的数; 两个槽同时有数是正常的,
  /// 它们回答的是两个问题(我还欠多少活 / 我手上还有多少在跑), 不是双计。
  final Widget? progressBadge;
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
      progressBadge: entry.progressBadge,
    );
  }
}

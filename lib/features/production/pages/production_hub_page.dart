// 生产管理入口页（hub）—— 2026-09-24 模块三段式统一：
//  ① 任务中心（置顶）：生产任务中心（调度台：待排产/进行中/历史记录）+
//     超产比例审批 + 追加用料审批（都是等计划员动手的队列，红徽章）。
//  ② 新建单据：新建生产计划单（→物料分析，creator-only）/ 新建生产日报
//     （→/production/daily-reports/new），一律不挂数（草稿在新页「草稿(N)」按钮
//     与记录页草稿分段可见）。
//  ③ 报表中心（最底）：计划明细/汇总/物料反查/链路健康初筛。
// 车间生产任务是另一个独立入口（我的车间任务页），红黄两条链都不算进本 hub。
//
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_module_progress_chip.dart';
import '../../../components/feedback/uten_module_todo_chip.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/feedback/uten_in_progress_badge.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/router/page_resume_provider.dart';
import '../widgets/production_pending_badge.dart';
import '../../../shared/badges/badge_registry.dart';

class ProductionHubPage extends ConsumerWidget {
  const ProductionHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    // 返回即刷新：办完审批/排产回到 hub 时按需重拉徽章汇总（与其它 hub 同款）。
    ref.onPageResume(RouteName.production, () => refreshBadges(ref));
    // ADR-117：车间在催计划下单的任务数(只对能下单、能看到那些分析的计划员非零)。
    final planningUrges = ref.watch(
      badgeEntryTodoProvider(BadgeEntry.productionPlanningUrges),
    );
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
              // ① 任务中心（2026-09-24 用户口径：置顶；调度台更名「生产任务中心」，
              //    两个审批队列同属任务中心区——都是等计划员动手的待办）。
              _section(
                context,
                theme,
                l10n.hubSectionTaskCenter,
                [
                  // 调度+进度已合并为一个三 Tab 页面（待排产/进行中/已完成）
                  _Entry(
                    icon: Icons.dashboard_customize_outlined,
                    label: '生产任务中心',
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
                    // ADR-117 车间在催计划下单的任务数(红，行内)：等计划员动手的
                    // 队列信号挂在任务中心卡上（2026-09-24 三段式：新建卡不挂数）。
                    labelSuffix: planningUrges > 0
                        ? UtenNotificationBadge(count: planningUrges)
                        : null,
                  ),
                  _Entry(
                    icon: Icons.fact_check_outlined,
                    label: '超产比例审批',
                    description: '核对原比例与申请比例，批准后生效',
                    location: RouteName.productionOverproductionRateRequests,
                    badge: UtenNotificationBadge(
                      count: ref.watch(
                        badgeEntryTodoProvider(
                          BadgeEntry.productionRateApprovals,
                        ),
                      ),
                    ),
                  ),
                  _Entry(
                    icon: Icons.add_box_outlined,
                    label: '追加用料审批',
                    description: '核对原定额与追加量，批准后安排领料',
                    location: RouteName.productionMaterialIncrementRequests,
                    badge: UtenNotificationBadge(
                      count: ref.watch(
                        badgeEntryTodoProvider(
                          BadgeEntry.productionMaterialIncrementApprovals,
                        ),
                      ),
                    ),
                  ),
                ],
                permissions,
                superAdmin,
              ),
              const SizedBox(height: UtenSpacing.s16),
              // ② 新建单据（creator-only 直达新建；无新建权限者浏览去任务中心）。
              _section(
                context,
                theme,
                '新建单据',
                [
                  _Entry(
                    icon: Icons.assignment_outlined,
                    label: '新建生产计划单',
                    description: l10n.productionHubPlanSub,
                    location: RouteName.productionMaterialAnalysis,
                  ),
                  _Entry(
                    icon: Icons.edit_calendar_outlined,
                    label: '新建生产日报',
                    description: '进卡即新建，填本车间当日产量',
                    location: RoutePath.productionDailyReportNew(),
                  ),
                ],
                permissions,
                superAdmin,
              ),
              const SizedBox(height: UtenSpacing.s16),
              // ③ 报表中心（最下）。
              _section(
                context,
                theme,
                '报表中心',
                [
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
                ],
                permissions,
                superAdmin,
              ),
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
    bool superAdmin,
  ) {
    // 卡片显隐 = hub 目录登记的落点 + 路由守卫(与 /production 入口守卫同源，ADR-109)。
    final visibleEntries = entries
        .where(
          (entry) => hubCardAllowed(
            RouteName.production,
            entry.location,
            permissions,
            superAdmin,
          ),
        )
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
    this.labelSuffix,
  });

  final IconData icon;
  final String label;
  final String description;
  final String location;

  /// 右上角红色徽章（待排产 / 在催任务数；>0 自动显示）。
  ///
  /// 本页每张卡最多一种计数，故只留这一个槽。2026-09-24 三段式：新建类卡
  /// （计划/日报）不再挂草稿徽章，草稿在新页「草稿(N)」按钮与记录页草稿分段可见。
  ///
  /// 「最多一种」说的是红色: 黄色的在办数另有 [progressBadge] 一个槽, 两者并存
  /// 不算往一个槽里塞两个红圆点。
  final Widget? badge;

  /// 右上角黄色「进行中」徽章, 渲染在 [badge] 左边(ADR-100)。
  ///
  /// 放「已经在办、还没完、现在不用我动手」的数; 两个槽同时有数是正常的,
  /// 它们回答的是两个问题(我还欠多少活 / 我手上还有多少在跑), 不是双计。
  final Widget? progressBadge;

  /// 标题右侧行内的次要计数（任务中心卡挂「在催 N」等队列信号时用）。
  final Widget? labelSuffix;
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
      labelSuffix: entry.labelSuffix,
    );
  }
}

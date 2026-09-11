// 委外管理入口页：与采购 hub 同构——任务中心 / 单据 / 报表 三组权限过滤卡片。
// 有子层级委外件的「先自制、后通知委外」由计划部在物料分析准备完成并通知后，
// 委外部才在任务中心看到申请；本页不放流程教学区。
//
// V53 仅是历史默认授权；现行入口按每个页面权限与个人/部门显式配置逐卡显隐。
//
// 计数口径（准则 14-徽章与计数口径）：任务中心 / 待退回供应商 / 各单据草稿都是
// 「必须由我处理」的待办，一律挂红色徽章并逐级累加（见
// shared/badges/todo_badge_registry.dart，草稿于 2026-09-11 由中性括号改为徽章）；
// 报表与历史兼容卡无计数。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_module_todo_chip.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../warehouse/pages/procurement_return_task_pages.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/widgets/procurement_inbound_badges.dart';
import '../../../components/feedback/uten_draft_badge.dart';
import '../../../shared/badges/todo_badge_registry.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../config/subcontract_doc_config.dart';
import '../config/subcontract_report_config.dart';
import '../widgets/subcontract_task_badge.dart';

class SubcontractHubPage extends ConsumerWidget {
  const SubcontractHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：回到本 hub 时重拉「待退回供应商」任务数。
    ref.onPageResume(RouteName.subcontract, () {
      ref.invalidate(
        procurementArrivalReturnCountProvider(
          ProcurementInboundOrderType.subcontract,
        ),
      );
    });
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // 权限门控（V305）：无对应 view 权限的卡片不显示（权限管理授权后可见）。
    final perms = ref.watch(currentPermissionsProvider);
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    bool can(String code) => isSuperAdmin || perms.contains(code);
    final taskEntries = <_Entry>[
      if (can(Perm.subcontractApplicationView))
        _Entry(
          icon: Icons.precision_manufacturing_outlined,
          label: l10n.subcontractHubTaskCenter,
          description: l10n.subcontractHubTaskCenterSub,
          location: RouteName.operationsSubcontractWorkbench,
          badge: const SubcontractTaskBadge(showLabel: true),
        ),
      if (can(Perm.supplierReturnTaskView))
        _Entry(
          icon: Icons.assignment_return_outlined,
          label: l10n.subcontractHubReturnVendor,
          description: l10n.hubSubPendingReturnQty,
          location: procurementReturnTasksLocation(
            ProcurementInboundOrderType.subcontract,
          ),
          badge: const ProcurementArrivalReturnBadge(
            orderType: ProcurementInboundOrderType.subcontract,
            showLabel: true,
          ),
        ),
    ];
    // 2026-09-06 收口：计划委外申请卡并入「委外任务中心」（待处理段含待生产
    // 合成行+进度弹窗）；回厂与品质跟踪卡退役（进度在任务中心/订货详情查看）。
    // 委外页不放仓库/品质动作入口——登记回厂在仓储模块预计到货办理。
    final docEntries = <_Entry>[
      if (can(Perm.subcontractOrderView))
        _Entry(
          icon: Icons.shopping_bag_outlined,
          label: '委外订货',
          description: '订货、财务审批与全链路进度（含回厂 IQC）',
          location: SubcontractRoute.list(
            SubcontractDocConfig.order.pathSegment,
          ),
          // 本人待自审草稿数（与新建页「草稿」按钮同源）。本卡没有别的待办
          // 徽章，草稿就占右上角 badge 槽——用户要的正是这个位置。
          badge: const UtenDraftBadge(kind: DraftDocKind.subcontractOrder),
        ),
      if (can(Perm.subcontractReturnView))
        _Entry(
          icon: Icons.undo_outlined,
          label: '成品退回',
          description: '退回委外成品并反向应付',
          location: SubcontractRoute.list(
            SubcontractDocConfig.returnDoc.pathSegment,
          ),
          // 同上：无其它待办徽章，草稿独占 badge 槽。
          badge: const UtenDraftBadge(kind: DraftDocKind.subcontractReturn),
        ),
      if (can(Perm.subcontractMaterialReturnView))
        _Entry(
          icon: Icons.assignment_return_outlined,
          label: '余料退回',
          description: '委外商处余料登记入库',
          location: SubcontractRoute.list(
            SubcontractDocConfig.materialReturn.pathSegment,
          ),
          badge: const UtenDraftBadge(
            kind: DraftDocKind.subcontractMaterialReturn,
          ),
        ),
      if (can(Perm.subcontractWasteView))
        _Entry(
          icon: Icons.gavel_outlined,
          label: '损耗与责任',
          description: '损耗、索赔与责任处理',
          location: SubcontractRoute.list(
            SubcontractDocConfig.waste.pathSegment,
          ),
          badge: const UtenDraftBadge(kind: DraftDocKind.subcontractWaste),
        ),
    ];
    final legacyEntries = <_Entry>[
      if (can(Perm.subcontractMaterialIssueView))
        _Entry(
          icon: Icons.history_rounded,
          label: '历史 BOM 子件发料',
          description: 'V304 历史单据查看与红冲',
          location: SubcontractRoute.list(
            SubcontractDocConfig.materialIssue.pathSegment,
          ),
        ),
    ];
    final reportEntries = <_Entry>[
      for (final k in SubcontractReportKind.values)
        if (can(Perm.subcontractReportView))
          _Entry(
            icon: k.icon,
            label: _subcontractReportTitle(k, l10n),
            description: _subcontractReportSubtitle(k, l10n),
            location: k.route,
          ),
    ];
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.subcontractHubTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          // 本模块累计：任务中心 + 待退回供应商 + 本模块四类草稿。数字由
          // todo_badge_registry 按 TodoModule.subcontract 求和得出（唯一实现），
          // 页面里不要再手写加法。AppBar 的 actions 行是 stretch 对齐，
          // 故包一层 Center 让徽章垂直居中；0 时组件自身不渲染。
          UtenModuleTodoChip(
            count: todoModuleCount(TodoModule.subcontract, ref.watch),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          // 轮询页不包选择区：委外任务徽章定时刷新（结构性闪现）与拖选并发有
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
              _section(context, theme, l10n.hubSectionTaskCenter, taskEntries),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, l10n.subcontractHubTitle, docEntries),
              const SizedBox(height: UtenSpacing.s16),
              _section(
                context,
                theme,
                l10n.subcontractHubSectionReports,
                reportEntries,
              ),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '历史兼容', legacyEntries),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个分组：标题 + 卡片网格；无权限可见卡片时整组隐藏。
  Widget _section(
    BuildContext context,
    ThemeData theme,
    String title,
    List<_Entry> entries,
  ) {
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
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
            itemCount: entries.length,
            spacing: UtenSpacing.s12,
            columns: const UtenResponsiveColumns(compact: 2, medium: 4),
            itemBuilder: (context, i, _) => _EntryTile(entry: entries[i]),
          ),
        ],
      ),
    );
  }
}

/// 一个入口项（单据类型或报表）。
class _Entry {
  _Entry({
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

  /// 右上角红色待办徽章；本页每张卡最多一个待办来源，草稿卡也用这个槽。
  /// 若某卡将来同时有待办与草稿，再把草稿挪到 [UtenHubCard.labelSuffix]
  /// 行内显示——一个 badge 槽塞两个红圆点读不懂。
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

// 报表卡标题/副标题本地化（按 SubcontractReportKind 枚举查）。
String _subcontractReportTitle(
  SubcontractReportKind k,
  AppLocalizations l10n,
) => switch (k) {
  SubcontractReportKind.detail => l10n.subcontractHubReportDetail,
  SubcontractReportKind.summary => l10n.subcontractHubReportSummary,
  SubcontractReportKind.inOutStatus => l10n.subcontractHubReportInOut,
};

String _subcontractReportSubtitle(
  SubcontractReportKind k,
  AppLocalizations l10n,
) => switch (k) {
  SubcontractReportKind.detail => l10n.hubSubDetailPerItem,
  SubcontractReportKind.summary => l10n.hubSubSummaryPerDoc,
  SubcontractReportKind.inOutStatus => l10n.subcontractHubReportInOutSub,
};

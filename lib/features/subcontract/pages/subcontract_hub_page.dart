// 委外管理入口页：与采购 hub 同构——任务中心 / 单据 / 报表 三组权限过滤卡片。
// 有子层级委外件的「先自制、后通知委外」由计划部在物料分析准备完成并通知后，
// 委外部才在任务中心看到申请；本页不放流程教学区。
//
// V53 仅是历史默认授权；现行入口按每个页面权限与个人/部门显式配置逐卡显隐。
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
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../warehouse/pages/procurement_return_task_pages.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/widgets/procurement_inbound_badges.dart';
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
    final docEntries = <_Entry>[
      if (can(Perm.subcontractOrderView))
        _Entry(
          icon: Icons.shopping_bag_outlined,
          label: '委外订货',
          description: '订货、财务审批与全链路进度',
          location: SubcontractRoute.list(
            SubcontractDocConfig.order.pathSegment,
          ),
        ),
      if (can(Perm.subcontractApplicationView))
        _Entry(
          icon: Icons.description_outlined,
          label: '计划委外申请',
          description: '计划部通知委外的只读申请',
          location: SubcontractRoute.list(
            SubcontractDocConfig.application.pathSegment,
          ),
        ),
      if (can(Perm.subcontractReceiptView))
        _Entry(
          icon: Icons.fact_check_outlined,
          label: '回厂与品质',
          description: '回厂登记、IQC 与待入库',
          location: SubcontractRoute.list(
            SubcontractDocConfig.receipt.pathSegment,
          ),
        ),
      if (can(Perm.subcontractReturnView))
        _Entry(
          icon: Icons.undo_outlined,
          label: '成品退回',
          description: '退回委外成品并反向应付',
          location: SubcontractRoute.list(
            SubcontractDocConfig.returnDoc.pathSegment,
          ),
        ),
      if (can(Perm.subcontractMaterialReturnView))
        _Entry(
          icon: Icons.assignment_return_outlined,
          label: '余料退回',
          description: '委外商处余料登记入库',
          location: SubcontractRoute.list(
            SubcontractDocConfig.materialReturn.pathSegment,
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
      ),
      body: SafeArea(
        child: UtenContentContainer(
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

// 委外全链路入口页：两条下单来源汇入同一执行链。
//  ① 直接委外：直接新建订货；物料分析委外：先在申请分解页选择只读申请明细。
//  ② 财务通过后，无子层级目标件直接进入仓库出仓；有子层级先走前置自制。
//  ③ 目标件出仓、加工回厂、IQC、余料/损耗责任和应付结算各有独立岗位页面。
// 点卡片进对应列表/报表页。卡片统一用 UtenHubCard（徽章恒在右上角）。
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
    final trackingEntries = <_Entry>[
      if (can(Perm.subcontractOrderView))
        _Entry(
          icon: Icons.precision_manufacturing_outlined,
          label: '委外订货与全链路',
          description: '财务、准备、目标件出仓、回厂 IQC、结案与应付',
          location: SubcontractRoute.list(
            SubcontractDocConfig.order.pathSegment,
          ),
        ),
      if (can(Perm.subcontractReceiptView))
        _Entry(
          icon: Icons.fact_check_outlined,
          label: '回厂与品质跟踪',
          description: '仓库登记回厂、IQC 隔离、PASS 放行或 FAIL 处置',
          location: SubcontractRoute.list(
            SubcontractDocConfig.receipt.pathSegment,
          ),
        ),
      if (can(Perm.subcontractMaterialIssueView))
        _Entry(
          icon: Icons.history_rounded,
          label: '历史 BOM 子件发料',
          description: '历史 BOM 子件发料兼容；不是新委外出仓入口',
          location: SubcontractRoute.list(
            SubcontractDocConfig.materialIssue.pathSegment,
          ),
        ),
      if (can(Perm.subcontractReturnView))
        _Entry(
          icon: Icons.undo_outlined,
          label: '成品退回',
          description: '绑定回厂 / IQC 来源，仓库退回并反向加工费应付',
          location: SubcontractRoute.list(
            SubcontractDocConfig.returnDoc.pathSegment,
          ),
        ),
      if (can(Perm.subcontractMaterialReturnView))
        _Entry(
          icon: Icons.assignment_return_outlined,
          label: '余料退回',
          description: '按委外商处净结存登记仓库实收并对称核减台账',
          location: SubcontractRoute.list(
            SubcontractDocConfig.materialReturn.pathSegment,
          ),
        ),
      if (can(Perm.subcontractWasteView))
        _Entry(
          icon: Icons.gavel_outlined,
          label: '损耗与责任',
          description: '实物损耗、超耗责任、索赔履约和会计事实分层处理',
          location: SubcontractRoute.list(
            SubcontractDocConfig.waste.pathSegment,
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
              const _SubcontractFlowOverview(),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, l10n.hubSectionTaskCenter, taskEntries),
              const SizedBox(height: UtenSpacing.s16),
              _section(context, theme, '履约、异常与责任', trackingEntries),
              const SizedBox(height: UtenSpacing.s16),
              _section(
                context,
                theme,
                l10n.subcontractHubSectionReports,
                reportEntries,
              ),
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
            // 8 单据：桌面 4 列 ×2 行；窄屏 2 列。
            columns: const UtenResponsiveColumns(compact: 2, medium: 4),
            itemBuilder: (context, i, _) => _EntryTile(entry: entries[i]),
          ),
        ],
      ),
    );
  }
}

class _SubcontractFlowOverview extends StatelessWidget {
  const _SubcontractFlowOverview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const steps = [
      ('1', '订货来源', '直接委外 / 物料分析申请分解'),
      ('2', '财务放行', '冻结委外商、价格、税率与结算'),
      ('3', '准备目标件', '无子层直接；有子层先完整自制'),
      ('4', '仓库出仓', '专属预留、拣货、审核交付加工商'),
      ('5', '回厂品质', '先出后进、IQC 隔离、PASS 放行'),
      ('6', '对账与责任', '应付对账、退回、余料/损耗责任'),
    ];
    return Semantics(
      container: true,
      label: '委外全链路：订货来源、财务放行、准备目标件、仓库出仓、回厂品质、对账与责任',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '委外不是采购：公司先交付目标件，加工完成回厂后再经品质放行',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final step in steps)
                  Container(
                    constraints: const BoxConstraints(
                      minWidth: 176,
                      minHeight: 68,
                    ),
                    padding: const EdgeInsets.all(UtenSpacing.s8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: UtenRadius.mdAll,
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: theme.colorScheme.primaryContainer,
                          foregroundColor: theme.colorScheme.onPrimaryContainer,
                          child: Text(
                            step.$1,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(step.$2, style: theme.textTheme.labelLarge),
                              Text(
                                step.$3,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
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

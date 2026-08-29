// 委外管理入口页（hub）—— 三个分组卡片（V304 全链路重设计后）：
//  ① 任务中心：委外任务中心（按委外商分解为订货单）+ 待退回供应商。
//  ② 委外管理：委外订货单（含全链路进度）+ 计划下达的委外申请（只读）。
//     材料出仓/成品回厂/成品退/材料退/损耗的执行移交仓库（仓库 hub 专属页面）；
//     询价老库 0 行未启用，卡片移除（路由/权限保留，历史链接不受影响）。
//  ③ 委外报表：3 张报表卡片（明细报表/汇总报表/出入状况表）。
// 点卡片进对应列表/报表页。卡片统一用 UtenHubCard（徽章恒在右上角）。
//
// 入口归综合营销部（DEPT_SALES）；view 权限全员，edit 归综合营销部（V53 seed）。
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
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../warehouse/pages/procurement_return_task_pages.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/widgets/procurement_inbound_badges.dart';
import '../config/subcontract_doc_config.dart';
import '../config/subcontract_report_config.dart';
import '../models/subcontract_doc.dart';
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
      if (can(Perm.subcontractOrderView))
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
        _Entry.fromCfg(SubcontractDocConfig.order, l10n),
      if (can(Perm.subcontractApplicationView))
        _Entry.fromCfg(SubcontractDocConfig.application, l10n),
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
              const SizedBox(height: UtenSpacing.s8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
                child: Text(
                  '材料出仓与成品回厂由仓库执行；打开委外订货单详情可跟踪全链路进度'
                  '(出仓单号 / 进仓单号 / 品质验收 / 应付)。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
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

/// 一个入口项（单据类型或报表）。
class _Entry {
  _Entry({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
    this.enabled = true,
    this.badge,
  });

  _Entry.fromCfg(SubcontractDocConfig cfg, AppLocalizations l10n)
    : this(
        icon: cfg.icon,
        label: _subcontractDocTitle(cfg.type, l10n),
        description: _subcontractDocSubtitle(cfg.type, l10n),
        location: cfg.skipListOnCreate
            ? SubcontractRoute.newList(cfg.type.pathSegment)
            : SubcontractRoute.list(cfg.type.pathSegment),
        enabled: cfg.enabled,
      );

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final bool enabled;
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
      enabled: entry.enabled,
      onDisabledTap: () =>
          context.appInfo(AppLocalizations.of(context).hubDisabledDocNotice),
    );
  }
}

// 单据卡标题/副标题本地化（config 仍是中文 const，列表/编辑页在用）。
String _subcontractDocTitle(SubcontractDocType t, AppLocalizations l10n) =>
    switch (t) {
      SubcontractDocType.inquiry => l10n.subcontractHubDocInquiry,
      SubcontractDocType.application => l10n.subcontractHubDocApplication,
      SubcontractDocType.order => l10n.subcontractHubDocOrder,
      SubcontractDocType.receipt => l10n.subcontractHubDocReceipt,
      SubcontractDocType.materialIssue => l10n.subcontractHubDocMaterialIssue,
      SubcontractDocType.returnDoc => l10n.subcontractHubDocReturn,
      SubcontractDocType.materialReturn => l10n.subcontractHubDocMaterialReturn,
      SubcontractDocType.waste => l10n.subcontractHubDocWaste,
    };

String _subcontractDocSubtitle(
  SubcontractDocType t,
  AppLocalizations l10n,
) => switch (t) {
  SubcontractDocType.inquiry => l10n.subcontractHubDocInquirySub,
  SubcontractDocType.application => l10n.hubSubReadOnlyPlan,
  SubcontractDocType.order => l10n.subcontractHubDocOrderSub,
  SubcontractDocType.receipt => l10n.subcontractHubDocReceiptSub,
  SubcontractDocType.materialIssue => l10n.subcontractHubDocMaterialIssueSub,
  SubcontractDocType.returnDoc => l10n.subcontractHubDocReturnSub,
  SubcontractDocType.materialReturn => l10n.subcontractHubDocMaterialReturnSub,
  SubcontractDocType.waste => l10n.subcontractHubDocWasteSub,
};

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

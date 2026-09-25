// 采购管理入口页（hub）—— 2026-09-24 模块三段式统一（docs/01-规划/
// 2026-09-24-模块三段式统一-任务中心查单与模块新建.md）：
//  ① 任务中心（置顶）：采购任务中心（运营工作台）+ 待退回供应商，红/黄徽章照准则 14。
//  ② 新建单据：新建采购订货/收货/退货（creator-only 直达 /new，一律不挂数）
//     + 采购催料（跟单动作，用户口径放新建区）。「计划下达的采购申请」只读卡已撤
//     （申请由物料分析下达；浏览在任务中心「申请待分解」段与 /purchase/requests 深链）。
//  ③ 报表中心（最底）：明细/汇总。
//
// 卡片统一用 UtenHubCard；显隐走 hub_catalog + 路由守卫同一份 any/all 契约
// (hubCardAllowed，ADR-109)。顶栏两枚药丸（黄=进行中/红=待办）= 服务端徽章目录
// 对 BadgeModule.purchase 求和；页面里不做加法。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_module_progress_chip.dart';
import '../../../components/feedback/uten_module_todo_chip.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_in_progress_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../warehouse/pages/procurement_return_task_pages.dart';
import '../../warehouse/widgets/procurement_inbound_badges.dart';
import '../config/purchase_doc_config.dart';
import '../config/purchase_report_config.dart';
import '../models/purchase_doc.dart';
import '../widgets/purchase_task_badge.dart';
import '../../../shared/badges/badge_registry.dart';

class PurchaseHubPage extends ConsumerWidget {
  const PurchaseHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：回到本 hub 时按需重拉徽章汇总(本端写过数据或超过 30 秒，
    // ADR-108)；本页全部卡片角标都在这一份汇总里。
    ref.onPageResume(RouteName.purchase, () => refreshBadges(ref));
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    // 卡片显隐 = hub 目录登记的落点 + 路由守卫(与 /purchase 入口守卫同源，ADR-109)。
    bool canOpen(String location) =>
        hubCardAllowed(RouteName.purchase, location, permissions, superAdmin);

    List<_Entry> visible(List<_Entry> entries) => entries
        .where((entry) => canOpen(entry.location))
        .toList(growable: false);
    final taskEntries = visible([
      _Entry(
        icon: Icons.pending_actions_rounded,
        label: l10n.purchaseHubTaskCenter,
        description: l10n.purchaseHubTaskCenterSub,
        location: RouteName.operationsPurchaseWorkbench,
        badge: const PurchaseTaskBadge(showLabel: true),
        // 黄=任务中心「进行中」段(已下单、球在财务/供应商手上); 红=申请待分解与
        // 财务驳回。同一张被驳回的单两枚都算得上, 那是两条链对两个问题的答案。
        progressBadge: UtenInProgressBadge(
          count: ref.watch(
            badgeEntryInProgressProvider(BadgeEntry.purchaseTaskCenter),
          ),
          showLabel: true,
        ),
      ),
      _Entry(
        icon: Icons.assignment_return_outlined,
        label: l10n.purchaseHubReturnVendor,
        description: l10n.hubSubPendingReturnQty,
        location: procurementReturnTasksLocation(
          ProcurementInboundOrderType.purchase,
        ),
        badge: const ProcurementArrivalReturnBadge(
          orderType: ProcurementInboundOrderType.purchase,
          showLabel: true,
        ),
      ),
    ]);
    final documentEntries = visible([
      _Entry.fromCfg(PurchaseDocConfig.order, l10n),
      _Entry.fromCfg(PurchaseDocConfig.receipt, l10n),
      _Entry.fromCfg(PurchaseDocConfig.returnDoc, l10n),
      // 2026-09-24 用户口径：催料是跟单动作，不是报表——放「新建单据」区。
      _Entry(
        icon: Icons.notifications_active_outlined,
        label: '采购催料',
        description: '跟单催料：订货未收与可用库存对照，逐单催办',
        location: '/purchase/report/expediting',
      ),
      // 「计划下达的采购申请」只读卡已撤（2026-09-24 用户口径：新建区不需要；
      // 申请由物料分析下达，浏览在任务中心「申请待分解」段与 /purchase/requests 深链）。
    ]);
    final reportEntries = visible([
      for (final kind in PurchaseReportKind.values)
        if (kind != PurchaseReportKind.expediting)
          _Entry(
            icon: kind.icon,
            label: _purchaseReportTitle(kind, l10n),
            description: _purchaseReportSubtitle(kind, l10n),
            location: '/purchase/report/${kind.name}',
          ),
    ]);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.purchaseHubTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          // 顶栏两枚药丸, 黄左红右(ADR-100, 与卡片右上角同序):
          // 「进行中 N」= 采购下登记的在办入口之和(当前只有任务中心一处);
          // 「待办 N」= 采购下全部待办入口之和(任务中心 + 待退回供应商 +
          // 三张单据草稿)。两个数字都由各自注册表求和得出, 页面里不要手写加法,
          // 否则与工作台「采购管理」卡的口径会各算各的。0 时组件自身不渲染。
          UtenModuleProgressChip(
            count: ref.watch(
              badgeModuleInProgressProvider(BadgeModule.purchase),
            ),
          ),
          UtenModuleTodoChip(
            count: ref.watch(badgeModuleTodoProvider(BadgeModule.purchase)),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          // 轮询页不包选择区：采购任务徽章定时刷新（结构性闪现）与拖选并发有
          // CME 风险（准则 §3.4，用户口径：轮询页不包）。
          selectable: false,
          child: ListView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s12,
              // 外壳 compact 已为子页面预留胶囊高度；此处再补呼吸。
              // medium+/桌面 Rail 外壳不预留，取更大值避免末卡贴底。
              bottom: context.breakpoint.isCompact
                  ? UtenSpacing.s16
                  : UtenSpacing.s40,
            ),
            children: [
              if (taskEntries.isNotEmpty)
                _section(
                  context,
                  theme,
                  l10n.hubSectionTaskCenter,
                  taskEntries,
                ),
              if (taskEntries.isNotEmpty && documentEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (documentEntries.isNotEmpty)
                _section(context, theme, '新建单据', documentEntries),
              if (documentEntries.isNotEmpty && reportEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (reportEntries.isNotEmpty)
                _section(context, theme, '报表中心', reportEntries),
              if (taskEntries.isEmpty &&
                  documentEntries.isEmpty &&
                  reportEntries.isEmpty)
                const UtenEmpty(
                  icon: Icons.lock_outline_rounded,
                  message: '暂无已授权的采购页面',
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
  ) {
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
    this.progressBadge,
  });

  /// 新建单据卡（2026-09-24 三段式）：只对能新建的人显示（外层 canOpen 过滤），
  /// 落点恒为 /new 编辑页（进卡即新建态，不显示历史）；新建入口一律不挂徽章
  ///（浏览去任务中心与列表深链）。
  _Entry.fromCfg(PurchaseDocConfig cfg, AppLocalizations l10n)
    : icon = cfg.icon,
      label = '新建${_purchaseDocTitle(cfg.type, l10n)}',
      description = _purchaseDocSubtitle(cfg.type, l10n),
      location = RoutePath.purchaseDocNew(cfg.type.pathSegment),
      badge = null,
      // 单据卡不挂黄: 订货/收货/退货的在途单据已经全在采购任务中心「进行中」里,
      // 这里再按单据数一遍就是同一条黄链内的双计(ADR-100 §2.4)。
      progressBadge = null;

  final IconData icon;
  final String label;
  final String description;
  final String location;

  /// 右上角红色徽章；待办数与草稿数都放这里，都会进上层累加。
  final Widget? badge;

  /// 右上角黄色「进行中」徽章，排在红徽章左边；走另一张注册表，与红数互不相干。
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

// 单据卡标题/副标题本地化（config 仍是中文 const，列表/编辑页在用）。
String _purchaseDocTitle(PurchaseDocType t, AppLocalizations l10n) =>
    switch (t) {
      PurchaseDocType.request => l10n.purchaseHubDocRequest,
      PurchaseDocType.order => l10n.purchaseHubDocOrder,
      PurchaseDocType.receipt => l10n.purchaseHubDocReceipt,
      PurchaseDocType.returnDoc => l10n.purchaseHubDocReturn,
    };

String _purchaseDocSubtitle(PurchaseDocType t, AppLocalizations l10n) =>
    switch (t) {
      PurchaseDocType.request => l10n.hubSubReadOnlyPlan,
      PurchaseDocType.order => l10n.purchaseHubDocOrderSub,
      PurchaseDocType.receipt => l10n.purchaseHubDocReceiptSub,
      PurchaseDocType.returnDoc => l10n.purchaseHubDocReturnSub,
    };

// 报表卡标题/副标题本地化（按 PurchaseReportKind 枚举查）。
String _purchaseReportTitle(PurchaseReportKind k, AppLocalizations l10n) =>
    switch (k) {
      PurchaseReportKind.detail => l10n.purchaseHubReportDetail,
      PurchaseReportKind.summary => l10n.purchaseHubReportSummary,
      PurchaseReportKind.expediting => l10n.purchaseHubReportExpediting,
    };

String _purchaseReportSubtitle(PurchaseReportKind k, AppLocalizations l10n) =>
    switch (k) {
      PurchaseReportKind.detail => l10n.hubSubDetailPerItem,
      PurchaseReportKind.summary => l10n.hubSubSummaryPerDoc,
      PurchaseReportKind.expediting => l10n.purchaseHubReportExpeditingSub,
    };

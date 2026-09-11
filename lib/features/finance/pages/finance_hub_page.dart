// 钱流管理入口页（hub）—— 两个分组卡片：
//  ① 钱流管理：销售收款/采购付款/一般费用/其它收入/银行存取款/支票管理 入口
//  ② 钱流报表：应收应付台账/对账单/流水账 入口
// 点卡片进对应列表/报表页。卡片统一用 UtenHubCard（图标统一 40×40），
// 计数口径（准则 14-徽章与计数口径）：
//   · 任务中心 6 张卡挂右上角红色待办徽章（进工作台「钱流管理」卡累加；
//     「销售订单财务确认」与「销售订单修改」是同一批单据的两个队列切片，
//     累加只认总数一次，见 shared/badges/todo_badge_registry.dart 末注）。
//   · 钱流单据 5 张卡挂草稿红徽章（2026-09-11 口径反转：草稿是本人必须处理完的活，
//     改红底白字并逐级累加，不再是中性括号）。
//   · 报表区 10 张卡是浏览型入口，不挂任何计数。
//   · 顶栏右上角挂本模块累计（上面两类之和）。
// 支票管理 = 账户 account_type=CHECK/FOREIGN_CHECK 的过滤视图（不单独模块），
// 入口指向 /finance/checks（由用户在 app_router 接到 AccountPage(initialAccountTypeFilter:'CHECK')）。
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
import '../../../core/router/permission_by_path.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../../components/feedback/uten_draft_badge.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/todo_badge_registry.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../../warehouse/widgets/procurement_inbound_badges.dart';
import '../../procurement_iqc_rejection/repositories/procurement_iqc_rejection_repository.dart';
import '../../procurement_iqc_rejection/widgets/procurement_iqc_rejection_badge.dart';
import '../finance_workflow_routes.dart';
import '../providers/finance_procurement_approval_count_provider.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';
import '../../../shared/providers/sales_shipment_finance_count_provider.dart';
import '../widgets/finance_procurement_approval_badge.dart';
import '../widgets/sales_order_finance_confirmation_badge.dart';

class FinanceHubPage extends ConsumerWidget {
  const FinanceHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：回到本 hub 时重拉「订货审批任务中心」「销售订单财务确认」「超量到货审批」计数。
    ref.onPageResume(RouteName.finance, () {
      ref.invalidate(financeProcurementApprovalCountProvider);
      ref.invalidate(salesOrderFinanceConfirmationCountProvider);
      ref.invalidate(financeArrivalExceptionCountProvider);
      ref.invalidate(procurementIqcRejectionOpenCountProvider);
    });
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final canViewProcurementApprovals =
        superAdmin || permissions.contains(Perm.financeOrderApprovalView);
    final canViewSalesConfirmations =
        superAdmin || permissions.contains(Perm.salesOrderFinanceView);
    final canAuditSalesShipments =
        superAdmin || permissions.contains(Perm.financeShipmentAudit);
    final canViewIqcRejections =
        superAdmin || permissions.contains(Perm.procurementIqcRejectionView);
    List<_Entry> visible(List<_Entry> entries) => entries
        .where((entry) {
          final requiredAny = requiredAnyPermFor(entry.location);
          final requiredAll = requiredAllPermsFor(entry.location);
          return (requiredAny == null ||
                  requiredAny.any(permissions.contains)) &&
              requiredAll.every(permissions.contains);
        })
        .toList(growable: false);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.financeHubTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          // 本模块累计：数字由 todo_badge_registry 对 TodoModule.finance 下全部
          // 登记入口求和得出（含本模块 5 类草稿），页面里不要手写加法——
          // 新增入口只改注册表，否则外层与内层又会对不上。0 时组件自身不渲染。
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: Center(
              child: UtenNotificationBadge(
                count: todoModuleCount(TodoModule.finance, ref.watch),
                size: 20,
                showLabel: true,
              ),
            ),
          ),
        ],
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
              if (canViewProcurementApprovals ||
                  canViewSalesConfirmations ||
                  canAuditSalesShipments ||
                  canViewIqcRejections) ...[
                _section(context, theme, l10n.hubSectionTaskCenter, [
                  // V294 闸门：销售订货单审核后先经财务确认再放行计划部。
                  if (canViewSalesConfirmations)
                    const _Entry(
                      icon: Icons.fact_check_outlined,
                      label: '销售订单财务确认',
                      description: '销售订货单审核后在此确认，确认后计划部才可见并排产',
                      location: FinanceWorkflowRoutes.salesOrderConfirmations,
                      badge: SalesOrderFinanceConfirmationBadge(
                        size: 16,
                        changesOnly: false,
                      ),
                    ),
                  if (canViewSalesConfirmations)
                    const _Entry(
                      icon: Icons.compare_arrows_outlined,
                      label: '销售订单修改',
                      description: '核对原内容与修改后内容，重新确认后放行后续任务',
                      location: FinanceWorkflowRoutes.salesOrderChanges,
                      badge: SalesOrderFinanceConfirmationBadge(
                        size: 16,
                        changesOnly: true,
                      ),
                    ),
                  if (canAuditSalesShipments)
                    const _Entry(
                      icon: Icons.local_shipping_outlined,
                      label: '出货财务审核',
                      description: '核对收款条件和未收金额，再交给仓库备货发货',
                      location: RouteName.financeSalesShipmentAudit,
                      badge: SalesShipmentFinanceBadge(),
                    ),
                  if (canViewProcurementApprovals)
                    _Entry(
                      icon: Icons.approval_outlined,
                      label: l10n.financeHubTaskApproval,
                      description: l10n.financeHubTaskApprovalSub,
                      location: FinanceWorkflowRoutes.approvalTasks,
                      badge: const FinanceProcurementApprovalBadge(size: 16),
                    ),
                  if (canViewProcurementApprovals)
                    _Entry(
                      icon: Icons.local_shipping_outlined,
                      label: l10n.financeHubTaskOverDelivery,
                      description: l10n.financeHubTaskOverDeliverySub,
                      location: FinanceWorkflowRoutes.arrivalExceptionTasks,
                      badge: const FinanceArrivalExceptionBadge(
                        showLabel: true,
                      ),
                    ),
                  if (canViewIqcRejections)
                    _Entry(
                      icon: Icons.assignment_late_outlined,
                      label: 'IQC 不合格退回与贷项',
                      description: '实物已退回后确认供应商贷项、零金额结案或修复财务异常',
                      location: RoutePath.procurementIqcRejections(
                        source: 'finance',
                      ),
                      badge: const ProcurementIqcRejectionBadge(
                        showLabel: true,
                      ),
                    ),
                ]),
                const SizedBox(height: UtenSpacing.s16),
              ],
              _section(
                context,
                theme,
                l10n.financeHubTitle,
                visible([
                  _Entry(
                    icon: Icons.south_west_outlined,
                    label: l10n.financeHubDocReceipt,
                    description: l10n.financeHubDocReceiptSub,
                    location: RoutePath.financeDocNew('receipts'),
                    // 单据 5 张卡没有其它待办徽章，草稿徽章独占右上角浮层位
                    // （用户要的就是这个位置）；与任务中心卡的红徽章同一视觉层级。
                    badge: const UtenDraftBadge(
                      kind: DraftDocKind.financeReceipt,
                    ),
                  ),
                  _Entry(
                    icon: Icons.north_east_outlined,
                    label: l10n.financeHubDocPayment,
                    description: l10n.financeHubDocPaymentSub,
                    location: RoutePath.financeDocNew('payments'),
                    badge: const UtenDraftBadge(
                      kind: DraftDocKind.financePayment,
                    ),
                  ),
                  _Entry(
                    icon: Icons.outbound_outlined,
                    label: l10n.financeHubDocExpense,
                    description: l10n.financeHubSubAllocatedByDept,
                    location: RoutePath.financeDocNew('expenses'),
                    badge: const UtenDraftBadge(
                      kind: DraftDocKind.financeExpense,
                    ),
                  ),
                  _Entry(
                    icon: Icons.add_circle_outline,
                    label: l10n.financeHubDocIncome,
                    description: l10n.financeHubSubAllocatedByDept,
                    location: RoutePath.financeDocNew('incomes'),
                    badge: const UtenDraftBadge(
                      kind: DraftDocKind.financeOtherIncome,
                    ),
                  ),
                  _Entry(
                    icon: Icons.swap_horiz_rounded,
                    label: l10n.financeHubDocBankTransfer,
                    description: l10n.financeHubDocBankTransferSub,
                    location: RoutePath.financeDocNew('bank-transfers'),
                    badge: const UtenDraftBadge(
                      kind: DraftDocKind.financeBankTransfer,
                    ),
                  ),
                  _Entry(
                    icon: Icons.receipt_long_outlined,
                    label: l10n.financeHubDocCheck,
                    description: l10n.financeHubDocCheckSub,
                    location: '/finance/checks',
                  ),
                  _Entry(
                    icon: Icons.apartment_rounded,
                    label: l10n.financeHubDocAssets,
                    description: l10n.financeHubDocAssetsSub,
                    location: RouteName.financeAssets,
                  ),
                ]),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _section(
                context,
                theme,
                l10n.financeHubSectionReports,
                visible([
                  const _Entry(
                    icon: Icons.payments_outlined,
                    label: '应付结算',
                    description: '采购与委外应付、已付、抵销、未付及到期跟踪',
                    location: RouteName.financePayables,
                  ),
                  _Entry(
                    icon: Icons.account_balance_wallet_outlined,
                    label: l10n.financeHubReportArAp,
                    description: l10n.financeHubReportArApSub,
                    location: RouteName.financeReportOverview,
                  ),
                  _Entry(
                    icon: Icons.list_alt_outlined,
                    label: l10n.financeHubReportDetail,
                    description: l10n.financeHubReportDetailSub,
                    location: RouteName.financeReportDetail,
                  ),
                  _Entry(
                    icon: Icons.bar_chart_outlined,
                    label: l10n.financeHubReportSummary,
                    description: l10n.financeHubReportSummarySub,
                    location: RouteName.financeReportSummary,
                  ),
                  _Entry(
                    icon: Icons.receipt_long_outlined,
                    label: l10n.financeHubReportStatement,
                    description: l10n.financeHubReportStatementSub,
                    location: RouteName.financeReportStatement,
                  ),
                  _Entry(
                    icon: Icons.account_balance_outlined,
                    label: l10n.financeHubReportAccountFlow,
                    description: l10n.financeHubReportAccountFlowSub,
                    location: RouteName.financeReportAccountFlow,
                  ),
                  const _Entry(
                    icon: Icons.savings_outlined,
                    label: '客户预收流水',
                    description: '查看预收款到账、抵扣、撤回及汇率差额',
                    location: RouteName.financeReportCustomerPrepayment,
                  ),
                  _Entry(
                    icon: Icons.handshake_outlined,
                    label: l10n.financeHubReportRecon,
                    description: l10n.financeHubReportReconSub,
                    location: RouteName.financeReportRecon,
                  ),
                  _Entry(
                    icon: Icons.calculate_outlined,
                    label: l10n.financeHubReportCost,
                    description: l10n.financeHubReportCostSub,
                    location: RouteName.financeReportCost,
                  ),
                  _Entry(
                    icon: Icons.menu_book_outlined,
                    label: l10n.financeHubReportGl,
                    description: l10n.financeHubReportGlSub,
                    location: RouteName.financeReportGl,
                  ),
                ]),
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
    if (entries.isEmpty) return const SizedBox.shrink();
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
            columns: const UtenResponsiveColumns(compact: 2, medium: 3),
            itemBuilder: (context, i, _) => _EntryTile(entry: entries[i]),
          ),
        ],
      ),
    );
  }
}

/// 一个入口项（单据类型或报表）。
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

  /// 右上角红色徽章：待办数或本人草稿数，都会进上层累加。
  ///
  /// 本页每张卡最多一个红徽章，故不再留行内 labelSuffix 槽——两个红点挤在
  /// 一张卡上读不懂，真要并存时才按「待办占 badge、草稿占 labelSuffix」拆。
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

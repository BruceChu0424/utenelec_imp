// 钱流管理入口页（hub）—— 两个分组卡片：
//  ① 钱流管理：销售收款/采购付款/一般费用/其它收入/银行存取款/支票管理 入口
//  ② 钱流报表：应收应付台账/对账单/流水账 入口
// 点卡片进对应列表/报表页。布局对齐采购 hub 的卡片风格（入口用 context.go，避免 push 失效）。
// 支票管理 = 账户 account_type=CHECK/FOREIGN_CHECK 的过滤视图（不单独模块），
// 入口指向 /finance/checks（由用户在 app_router 接到 AccountPage(initialAccountTypeFilter:'CHECK')）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/permission_by_path.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/widgets/procurement_inbound_badges.dart';
import '../finance_workflow_routes.dart';
import '../providers/finance_procurement_approval_count_provider.dart';
import '../widgets/finance_procurement_approval_badge.dart';

class FinanceHubPage extends ConsumerWidget {
  const FinanceHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：回到本 hub 时重拉「订货审批任务中心」「超量到货审批」计数。
    ref.onPageResume(RouteName.finance, () {
      ref.invalidate(financeProcurementApprovalCountProvider);
      ref.invalidate(financeArrivalExceptionCountProvider);
    });
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final canViewApprovals =
        superAdmin || permissions.contains(Perm.financeOrderApprovalView);
    final canManageResponsibilities =
        superAdmin || permissions.contains(Perm.workflowAssignmentManage);
    List<_Entry> visible(List<_Entry> entries) => entries
        .where((entry) {
          final required = requiredAnyPermFor(entry.location);
          return required == null || required.any(permissions.contains);
        })
        .toList(growable: false);
    return Scaffold(
      appBar: UtenAppBar(
        title: '钱流管理',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: canManageResponsibilities
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: UtenSpacing.s8),
                  child: UtenButton(
                    key: const Key('finance-workflow-responsibilities'),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.manage_accounts_outlined,
                    onPressed: () =>
                        goFrom(context, FinanceWorkflowRoutes.responsibilities),
                    child: const Text('审批负责人设置'),
                  ),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            children: [
              if (canViewApprovals) ...[
                _section(context, theme, '任务中心', const [
                  _Entry(
                    icon: Icons.approval_outlined,
                    label: '订货审批任务中心',
                    description: '只显示明确分配给我的采购 / 委外订货单',
                    location: FinanceWorkflowRoutes.approvalTasks,
                    badge: FinanceProcurementApprovalBadge(),
                  ),
                  _Entry(
                    icon: Icons.local_shipping_outlined,
                    label: '超量到货审批',
                    description: '审核实际到货超出已批准订货数量的任务',
                    location: FinanceWorkflowRoutes.arrivalExceptionTasks,
                    badge: FinanceArrivalExceptionBadge(),
                  ),
                ]),
                const SizedBox(height: UtenSpacing.s16),
              ],
              _section(
                context,
                theme,
                '钱流管理',
                visible([
                  _Entry(
                    icon: Icons.south_west_outlined,
                    label: '销售收款',
                    description: '核销应收 / 直接收款',
                    location: RoutePath.financeDocNew('receipts'),
                  ),
                  _Entry(
                    icon: Icons.north_east_outlined,
                    label: '采购付款',
                    description: '核销应付 / 直接付款',
                    location: RoutePath.financeDocNew('payments'),
                  ),
                  _Entry(
                    icon: Icons.outbound_outlined,
                    label: '一般费用',
                    description: '按部门分摊',
                    location: RoutePath.financeDocNew('expenses'),
                  ),
                  _Entry(
                    icon: Icons.add_circle_outline,
                    label: '其它收入',
                    description: '按部门分摊',
                    location: RoutePath.financeDocNew('incomes'),
                  ),
                  _Entry(
                    icon: Icons.swap_horiz_rounded,
                    label: '银行存取款',
                    description: '账户间转入',
                    location: RoutePath.financeDocNew('bank-transfers'),
                  ),
                  const _Entry(
                    icon: Icons.receipt_long_outlined,
                    label: '支票管理',
                    description: '支票账户视图',
                    location: '/finance/checks',
                  ),
                  const _Entry(
                    icon: Icons.apartment_rounded,
                    label: '资产与待摊',
                    description: '专业子账 / 审批 / 折旧摊销 / 期间控制',
                    location: RouteName.financeAssets,
                  ),
                ]),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _section(
                context,
                theme,
                '钱流报表',
                visible([
                  const _Entry(
                    icon: Icons.account_balance_wallet_outlined,
                    label: '应收应付',
                    description: '树形分组：客户/供应商类别 AR/AP 余额',
                    location: RouteName.financeReportOverview,
                  ),
                  const _Entry(
                    icon: Icons.list_alt_outlined,
                    label: '明细报表',
                    description: '应收/应付/收款/付款/费用/收入/费用冲销',
                    location: RouteName.financeReportDetail,
                  ),
                  const _Entry(
                    icon: Icons.bar_chart_outlined,
                    label: '汇总报表',
                    description: '应收/应付/收款/付款/费用/收入 汇总',
                    location: RouteName.financeReportSummary,
                  ),
                  const _Entry(
                    icon: Icons.receipt_long_outlined,
                    label: '往来对帐单',
                    description: '客户/供应商 流水·明细·年度对帐',
                    location: RouteName.financeReportStatement,
                  ),
                  const _Entry(
                    icon: Icons.account_balance_outlined,
                    label: '账户流水',
                    description: '帐户进出流水 + 银行存取款',
                    location: RouteName.financeReportAccountFlow,
                  ),
                  const _Entry(
                    icon: Icons.handshake_outlined,
                    label: '对账单',
                    description: '委外加工/采购外放/供应商/其他应收/客户 月结对账',
                    location: RouteName.financeReportRecon,
                  ),
                  const _Entry(
                    icon: Icons.calculate_outlined,
                    label: '成本核算',
                    description: '产品成本/销售成本/铜柱加工费/塑料耗用',
                    location: RouteName.financeReportCost,
                  ),
                  const _Entry(
                    icon: Icons.menu_book_outlined,
                    label: '总账报表',
                    description: '科目余额表/资产负债/利润/费用明细/经营损益',
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
        child: Container(
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
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Icon(entry.icon, color: color, size: 24),
                  ),
                  const Spacer(),
                  ?entry.badge,
                ],
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
      ),
    );
  }
}

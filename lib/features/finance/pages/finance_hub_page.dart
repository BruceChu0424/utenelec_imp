// 钱流管理入口页（hub）—— 四个分组：
//  ① 任务中心：业务审核中心（销售订单确认/订单修改/出货/订货/超量到货/IQC 退回
//     六个队列在页内分段办理，2026-09-18 由 6 张卡合并为 1 张卡）
//     报价核价(ADR-134)：销售报价由财务定价格和折扣，确认后销售才能转订货单；
//     单独一张卡(不是审核放行而是改价，页面与认领口径不同)，红徽章 = 待核价张数
//  ② 新建单据：销售收款/采购付款/一般费用/其它收入/银行存取款
//  ③ 设置与台账：报销设置/支票管理/资产
//  ④ 钱流报表：应收应付台账/对账单/流水账
// 卡片统一用 UtenHubCard（图标统一 40×40），
// 计数口径（准则 14-徽章与计数口径）：
//   · 「业务审核中心」卡挂右上角红色待办徽章(全部审核队列之和，服务端徽章目录
//     financeAuditCenter 入口算好，ADR-108；「订单修改」是「销售订单确认」的队列切片，
//     总数只计一次）。原 6 张队列卡的旧路由保留，通知深链仍直达具体队列。
//   · 新建单据卡不挂徽章；草稿仍在新建页草稿按钮与列表分段显示红数，
//     顶栏「草稿」按钮进入单表，首列类别统一筛选五类钱流单据与资料草稿。
//   · 报表区 10 张卡是浏览型入口，不挂任何计数。
//   · 顶栏右上角挂本模块累计（业务审核、报销审批与钱流草稿之和）。
//   · 财务审批队列仍只计红色待办。供应商预付已登记真实付款、尚无合法入账记录时，
//     applicationFinance 单一入口计黄色跟进；有合法记录且有独立关联权时转红。
//     该跟进属于财务待入账，不把采购、销售等业务在途重复累计到财务。
// 支票管理 = 账户 account_type=CHECK/FOREIGN_CHECK 的过滤视图（不单独模块），
// 入口指向 /finance/checks（由用户在 app_router 接到 AccountPage(initialAccountTypeFilter:'CHECK')）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/drafts/form_drafts_page.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import '../widgets/finance_accounting_import_dialog.dart';
import '../widgets/finance_template_input_dialog.dart';
import '../widgets/finance_expense_analysis_dialog.dart';
import '../widgets/finance_asset_opening_group_dialog.dart';
import '../widgets/finance_statement_document_dialog.dart';
import '../widgets/finance_material_statement_dialog.dart';
import '../widgets/finance_chart_metadata_dialog.dart';
import '../widgets/finance_durable_command_dialog.dart';

import '../widgets/gl_report_line_bindings_dialog.dart';
import '../widgets/inventory_cost_posting_dialog.dart';
import '../widgets/finance_statement_compare_dialog.dart';
import '../widgets/finance_subcontract_loss_policy_dialog.dart';
import '../widgets/finance_payable_statement_adjustment_dialog.dart';
import '../widgets/finance_procurement_confirmation_dialog.dart';
import '../widgets/finance_auxiliary_import_dialog.dart';
import '../widgets/finance_subcontract_quantity_evidence_dialog.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_module_badges.dart';
import '../../../components/cards/uten_hub_card.dart';
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
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/auth/permissions.dart';
import '../widgets/finance_audit_center_badge.dart';
import '../config/finance_requirement_names.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/badges/badge_scope.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

class FinanceHubPage extends ConsumerStatefulWidget {
  const FinanceHubPage({super.key});
  @override
  ConsumerState<FinanceHubPage> createState() => _FinanceHubPageState();
}

class _FinanceHubPageState extends ConsumerState<FinanceHubPage> {
  Widget _withFinancialSourceDrafts(Widget child) {
    for (final descriptor in const [
      FormDraftCatalog.financeAccountingImport,
      FormDraftCatalog.financeCostTemplateInput,
      FormDraftCatalog.financeAssetTemplateInput,
      FormDraftCatalog.financeExpenseAnalysisInput,
      FormDraftCatalog.financeAssetOpeningGroup,
      FormDraftCatalog.financeMaterialStatement,
      FormDraftCatalog.financeChartMetadata,
      FormDraftCatalog.financeDurableCommand,
      FormDraftCatalog.financeStatementComparison,
      FormDraftCatalog.financeSubcontractLossPolicy,
      FormDraftCatalog.financeSubcontractQuantityEvidence,
      FormDraftCatalog.financeProcurementConfirmation,
      FormDraftCatalog.financeAuxiliaryImport,
      FormDraftCatalog.financePayableStatementAdjustment,
      FormDraftCatalog.financeStatementProfile,
      FormDraftCatalog.financeStatementProfileReview,
      FormDraftCatalog.financeStatementReview,
      FormDraftCatalog.financeStatementClientReview,
    ]) {
      child = FormDraftDialogResume(
        descriptor: descriptor,
        onResume: (parameters) async {
          final id = parameters['draftId'];
          if (descriptor == FormDraftCatalog.financeDurableCommand) {
            final operation = FinanceDurableOperation.parse(
              parameters['operation'] ?? '',
            );
            final target = parameters['target'] ?? '';
            if (id == null || !operation.validTarget(target)) {
              throw const FormatException('原财务命令缺少草稿编号或原目标');
            }
            switch (operation) {
              case FinanceDurableOperation.procurementPolicy:
                await showFinanceProcurementPolicyDialog(
                  context,
                  resumeDraftId: id,
                );
              case FinanceDurableOperation.reportBinding:
                await showFinanceReportBindingCommand(
                  context,
                  lineKey: target,
                  resumeDraftId: id,
                );
              case FinanceDurableOperation.reportDefaults:
                await showFinanceReportDefaultsCommand(
                  context,
                  resumeDraftId: id,
                );
              default:
                await showInventoryCostCommand(
                  context,
                  operation: operation,
                  target: target,
                  resumeDraftId: id,
                );
            }
            return;
          }
          if (descriptor == FormDraftCatalog.financeChartMetadata) {
            final code = parameters['code'];
            if (code == null ||
                !RegExp(r'^[0-9]{1,32}$').hasMatch(code) ||
                id == null) {
              throw const FormatException('科目名称草稿缺少原编码或草稿编号');
            }
            await showFinanceChartMetadataDialog(
              context,
              code: code,
              resumeDraftId: id,
            );
            return;
          }
          if (descriptor == FormDraftCatalog.financeProcurementConfirmation) {
            final supplier = parameters['supplierId'],
                currency = parameters['currencyId'];
            if (supplier == null ||
                supplier.isEmpty ||
                currency == null ||
                currency.isEmpty) {
              throw const FormatException('对账确认草稿缺少原供应商或币别');
            }
            await showFinanceProcurementConfirmationDialog(
              context,
              supplierId: supplier,
              currencyId: currency,
              resumeDraftId: id,
            );
            return;
          }
          if (descriptor == FormDraftCatalog.financeAuxiliaryImport) {
            const keys = ['receivable', 'currencyId', 'dateFrom', 'dateTo'];
            if (keys.any(
                  (key) => parameters[key] == null || parameters[key]!.isEmpty,
                ) ||
                !const {'true', 'false'}.contains(parameters['receivable'])) {
              throw const FormatException('辅助明细草稿缺少原类别、币别或期间');
            }
            await showFinanceAuxiliaryImportDialog(
              context,
              receivable: parameters['receivable'] == 'true',
              currencyId: parameters['currencyId']!,
              dateFrom: parameters['dateFrom']!,
              dateTo: parameters['dateTo']!,
              resumeDraftId: id,
            );
            return;
          }
          if (descriptor ==
              FormDraftCatalog.financeSubcontractQuantityEvidence) {
            const keys = ['supplierId', 'dateFrom', 'dateTo'];
            if (keys.any(
              (key) => parameters[key] == null || parameters[key]!.isEmpty,
            )) {
              throw const FormatException('数量资料草稿缺少原供应商或期间');
            }
            await showFinanceSubcontractQuantityEvidenceDialog(
              context,
              scope: {for (final key in keys) key: parameters[key]!},
              purpose: parameters['quantityPurpose'] ?? 'ROW_CORRESPONDENCE',
              evidenceId: parameters['evidenceId'],
              resumeDraftId: id,
            );
            return;
          }
          if (descriptor ==
              FormDraftCatalog.financePayableStatementAdjustment) {
            final review = parameters['statementReviewId'],
                fingerprint = parameters['expectedSourceFingerprint'];
            if (review == null || fingerprint == null) {
              throw const FormatException('对账处理草稿缺少原件及来源身份');
            }
            await showFinancePayableStatementAdjustmentDialog(
              context,
              statementReviewId: review,
              expectedSourceFingerprint: fingerprint,
              resumeDraftId: id,
            );
            return;
          }
          if (descriptor == FormDraftCatalog.financeSubcontractLossPolicy) {
            final supplier = parameters['supplierId'];
            if (supplier == null || supplier.isEmpty) {
              throw const FormatException('损耗率草稿缺少原供应商身份');
            }
            await showFinanceSubcontractLossPolicyDialog(
              context,
              supplierId: supplier,
              policyId: parameters['policyId'],
              resumeDraftId: id,
            );
            return;
          }
          if (descriptor == FormDraftCatalog.financeStatementComparison) {
            const keys = [
              'templateKey',
              'partyRole',
              'partyId',
              'currencyId',
              'dateFrom',
              'dateTo',
            ];
            if (keys.any((key) => parameters['statement.$key'] == null)) {
              throw const FormatException('原表比对草稿缺少原对象、币别或期间');
            }
            await showFinanceStatementCompareDialog(
              context,
              scope: {
                for (final key in keys) key: parameters['statement.$key']!,
              },
              resumeDraftId: id,
            );
            return;
          }
          if (descriptor == FormDraftCatalog.financeMaterialStatement) {
            await showFinanceMaterialStatementDialog(
              context,
              resumeDraftId: id,
            );
            return;
          }
          if (descriptor == FormDraftCatalog.financeAssetOpeningGroup) {
            await showFinanceAssetOpeningGroupDialog(
              context,
              resumeDraftId: id,
            );
            return;
          }
          if (const {
            FormDraftCatalog.financeStatementProfile,
            FormDraftCatalog.financeStatementProfileReview,
            FormDraftCatalog.financeStatementReview,
            FormDraftCatalog.financeStatementClientReview,
          }.contains(descriptor)) {
            const keys = [
              'templateKey',
              'partyRole',
              'partyId',
              'currencyId',
              'dateFrom',
              'dateTo',
            ];
            if (keys.any((key) => parameters['statement.$key'] == null)) {
              throw const FormatException('原对账资料草稿缺少原对象、币别或期间，请核对原记录');
            }
            await showFinanceStatementDocumentDialog(
              context,
              templateKey: parameters['statement.templateKey']!,
              partyRole: parameters['statement.partyRole']!,
              partyId: parameters['statement.partyId']!,
              currencyId: parameters['statement.currencyId']!,
              dateFrom: parameters['statement.dateFrom']!,
              dateTo: parameters['statement.dateTo']!,
              materialContextId: parameters['statement.materialContextId'],
              allMaterialContexts:
                  parameters['statement.allMaterialContexts'] != 'false',
              resumeDraftId: id,
              draftMode: parameters['statement.mode'],
              draftTargetId: parameters['statement.targetId'],
              draftProfileKind: parameters['statement.profileKind'],
            );
            return;
          }
          if (descriptor == FormDraftCatalog.financeAccountingImport) {
            await showFinanceAccountingImportDialog(context, resumeDraftId: id);
            return;
          }
          if (descriptor == FormDraftCatalog.financeExpenseAnalysisInput) {
            final period = parameters['expense.period'],
                mode = parameters['expenseMode'];
            if (period == null || mode == null) {
              throw const FormatException('费用原表草稿缺少原月份或操作，请从草稿列表核对原记录');
            }
            await showFinanceExpenseAnalysisDialog(
              context,
              period: period,
              mode: mode,
              lineKey: parameters['expense.lineKey'],
              entryId: parameters['expense.entryId'],
              groupId: parameters['expense.groupId'],
              resumeDraftId: id,
            );
            return;
          }
          final kind = parameters['inputKind'];
          if (kind == null) {
            throw const FormatException('原表资料草稿缺少原类型，请从草稿列表核对原记录');
          }
          final scope = <String, dynamic>{
            for (final entry in parameters.entries)
              if (entry.key.startsWith('input.'))
                entry.key.substring(6): entry.key == 'input.templateCompleted'
                    ? entry.value == 'true'
                    : entry.value,
          };
          await showFinanceTemplateInputDialog(
            context,
            kind: kind,
            scope: scope,
            resumeDraftId: id,
          );
        },
        child: child,
      );
    }
    return child;
  }

  @override
  Widget build(BuildContext context) {
    // 返回即刷新：回到本 hub 时按需重拉徽章汇总(本端写过数据或超过 30 秒，ADR-108)。
    ref.onPageResume(RouteName.finance, () => refreshBadges(ref));
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    // 卡片显隐 = hub 目录登记的落点 + 路由守卫(与 /finance 入口守卫同源，ADR-109)；
    // 业务审核中心的五类队列在页内按各自查看码分段，入口按它自己的路由守卫。
    bool canOpen(String location) =>
        hubCardAllowed(RouteName.finance, location, permissions, superAdmin);
    final canOpenAuditCenter = canOpen(RouteName.financeAudits);
    final canOpenQuoteReview = canOpen(RouteName.financeQuoteReview);
    final canOpenStockCountReview = canOpen(RouteName.financeStockCountReview);
    final canOpenExpenseConfirmation = canOpen(
      RoutePath.financeExpenseConfirmation,
    );
    final canHandleExpense = canOpen('/approvals/FINANCE');
    final canOpenApplications = canOpen('/finance/applications');
    List<_Entry> visible(List<_Entry> entries) => entries
        .where((entry) => canOpen(entry.location))
        .toList(growable: false);
    return _withFinancialSourceDrafts(
      Scaffold(
        appBar: UtenAppBar(
          title: l10n.financeHubTitle,
          leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
          ),
          actions: [
            const FormDraftsAppBarButton(categoryId: 'finance'),
            // 本模块累计：服务端徽章目录对钱流容器全部入口算好的和(含本模块 5 类
            // 草稿，ADR-108)，页面里不做加法。0 时组件自身不渲染。
            if (!compact) const UtenModuleBadges(module: BadgeModule.finance),
          ],
          bottom: UtenModuleBadges.compactAppBarBottom(
            context,
            ref,
            BadgeModule.finance,
          ),
        ),
        body: SafeArea(
          child: UtenContentContainer(
            child: ListView(
              key: const PageStorageKey('finance-hub-scroll'),
              padding: EdgeInsets.only(
                top: UtenSpacing.s12,
                // compact 悬浮胶囊避让：滚到底末卡要能越过胶囊
                bottom: context.breakpoint.isCompact
                    ? math.max(
                        UtenSpacing.s16,
                        UtenCapsuleNavScope.occlusionOf(context),
                      )
                    : UtenSpacing.s40,
              ),
              children: [
                if (canOpenAuditCenter ||
                    canOpenQuoteReview ||
                    canOpenStockCountReview ||
                    canOpenExpenseConfirmation ||
                    canHandleExpense ||
                    canOpenApplications) ...[
                  _section(context, theme, l10n.hubSectionTaskCenter, [
                    // 2026-09-18 合并：原 6 张审核队列卡（销售订单财务确认/销售订单
                    // 修改/出货财务审核/订货审批/超量到货审批/IQC 不合格退回与贷项）
                    // 并为一张「业务审核中心」卡，队列在页内按权限分段显示；
                    // 角标 = 五类队列待办之和（FinanceAuditCenterBadge 走注册表）。
                    if (canOpenAuditCenter)
                      const _Entry(
                        icon: Icons.fact_check_outlined,
                        label: '业务审核中心',
                        description: '销售订单 · 出货 · 订货 · 超量到货 · IQC 退回，一站式审核',
                        location: RouteName.financeAudits,
                        badgeScope: BadgeScope.entry(
                          BadgeEntry.financeAuditCenter,
                        ),
                        badge: FinanceAuditCenterBadge(),
                      ),
                    // 报价核价(ADR-134)：红徽章 = 等财务定价确认的报价。
                    if (canOpenStockCountReview)
                      const _Entry(
                        icon: Icons.inventory_outlined,
                        label: '普通仓盘点审核',
                        description: '核对盘点前后数量与重量，审核通过后更新库存',
                        location: RouteName.financeStockCountReview,
                        badgeScope: BadgeScope.entry(
                          BadgeEntry.financeStockCountReview,
                        ),
                      ),
                    if (canOpenExpenseConfirmation)
                      const _Entry(
                        icon: Icons.fact_check_outlined,
                        label: '费用单财务确认',
                        description: '核对一般费用已过账凭证，完成财务确认',
                        location: RoutePath.financeExpenseConfirmation,
                        badgeScope: BadgeScope.entry(
                          BadgeEntry.financeExpenseConfirmation,
                        ),
                      ),
                    if (canOpenQuoteReview)
                      _Entry(
                        icon: Icons.price_check_outlined,
                        label: l10n.quoteFinanceHubTitle,
                        description: l10n.quoteFinanceHubSubtitle,
                        location: RouteName.financeQuoteReview,
                        badgeScope: const BadgeScope.entry(
                          BadgeEntry.financeQuoteReview,
                        ),
                      ),
                    if (canHandleExpense)
                      const _Entry(
                        icon: Icons.receipt_long_outlined,
                        label: '申请审批中心',
                        description: '报销与其他申请按实际岗位办理',
                        location: '/approvals/FINANCE',
                        badgeScope: BadgeScope.entries(
                          todo: BadgeEntry.expenseFinance,
                          inProgress: BadgeEntry.applicationFinance,
                          additionalTodoEntries: {
                            BadgeEntry.applicationFinance,
                          },
                        ),
                      ),
                    if (canOpenApplications)
                      const _Entry(
                        icon: Icons.account_tree_outlined,
                        label: FinanceRequirementNames.financeApplications,
                        description: '出差、报销、付款、预付及工资原流程',
                        location: '/finance/applications',
                        badgeScope: BadgeScope.entry(
                          BadgeEntry.financeApplications,
                        ),
                      ),
                  ]),
                  const SizedBox(height: UtenSpacing.s16),
                ],
                // 2026-09-24 三段式：任务中心 → 新建单据 → 设置与台账 → 报表中心。
                _section(
                  context,
                  theme,
                  '新建单据',
                  visible([
                    _Entry(
                      icon: Icons.south_west_outlined,
                      label: '新建${l10n.financeHubDocReceipt}',
                      description: l10n.financeHubDocReceiptSub,
                      location: RoutePath.financeDocNew('receipts'),
                    ),
                    _Entry(
                      icon: Icons.north_east_outlined,
                      label: '新建${l10n.financeHubDocPayment}',
                      description: l10n.financeHubDocPaymentSub,
                      location: RoutePath.financeDocNew('payments'),
                    ),
                    _Entry(
                      icon: Icons.outbound_outlined,
                      label: '新建${l10n.financeHubDocExpense}',
                      description: l10n.financeHubSubAllocatedByDept,
                      location: RoutePath.financeDocNew('expenses'),
                    ),
                    _Entry(
                      icon: Icons.add_circle_outline,
                      label: '新建${l10n.financeHubDocIncome}',
                      description: l10n.financeHubSubAllocatedByDept,
                      location: RoutePath.financeDocNew('incomes'),
                    ),
                    _Entry(
                      icon: Icons.swap_horiz_rounded,
                      label: '新建${l10n.financeHubDocBankTransfer}',
                      description: l10n.financeHubDocBankTransferSub,
                      location: RoutePath.financeDocNew('bank-transfers'),
                    ),
                  ]),
                ),
                const SizedBox(height: UtenSpacing.s16),
                // 2026-09-24 三段式：设置与台账（浏览管理卡，不挂数；不属于新建区）。
                _section(
                  context,
                  theme,
                  '设置与台账',
                  visible([
                    _Entry(
                      icon: Icons.tune_outlined,
                      label: l10n.expenseFlowSettingsTitle,
                      description: l10n.expenseFlowSettingsEntryDescription,
                      location: '/expense/settings',
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
                  '报表中心',
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
                    // ADR-131 车间内料仓用量与结算 (塑料用量附表的数据来源)。
                    _Entry(
                      icon: Icons.scale_outlined,
                      label: l10n.workshopMaterialReports,
                      description: l10n.workshopMaterialReportsHubDesc,
                      location: RouteName.workshopMaterialReports,
                    ),
                  ]),
                ),
              ],
            ),
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
    return UtenPageEdgePadding(
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
            compactMinItemWidth: 132,
            columns: const UtenResponsiveColumns(compact: 2, medium: 3),
            minItemWidth:
                entries.any(
                  (entry) => entry.badgeScope != null || entry.badge != null,
                )
                ? UtenHubCard.minimumBadgeRowWidth(context)
                : null,
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
    this.badgeScope,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final BadgeScope? badgeScope;

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
      onTap: () => pushFrom<void>(context, entry.location),
      badgeScope: entry.badgeScope,
      badge: entry.badge,
    );
  }
}

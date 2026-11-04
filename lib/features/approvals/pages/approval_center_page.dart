import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_button.dart';

import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../applications/pages/business_application_list_page.dart';
import '../../expense/pages/expense_approval_list_page.dart';
import '../../expense/providers/expense_providers.dart';
import '../../expense/repositories/expense_repository.dart';
import '../../sales/pages/sales_manager_review_page.dart';

/// The same review workspace serves department heads, finance and executives.
/// Scope is sent to the server; clients never filter a page after pagination.
class ApprovalCenterPage extends ConsumerStatefulWidget {
  const ApprovalCenterPage({
    super.key,
    required this.departmentCode,
    this.initialGroup,
    this.initialApplicationQueue,
  });
  final String departmentCode;
  final String? initialGroup;
  final String? initialApplicationQueue;

  @override
  ConsumerState<ApprovalCenterPage> createState() => _ApprovalCenterPageState();
}

class _ApprovalCenterPageState extends ConsumerState<ApprovalCenterPage> {
  String? _group;
  String? _historyKind;

  @override
  void initState() {
    super.initState();
    _group = widget.initialGroup;
  }

  @override
  void didUpdateWidget(covariant ApprovalCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.departmentCode != widget.departmentCode ||
        oldWidget.initialGroup != widget.initialGroup) {
      _group = widget.initialGroup;
      _historyKind = null;
    }
  }

  bool get _finance => widget.departmentCode == 'FINANCE';
  bool get _executive => widget.departmentCode == 'GM';
  String get _departmentCode =>
      widget.departmentCode == 'GM_DEPARTMENT' ? 'GM' : widget.departmentCode;
  ExpenseApprovalReadScope get _scope => ExpenseApprovalReadScope(
    approvalStage: _finance
        ? 'FINANCE'
        : _executive
        ? 'EXECUTIVE'
        : 'DEPARTMENT',
    departmentCode: _finance || _executive ? null : _departmentCode,
  );

  @override
  Widget build(BuildContext context) {
    int fact(String key) => ref.watch<int>(badgeFactProvider(key));
    final permissions = ref.watch(currentPermissionsProvider);
    final expensePermissions = _finance
        ? const [
            Perm.expenseApprove,
            Perm.expenseApproveFinanceInitial,
            Perm.expenseApproveFinanceReview,
            Perm.expensePay,
            Perm.expenseView,
          ]
        : _executive
        ? const [Perm.expenseApproveExecutive]
        : const [Perm.expenseApproveDepartment];
    final applicationPermissions = _finance
        ? const [
            Perm.applicationApproveFinanceInitial,
            Perm.applicationApproveFinanceReview,
            Perm.applicationReceive,
            Perm.applicationPay,
            Perm.applicationPrepaymentLinkFinance,
            Perm.applicationView,
          ]
        : _executive
        ? const [
            Perm.applicationApproveExecutive,
            Perm.applicationApproveViceExecutive,
          ]
        : widget.departmentCode == 'DEPT_PMC'
        ? const [
            Perm.applicationApproveDepartment,
            Perm.applicationApproveProcurement,
          ]
        : const [Perm.applicationApproveDepartment];
    final expenseAllowed = expensePermissions.any(permissions.contains);
    final applicationsAllowed = applicationPermissions.any(
      permissions.contains,
    );
    final ordersAllowed =
        widget.departmentCode == 'DEPT_SALES' &&
        const [
          Perm.salesOrderManagerView,
          Perm.salesQuoteManagerView,
        ].any(permissions.contains);
    final groups = <String>[
      if (expenseAllowed) 'expense',
      if (applicationsAllowed) 'application',
      if (ordersAllowed) 'order',
    ];
    String label(String key) => switch (key) {
      'expense' => '报销审批',
      'application' => '申请审批',
      'order' => '订单审批',
      _ => '历史记录',
    };
    int count(String key) => switch (key) {
      'expense' =>
        _finance
            ? fact('expense.financeInitialPendingApprovalCount') +
                  fact('expense.financeReviewPendingApprovalCount') +
                  fact(BadgeFact.expensePendingPayment)
            : _executive
            ? fact('expense.executivePendingApprovalCount')
            : fact('expense.departmentPendingByCode.$_departmentCode'),
      'application' =>
        _finance
            ? fact('application.financePendingCount') +
                  fact('application.financeReceivePendingCount') +
                  fact('application.payableCount') +
                  fact('application.prepaymentPostingTodoCount')
            : _executive
            ? fact('application.executivePendingCount') +
                  fact('application.viceExecutivePendingCount')
            : fact('application.departmentPendingByCode.$_departmentCode') +
                  (widget.departmentCode == 'DEPT_PMC'
                      ? fact('application.procurementPendingCount')
                      : 0),
      'order' => ref.watch(
        badgeEntryTodoProvider(BadgeEntry.salesManagerReview),
      ),
      _ => 0,
    };
    int inProgress(String key) => key == 'application' && _finance
        ? fact('application.prepaymentPostingInProgressCount')
        : 0;
    final summaryLoaded = ref.watch(
      badgeSummaryProvider.select((value) => value.loaded),
    );
    if (_group != 'history' && !groups.contains(_group) && summaryLoaded) {
      _group =
          groups.where((key) => count(key) > 0).firstOrNull ??
          groups.where((key) => inProgress(key) > 0).firstOrNull ??
          groups.firstOrNull;
    }
    final group = (_group == 'history' || groups.contains(_group))
        ? _group
        : groups.firstOrNull;
    final history = group == 'history';
    final historyKind = groups.contains(_historyKind)
        ? _historyKind
        : groups.firstOrNull;
    final active = history ? historyKind : group;
    Widget content = const SizedBox.shrink();
    if (active == 'expense') {
      content = ProviderScope(
        key: ValueKey((_scope, history)),
        overrides: [expenseApprovalReadScopeProvider.overrideWithValue(_scope)],
        child: ExpenseApprovalListPage(
          embedded: true,
          historyOnly: history,
          resumeLocation: '/approvals/${widget.departmentCode}',
          initialQueue: history ? ApprovalQueue.history : ApprovalQueue.pending,
        ),
      );
    } else if (active == 'application') {
      content = BusinessApplicationApprovalListPage(
        key: ValueKey((widget.departmentCode, history)),
        embedded: true,
        approvalStage: _finance
            ? 'FINANCE'
            : _executive
            ? 'MANAGEMENT'
            : widget.departmentCode == 'DEPT_PMC'
            ? 'PMC'
            : 'DEPARTMENT',
        departmentCode: _finance || _executive ? null : _departmentCode,
        initialHistory: history,
        initialQueue: history ? 'history' : widget.initialApplicationQueue,
        historyOnly: history,
        resumeLocation: '/approvals/${widget.departmentCode}',
      );
    } else if (active == 'order') {
      content = SalesManagerReviewPage(
        key: ValueKey(('order', history)),
        embedded: true,
        initialKind: 'order',
        initialHistory: history,
        historyOnly: history,
      );
    }
    return Scaffold(
      appBar: UtenAppBar(
        title: _finance
            ? '财务审批中心'
            : _executive
            ? '总经办任务中心'
            : '审批中心',
        showBackButton: true,
        actions: [
          if (permissions.contains(Perm.approvalPolicyManage))
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.rule_folder_outlined,
              onPressed: () => context.push('/approvals/settings'),
              child: const Text('审批设置'),
            ),
        ],
        info: '只显示当前授权范围内的单据。审批结果、驳回原因与每次修订均保留记录。',
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s12,
              UtenSpacing.s16,
              UtenSpacing.s8,
            ),
            child: UtenFilterToolbar<String>(
              segmentsKey: const Key('approval-center-categories'),
              segments: [
                for (final key in groups)
                  UtenFilterSegment(
                    value: key,
                    label: label(key),
                    count: count(key),
                    inProgressCount: inProgress(key),
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                if (groups.isNotEmpty)
                  const UtenFilterSegment(value: 'history', label: '历史记录'),
              ],
              selected: {?group},
              onSelectionChanged: (value) => setState(() => _group = value),
            ),
          ),
          if (history)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
              child: UtenFilterToolbar<String>(
                autoSelectBadge: false,
                segments: [
                  for (final key in groups)
                    UtenFilterSegment(value: key, label: label(key)),
                ],
                selected: {?historyKind},
                onSelectionChanged: (value) =>
                    setState(() => _historyKind = value),
              ),
            ),
          Expanded(child: content),
        ],
      ),
    );
  }
}

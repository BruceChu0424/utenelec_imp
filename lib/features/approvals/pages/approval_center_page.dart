import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_button.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_refresh_scope.dart';
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
  int _refreshTick = 0;
  final _refreshController = UtenRefreshController();

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

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
    // 与任务中心「默认不选、点击后加载」范式一致：计数到位后只自动选中
    // 真有待办/在办的分类；红黄皆无保持未选（占位引导态），不再兜底选第一组。
    if (_group != 'history' && !groups.contains(_group) && summaryLoaded) {
      _group =
          groups.where((key) => count(key) > 0).firstOrNull ??
          groups.where((key) => inProgress(key) > 0).firstOrNull;
    }
    final group = (_group == 'history' || groups.contains(_group))
        ? _group
        : null;
    final history = group == 'history';
    final historyKind = groups.contains(_historyKind)
        ? _historyKind
        : groups.firstOrNull;
    final active = history ? historyKind : group;
    final categoryBar = UtenFilterToolbar<String>(
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
      selected: group == null ? const <String>{} : {group},
      onSelectionChanged: (value) => setState(() => _group = value),
    );
    final historyBar = UtenFilterToolbar<String>(
      autoSelectBadge: false,
      segments: [
        for (final key in groups)
          UtenFilterSegment(value: key, label: label(key)),
      ],
      selected: historyKind == null ? const <String>{} : {historyKind},
      onSelectionChanged: (value) => setState(() => _historyKind = value),
    );
    // 2026-11-04 上滑先把表格钉顶（同仓库任务中心/业务审核中心 externalHeader
    // 范式）：选中分类后父分类行（历史态含分类选择行）作为外置头传给内嵌页，
    // 由内嵌页挂进自己的折叠头随页滚走；未选分类时父行仍钉在引导占位上方。
    // 与正文的间距由内嵌页在 externalHeader 之后统一补 rowGap，这里不再叠加。
    final groupHeader = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        categoryBar,
        if (history) ...[
          const SizedBox(height: UtenFilterRow.rowGap),
          historyBar,
        ],
      ],
    );
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
          refreshTick: _refreshTick,
          externalHeader: groupHeader,
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
        refreshTick: _refreshTick,
        externalHeader: groupHeader,
      );
    } else if (active == 'order') {
      content = SalesManagerReviewPage(
        key: ValueKey(('order', history)),
        embedded: true,
        initialKind: 'order',
        initialHistory: history,
        historyOnly: history,
        refreshTick: _refreshTick,
        externalHeader: groupHeader,
      );
    }
    // 刷新按钮与其他任务中心页同位（右上角 AppBar）：徽章汇总直接重拉，
    // 当前分段的列表请求由 refreshTick 传给内嵌页并登记到刷新作用域。
    return UtenRefreshScope(
      controller: _refreshController,
      child: Scaffold(
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
            UtenRefreshButton(
              key: const Key('approval-center-refresh'),
              onRefresh: () => _refreshController.run(() {
                _refreshController.track(refreshBadges(ref));
                setState(() => _refreshTick++);
              }),
            ),
          ],
          info: '只显示当前授权范围内的单据。审批结果、驳回原因与每次修订均保留记录。',
        ),
        // 布局对齐任务中心范式（仓库任务中心/财务业务审核中心）：页面容器统一
        // 提供 gutter（父分类行与正文同缘、随窗口取 16/24），父行与子分类行之间
        // 用统一 rowGap，不再手写 16px 缩进与页面自加的水平边距。
        body: SafeArea(
          child: groups.isEmpty
              ? Center(
                  child: Text(
                    '暂无已授权的审批任务，请联系管理员开通。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : UtenContentContainer.wide(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s16,
                    ),
                    // 未选分类 = 引导占位（子分类不出现、不发请求）；有待办的
                    // 分类由上方自动选中逻辑/用户点击进入正文。选中后父分类行
                    // 经 externalHeader 进内嵌页折叠头（上滑先把表格钉顶）。
                    child: group == null
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              categoryBar,
                              const SizedBox(height: UtenSpacing.s8),
                              const Expanded(
                                child: UtenFilterPlaceholder(
                                  message: '在上方选择分类后开始审批',
                                  description: '分段右侧数字徽章为该分类的待办数量',
                                ),
                              ),
                            ],
                          )
                        : content,
                  ),
                ),
        ),
      ),
    );
  }
}

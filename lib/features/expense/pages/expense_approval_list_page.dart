import '../../../shared/providers/native_facet_options.dart';
import '../../../shared/formatters/exact_decimal.dart';
// 报销审批列表页（审批人 + 财务打款双队列）
// 文档：docs/03-页面/报销审批列表页.md
//
// 2026-09-19 V608 全链路改版：对齐 purchase 范式——UtenFilterToolbar 分段
// （待审批/待付款按权限显隐，计数来自 /summary，两队列都是「等本页用户动手」
// → actionable 红徽章口径）+ 队列汇总统计条（待审批/待付款/本月提交/本月已付款）
// + 表格增「报销单号」列；批量通过/驳回改走后端单事务端点（approve-batch /
// reject-batch，全成全败，不再前端逐单循环）。
// 历史：2026-09-09 表格化；2026-09-10 表头筛选 + 责任提示；2026-09-16 类别桶。

import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_progress_dialog.dart';
import '../../../shared/models/retained_async_page.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../shared/models/paged_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_batch_reject_dialog.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_refresh_scope.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../core/network/read_scope_revision.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../providers/expense_providers.dart';
import '../providers/expense_counts_provider.dart';
import '../providers/expense_action_eligibility.dart';
import '../repositories/expense_repository.dart';
import '../../../shared/badges/badge_registry.dart';

/// 单次批量上限（与后端 @Size(max=50) 对齐）。
const int kExpenseBatchLimit = 50;

class ExpenseFinanceApprovalPage extends StatelessWidget {
  const ExpenseFinanceApprovalPage({super.key, this.initialQueue});
  final ApprovalQueue? initialQueue;
  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      expenseApprovalReadScopeProvider.overrideWithValue(
        const ExpenseApprovalReadScope(approvalStage: 'FINANCE'),
      ),
    ],
    child: ExpenseApprovalListPage(initialQueue: initialQueue),
  );
}

class ExpenseApprovalListPage extends ConsumerStatefulWidget {
  const ExpenseApprovalListPage({
    super.key,
    this.initialQueue,
    this.embedded = false,
    this.historyOnly = false,
    this.resumeLocation,
    this.refreshTick = 0,
    this.externalHeader,
  });
  final ApprovalQueue? initialQueue;
  final bool embedded;
  final bool historyOnly;
  final String? resumeLocation;

  /// 宿主(审批中心)右上角刷新的递增计数；变化时本页重拉队列数据。
  final int refreshTick;

  /// 宿主父分类行：由本页挂进折叠头随页滚走（上滑先把表格钉顶，
  /// 2026-09-24「表格滑到顶」口径，同仓库任务中心/业务审核中心范式）。
  final Widget? externalHeader;

  @override
  ConsumerState<ExpenseApprovalListPage> createState() =>
      _ExpenseApprovalListPageState();
}

class _ExpenseApprovalListPageState
    extends ConsumerState<ExpenseApprovalListPage> {
  /// 待审批段多选：报销单 id（跨页保留）。换分段清空。
  final _tableRows = MasterDataTableRowsController<ExpenseClaim>();
  final _retainedPage = RetainedAsyncPage<PagedResult<ExpenseClaim>>();
  Set<String> _selectedIds = {};
  final Map<String, ExpenseClaim> _selectedClaims = {};
  int _selectionGeneration = 0;
  int _operationGeneration = 0;

  /// 批量审批进行中（防并发 + 按钮加载态）。
  bool _batchBusy = false;
  bool _refreshing = false;
  bool _queueReady = true;
  int _queueGeneration = 0;
  bool _queueListenerBound = false;

  /// 身份/权限/范围失效（_retireSelection 的旁路）：批量进度弹窗据此收尾，
  /// 让旧批量的迟到结果不再呈现。
  final _identityChanges = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _prepareInitialQueue();
    ref.listenManual(expenseActionEligibilityProvider, (previous, next) {
      if (previous != next) _retireSelection();
    });
    ref.listenManual(readScopeRevisionProvider, (previous, next) {
      if (previous != next) _retireSelection();
    });
  }

  @override
  void dispose() {
    _identityChanges.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ExpenseApprovalListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialQueue != widget.initialQueue) _prepareInitialQueue();
    // 宿主(审批中心)右上角刷新：请求登记到宿主 UtenRefreshScope，
    // 按钮等待真实列表请求收尾。延迟到帧后执行，避免在 build 期间
    // invalidate provider。
    if (oldWidget.refreshTick != widget.refreshTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) UtenRefreshScope.track(context, _refreshQueue());
      });
    }
  }

  void _prepareInitialQueue() {
    _retireSelection();
    final generation = ++_queueGeneration;
    final requested = widget.initialQueue;
    if (requested == null) {
      _queueReady = true;
      return;
    }
    _queueReady = false;
    // Retain the auto-disposed queue until the first business-list build watches
    // it; otherwise the post-frame route selection could reset to the default.
    if (!_queueListenerBound) {
      ref.listenManual(approvalQueueProvider, (_, _) {});
      _queueListenerBound = true;
    }
    _selectedIds.clear();
    _selectedClaims.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _queueGeneration) return;
      ref
          .read(approvalQueueProvider.notifier)
          .state = expenseApprovalInitialQueue(
        ref.read(currentPermissionsProvider),
        requested,
      );
      setState(() => _queueReady = true);
    });
  }

  void _retireSelection() {
    if (!mounted) return;
    ++_selectionGeneration;
    ++_operationGeneration;
    _identityChanges.value++;
    void clear() {
      _selectedIds = {};
      _selectedClaims.clear();
      _batchBusy = false;
    }

    if (_selectedIds.isNotEmpty || _batchBusy) {
      setState(clear);
    } else {
      clear();
    }
  }

  void _select(Set<String> requested) {
    if (_batchBusy) return;
    final eligibility = ref.read(expenseActionEligibilityProvider);
    final visible = {for (final claim in _tableRows.items) claim.id: claim};
    final next = requested
        .where(
          (id) =>
              eligibility.canReviewClaim(visible[id] ?? _selectedClaims[id]),
        )
        .toSet();
    if (next.length == _selectedIds.length &&
        next.every(_selectedIds.contains)) {
      return;
    }
    setState(() {
      ++_selectionGeneration;
      _selectedClaims.removeWhere((id, _) => !next.contains(id));
      for (final id in next) {
        _selectedClaims.putIfAbsent(id, () => visible[id]!);
      }
      _selectedIds = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(
      widget.resumeLocation ?? '/expense/approval',
      _refreshQueue,
    );
    if (!_queueReady) {
      // 嵌入审批中心时不重复出自己的 AppBar，宿主父分类行钉在骨架上方
      //（同订货审批任务中心 _pinHostHeader：点击子分类瞬间分类栏不得消失）。
      return Scaffold(
        appBar: widget.embedded ? null : const UtenAppBar(title: '报销审批'),
        body: widget.externalHeader == null
            ? const UtenPageEdgePadding(child: UtenSkeletonList())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  widget.externalHeader!,
                  const SizedBox(height: UtenFilterRow.rowGap),
                  const Expanded(child: UtenSkeletonList()),
                ],
              ),
      );
    }
    ref
        .read(expenseApprovalListProvider.notifier)
        .bindReadView(context, visiblePage: () => _tableRows.visiblePage);
    final queue = ref.watch(approvalQueueProvider);
    final facets = ref.watch(expenseApprovalFacetsProvider(queue));
    final filters = ref.watch(expenseApprovalFiltersProvider);
    // 2026-09-25 单号列统一：报销单号表头排序（服务端白名单 claimNo）。
    final sortColumn = ref.watch(expenseApprovalSortColumnProvider);
    final sortAscending = ref.watch(expenseApprovalSortAscendingProvider);
    final paginationScope = (
      queue,
      filters,
      sortColumn,
      sortAscending,
      retainedReaderEpoch(ref),
    );
    final listAsync = _retainedPage.resolveFor(
      ref,
      paginationScope,
      expenseApprovalListProvider,
    );
    final page =
        listAsync.value ??
        const PagedResult<ExpenseClaim>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 0,
        );
    int fact(String key) => ref.watch<int>(badgeFactProvider(key));
    final scope = ref.watch(expenseApprovalReadScopeProvider);
    final facetQuery = <String, dynamic>{
      'queue': queue.name,
      ...scope.query,
      'year': ?filters.year,
      'month': ?filters.month,
      'departmentId': ?filters.departmentId,
      'category': ?filters.category,
      'claimNo': ?filters.claimNo,
      'sort': ?sortColumn,
      if (sortColumn != null) 'order': sortAscending ? 'asc' : 'desc',
    };
    final summaryAsync = scope.isScoped
        ? null
        : ref.watch(expenseQueueSummaryProvider);
    final counts = ref.watch(expenseCountsProvider);
    final int pendingCount = scope.departmentCode != null
        ? fact('expense.departmentPendingByCode.${scope.departmentCode}')
        : scope.approvalStage == 'EXECUTIVE'
        ? fact('expense.executivePendingApprovalCount')
        : scope.isFinance
        ? fact('expense.financeInitialPendingApprovalCount') +
              fact('expense.financeReviewPendingApprovalCount')
        : counts.pendingApprovalCount;
    final permissions = ref.watch(currentPermissionsProvider);
    final canView = !scope.isScoped && permissions.contains(Perm.expenseView);
    final canApprove = hasExpenseApprovalPermission(permissions);
    final canPay =
        (!scope.isScoped || scope.isFinance) &&
        permissions.contains(Perm.expensePay);
    final eligibility = ref.watch(expenseActionEligibilityProvider);
    final isPendingQueue = queue == ApprovalQueue.pending;
    final summary = summaryAsync?.value;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // 嵌入审批中心（分类栏精简）：队列行退役，待审核/待付款的队列切换由
    // 首列「状态」表头筛选承载（同订货审批任务中心 status→分段联动范式）；
    // 历史记录不在筛选里——宿主父分类行已有「历史记录」段。
    final queueFilterable = widget.embedded && !widget.historyOnly;
    final statusFacets = queueFilterable
        ? <String, List<MasterFacetBucket>>{
            'status': [
              MasterFacetBucket(
                value: ApprovalQueue.pending.name,
                label: '待审核',
                count: pendingCount,
              ),
              if (canPay)
                MasterFacetBucket(
                  value: ApprovalQueue.payable.name,
                  label: '待付款',
                  count: counts.pendingPaymentCount,
                ),
            ],
          }
        : const <String, List<MasterFacetBucket>>{};

    Widget body = Padding(
      // 嵌入审批中心时顶部间距由父分类行的统一 rowGap 提供，避免双层间距叠加；
      // 独立页保留自身顶部间距。
      padding: EdgeInsets.only(top: widget.embedded ? 0 : UtenSpacing.s8),
      child: UtenCollapsingHeaderScrollView(
        // 两队列都是「确实在等本页用户动手」→ actionable 红徽章
        // （docs/00-项目准则/14-徽章与计数口径.md §二）。
        // 2026-09-24 对齐物料分析页：统计条随页滚走，body 只剩表格。
        // 2026-11-04 审批中心分类栏精简：嵌入态不再自带队列行——待审核/待付款
        // 由表格首列「状态」表头筛选驱动（同订货审批任务中心范式），历史记录走
        // 宿主父分类行；宿主父行经 [Widget.externalHeader] 挂进折叠头随页滚走。
        collapsingHeader: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.externalHeader != null) ...[
              widget.externalHeader!,
              const SizedBox(height: UtenFilterRow.rowGap),
            ],
            if (!widget.embedded)
              UtenFilterToolbar<ApprovalQueue>(
                segmentsKey: const Key('expense-approval-segments'),
                segments: [
                  if (!widget.historyOnly && canView)
                    const UtenFilterSegment(
                      value: ApprovalQueue.browse,
                      label: '全部单据',
                    ),
                  if (!widget.historyOnly && (canView || canApprove))
                    UtenFilterSegment(
                      value: ApprovalQueue.pending,
                      label: '待审核',
                      count: canApprove
                          ? (scope.isScoped
                                ? pendingCount
                                : summary?.actionablePendingCount)
                          : summary?.pendingCount,
                      countForm: canApprove
                          ? UtenSegmentCountForm.actionable
                          : UtenSegmentCountForm.browsing,
                    ),
                  if (!widget.historyOnly && (canView || canPay))
                    UtenFilterSegment(
                      value: ApprovalQueue.payable,
                      label: '待付款',
                      count: canPay
                          ? (scope.isScoped
                                ? counts.pendingPaymentCount
                                : summary?.actionablePayableCount)
                          : summary?.payableCount,
                      countForm: canPay
                          ? UtenSegmentCountForm.actionable
                          : UtenSegmentCountForm.browsing,
                    ),
                  UtenFilterSegment(
                    value: ApprovalQueue.history,
                    label: l10n.expenseFlowHistory,
                    count: queue == ApprovalQueue.history
                        ? listAsync.value?.total
                        : null,
                  ),
                ],
                selected: {queue},
                onSelectionChanged: (value) {
                  _retireSelection();
                  ref.read(approvalQueueProvider.notifier).state = value;
                },
              ),
            // 队列汇总统计条（/summary：两队列 + 本月口径，财务汇总；随页滚走）。
            if (summary != null)
              UtenPageEdgePadding(
                padding: const EdgeInsets.only(
                  top: UtenSpacing.s8,
                  bottom: UtenSpacing.s8,
                  left: UtenSpacing.s4,
                  right: UtenSpacing.s4,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.fact_check_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        // 报销恒人民币（2026-10-10 金额带单位口径：数值后带「元」）。
                        '待审批 ${summary.pendingCount} 单 · '
                        '${financeExactMoneyDisplay(summary.pendingAmountText)} 元　|　'
                        '待付款 ${summary.payableCount} 单 · '
                        '${financeExactMoneyDisplay(summary.payableAmountText)} 元　|　'
                        '本月提交 ${summary.monthSubmittedCount} 单 · '
                        '${financeExactMoneyDisplay(summary.monthSubmittedAmountText)} 元　|　'
                        '本月已付款 ${summary.monthPaidCount} 单 · '
                        '${financeExactMoneyDisplay(summary.monthPaidAmountText)} 元',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        body: MasterDataTableView<ExpenseClaim>(
          expensiveRowMounts: false,
          rowsController: _tableRows,
          tableKey:
              'features.expense.pages.expense_approval_list_page.ExpenseApprovalListPageState.build.1',
          key: const Key('expense-approval-table'),
          paginationScope: paginationScope,
          isLoading: listAsync.isLoading && !listAsync.hasValue,
          loadingMore: listAsync.isLoading && listAsync.hasValue,
          error: listAsync.hasError
              ? (humanErrorMessage(listAsync.error!) ?? '读取完整列表失败，请重试')
              : null,
          onRetry: _refreshQueue,
          primary: true,
          columns: _columns,
          items: page.items,
          // 部门 / 年月筛选桶来自后端聚合；未加载完成前列头暂无筛选项。
          // 2026-09-25 单号列统一：facets 响应含报销单号桶（claimNo）。
          // 嵌入态 'status' 桶 = 队列切换（待审核/待付款），计数与原队列段同源。
          facets: {...facets.value ?? const {}, ...statusFacets},
          facetPageLoaders: nativeFacetLoaders(
            ref,
            path: '/expense-claims/facets',
            fields: const ['claimNo'],
            filters: facetQuery,
          ),
          facetSearchScope: nativeFacetSearchScope(
            ref,
            '/expense-claims/facets',
            facetQuery,
          ),
          nullCounts: const {},
          filters: {
            ...filters.asTableFilters,
            if (queueFilterable) 'status': queue.name,
          },
          onFilterChanged: (key, value) {
            if (queueFilterable && key == 'status') {
              final next = value == ApprovalQueue.payable.name
                  ? ApprovalQueue.payable
                  : ApprovalQueue.pending;
              if (next == queue) return;
              _retireSelection();
              ref.read(approvalQueueProvider.notifier).state = next;
              return;
            }
            _onFilterChanged(key, value);
          },
          // 2026-09-25 单号列统一：表头排序走服务端白名单（claimNo）。
          sortColumn: sortColumn,
          sortAscending: sortAscending,
          onSortChange: (column, ascending) {
            ref.read(expenseApprovalSortColumnProvider.notifier).state = column;
            ref.read(expenseApprovalSortAscendingProvider.notifier).state =
                ascending;
          },
          // 待审批段开多选 + 悬浮批量通过/驳回；待付款段只读浏览
          //（打款参数逐单不同，打款在详情页完成）。
          selectable: isPendingQueue && eligibility.canReview,
          idOf: (claim) => eligibility.canReviewClaim(claim) ? claim.id : null,
          rowKeyOf: (claim) => claim.id,
          selectedIds: _selectedIds,
          onSelectedIdsChanged: _select,
          batchActionsBuilder: isPendingQueue && eligibility.canReview
              ? _batchActions
              : null,
          // 双击行进入审批详情：push（2026-09-24 起），审批后详情 pop 回本页，
          // 列表实例与筛选/页码保留，数据由 provider 失效自动换新；
          // 原来 go 直达会把列表实例抹掉，详情返回只能落 default。
          onRowTap: (claim) async {
            await context.push('/expense/approval/${claim.id}');
            if (mounted && scope.isScoped) await _refreshQueue();
          },
          emptyMessage: switch (queue) {
            ApprovalQueue.pending => '暂无待审批报销',
            ApprovalQueue.payable => '暂无待付款报销',
            ApprovalQueue.history => '暂无已处理报销',
            ApprovalQueue.browse => '授权范围内暂无报销单',
          },
          currentPage: page.page,
          totalPages: page.totalPages,
          onPageChange: (p) =>
              ref.read(expenseApprovalListProvider.notifier).goToPage(p),
        ),
      ),
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    } else {
      body = UtenPageEdgePadding(child: body);
    }

    return Scaffold(
      appBar: widget.embedded
          ? null
          : UtenAppBar(
              title: '报销审批',
              showBackButton: true,
              actions: [
                UtenRefreshButton(
                  enabled: !_batchBusy,
                  busy: listAsync.isLoading,
                  onRefresh: _refreshQueue,
                ),
              ],
            ),
      body: Stack(
        children: [
          body,
          if (_refreshing)
            const UtenBusyOverlay(title: '正在处理报销', showDoNotLeaveHint: false),
        ],
      ),
    );
  }

  /// 表头筛选：部门 / 年月 → 下推 provider 参数（列表 provider 重建即回第 1 页）；
  /// 选「所有」= 清该列；换筛选后旧选中集失效。
  void _onFilterChanged(String key, String? value) {
    final current = ref.read(expenseApprovalFiltersProvider);
    ref.read(expenseApprovalFiltersProvider.notifier).state = current
        .withColumn(key, value);
    _retireSelection();
  }

  final List<MasterColumnDef<ExpenseClaim>> _columns = [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 170,
      value: (claim) => claim.progressLabel,
      // 2026-09-27 用户口径「表格状态列整格底色」（口径同报销列表；ADR-169
      // 档位锚定）：草稿=灰 / 待审批·审批中=蓝（已提交流转；「轮到我审/我付」
      // 由待审批·待付款分段的红徽章表达）/ 已通过待打款=琥珀（本页待付款段
      // 里=等待登记付款，无异常）/ 驳回=红 / 已付款=绿。
      cellColor: (context, claim) =>
          utenStatusBadgeCellColor(switch (claim.status) {
            ExpenseClaimStatus.draft => UtenStatusBadgeType.neutral,
            ExpenseClaimStatus.submitted ||
            ExpenseClaimStatus.reviewing => UtenStatusBadgeType.info,
            ExpenseClaimStatus.approved => UtenStatusBadgeType.warning,
            ExpenseClaimStatus.rejected => UtenStatusBadgeType.danger,
            ExpenseClaimStatus.paid => UtenStatusBadgeType.success,
          }),
    ),
    MasterColumnDef(
      key: 'claimNo',
      label: '报销单号',
      width: 160,
      // 2026-09-25 单号列统一：可排序（服务端白名单 claimNo）+ 值筛选（facets）。
      sortable: true,
      value: (claim) => claim.claimNo,
    ),
    MasterColumnDef(
      key: 'applicantName',
      label: '申请人',
      width: 120,
      value: (claim) => claim.applicantName,
    ),
    MasterColumnDef(
      key: 'departmentName',
      label: '部门',
      width: 150,
      value: (claim) => claim.departmentName,
    ),
    MasterColumnDef(
      key: 'title',
      label: '标题',
      width: 240,
      value: (claim) => claim.title,
    ),
    MasterColumnDef(
      key: 'category',
      label: '费用类别',
      width: 160,
      value: (claim) =>
          claim.items.map((item) => item.category.label).toSet().join(' / '),
    ),
    MasterColumnDef(
      key: 'totalAmount',
      exactValueOf: (claim) => claim.totalAmountText,
      label: '金额',
      width: 110,
      type: 'money',
      value: (claim) => financeExactMoneyDisplay(claim.totalAmountText),
    ),
    MasterColumnDef(
      key: 'currency',
      label: '币种',
      width: 80,
      value: (_) => expenseClaimCurrencyName,
    ),
    MasterColumnDef(
      key: 'yearMonth',
      label: '年月',
      width: 90,
      info: '报销单创建的年月；点击表头可按这个年月筛选。',
      value: (claim) => expenseYearMonth(claim.createdAt),
    ),
    MasterColumnDef(
      key: 'submittedAt',
      label: '提交时间',
      width: 150,
      type: 'date',
      value: (claim) => _formatTime(claim.submittedAt ?? claim.createdAt),
    ),
  ];

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final permissions = ref.watch(currentPermissionsProvider);
    return [
      if (permissions.contains(Perm.attachmentView) &&
          permissions.contains(Perm.attachmentDownload))
        UtenButton(
          key: const Key('expense-batch-approve'),
          type: UtenButtonType.success,
          size: UtenButtonSize.large,
          icon: Icons.check_circle_outline_rounded,
          onPressed: selectedIds.isNotEmpty && !_batchBusy
              ? () => _batchApprove(Set<String>.of(selectedIds))
              : null,
          child: Text('批量通过(${selectedIds.length})'),
        ),
      UtenButton(
        key: const Key('expense-batch-reject'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.cancel_outlined,
        onPressed: selectedIds.isNotEmpty && !_batchBusy
            ? () => _batchReject(Set<String>.of(selectedIds))
            : null,
        child: Text('批量驳回(${selectedIds.length})'),
      ),
    ];
  }

  /// 单次批量上限守卫（与后端 @Size(max=50) 对齐）。
  bool _withinBatchLimit(int count) {
    if (count <= kExpenseBatchLimit) return true;
    context.appError('单次最多批量处理 $kExpenseBatchLimit 单，请分批操作（当前 $count 单）');
    return false;
  }

  // ---- 批量通过 / 批量驳回（V608：后端单事务端点，全成全败） -------------------

  Future<String?> _confirmBatchApproval(int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text('批量通过($count)'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenReviewerResponsibilityNotice(
                actionLabel: '报销审批',
                description: '确认后，系统将以此登录员工记录所选 $count 单报销的审批责任。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '将统一审批所选 $count 单报销。若有单据不满足条件，本批将全部保留待审批，'
                '通过后流转至下一审批环节；最终批准后才可付款。请先逐单核对明细与原件，财务节点须完成凭证查验。',
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认批量通过'),
          ),
        ],
      ),
    );
    return confirmed == true ? '' : null;
  }

  Future<void> _batchApprove(Set<String> ids) => _runBatch(
    ids,
    approve: true,
    confirm: () => _confirmBatchApproval(ids.length),
  );

  Future<void> _batchReject(Set<String> ids) => _runBatch(
    ids,
    approve: false,
    confirm: () => showUtenBatchRejectDialog(
      context,
      count: ids.length,
      actionLabel: '报销审批',
      subjectLabel: '报销单',
    ),
  );

  Future<void> _runBatch(
    Set<String> ids, {
    required bool approve,
    required Future<String?> Function() confirm,
  }) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final eligibility = ref.read(expenseActionEligibilityProvider);
    if (ids.any(
      (id) => approve
          ? !eligibility.canInspectClaim(_selectedClaims[id])
          : !eligibility.canReviewClaim(_selectedClaims[id]),
    )) {
      return;
    }
    final versions = Map<String, int>.unmodifiable({
      for (final id in ids) id: _selectedClaims[id]!.version,
    });
    final repository = ref.read(expenseRepositoryProvider);
    final selection = _selectionGeneration;
    final operation = ++_operationGeneration;
    bool ownerCurrent() =>
        mounted &&
        operation == _operationGeneration &&
        ref.read(expenseActionEligibilityProvider) == eligibility &&
        identical(ref.read(expenseRepositoryProvider), repository);
    bool current() =>
        ownerCurrent() &&
        selection == _selectionGeneration &&
        ref.read(approvalQueueProvider) == ApprovalQueue.pending;
    var attempted = false;
    setState(() => _batchBusy = true);
    try {
      final processed = await runSensitiveWrite<int?>(
        ref,
        isCurrent: current,
        write: () async {
          final reason = await confirm();
          if (reason == null ||
              (!approve && reason.trim().isEmpty) ||
              !current()) {
            return null;
          }
          attempted = true;
          if (!mounted) return null;
          // 整批一次请求，发出后无法撤回：不提供「取消」。
          return showUtenProgress<int?>(
            context,
            title: approve ? '批量通过报销' : '批量驳回报销',
            icon: approve
                ? Icons.check_circle_outline_rounded
                : Icons.cancel_outlined,
            initialStatus: approve ? '正在批量通过' : '正在批量驳回',
            initialDetail: '${ids.length} 单',
            cancellable: false,
            invalidation: _identityChanges,
            action: (_) => approve
                ? repository.approveBatch(ids, expectedVersions: versions)
                : repository.rejectBatch(
                    ids,
                    reason,
                    expectedVersions: versions,
                  ),
          );
        },
      );
      if (!mounted || !current() || processed == null) return;
      context.appSuccess(
        approve ? '已通过 $processed 单报销' : '已驳回 $processed 单报销，等待申请人修订后重新提交',
      );
    } catch (error) {
      if (mounted && current()) {
        context.appApiError(error);
      }
    } finally {
      final refresh = current() && attempted;
      if (mounted && operation == _operationGeneration) {
        setState(() {
          _batchBusy = false;
          if (attempted) {
            ++_selectionGeneration;
            _selectedIds = {};
            _selectedClaims.clear();
          }
        });
      }
      if (refresh) _refreshQueue(stillCurrent: ownerCurrent);
    }
  }

  /// 批量动作后列表、筛选桶与汇总一起刷新（计数随队列变化）。
  Future<void> _refreshQueue({bool Function()? stillCurrent}) async {
    if (_refreshing || (stillCurrent != null && !stillCurrent())) return;
    setState(() => _refreshing = true);
    ref.read(expenseApprovalListProvider.notifier).invalidateCachedPages();
    final facets = expenseApprovalFacetsProvider(
      ref.read(approvalQueueProvider),
    );
    ref.invalidate(expenseApprovalListProvider);
    ref.invalidate(facets);
    ref.invalidate(expenseQueueSummaryProvider);
    try {
      await Future.wait([
        refreshBadges(ref),
        ref.read(expenseApprovalListProvider.future),
        ref.read(facets.future),
        if (!ref.read(expenseApprovalReadScopeProvider).isScoped)
          ref.read(expenseQueueSummaryProvider.future),
      ]);
    } catch (error) {
      if (mounted && (stillCurrent == null || stillCurrent())) {
        setState(() => _refreshing = false);
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }
}

/// 报销单「年月」列值（yyyy-MM，ChinaDateTime 已按业务时区解析）。
String expenseYearMonth(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}';

String _formatTime(DateTime t) => ChinaDateTime.formatDateTime(t);

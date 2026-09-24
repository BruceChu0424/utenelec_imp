// 报销审批列表页（审批人 + 财务打款双队列）
// 文档：docs/03-页面/报销审批列表页.md
//
// 2026-09-19 V608 全链路改版：对齐 purchase 范式——UtenFilterToolbar 分段
// （待审批/待付款按权限显隐，计数来自 /summary，两队列都是「等本页用户动手」
// → actionable 红徽章口径）+ 队列汇总统计条（待审批/待付款/本月提交/本月已付款）
// + 表格增「报销单号」列；批量通过/驳回改走后端单事务端点（approve-batch /
// reject-batch，全成全败，不再前端逐单循环）。
// 历史：2026-09-09 表格化；2026-09-10 表头筛选 + 责任提示；2026-09-16 类别桶。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_batch_reject_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../providers/expense_providers.dart';
import '../repositories/expense_repository.dart';
import '../../../shared/badges/badge_registry.dart';

/// 单次批量上限（与后端 @Size(max=50) 对齐）。
const int kExpenseBatchLimit = 50;

class ExpenseApprovalListPage extends ConsumerStatefulWidget {
  const ExpenseApprovalListPage({super.key});

  @override
  ConsumerState<ExpenseApprovalListPage> createState() =>
      _ExpenseApprovalListPageState();
}

class _ExpenseApprovalListPageState
    extends ConsumerState<ExpenseApprovalListPage> {
  /// 待审批段多选：报销单 id（跨页保留）。换分段清空。
  Set<String> _selectedIds = {};
  final Map<String, int> _selectedVersions = {};

  /// 批量审批进行中（防并发 + 按钮加载态）。
  bool _batchBusy = false;

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(approvalQueueProvider);
    final listAsync = ref.watch(expenseApprovalListProvider);
    final facets = ref.watch(expenseApprovalFacetsProvider(queue));
    final filters = ref.watch(expenseApprovalFiltersProvider);
    final summaryAsync = ref.watch(expenseQueueSummaryProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    final canApprove = permissions.contains(Perm.expenseApprove);
    final canPay = permissions.contains(Perm.expensePay);
    final isPendingQueue = queue == ApprovalQueue.pending;
    final summary = summaryAsync.valueOrNull;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    Widget body = Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: UtenCollapsingHeaderScrollView(
        // 两队列都是「确实在等本页用户动手」→ actionable 红徽章
        // （docs/00-项目准则/14-徽章与计数口径.md §二）。
        collapsingHeader: UtenFilterToolbar<ApprovalQueue>(
          segmentsKey: const Key('expense-approval-segments'),
          segments: [
            if (canApprove)
              UtenFilterSegment(
                value: ApprovalQueue.pending,
                label: '待审批',
                count: summary?.pendingCount,
                countForm: UtenSegmentCountForm.actionable,
              ),
            if (canPay)
              UtenFilterSegment(
                value: ApprovalQueue.payable,
                label: '待付款',
                count: summary?.payableCount,
                countForm: UtenSegmentCountForm.actionable,
              ),
            UtenFilterSegment(
              value: ApprovalQueue.history,
              label: l10n.expenseFlowHistory,
              count: queue == ApprovalQueue.history
                  ? listAsync.valueOrNull?.total
                  : null,
            ),
          ],
          selected: {queue},
          onSelectionChanged: (value) {
            setState(() {
              ref.read(approvalQueueProvider.notifier).state = value;
              _selectedIds = {}; // 选中的是旧分段内的报销单
            });
          },
        ),
        body: Column(
          children: [
            // 队列汇总统计条（/summary：两队列 + 本月口径，财务汇总）。
            if (summary != null)
              Padding(
                padding: const EdgeInsets.only(
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
                        '待审批 ${summary.pendingCount} 单 · ¥ '
                        '${summary.pendingAmount.toStringAsFixed(2)}　|　'
                        '待付款 ${summary.payableCount} 单 · ¥ '
                        '${summary.payableAmount.toStringAsFixed(2)}　|　'
                        '本月提交 ${summary.monthSubmittedCount} 单 · ¥ '
                        '${summary.monthSubmittedAmount.toStringAsFixed(2)}　|　'
                        '本月已付款 ${summary.monthPaidCount} 单 · ¥ '
                        '${summary.monthPaidAmount.toStringAsFixed(2)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: listAsync.when(
                loading: () => const UtenSkeletonList(itemCount: 4),
                error: (e, _) => UtenEmpty.error(
                  message: '加载失败，请重试',
                  actionLabel: l10n.commonRetry,
                  onAction: () => ref.invalidate(expenseApprovalListProvider),
                ),
                data: (page) => MasterDataTableView<ExpenseClaim>(
                  key: const Key('expense-approval-table'),
                  primary: true,
                  columns: _columns,
                  items: page.items,
                  // 部门 / 年月筛选桶来自后端聚合；未加载完成前列头暂无筛选项。
                  facets: facets.valueOrNull ?? const {},
                  nullCounts: const {},
                  filters: filters.asTableFilters,
                  onFilterChanged: _onFilterChanged,
                  // 待审批段开多选 + 悬浮批量通过/驳回；待付款段只读浏览
                  //（打款参数逐单不同，打款在详情页完成）。
                  selectable: isPendingQueue,
                  idOf: (claim) => claim.id,
                  selectedIds: _selectedIds,
                  onSelectedIdsChanged: (next) => setState(() {
                    _selectedVersions.removeWhere(
                      (id, _) => !next.contains(id),
                    );
                    for (final claim in page.items) {
                      if (next.contains(claim.id) &&
                          !_selectedIds.contains(claim.id)) {
                        _selectedVersions[claim.id] = claim.version;
                      }
                    }
                    _selectedIds = next;
                  }),
                  batchActionsBuilder: isPendingQueue ? _batchActions : null,
                  // 双击行进入审批详情：push（2026-09-24 起），审批后详情 pop 回本页，
                  // 列表实例与筛选/页码保留，数据由 provider 失效自动换新；
                  // 原来 go 直达会把列表实例抹掉，详情返回只能落 default。
                  onRowTap: (claim) =>
                      context.push('/expense/approval/${claim.id}'),
                  emptyMessage: switch (queue) {
                    ApprovalQueue.pending => '暂无待审批报销',
                    ApprovalQueue.payable => '暂无待付款报销',
                    ApprovalQueue.history => '暂无已处理报销',
                  },
                  currentPage: page.page,
                  totalPages: page.totalPages,
                  onPageChange: (p) => ref
                      .read(expenseApprovalListProvider.notifier)
                      .goToPage(p),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '报销审批',
        showBackButton: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _refreshQueue,
          ),
        ],
      ),
      body: body,
    );
  }

  /// 表头筛选：部门 / 年月 → 下推 provider 参数（列表 provider 重建即回第 1 页）；
  /// 选「所有」= 清该列；换筛选后旧选中集失效。
  void _onFilterChanged(String key, String? value) {
    final current = ref.read(expenseApprovalFiltersProvider);
    ref.read(expenseApprovalFiltersProvider.notifier).state = current
        .withColumn(key, value);
    setState(() => _selectedIds = {});
  }

  final List<MasterColumnDef<ExpenseClaim>> _columns = [
    MasterColumnDef(
      key: 'claimNo',
      label: '报销单号',
      width: 160,
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
      label: '金额',
      width: 110,
      type: 'money',
      value: (claim) => claim.totalAmount.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'yearMonth',
      label: '年月',
      width: 90,
      info: '报销单创建月份（业务时区）；表头筛选按此月份下推后端 year/month 参数。',
      value: (claim) => expenseYearMonth(claim.createdAt),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (claim) => claim.status.label,
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
          isLoading: _batchBusy,
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
        isLoading: _batchBusy,
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

  Future<void> _batchApprove(Set<String> ids) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final count = ids.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
                '通过后进入待付款队列。请先逐单打开详情核对明细、原件并登记查验结果。',
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
    if (confirmed != true || !mounted) return;
    setState(() => _batchBusy = true);
    try {
      final processed = await ref
          .read(expenseRepositoryProvider)
          .approveBatch(
            ids,
            expectedVersions: {
              for (final id in ids) id: _selectedVersions[id]!,
            },
          );
      if (mounted) {
        context.appSuccess('已通过 $processed 单报销');
      }
    } catch (error) {
      if (mounted) {
        context.appApiError(error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _batchBusy = false;
          _selectedIds = {};
        });
      }
      if (mounted) _refreshQueue();
    }
  }

  /// 批量驳回：统一原因对话框一次填写（含责任提示），后端单事务应用。
  Future<void> _batchReject(Set<String> ids) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final reason = await showUtenBatchRejectDialog(
      context,
      count: ids.length,
      actionLabel: '报销审批',
      subjectLabel: '报销单',
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() => _batchBusy = true);
    try {
      final processed = await ref
          .read(expenseRepositoryProvider)
          .rejectBatch(
            ids,
            reason,
            expectedVersions: {
              for (final id in ids) id: _selectedVersions[id]!,
            },
          );
      if (mounted) {
        context.appSuccess('已驳回 $processed 单报销，等待申请人修订后重新提交');
      }
    } catch (error) {
      if (mounted) {
        context.appApiError(error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _batchBusy = false;
          _selectedIds = {};
        });
      }
      if (mounted) _refreshQueue();
    }
  }

  /// 批量动作后列表、筛选桶与汇总一起刷新（计数随队列变化）。
  void _refreshQueue() {
    refreshBadges(ref);
    ref.invalidate(expenseApprovalListProvider);
    ref.invalidate(
      expenseApprovalFacetsProvider(ref.read(approvalQueueProvider)),
    );
    ref.invalidate(expenseQueueSummaryProvider);
  }
}

/// 报销单「年月」列值（yyyy-MM，ChinaDateTime 已按业务时区解析）。
String expenseYearMonth(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}';

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

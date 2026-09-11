// 报销审批列表页（表格版）
// 文档：docs/03-页面/报销审批列表页.md
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 2026-09-10 表头筛选 + 责任提示：列增「部门」「年月」，两列表头筛选桶来自后端
// /expense-claims/facets（按分段状态集聚合），选中后下推 departmentId / year /
// month 参数并回第 1 页（非页内裁剪）；批量通过/驳回确认框统一带
// UtenReviewerResponsibilityNotice（actionLabel「报销审批」）；批量驳回原因框升位为
// 公共 UtenBatchRejectDialog。
// 列：申请人/部门/标题/金额/年月/状态/提交时间。顶部 UtenSegmentedFilter 分段
//（待审批/待打款，按权限显隐）保留；待审批段开多选 + 右下角悬浮
//「批量通过(N)」「批量驳回(N)」——均逐单复用 repository approve/reject 单审 API，
// 失败聚合提示。待打款段打款参数（账户/方式/日期）逐单不同，不支持批量，打款仍在
// 行内双击进入的审批详情页完成。行双击进审批详情。
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区，页面不再重复套容器；
// 窄屏表格横向滚动即可

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_batch_reject_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../providers/expense_providers.dart';
import '../repositories/expense_repository.dart';

/// 单次批量上限：逐单循环单审 API，超过则提示分批（无后端批量端点）。
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

  /// 批量审批进行中（防并发 + 按钮加载态）。
  bool _batchBusy = false;

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(approvalQueueProvider);
    final listAsync = ref.watch(expenseApprovalListProvider);
    final facets = ref.watch(expenseApprovalFacetsProvider(queue));
    final filters = ref.watch(expenseApprovalFiltersProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    final canApprove = permissions.contains(Perm.expenseApprove);
    final canPay = permissions.contains(Perm.expensePay);
    final isPendingQueue = queue == ApprovalQueue.pending;
    final l10n = AppLocalizations.of(context);

    // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
    Widget body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s8,
          ),
          child: UtenSegmentedFilter<ApprovalQueue>(
            selected: queue,
            onChanged: (v) => setState(() {
              ref.read(approvalQueueProvider.notifier).state = v;
              _selectedIds = {}; // 选中的是旧分段内的报销单
            }),
            segments: [
              if (canApprove)
                const UtenSegment(value: ApprovalQueue.pending, label: '待审批'),
              if (canPay)
                const UtenSegment(value: ApprovalQueue.payable, label: '待打款'),
            ],
          ),
        ),
        Expanded(
          child: listAsync.when(
            loading: () => const UtenSkeletonList(itemCount: 4),
            error: (e, _) => UtenEmpty.error(
              message: '加载失败：$e',
              actionLabel: l10n.commonRetry,
              onAction: () => ref.invalidate(expenseApprovalListProvider),
            ),
            data: (page) => RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(expenseApprovalListProvider);
                ref.invalidate(expenseApprovalFacetsProvider(queue));
              },
              child: MasterDataTableView<ExpenseClaim>(
                key: const Key('expense-approval-table'),
                columns: _columns,
                items: page.items,
                // 部门 / 年月筛选桶来自后端聚合；未加载完成前列头暂无筛选项。
                facets: facets.valueOrNull ?? const {},
                nullCounts: const {},
                filters: filters.asTableFilters,
                onFilterChanged: _onFilterChanged,
                // 待审批段开多选 + 悬浮批量通过/驳回；待打款段只读浏览
                //（打款参数逐单不同，打款在详情页完成）。
                selectable: isPendingQueue,
                idOf: (claim) => claim.id,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: (next) =>
                    setState(() => _selectedIds = next),
                batchActionsBuilder: isPendingQueue ? _batchActions : null,
                // 双击行进入审批详情（保留现有路由与 go 语义）。
                onRowTap: (claim) =>
                    context.go('/expense/approval/${claim.id}'),
                emptyMessage: isPendingQueue ? '暂无待审批报销' : '暂无待打款报销',
                currentPage: page.page,
                totalPages: page.totalPages,
                onPageChange: (p) =>
                    ref.read(expenseApprovalListProvider.notifier).goToPage(p),
              ),
            ),
          ),
        ),
      ],
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: const UtenAppBar(title: '报销审批', showBackButton: true),
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
      key: 'applicantName',
      label: '申请人',
      width: 130,
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
      width: 260,
      value: (claim) => claim.title,
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
    return [
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

  /// 单次批量上限守卫（逐单循环 HTTP，超限提示分批）。
  bool _withinBatchLimit(int count) {
    if (count <= kExpenseBatchLimit) return true;
    context.appError('单次最多批量处理 $kExpenseBatchLimit 单，请分批操作（当前 $count 单）');
    return false;
  }

  // ---- 批量通过 / 批量驳回 --------------------------------------------------

  /// 逐单复用单审 API（幂等）：单条失败不中断整批，失败原因聚合提示。
  Future<void> _batchApprove(Set<String> ids) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final l10n = AppLocalizations.of(context);
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
                '将逐单通过所选 $count 单报销，通过后进入待打款队列。'
                '如需核对明细与发票，请双击行进入详情逐单审阅。',
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
    final repo = ref.read(expenseRepositoryProvider);
    var okCount = 0;
    final failures = <String>[];
    for (final id in ids) {
      try {
        await repo.approve(id);
        okCount++;
      } on ApiException catch (e) {
        failures.add(e.message);
      } catch (_) {
        failures.add(l10n.commonError);
      }
    }
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _selectedIds = {};
    });
    if (okCount > 0) {
      context.appSuccess(
        '已通过 $okCount 单报销'
        '${failures.isNotEmpty ? '，${failures.length} 单失败' : ''}',
      );
    }
    if (failures.isNotEmpty) {
      context.appError('批量通过未全部完成：${failures.first}');
    }
    _refreshQueue();
  }

  /// 批量驳回：统一原因对话框一次填写（含责任提示），逐单应用同一原因；失败聚合提示。
  Future<void> _batchReject(Set<String> ids) async {
    if (_batchBusy || ids.isEmpty || !_withinBatchLimit(ids.length)) return;
    final l10n = AppLocalizations.of(context);
    final reason = await showUtenBatchRejectDialog(
      context,
      count: ids.length,
      actionLabel: '报销审批',
      subjectLabel: '报销单',
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() => _batchBusy = true);
    final repo = ref.read(expenseRepositoryProvider);
    var okCount = 0;
    final failures = <String>[];
    for (final id in ids) {
      try {
        await repo.reject(id, reason);
        okCount++;
      } on ApiException catch (e) {
        failures.add(e.message);
      } catch (_) {
        failures.add(l10n.commonError);
      }
    }
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _selectedIds = {};
    });
    if (okCount > 0) {
      context.appSuccess(
        '已驳回 $okCount 单报销'
        '${failures.isNotEmpty ? '，${failures.length} 单失败' : ''}',
      );
    }
    if (failures.isNotEmpty) {
      context.appError('批量驳回未全部完成：${failures.first}');
    }
    _refreshQueue();
  }

  /// 批量动作后列表与筛选桶一起刷新（桶计数随队列变化）。
  void _refreshQueue() {
    ref.invalidate(expenseApprovalListProvider);
    ref.invalidate(
      expenseApprovalFacetsProvider(ref.read(approvalQueueProvider)),
    );
  }
}

/// 报销单「年月」列值（yyyy-MM，ChinaDateTime 已按业务时区解析）。
String expenseYearMonth(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}';

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

// 报销列表页（表格版）
// 文档：docs/03-页面/报销列表页.md
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 列：标题/类别/明细项数/金额/状态/提交时间/审批打款信息（原卡片字段全部保留，
// 类别与审批打款信息为表格化新增）。顶部 UtenSegmentedFilter 分段（全部/草稿/
// 处理中/已完成）保留在标题行；行双击进详情；无多选。分页走表格内置翻页条
//（含跳页，provider 补 goToPage——同批次一工资条先例）。空态/FAB 新建入口不变。
// 2026-09-10 表头筛选：「状态」列筛选桶 = 当前分段的状态集（全部段 = 六态），
// 选中后下推后端 status 参数并回第 1 页，同时把顶部分段切到该状态所属段；
// 换分段清空状态筛选。
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区，页面不再重复套容器；
// 窄屏表格横向滚动即可

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_list_create_action.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../providers/expense_providers.dart';

class ExpenseListPage extends ConsumerWidget {
  const ExpenseListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(expenseListProvider);
    final filter = ref.watch(expenseFilterProvider);
    final statusFilter = ref.watch(expenseStatusFilterProvider);
    final createAction = UtenListCreateAction(
      emptyIcon: Icons.receipt_long_outlined,
      emptyMessage: '暂无报销单',
      emptyDescription: '新建第一笔报销，提交后可在这里跟踪处理进度',
      emptyActionLabel: '新建报销',
      fabLabel: '新建报销',
      actionIcon: Icons.add_rounded,
      onPressed: () => context.go(RouteName.expenseNew),
    );

    // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
    Widget body = RefreshIndicator(
      onRefresh: () => ref.read(expenseListProvider.notifier).refresh(),
      child: list.when(
        loading: () => const UtenSkeletonList(itemCount: 6),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          actionLabel: '重试',
          onAction: () => ref.invalidate(expenseListProvider),
        ),
        data: (page) {
          final claims = page.items;
          // 空态保持「唯一新建入口」口径（新建按钮在空态里，不出 FAB）；
          // 空态自带 ListView 占位（不可再外包滚动视图，无界高度会崩）。
          if (claims.isEmpty) {
            return createAction.emptyState(topSpacing: 80);
          }
          return MasterDataTableView<ExpenseClaim>(
            key: const Key('expense-list-table'),
            columns: _columns,
            items: claims,
            facets: {'status': _statusFacets(filter)},
            nullCounts: const {},
            filters: {'status': statusFilter?.name},
            onFilterChanged: (key, value) => _onFilterChanged(ref, key, value),
            // 双击行进入报销详情（保留现有路由与 push 语义）。
            onRowTap: (claim) =>
                context.push(RoutePath.expenseDetail(claim.id)),
            emptyMessage: '暂无报销单',
            currentPage: page.page,
            totalPages: page.totalPages,
            onPageChange: (p) =>
                ref.read(expenseListProvider.notifier).goToPage(p),
          );
        },
      ),
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '报销',
        showBackButton: true,
        centerWidget: UtenSegmentedFilter<ExpenseFilter>(
          selected: filter,
          onChanged: (v) {
            ref.read(expenseFilterProvider.notifier).state = v;
            // 分段换了口径，表头状态筛选随之失效。
            ref.read(expenseStatusFilterProvider.notifier).state = null;
          },
          segments: const [
            UtenSegment(value: ExpenseFilter.all, label: '全部'),
            UtenSegment(value: ExpenseFilter.draft, label: '草稿'),
            UtenSegment(value: ExpenseFilter.processing, label: '处理中'),
            UtenSegment(value: ExpenseFilter.finished, label: '已完成'),
          ],
        ),
      ),
      floatingActionButton: createAction.floatingActionButton(
        context,
        hasItems: list.valueOrNull?.items.isNotEmpty ?? false,
      ),
      body: body,
    );
  }
}

/// 「状态」列筛选桶：当前分段的状态集（全部段 = 六态）；value=枚举名，label=中文。
/// 桶不带计数（列表按页拉取，无全量计数口径）。
List<MasterFacetBucket> _statusFacets(ExpenseFilter filter) {
  final statuses = filter.apiStatuses ?? ExpenseClaimStatus.values;
  return [
    for (final status in statuses)
      MasterFacetBucket(value: status.name, count: 0, label: status.label),
  ];
}

/// 表头状态筛选 → 精确状态下推后端（provider 重建即回第 1 页）+ 顶部分段同步切换。
void _onFilterChanged(WidgetRef ref, String key, String? value) {
  if (key != 'status') return;
  final status = value == null
      ? null
      : ExpenseClaimStatus.values.where((s) => s.name == value).firstOrNull;
  if (status != null) {
    ref.read(expenseFilterProvider.notifier).state = expenseFilterOfStatus(
      status,
    );
  }
  ref.read(expenseStatusFilterProvider.notifier).state = status;
}

final List<MasterColumnDef<ExpenseClaim>> _columns = [
  MasterColumnDef(
    key: 'title',
    label: '标题',
    width: 220,
    value: (claim) => claim.title,
  ),
  MasterColumnDef(
    key: 'category',
    label: '类别',
    width: 150,
    info: '本单全部明细项的报销类别（去重，顿号连接）。',
    value: (claim) => _categoryText(claim),
  ),
  MasterColumnDef(
    key: 'itemCount',
    label: '明细项数',
    width: 90,
    type: 'number',
    value: (claim) => claim.items.length.toString(),
  ),
  MasterColumnDef(
    key: 'totalAmount',
    label: '金额',
    width: 110,
    type: 'money',
    value: (claim) => claim.totalAmount.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'status',
    label: '状态',
    width: 90,
    value: (claim) => claim.status.label,
  ),
  MasterColumnDef(
    key: 'submittedAt',
    label: '提交时间',
    width: 150,
    type: 'date',
    value: (claim) => _formatTime(claim.submittedAt ?? claim.createdAt),
  ),
  MasterColumnDef(
    key: 'progress',
    label: '审批/打款信息',
    width: 230,
    info:
        '已驳回显示驳回原因；已通过显示审批时间；已打款显示打款时间；'
        '完整审批轨迹在详情页。',
    value: (claim) => _progressText(claim),
  ),
];

/// 类别列：明细项类别去重拼接（报销单没有单一类别，类别挂在明细项上）。
String _categoryText(ExpenseClaim claim) {
  final labels = <String>{};
  for (final item in claim.items) {
    labels.add(item.category.label);
  }
  return labels.join('、');
}

/// 审批/打款信息列（无进展返回 null，单元格留空）。
String? _progressText(ExpenseClaim claim) {
  switch (claim.status) {
    case ExpenseClaimStatus.draft:
      return null;
    case ExpenseClaimStatus.submitted:
    case ExpenseClaimStatus.reviewing:
      return null;
    case ExpenseClaimStatus.approved:
      return '审批通过 ${_formatTime(claim.approvedAt!)}';
    case ExpenseClaimStatus.rejected:
      return '驳回：${claim.rejectReason ?? '未填写原因'}';
    case ExpenseClaimStatus.paid:
      return '打款 ${_formatTime(claim.paidAt!)}';
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

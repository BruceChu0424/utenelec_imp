// 报销列表页（我的报销）
// 文档：docs/03-页面/报销列表页.md
//
// 2026-09-19 V608 全链路改版：对齐 purchase_doc_list_page 范式——
// AppBar(标题+右上刷新) + UtenContentContainer.wide + UtenCollapsingHeaderScrollView
// （折叠头=UtenFilterToolbar 分段，进页面默认不选，占位引导）+ 页面头行
// （Icon + 标题(N) + 新建按钮）+ MasterDataTableView(primary:true)。
// 列增「单号」（BX 单号，V608 创建即铸）、「进度」列带操作人姓名回显。
// 历史：2026-09-09 卡片网格 → 表格化；2026-09-10 表头状态筛选；
// 2026-09-16 类别筛选桶。
//
// 响应式：medium+ 外壳（MainShellPage）已收敛内容区；表格自身处理窄屏横向滚动。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../providers/expense_providers.dart';
import '../providers/expense_counts_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';

class ExpenseListPage extends ConsumerWidget {
  const ExpenseListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(expenseListProvider);
    final counts = ref.watch(expenseCountsProvider).valueOrNull;
    // 「处理中」= 本人已交出去、正在审批或等出纳付款的单(球不在我手上但也没完)。
    // 走注册表同一个入口 provider, 免得这里和工作台各算各的。
    final processingCount = ref.watch(expenseMineProcessingCountProvider);
    final canApply = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.expenseApply);
    final filter = ref.watch(expenseFilterProvider);
    final statusFilter = ref.watch(expenseStatusFilterProvider);
    final categoryFilter = ref.watch(expenseCategoryFilterProvider);
    final total = list.valueOrNull?.total ?? 0;

    return Scaffold(
      appBar: UtenAppBar(
        title: '我的报销',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => ref.read(expenseListProvider.notifier).refresh(),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: UtenCollapsingHeaderScrollView(
              // 分段(进页面默认「全部」: 我的报销是个人列表, 落地即见数据)。
              // 三形态各就各位(ADR-100): 草稿 / 待修订是本人要动手的活 -> 红;
              // 「处理中」已经交出去、在审批人或出纳手上滚着 -> 黄;
              // 「全部」「已完成」是浏览型 -> 不挂 / 括号。
              collapsingHeader: UtenFilterToolbar<ExpenseFilter>(
                segmentsKey: const Key('expense-list-segments'),
                segments: [
                  const UtenFilterSegment(
                    value: ExpenseFilter.all,
                    label: '全部',
                  ),
                  UtenFilterSegment(
                    value: ExpenseFilter.draft,
                    label: '草稿',
                    count: counts?.draftCount,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                  UtenFilterSegment(
                    value: ExpenseFilter.rejected,
                    label: '待修订',
                    count: counts?.rejectedCount,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                  UtenFilterSegment(
                    value: ExpenseFilter.processing,
                    label: '处理中',
                    count: processingCount,
                    countForm: UtenSegmentCountForm.inProgress,
                  ),
                  const UtenFilterSegment(
                    value: ExpenseFilter.finished,
                    label: '已完成',
                  ),
                ],
                selected: {filter},
                onSelectionChanged: (value) {
                  ref.read(expenseFilterProvider.notifier).state = value;
                  // 分段换了口径，表头状态筛选随之失效。
                  ref.read(expenseStatusFilterProvider.notifier).state = null;
                },
              ),
              body: Column(
                children: [
                  // 页面头：Icon + 标题 + 计数 + 新建按钮（唯一新建入口，
                  // 空态由表格内置空态提示，不再出 FAB）。
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        Text(
                          '我的报销 ($total)',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        if (canApply)
                          UtenButton(
                            type: UtenButtonType.tonal,
                            icon: Icons.add_rounded,
                            onPressed: () => context.push(RouteName.expenseNew),
                            child: const Text('新建报销'),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: list.when(
                      loading: () => const UtenSkeletonList(itemCount: 6),
                      error: (e, _) => MasterDataTableView<ExpenseClaim>(
                        key: const Key('expense-list-table'),
                        columns: _columns,
                        items: const [],
                        facets: const {},
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                        emptyMessage: '加载失败，请重试',
                        error: '加载失败，请重试',
                        onRetry: () => ref.invalidate(expenseListProvider),
                      ),
                      data: (page) => MasterDataTableView<ExpenseClaim>(
                        key: const Key('expense-list-table'),
                        // primary:true → 表体参与「分类条折叠 → 表格内滚」联动。
                        primary: true,
                        columns: _columns,
                        items: page.items,
                        facets: {
                          'status': _statusFacets(filter),
                          // 类别是固定枚举（明细项级别），前端硬编码桶；value=类别码。
                          'category': _categoryFacets(),
                        },
                        nullCounts: const {},
                        filters: {
                          'status': statusFilter?.name,
                          'category': categoryFilter,
                        },
                        onFilterChanged: (key, value) =>
                            _onFilterChanged(ref, key, value),
                        // 双击行进入报销详情。
                        onRowTap: (claim) =>
                            context.push(RoutePath.expenseDetail(claim.id)),
                        emptyMessage: '暂无报销单',
                        currentPage: page.page,
                        totalPages: page.totalPages,
                        onPageChange: (p) =>
                            ref.read(expenseListProvider.notifier).goToPage(p),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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

/// 「类别」列筛选桶（固定枚举，前端硬编码；count=0 表示不强调计数）。
List<MasterFacetBucket> _categoryFacets() => [
  for (final category in ExpenseCategory.values)
    MasterFacetBucket(
      value: category.apiValue,
      count: 0,
      label: category.label,
    ),
];

/// 表头筛选 → 下推后端（provider 重建即回第 1 页）；状态桶同时同步顶部分段。
void _onFilterChanged(WidgetRef ref, String key, String? value) {
  if (key == 'category') {
    ref.read(expenseCategoryFilterProvider.notifier).state =
        value?.trim().isEmpty == true ? null : value;
    return;
  }
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
    key: 'claimNo',
    label: '报销单号',
    width: 160,
    value: (claim) => claim.claimNo,
  ),
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
    label: '审批/付款记录',
    width: 230,
    info:
        '已驳回显示驳回原因与驳回人；已通过显示审批人与时间；已付款显示付款登记时间；'
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
      return '${claim.approvedByName ?? ''} 审批通过 ${_formatTime(claim.approvedAt!)}'
          .trim();
    case ExpenseClaimStatus.rejected:
      return '驳回：${claim.rejectReason ?? '未填写原因'}'
          '${claim.rejectedByName == null ? '' : '（${claim.rejectedByName}）'}';
    case ExpenseClaimStatus.paid:
      return '${claim.paidByName ?? ''} 已付款 ${_formatTime(claim.paidAt!)}'
          .trim();
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

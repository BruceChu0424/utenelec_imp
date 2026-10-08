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

import '../../../shared/models/retained_async_page.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_category.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../providers/expense_providers.dart';
import '../../../shared/badges/badge_registry.dart';
import '../providers/expense_counts_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/mixins/draft_bulk_delete_mixin.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../repositories/expense_repository.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';

class ExpenseListPage extends ConsumerStatefulWidget {
  const ExpenseListPage({super.key});

  @override
  ConsumerState<ExpenseListPage> createState() => _ExpenseListPageState();
}

class _ExpenseListPageState extends ConsumerState<ExpenseListPage>
    with DraftBulkDeleteMixin<ExpenseListPage> {
  final _retainedPage = RetainedAsyncPage<PagedResult<ExpenseClaim>>();
  final _tableRows = MasterDataTableRowsController<ExpenseClaim>();

  bool _isOwnDraft(ExpenseClaim claim) =>
      claim.status == ExpenseClaimStatus.draft &&
      claim.applicantId == ref.read(sessionProvider).user?.employeeId;

  Future<void> _deleteDraft(String id, int expectedVersion) async {
    final scope = ref.read(authenticatedScopeProvider);
    final repository = ref.read(expenseRepositoryProvider);
    final current = await repository.getById(id);
    if (!mounted ||
        scope == null ||
        scope.readOnly ||
        ref.read(authenticatedScopeProvider) != scope ||
        !selectedDraftIds.contains(id) ||
        ref.read(expenseFilterProvider) != ExpenseFilter.draft ||
        !ref.read(currentPermissionsProvider).contains(Perm.expenseApply) ||
        !_isOwnDraft(current)) {
      throw ApiException('CONFLICT', '仅能删除本人尚未提交的报销草稿');
    }
    if (current.version != expectedVersion) {
      throw ApiException('CONFLICT', '报销单已被修改，请刷新后重新选择');
    }
    await repository.delete(id, expectedVersion: expectedVersion);
  }

  FormDraftCategoryScope get _formDraftScope =>
      const FormDraftCategoryScope(kind: 'expense');

  Widget _withFormDraftRows(MasterDataTableView<ExpenseClaim> table) =>
      ref.watch(expenseFilterProvider) == ExpenseFilter.draft
      ? FormDraftCategoryTable<ExpenseClaim>(
          scope: _formDraftScope,
          table: table,
          formalId: (item) => item.id,
        )
      : table;

  @override
  Widget build(BuildContext context) {
    ref.listen(expenseListProvider, (previous, next) {
      if (next.isLoading || !next.hasValue) return;
      if (next.requireValue.page > 1 &&
          next.requireValue.page != previous?.valueOrNull?.page) {
        return;
      }
      retainDraftSelection([
        for (final claim in next.requireValue.items)
          if (_isOwnDraft(claim)) claim.id,
      ]);
    });
    final rawList = ref.watch(expenseListProvider);
    final counts = ref.watch(expenseCountsProvider);
    // 「处理中」= 本人已交出去、正在审批或等出纳付款的单(球不在我手上但也没完)。
    // 与工作台「我的报销」卡黄数同一个入口(徽章汇总), 免得这里和工作台各算各的。
    final processingCount = ref.watch(
      badgeEntryInProgressProvider(BadgeEntry.expenseMine),
    );
    final canApply = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.expenseApply);
    final filter = ref.watch(expenseFilterProvider);
    final statusFilter = ref.watch(expenseStatusFilterProvider);
    final categoryFilter = ref.watch(expenseCategoryFilterProvider);
    // 2026-09-25 单号列统一：报销单号值筛选（服务端 facets/精确匹配）+ 表头排序。
    final claimNoFilter = ref.watch(expenseClaimNoFilterProvider);
    final sortColumn = ref.watch(expenseSortColumnProvider);
    final sortAscending = ref.watch(expenseSortAscendingProvider);
    final paginationScope = (
      filter,
      statusFilter,
      categoryFilter,
      claimNoFilter,
      sortColumn,
      sortAscending,
      ref.watch(masterDataSessionKeyProvider),
    );
    final list = _retainedPage.resolve(paginationScope, rawList);
    final mineFacets = ref.watch(expenseMineFacetsProvider);
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
              // 2026-09-24 对齐物料分析页：页面头移入滚走区，body 只剩表格。
              collapsingHeader: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UtenFilterToolbar<ExpenseFilter>(
                    segmentsKey: const Key('expense-list-segments'),
                    segments: [
                      const UtenFilterSegment(
                        value: ExpenseFilter.all,
                        label: '全部',
                      ),
                      UtenFilterSegment(
                        value: ExpenseFilter.draft,
                        label: '草稿',
                        count:
                            counts.draftCount +
                            ref.watch(
                              formDraftCategoryCountProvider(_formDraftScope),
                            ),
                        countForm: UtenSegmentCountForm.actionable,
                      ),
                      UtenFilterSegment(
                        value: ExpenseFilter.rejected,
                        label: '待修订',
                        count: counts.rejectedCount,
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
                      clearDraftSelection();
                      ref.read(expenseFilterProvider.notifier).state = value;
                      // 分段换了口径，表头状态筛选随之失效。
                      ref.read(expenseStatusFilterProvider.notifier).state =
                          null;
                    },
                  ),
                  // 页面头：Icon + 标题 + 计数 + 新建按钮（唯一新建入口，
                  // 空态由表格内置空态提示，不再出 FAB；随页滚走）。
                  Padding(
                    padding: const EdgeInsets.only(
                      top: UtenSpacing.s8,
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
                        if (canApply && filter != ExpenseFilter.draft)
                          UtenButton(
                            type: UtenButtonType.tonal,
                            icon: Icons.add_rounded,
                            onPressed: () => context.push(RouteName.expenseNew),
                            child: const Text('新建报销'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              body: list.when(
                skipLoadingOnReload: true,
                skipError: true,
                loading: () =>
                    filter == ExpenseFilter.draft &&
                        ref
                            .watch(formDraftCategoryProvider(_formDraftScope))
                            .isNotEmpty
                    ? _withFormDraftRows(
                        MasterDataTableView<ExpenseClaim>(
                          tableKey:
                              'features.expense.pages.expense_list_page.ExpenseListPageState.build.1',
                          key: const Key('expense-list-table'),
                          columns: _columns,
                          items: const [],
                          facets: const {},
                          nullCounts: const {},
                          filters: const {},
                          onFilterChanged: (_, _) {},
                          isLoading: true,
                        ),
                      )
                    : const UtenSkeletonList(itemCount: 6),
                error: (e, _) => _withFormDraftRows(
                  MasterDataTableView<ExpenseClaim>(
                    tableKey:
                        'features.expense.pages.expense_list_page.ExpenseListPageState.build.2',
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
                ),
                data: (page) => _withFormDraftRows(
                  MasterDataTableView<ExpenseClaim>(
                    tableKey:
                        'features.expense.pages.expense_list_page.ExpenseListPageState.build.3',
                    key: const Key('expense-list-table'),
                    // primary:true → 表体参与「分类条折叠 → 表格内滚」联动。
                    primary: true,
                    columns: _columns,
                    items: page.items,
                    rowsController: _tableRows,
                    paginationScope: paginationScope,
                    loadingMore: list.isLoading,
                    error: list.hasError
                        ? (humanErrorMessage(list.error!) ?? '加载更多没有成功，请重试')
                        : null,
                    onRetry: () => ref.invalidate(expenseListProvider),
                    facets: {
                      'status': _statusFacets(filter),
                      // 类别是固定枚举（明细项级别），前端硬编码桶；value=类别码。
                      'category': _categoryFacets(),
                      // 报销单号桶来自服务端（facets?queue=mine，2026-09-25 单号列统一）。
                      'claimNo': mineFacets.valueOrNull?['claimNo'] ?? const [],
                    },
                    nullCounts: const {},
                    filters: {
                      'status': statusFilter?.name,
                      'category': categoryFilter,
                      'claimNo': claimNoFilter,
                    },
                    onFilterChanged: (key, value) {
                      clearDraftSelection();
                      _onFilterChanged(ref, key, value);
                    },
                    // 2026-09-25 单号列统一：表头排序走服务端白名单（claimNo）。
                    sortColumn: sortColumn,
                    sortAscending: sortAscending,
                    onSortChange: (column, ascending) {
                      clearDraftSelection();
                      ref.read(expenseSortColumnProvider.notifier).state =
                          column;
                      ref.read(expenseSortAscendingProvider.notifier).state =
                          ascending;
                    },
                    // 双击行进入报销详情。
                    onRowTap: (claim) =>
                        context.push(RoutePath.expenseDetail(claim.id)),
                    selectable: canApply && filter == ExpenseFilter.draft,
                    idOf: (claim) => !draftDeleteBusy && _isOwnDraft(claim)
                        ? claim.id
                        : null,
                    rowKeyOf: (claim) => claim.id,
                    selectedIds: selectedDraftIds,
                    onSelectedIdsChanged: draftDeleteBusy
                        ? null
                        : selectDraftIds,
                    batchActionsBuilder: (_, _) => [
                      buildDraftDeleteButton(
                        documentLabel: '报销单',
                        delete: (id) => _deleteDraft(
                          id,
                          _tableRows.items
                              .firstWhere((claim) => claim.id == id)
                              .version,
                        ),
                        reload: () =>
                            ref.read(expenseListProvider.notifier).refresh(),
                      ),
                    ],
                    emptyMessage: '暂无报销单',
                    currentPage: page.page,
                    totalPages: page.totalPages,
                    onPageChange: (p) =>
                        ref.read(expenseListProvider.notifier).goToPage(p),
                  ),
                ),
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
  // 报销单号值筛选（2026-09-25 单号列统一）：服务端精确匹配，空 = 清除。
  if (key == 'claimNo') {
    final next = value?.trim();
    ref.read(expenseClaimNoFilterProvider.notifier).state =
        next == null || next.isEmpty ? null : next;
    return;
  }
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
    key: 'status',
    label: '状态',
    width: 72,
    value: (claim) => claim.status.label,
    // 2026-09-27 用户口径「表格状态列整格底色」：草稿=灰 / 在审=蓝 /
    // 待打款=青 / 驳回=红 / 已打款=绿。
    cellColor: (context, claim) =>
        udenStatusBadgeCellColor(context, switch (claim.status) {
          ExpenseClaimStatus.draft => UtenStatusBadgeType.neutral,
          ExpenseClaimStatus.submitted ||
          ExpenseClaimStatus.reviewing => UtenStatusBadgeType.info,
          ExpenseClaimStatus.approved => UtenStatusBadgeType.accent,
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

// 报销列表页（我的报销）
// 文档：docs/03-页面/报销列表页.md
//
// 2026-09-19 V608 全链路改版：对齐 purchase_doc_list_page 范式——
// AppBar(标题+右上刷新) + UtenContentContainer.wide + UtenCollapsingHeaderScrollView
// （折叠头=UtenFilterToolbar 分段）+ MasterDataTableView(primary:true)。
// 标题只保留在 AppBar；新建报销统一在右下角，草稿分类与批量动作同组。
// 列增「单号」（BX 单号，V608 创建即铸）、「进度」列带操作人姓名回显。
// 历史：2026-09-09 卡片网格 → 表格化；2026-09-10 表头状态筛选；
// 2026-09-16 类别筛选桶。
//
// 响应式：medium+ 外壳（MainShellPage）已收敛内容区；表格自身处理窄屏横向滚动。

import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/retained_async_page.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/formatters/money_display.dart';
import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_category.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
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

  Widget _createAction() => UtenButton(
    key: const Key('expense-list-create'),
    size: UtenButtonSize.large,
    icon: Icons.add_rounded,
    onPressed: draftDeleteBusy
        ? null
        : () => context.push(RouteName.expenseNew),
    child: const Text('新建报销'),
  );

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(RouteName.expense, () {
      ref.read(expenseListProvider.notifier).refresh();
      ref.invalidate(expenseMineFacetsProvider);
      refreshBadges(ref);
    });
    ref.listen(expenseListProvider, (previous, next) {
      if (next.isLoading || !next.hasValue) return;
      if (next.requireValue.page > 1 &&
          next.requireValue.page != previous?.value?.page) {
        return;
      }
      retainDraftSelection([
        for (final claim in next.requireValue.items)
          if (_isOwnDraft(claim)) claim.id,
      ]);
    });
    ref.read(expenseListProvider.notifier).bindReadView(context,
      visiblePage: () => _tableRows.visiblePage);
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
      retainedReaderEpoch(ref),
    );
    final list = _retainedPage.resolveFor(
      ref,
      paginationScope,
      expenseListProvider,
    );
    final page =
        list.value ??
        const PagedResult<ExpenseClaim>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 0,
        );
    final mineFacets = ref.watch(expenseMineFacetsProvider);
    // 草稿表格已有右下角批量组，新建并入同组；其他分类和加载/错误态
    // 由 Scaffold 提供唯一入口，避免页面浮动组遮住表格批量删除。
    final createInDraftTable =
        canApply && filter == ExpenseFilter.draft && list.hasValue;

    return Scaffold(
      appBar: UtenAppBar(
        title: '我的报销',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          UtenRefreshButton(
            onRefresh: () => ref.read(expenseListProvider.notifier).refresh(),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: canApply && !createInDraftTable
          ? UtenFloatingActionGroup(children: [_createAction()])
          : null,
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: UtenCollapsingHeaderScrollView(
              // 默认只查询本人待办与进行中；已付款单据从历史单据查阅。
              // 三形态各就各位(ADR-100): 草稿 / 待修订是本人要动手的活 -> 红;
              // 「处理中」已经交出去、在审批人或出纳手上滚着 -> 黄;
              // 历史单据不挂待办数。
              // 2026-09-24 对齐物料分析页：页面头移入滚走区，body 只剩表格。
              collapsingHeader: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UtenFilterToolbar<ExpenseFilter>(
                    segmentsKey: const Key('expense-list-segments'),
                    segments: [
                      const UtenFilterSegment(
                        value: ExpenseFilter.all,
                        label: '待办与进行中',
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
                        label: '历史单据',
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
                ],
              ),
              body: _withFormDraftRows(
                MasterDataTableView<ExpenseClaim>(
                  expensiveRowMounts: false,
                  tableKey:
                      'features.expense.pages.expense_list_page.ExpenseListPageState.build.3',
                  key: const Key('expense-list-table'),
                  bottomContentPadding: canApply
                      ? UtenFloatingActionGroup.scrollClearance
                      : 0,
                  // primary:true → 表体参与「分类条折叠 → 表格内滚」联动。
                  primary: true,
                  columns: _columns,
                  items: page.items,
                  rowsController: _tableRows,
                  paginationScope: paginationScope,
                  isLoading: list.isLoading && !list.hasValue,
                  loadingMore: list.isLoading && list.hasValue,
                  error: list.hasError
                      ? (humanErrorMessage(list.error!) ?? '加载更多没有成功，请重试')
                      : null,
                  onRetry: () => ref.read(expenseListProvider.notifier).retry(),
                  facets: {
                    'status': _statusFacets(filter),
                    // 类别是固定枚举（明细项级别），前端硬编码桶；value=类别码。
                    'category': _categoryFacets(),
                    // 报销单号桶来自服务端（facets?queue=mine，2026-09-25 单号列统一）。
                    'claimNo': mineFacets.value?['claimNo'] ?? const [],
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
                    ref.read(expenseSortColumnProvider.notifier).state = column;
                    ref.read(expenseSortAscendingProvider.notifier).state =
                        ascending;
                  },
                  // 双击行进入报销详情。
                  onRowTap: (claim) =>
                      context.push(RoutePath.expenseDetail(claim.id)),
                  selectable: canApply && filter == ExpenseFilter.draft,
                  idOf: (claim) =>
                      !draftDeleteBusy && _isOwnDraft(claim) ? claim.id : null,
                  rowKeyOf: (claim) => claim.id,
                  selectedIds: selectedDraftIds,
                  onSelectedIdsChanged: draftDeleteBusy ? null : selectDraftIds,
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
                    if (canApply) _createAction(),
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
    // 2026-09-27 用户口径「表格状态列整格底色」；档位按 ADR-169 锚定
    // （14-徽章口径 §四：驳回需修订=红、处理中=warning/info、已完成=绿、
    // 草稿=灰）：草稿=灰 / 待审批·审批中=蓝（已提交流转）/
    // 已通过待打款=琥珀（等待外部付款，无异常）/ 驳回=红 / 已付款=绿。
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
    width: 140,
    type: 'money',
    // 报销恒人民币（2026-10-10 金额带单位口径：数值后自动带「元」）。
    value: (claim) =>
        financeLocalMoneyWithUnitSuffix(claim.totalAmount.toStringAsFixed(2)),
  ),
  MasterColumnDef(
    key: 'submittedAt',
    label: '提交时间',
    width: 150,
    type: 'date',
    value: (claim) => _formatTime(claim.submittedAt ?? claim.createdAt),
  ),
  MasterColumnDef(
    key: 'auditTrail',
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

String _formatTime(DateTime t) => ChinaDateTime.formatDateTime(t);

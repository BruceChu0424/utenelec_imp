// 生产计划单列表页（生产管理 / production_plan:view）。
//
// 复用基础资料布局：UtenAppBar(标题/返回/刷新) + UtenContentContainer > 标题行
// (Icon+label+(N)+新建) + 状态筛选(UtenFilterToolbar 分段+搜索) + MasterDataTableView。
// 过滤由本页自带的状态分段工具条 + 关键词搜索承担（facets 传空，表头降级为纯标签）。
// 「新建」进入计划前物料分析，按 production_material_analysis:create 权限显隐。
//
// 路径写死（待用户在 route_names.dart 加 RouteName.production* 后替换）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/data_display/doc_status_badge.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../shared/providers/document_status_counts_provider.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_plan.dart';
import '../repositories/production_repository.dart';

class ProductionPlanListPage extends ConsumerStatefulWidget {
  const ProductionPlanListPage({super.key, this.initialStatus});

  /// 深链预选（路由 `?status=draft`）：新建页「草稿(N)」按钮进来时直接落在草稿段。
  final String? initialStatus;

  @override
  ConsumerState<ProductionPlanListPage> createState() =>
      _ProductionPlanListPageState();
}

class _ProductionPlanListPageState
    extends ConsumerState<ProductionPlanListPage> {
  final _list = PagedListController<ProductionPlanListItem>();
  int? _statusFilter; // null=全部
  bool _statusFilterSelected = false; // 进页面不预选（不选=不过滤）

  /// 表头列筛选：车间（departments/tree 展平桶，value=UUID 回传 departmentId）。
  String? _workshopIdFilter;

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;

  @override
  void initState() {
    super.initState();
    // 深链 ?status=draft：预选「草稿」段（新建页「草稿(N)」按钮的落点）。
    if (isDraftStatusQuery(widget.initialStatus)) {
      _statusFilter = 0;
      _statusFilterSelected = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload(1));
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  bool get _canCreate => ref
      .read(currentPermissionsProvider)
      .contains(Perm.productionMaterialAnalysisCreate);

  /// 多选选中计划单 id（跨页保留；组件只读 + 回交新集合，这里就地同步进 final 集合）。
  final Set<String> _selectedIds = {};
  bool _batching = false;

  // 批量审核 / 删除与单张同一个码(permissions-06：旧的前端专属批量码已删除，
  // 服务端批量端点只认 approve / delete)。
  bool get _canBatchApprove =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanApprove);

  bool get _canBatchDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanDelete);

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<ProductionPlanListItem>> _fetch() async {
    final names = ref.read(masterNameServiceProvider);
    // 字典与列表并行(ADR-108)，不再先等字典。
    final dictionaries = names.ensureLoaded();
    final r = await ref
        .read(productionPlanRepositoryProvider)
        .list(
          page: _list.pageNum,
          filter: ProductionPlanFilter(
            keyword: _list.normalizedKeyword,
            departmentId: _workshopIdFilter,
            status: _statusFilter,
          ),
          sort: _list.sortKey,
          order: _list.sortOrder,
        );
    // 跟单员姓名服务端随行已给；只有缺名的行才按 id 补查(部门名已在 ensureLoaded 加载)。
    await Future.wait([
      dictionaries,
      names.loadEmployeeNames([
        for (final e in r.items)
          if ((e.sellerName ?? '').trim().isEmpty) e.sellerId,
      ]),
    ]);
    return r;
  }

  /// 分段计数范围(2026-09-21 用户口径: 父分类 hub 卡有草稿红徽章, 子分类也要有数)。
  static const _statusScope = DocumentStatusScope(DraftDocKind.productionPlan);

  Future<void> _reload([int? page, bool silent = false]) {
    // 列表重拉时同步分段计数(写操作成功 / 返回本页 / 手动刷新都经过这里)。
    ref.invalidate(documentStatusCountsProvider(_statusScope));
    return _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);
  }

  void _onStatus(int? s) {
    setState(() {
      _statusFilter = s;
      _statusFilterSelected = true;
    });
    _reload(1);
  }

  /// 表头筛选回调：车间值并进 repository.list 的 departmentId；状态列与
  /// 分段条联动（复用 [_onStatus]），重拉回第 1 页。
  void _onColumnFilterChanged(String key, String? value) {
    if (key == 'workshop') {
      setState(() => _workshopIdFilter = value);
      _reload(1);
    } else if (key == 'status') {
      _onStatus(value == null ? null : int.tryParse(value));
    }
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  /// 批量审核选中(草稿→已审)：一次请求、服务端单事务；非草稿计为跳过。
  Future<void> _batchApprove() => _runBatch(
    verb: '审核',
    danger: false,
    reviewerResponsibility: true,
    run: (ids) => ref.read(productionPlanRepositoryProvider).batchApprove(ids),
  );

  /// 批量删除选中草稿：一次请求、服务端单事务；非草稿计为跳过，删除不可撤销。
  Future<void> _batchDelete() => _runBatch(
    verb: '删除',
    danger: true,
    run: (ids) => ref.read(productionPlanRepositoryProvider).batchDelete(ids),
  );

  /// 批量执行通用骨架：确认 → 一次服务端批量请求(单事务，任何一张失败整批回滚)
  /// → 清空选中并刷新 + 结果提示。
  Future<void> _runBatch({
    required String verb,
    required bool danger,
    required Future<ProductionPlanBatchResult> Function(List<String> ids) run,
    bool reviewerResponsibility = false,
  }) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty || _batching) return;
    // 服务端单事务逐张执行，一次太多会超过接收超时；超过上限先请用户分批勾选。
    if (ids.length > ProductionPlanRepository.batchLimit) {
      context.appWarning(
        '一次最多批量$verb ${ProductionPlanRepository.batchLimit} 张，'
        '当前勾选了 ${ids.length} 张，请减少勾选后分批处理',
      );
      return;
    }
    final message = danger
        ? '将删除选中的 ${ids.length} 个生产计划单草稿；非草稿将被跳过，删除不可撤销。'
        : '将审核选中的 ${ids.length} 个生产计划单(草稿→已审)；非草稿将被跳过。';
    final confirmed = reviewerResponsibility
        ? await showUtenReviewerConfirmDialog(
            context,
            title: '批量$verb(${ids.length} 个)',
            message: message,
            confirmLabel: '确认批量$verb',
            actionLabel: '批量审核',
          )
        : await UtenDialog.show(
            context,
            title: '批量$verb(${ids.length} 个)',
            content: Text(message),
            confirmLabel: '确认批量$verb',
            danger: danger,
          );
    if (confirmed != true) return;
    setState(() => _batching = true);
    ProductionPlanBatchResult result;
    try {
      result = await run(ids);
    } catch (error) {
      if (!mounted) return;
      // 网络中断或超时：服务端可能已经提交，不能说「没有任何计划被处理」。
      // 先按服务端最新状态刷新列表，再请用户按列表核对，而不是直接重试。
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          (error is ApiException && (error.httpStatus ?? 0) >= 500);
      if (uncertain) {
        setState(() {
          _batching = false;
          _selectedIds.clear();
        });
        await _reload();
        if (mounted) {
          context.appWarning(
            '网络中断，没能确认批量$verb是否已完成；列表已按最新状态刷新，'
            '请核对后再决定是否重新$verb',
          );
        }
        return;
      }
      setState(() => _batching = false);
      // 服务端明确拒绝：单事务整批未生效，提示里带上是哪一张、为什么。
      context.appApiError(error, fallback: '批量$verb未完成，本次没有任何计划被$verb');
      return;
    }
    if (!mounted) return;
    setState(() {
      _batching = false;
      _selectedIds.clear();
    });
    await _reload();
    if (mounted) {
      final reasons = result.skipped
          .take(3)
          .map((row) => '${row.billNo ?? '计划'}：${row.reason}')
          .join('；');
      context.appSuccess(
        '批量$verb完成：成功 ${result.done.length}，跳过 ${result.skipped.length}'
        '${reasons.isEmpty ? '' : '($reasons)'}',
      );
    }
  }

  /// 批量业务动作由 MasterDataTableView 统一悬浮在右下角；选择摘要仍在表头上方。
  List<Widget> _planBatchActions(
    BuildContext context,
    Set<String> selectedIds,
  ) {
    return [
      if (_canBatchApprove)
        UtenButton(
          type: UtenButtonType.tonal,
          size: UtenButtonSize.large,
          onPressed: _batching ? null : _batchApprove,
          child: Text('批量审核(${selectedIds.length})'),
        ),
      if (_canBatchDelete)
        UtenButton(
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          onPressed: _batching ? null : _batchDelete,
          child: Text('批量删除(${selectedIds.length})'),
        ),
    ];
  }

  List<MasterColumnDef<ProductionPlanListItem>> _columns(
    MasterNameService names,
  ) => <MasterColumnDef<ProductionPlanListItem>>[
    MasterColumnDef(
      key: 'billNo',
      label: '单据号',
      width: 140,
      value: (it) => it.billNo,
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '单据日期',
      width: 120,
      type: 'date',
      sortable: true,
      value: (it) => productionDateOnly(it.billDate),
    ),
    MasterColumnDef(
      key: 'deliveryDate',
      label: '交货日',
      width: 120,
      type: 'date',
      sortable: true,
      value: (it) => productionDateOnly(it.deliveryDate),
    ),
    MasterColumnDef(
      key: 'workshop',
      label: '车间',
      width: 160,
      value: (it) => names.department(it.departmentId),
    ),
    MasterColumnDef(
      key: 'seller',
      label: '跟单员',
      width: 140,
      value: (it) => names.employeeOr(it.sellerName, it.sellerId),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (it) => productionStatusLabel(it.status),
      // 状态徽章（草稿中性/已审绿/红冲红）；value 仍是纯文本供列宽/排序/筛选。
      cellBuilder: (_, it) => UtenStatusBadge(
        label: productionStatusLabel(it.status),
        type: docStatusBadgeType(it.status),
        size: UtenStatusBadgeSize.small,
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    // 分段计数(一次请求带回草稿/已审/红冲三桶); 加载中或无权限为 null, 不渲染数字。
    final statusCounts = ref
        .watch(documentStatusCountsProvider(_statusScope))
        .valueOrNull;
    // 返回即刷新：从详情/编辑页（保存/审核/删除后）回到本列表时静默重拉当前页，
    // 不再停留在进入子页前的老数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () => _reload(null, true));
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产计划单',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _reload(1),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: ListenableBuilder(
              listenable: _list,
              builder: (context, _) {
                final total = _list.total;
                // 「顶部折叠 + 表格吸顶内滚」：标题行随上滑收起腾出空间，
                // 筛选/表格区占满剩余空间、表体内部滚动（与单据列表页统一）。
                return UtenCollapsingHeaderScrollView(
                  // 页面头：Icon + 标题 + 计数 + 新建按钮（搜索条挪到下方筛选区/侧栏）
                  collapsingHeader: Padding(
                    padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.assignment_outlined,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        Text(
                          '计划单 ($total)',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        if (_canCreate)
                          UtenButton(
                            type: UtenButtonType.tonal,
                            icon: Icons.add_rounded,
                            onPressed: () =>
                                context.push('/production/plans/new'),
                            child: const Text('新建'),
                          ),
                      ],
                    ),
                  ),
                  // 多选批量操作条由 MasterDataTableView.batchActionsBuilder 统一渲染
                  // （常驻、未选灰色禁用，与货品资料等主档页一致），见 _planBatchActions。
                  // 桌面：左筛选侧栏（统一筛选工具条）+ 右表格；手机：垂直堆叠
                  body: UtenListTwoPane(
                    // 全平台统一筛选工具条：状态分段 + 胶囊搜索框。
                    filterPane: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s4,
                      ),
                      child: UtenFilterToolbar<int?>(
                        // 2026-09-21 用户口径: hub 卡有草稿红徽章, 子分类也要有数——
                        // 草稿红徽章(与卡面同源同数), 已审 / 红冲中性括号, 「全部」不挂。
                        segments: [
                          const UtenFilterSegment(value: null, label: '全部'),
                          UtenFilterSegment(
                            value: kProductionStatusDraft,
                            label: '草稿',
                            count: statusCounts?[DocumentStatusBucket.draft],
                            countForm: UtenSegmentCountForm.actionable,
                          ),
                          UtenFilterSegment(
                            value: kProductionStatusApproved,
                            label: '已审',
                            count: statusCounts?[DocumentStatusBucket.approved],
                          ),
                          UtenFilterSegment(
                            value: kProductionStatusReversed,
                            label: '红冲',
                            count: statusCounts?[DocumentStatusBucket.reversed],
                          ),
                        ],
                        selected: _statusFilterSelected
                            ? {_statusFilter}
                            : const {},
                        onSelectionChanged: _onStatus,
                        searchHint: '搜索单据号',
                        initialSearchValue: _list.keyword,
                        onSearchChanged: (v) {
                          _list.keyword = v;
                          _reload(1);
                        },
                      ),
                    ),
                    tablePane: MasterDataTableView<ProductionPlanListItem>(
                      // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
                      primary: true,
                      columns: _columns(names),
                      items: _list.page?.items ?? const [],
                      facets: {
                        'workshop': masterDictionaryFacets(
                          names.departmentEntries,
                        ),
                        'status': const [
                          MasterFacetBucket(
                            value: '$kProductionStatusDraft',
                            count: 0,
                            label: '草稿',
                          ),
                          MasterFacetBucket(
                            value: '$kProductionStatusApproved',
                            count: 0,
                            label: '已审',
                          ),
                          MasterFacetBucket(
                            value: '$kProductionStatusReversed',
                            count: 0,
                            label: '红冲',
                          ),
                        ],
                      },
                      nullCounts: const {},
                      filters: {
                        'workshop': _workshopIdFilter,
                        'status': _statusFilterSelected
                            ? _statusFilter?.toString()
                            : null,
                      },
                      onFilterChanged: _onColumnFilterChanged,
                      sortColumn: _list.sortKey,
                      sortAscending: _list.sortAsc,
                      onSortChange: _onSortChange,
                      onRowTap: (it) =>
                          context.push('/production/plans/${it.id}'),
                      // 多选：仅当用户有任一批量权限时开启勾选列（否则不显示，保持原样）。
                      selectable: _canBatchApprove || _canBatchDelete,
                      idOf: (it) => it.id,
                      selectedIds: _selectedIds,
                      onSelectedIdsChanged: (next) => setState(() {
                        _selectedIds
                          ..clear()
                          ..addAll(next);
                      }),
                      // 批量操作条：组件统一渲染（常驻、未选灰色禁用）。
                      batchActionsBuilder: _planBatchActions,
                      isLoading: _list.isLoadingFirst,
                      loadingMore: _list.isLoadingMore,
                      error: _list.error,
                      onRetry: () => _reload(),
                      emptyMessage: '暂无生产计划单',
                      currentPage: _list.currentPage,
                      totalPages: _list.totalPages,
                      onPageChange: (p) => _reload(p),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

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
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_plan.dart';
import '../repositories/production_repository.dart';

/// 保留模块别名以兼容既有调用，实际值统一来自全局 [Perm]。
class ProductionPerm {
  const ProductionPerm._();
  static const planView = Perm.productionPlanView;
  static const dailyReportView = Perm.productionDailyReportView;
  static const dailyReportEdit = Perm.productionDailyReportEdit;
  static const reportView = Perm.productionReportView;
}

class ProductionPlanListPage extends ConsumerStatefulWidget {
  const ProductionPlanListPage({super.key});

  @override
  ConsumerState<ProductionPlanListPage> createState() =>
      _ProductionPlanListPageState();
}

class _ProductionPlanListPageState
    extends ConsumerState<ProductionPlanListPage> {
  final _list = PagedListController<ProductionPlanListItem>();
  int? _statusFilter; // null=全部
  bool _statusFilterSelected = false; // 进页面不预选（不选=不过滤）

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;

  @override
  void initState() {
    super.initState();
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

  bool get _canBatchApprove {
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionPlanBatchApprove) &&
        permissions.contains(Perm.productionPlanApprove);
  }

  bool get _canBatchDelete {
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionPlanBatchDelete) &&
        permissions.contains(Perm.productionPlanDelete);
  }

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<ProductionPlanListItem>> _fetch() async {
    await ref.read(masterNameServiceProvider).ensureLoaded();
    final r = await ref
        .read(productionPlanRepositoryProvider)
        .list(
          page: _list.pageNum,
          filter: ProductionPlanFilter(
            keyword: _list.normalizedKeyword,
            status: _statusFilter,
          ),
          sort: _list.sortKey,
          order: _list.sortOrder,
        );
    // 跟单员名按需解析（部门名已在 ensureLoaded 加载）。
    await ref
        .read(masterNameServiceProvider)
        .loadEmployeeNames(r.items.map((e) => e.sellerId).whereType<String>());
    return r;
  }

  Future<void> _reload([int? page, bool silent = false]) =>
      _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);

  void _onStatus(int? s) {
    setState(() {
      _statusFilter = s;
      _statusFilterSelected = true;
    });
    _reload(1);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  /// 批量审核选中（草稿→已审）：逐条调 approve；非草稿服务端拒绝，计为跳过。
  Future<void> _batchApprove() => _runBatch(
    verb: '审核',
    danger: false,
    reviewerResponsibility: true,
    run: (id) async {
      await ref.read(productionPlanRepositoryProvider).approve(id);
    },
  );

  /// 批量删除选中草稿：逐条调 delete（仅草稿）；非草稿跳过，删除不可撤销。
  Future<void> _batchDelete() => _runBatch(
    verb: '删除',
    danger: true,
    run: (id) => ref.read(productionPlanRepositoryProvider).delete(id),
  );

  /// 批量执行通用骨架：确认 → 逐条调用（非草稿/失败计跳过）→ 清空选中并刷新 + 结果提示。
  Future<void> _runBatch({
    required String verb,
    required bool danger,
    required Future<void> Function(String id) run,
    bool reviewerResponsibility = false,
  }) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty || _batching) return;
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
    var success = 0;
    var skipped = 0;
    for (final id in ids) {
      try {
        await run(id);
        success++;
      } catch (_) {
        skipped++;
      }
    }
    if (!mounted) return;
    setState(() {
      _batching = false;
      _selectedIds.clear();
    });
    await _reload();
    if (mounted) {
      context.appSuccess('批量$verb完成：成功 $success，跳过 $skipped');
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
      value: (it) => names.employee(it.sellerId),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (it) => productionStatusLabel(it.status),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
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
            onPressed: () => _reload(),
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
                    splitPersistenceKey: 'production.planList',
                    // 全平台统一筛选工具条：状态分段 + 胶囊搜索框。
                    filterPane: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s4,
                      ),
                      child: UtenFilterToolbar<int?>(
                        segments: const [
                          UtenFilterSegment(value: null, label: '全部'),
                          UtenFilterSegment(
                            value: kProductionStatusDraft,
                            label: '草稿',
                          ),
                          UtenFilterSegment(
                            value: kProductionStatusApproved,
                            label: '已审',
                          ),
                          UtenFilterSegment(
                            value: kProductionStatusReversed,
                            label: '红冲',
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
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
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

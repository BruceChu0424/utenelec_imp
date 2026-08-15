// 生产计划单列表页（生产管理 / production_plan:view）。
//
// 复用基础资料布局：UtenAppBar(标题/返回/刷新) + UtenContentContainer > 标题行
// (Icon+label+(N)+搜索+新建) + 状态筛选(ChoiceChip Wrap) + MasterDataTableView。
// 过滤由本页自带的状态 ChoiceChip + 关键词搜索 + 日期范围承担（facets 传空，表头降级为纯标签）。
// 「新建」进入计划前物料分析，按 production_material_analysis:manage 权限显隐。
//
// 路径写死（待用户在 route_names.dart 加 RouteName.production* 后替换）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
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
  PagedResult<ProductionPlanListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  String _keyword = '';
  int? _statusFilter; // null=全部
  // 列排序态：_sortKey=当前排序列 key（null=不排序，走后端默认 billDate DESC）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  bool get _canCreate => ref
      .read(currentPermissionsProvider)
      .contains(Perm.productionMaterialAnalysisManage);

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
        permissions.contains(Perm.productionPlanEdit);
  }

  Future<void> _load(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final r = await ref
          .read(productionPlanRepositoryProvider)
          .list(
            page: page,
            filter: ProductionPlanFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              status: _statusFilter,
            ),
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      // 跟单员名按需解析（部门名已在 ensureLoaded 加载）。
      await ref
          .read(masterNameServiceProvider)
          .loadEmployeeNames(
            r.items.map((e) => e.sellerId).whereType<String>(),
          );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载列表失败';
        _loading = false;
      });
    }
  }

  void _onStatus(int? s) {
    setState(() => _statusFilter = s);
    _load(1);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _load(1);
  }

  /// 批量审核选中（草稿→已审）：逐条调 approve；非草稿服务端拒绝，计为跳过。
  Future<void> _batchApprove() => _runBatch(
    verb: '审核',
    danger: false,
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
  }) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty || _batching) return;
    final confirmed = await UtenDialog.show(
      context,
      title: '批量$verb（${ids.length} 个）',
      content: Text(
        danger
            ? '将删除选中的 ${ids.length} 个生产计划单草稿；非草稿将被跳过，删除不可撤销。'
            : '将审核选中的 ${ids.length} 个生产计划单（草稿→已审）；非草稿将被跳过。',
      ),
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
    await _load(_pageNum);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('批量$verb完成：成功 $success，跳过 $skipped')),
      );
    }
  }

  /// 批量操作按钮（交由 MasterDataTableView 工具条统一渲染）：按权限显隐批量审核/删除。
  /// 选中集非空时可点；未选中时由组件层整条灰化 + AbsorbPointer 拦截，故此处无需判空
  ///（_runBatch 内另有空集守卫）。_batchApprove/_batchDelete 直接读 _selectedIds。
  List<Widget> _planBatchActions(BuildContext context, Set<String> _) {
    return [
      if (_canBatchApprove)
        UtenButton(
          type: UtenButtonType.tonal,
          onPressed: _batching ? null : _batchApprove,
          child: const Text('批量审核'),
        ),
      if (_canBatchDelete)
        UtenButton(
          type: UtenButtonType.danger,
          onPressed: _batching ? null : _batchDelete,
          child: const Text('批量删除'),
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
    final total = _page?.total ?? 0;
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
            onPressed: () => _load(_pageNum),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 页面头：Icon + 标题 + 计数 + 新建按钮（搜索条挪到下方筛选区/侧栏）
                Padding(
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
                // 桌面：左筛选侧栏（搜索 + 状态 Chip）+ 右表格；手机：垂直堆叠
                Expanded(
                  child: UtenListTwoPane(
                    filterPane: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: UtenSearchBar(
                              hint: '搜索单据号',
                              initialValue: _keyword,
                              onChanged: (v) {
                                setState(() => _keyword = v);
                                _load(1);
                              },
                            ),
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _statusChip('全部', null),
                              _statusChip('草稿', kProductionStatusDraft),
                              _statusChip('已审', kProductionStatusApproved),
                              _statusChip('红冲', kProductionStatusReversed),
                            ],
                          ),
                        ],
                      ),
                    ),
                    tablePane: MasterDataTableView<ProductionPlanListItem>(
                      columns: _columns(names),
                      items: _page?.items ?? const [],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      sortColumn: _sortKey,
                      sortAscending: _sortAsc,
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
                      isLoading: _loading && _page == null,
                      loadingMore: _loading && _page != null,
                      error: _error,
                      onRetry: () => _load(_pageNum),
                      emptyMessage: '暂无生产计划单',
                      currentPage: _page?.page ?? 1,
                      totalPages: _page?.totalPages ?? 1,
                      onPageChange: (p) => _load(p),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusChip(String label, int? value) {
    final selected = _statusFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _onStatus(value),
    );
  }
}

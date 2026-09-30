// 产成品入库任务(可嵌入)：FQC 放行上限进入队列；登记入库仓库与库位后走两条路线之一
// ——「先入库后质检」(登记即按库位上架，合格自动入库)或「先质检后入库」(品质放行后按
// 实物完成最终点收，支持短收余量与批量全量点收)。
//
// 2026-09-27 用户口径「产成品入库与采购/委外入库 UI、逻辑一样」：待登记任务多选后与
// 预计到货同款两颗路线按钮并排(inboundRouteBatchButtons)，点哪颗就带着路线进批量登记页。
//
// 2026-09-01 起「入库任务中心 · 产成品入库」待点收分段内嵌本组件（embedded=true
// 时搜索框由任务中心页级工具条接管）；独立路由 /warehouse/production-finished-in/tasks
// 由对应页面以 embedded=false 包一层继续承接。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/master_server_column_filters.dart';
import '../models/inbound_registration_line.dart';
import '../models/production_finished_inbound_task.dart';
import '../models/stock_doc.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_finished_inbound_task_repository.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import 'inbound_registration_widgets.dart';

class ProductionFinishedInboundTasksView extends ConsumerStatefulWidget {
  const ProductionFinishedInboundTasksView({
    super.key,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
    this.onLoadingChanged,
    this.externalHeader,
  });

  /// 任务中心页级搜索关键字（embedded 模式生效）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在入库任务中心·产成品入库分段内（搜索框由页级工具条接管）。
  final bool embedded;

  /// 宿主（任务中心大类行 + 小类行/复合分段行）：挂进折叠头随页滚走
  /// （2026-09-24 用户口径「表格完全置顶」）。
  final Widget? externalHeader;

  /// 加载态变化回调（独立页 AppBar 刷新按钮据此置灰/转圈）。
  final ValueChanged<bool>? onLoadingChanged;

  @override
  ConsumerState<ProductionFinishedInboundTasksView> createState() =>
      _ProductionFinishedInboundTasksViewState();
}

class _ProductionFinishedInboundTasksViewState
    extends ConsumerState<ProductionFinishedInboundTasksView> {
  PagedResult<ProductionFinishedInboundTask>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';

  /// 表头列筛选（2026-09-16）：任务步骤（固定枚举）+ 仓库（dict 桶，仅待点收单有仓）。
  String? _taskStageFilter;
  String? _warehouseIdFilter;

  /// 表头排序 + 任务单号/生产计划列值筛选 + facets 桶 + 防串台代数
  /// （2026-09-25 单号列统一，共享状态见 MasterServerColumnFilters）；
  /// 排序列 key 见 [_kSortFields]，null = 服务端默认序。
  final _columnFilters = MasterServerColumnFilters();
  int _requestVersion = 0;
  final _tableRows =
      MasterDataTableRowsController<ProductionFinishedInboundTask>();
  final Set<String> _selectedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // dict 装载完成后补一次 setState：内部缓存变化不触发 provider 通知。
      ref
          .read(masterNameServiceProvider)
          .ensureLoaded()
          .then((_) => mounted ? setState(() {}) : null);
      _load(1);
    });
  }

  @override
  void didUpdateWidget(ProductionFinishedInboundTasksView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      _keyword = widget.keyword;
      // build 期不能同步触发加载（onLoadingChanged 会 setState 父级）——post-frame。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _load(1, replaceActive: true),
      );
    }
  }

  void _onSearchInput(String value) {
    if (_keyword == value) return;
    _keyword = value;
    _requestVersion++;
  }

  Future<void> _search(String value) async {
    if (_keyword != value) _onSearchInput(value);
    await _load(1, replaceActive: true);
  }

  Future<void> _load(int page, {bool replaceActive = false}) async {
    if (_loading && !replaceActive) return;
    final requestVersion = ++_requestVersion;
    final keyword = _keyword;
    setState(() {
      _loading = true;
      _error = null;
    });
    widget.onLoadingChanged?.call(true);
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .tasks(
            page: page,
            keyword: keyword,
            taskStage: _taskStageFilter,
            warehouseId: _warehouseIdFilter,
            scope: WarehouseListScope.of(context),
            sort: _kSortFields[_columnFilters.sortColumn],
            order: _columnFilters.sortColumn == null
                ? null
                : (_columnFilters.sortAscending ? 'asc' : 'desc'),
            taskNo: _columnFilters['taskNo'],
            planNo: _columnFilters['planNo'],
          );
      if (!mounted || requestVersion != _requestVersion) return;
      // 单号 facets 与列表同口径（2026-09-25 单号列统一）；失败静默（下拉降级为空）。
      unawaited(_loadBillNoFacets());
      setState(() {
        _result = result;
        _loading = false;
      });
      // Reconcile after the table has combined any appended pages.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || requestVersion != _requestVersion) return;
        final visibleIds = <String>{
          for (final task in _tableRows.items)
            if (task.isArrivalRegistration)
              'reg:${task.reportId ?? ''}'
            else if ((task.documentId ?? '').isNotEmpty)
              'doc:${task.documentId}',
        }..removeWhere((id) => id.endsWith(':') || id.endsWith(':null'));
        if (_selectedIds.any((id) => !visibleIds.contains(id))) {
          setState(
            () => _selectedIds.removeWhere((id) => !visibleIds.contains(id)),
          );
        }
      });
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
      widget.onLoadingChanged?.call(false);
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '产成品入库任务加载失败，请检查网络后重试';
        _loading = false;
      });
      widget.onLoadingChanged?.call(false);
    }
    widget.onLoadingChanged?.call(false);
  }

  /// 表头排序键 → 服务端 sort 参数（2026-09-25 单号列统一；未列出的列不可排序）。
  static const _kSortFields = <String, String>{
    'taskNo': 'taskNo',
    'planNo': 'planNo',
  };

  /// 表头排序变化：服务端重排整个结果集，回第 1 页（勾选跨页保留，不清）。
  void _onSortChange(String? column, bool ascending) {
    final next = column != null && _kSortFields.containsKey(column)
        ? column
        : null;
    if (next == _columnFilters.sortColumn &&
        (next == null || ascending == _columnFilters.sortAscending)) {
      return;
    }
    _columnFilters.handleSortChanged(
      next,
      ascending,
      onChanged: () {
        if (mounted) setState(() {});
        _load(1, replaceActive: true);
      },
    );
  }

  /// 任务单号/生产计划 facets（2026-09-25 单号列统一）：与列表同过滤口径
  /// （不含单号列自身值筛选）。
  Future<void> _loadBillNoFacets() => _columnFilters.loadFacets(
    () => ref
        .read(productionFinishedInboundTaskRepositoryProvider)
        .taskBillNoFacets(
          keyword: _keyword,
          taskStage: _taskStageFilter,
          warehouseId: _warehouseIdFilter,
          scope: WarehouseListScope.of(context),
        ),
    onLoaded: () {
      if (mounted) setState(() {});
    },
  );

  Future<void> _openTask(ProductionFinishedInboundTask task) async {
    if (task.isArrivalRegistration) {
      final reportId = task.reportId;
      if (reportId == null || reportId.isEmpty) {
        context.appWarning('该到货登记任务缺少报工单标识，请刷新后重试', force: true);
        return;
      }
      final changed = await context.push<bool>(
        RoutePath.warehouseProductionFinishedArrivalRegistration(
          reportId,
          returnTo: GoRouterState.of(context).matchedLocation,
        ),
      );
      if (!mounted || changed != true) return;
      // 登记页只失效了待点收计数；返回后统一失效，保证分段徽章/hub/工作台即时联动。
      invalidateWarehouseTaskCounts(ref);
      await _load(_result?.page ?? 1);
      return;
    }

    final documentId = task.documentId;
    if (documentId == null || documentId.isEmpty) {
      context.appWarning('该最终点收任务缺少入库单标识，请刷新后重试', force: true);
      return;
    }
    goFrom(
      context,
      RoutePath.stockDocDetail(StockDocType.finishedIn.code, documentId),
    );
  }

  void _setSelectedIds(Set<String> next) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
    });
  }

  /// 多选「批量全量点收入库」（2026-09-12 弹窗改页，与入库中心统一口径）：
  /// 进批量点收页（所选任务一张表 + 底部确认批量入库，小结确认后整批同事务提交）。
  Future<void> _confirmSelected(Set<String> selectedIds) async {
    final documentIds = selectedIds
        .where((id) => id.startsWith('doc:'))
        .map((id) => id.substring(4))
        .toSet();
    if (documentIds.isEmpty) {
      context.appWarning('请先选择待最终点收任务');
      return;
    }
    if (documentIds.length != selectedIds.length) {
      context.appWarning('登记送检与最终点收属于不同步骤，请分开选择');
      return;
    }
    final targets = _tableRows.items
        .where(
          (task) =>
              (task.documentId ?? '').isNotEmpty &&
              documentIds.contains(task.documentId),
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      context.appWarning('所选任务状态已变化，请刷新后重新选择');
      return;
    }
    final changed = await context.push<bool>(
      RouteName.warehouseProductionFinishedBatchStockIn,
      extra: targets,
    );
    if (!mounted || changed != true) return;
    setState(() => _selectedIds.clear());
    invalidateWarehouseTaskCounts(ref);
    await _load(_result?.page ?? 1, replaceActive: true);
  }

  /// 「先入库后质检」批量入口(与登记页同款独立权限点，服务端兜底)。
  bool get _canStockInFirst =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionFinishedInBeforeInspection);

  /// 多选「先入库后质检(N)」/「先质检后入库(N)」：带着所选路线进多报工单汇总登记页，
  /// 页面只显示这一条路线的提交按钮(与预计到货批量登记同款)。
  Future<void> _openBatchRegistration(
    Set<String> selectedIds,
    InboundRoute route,
  ) async {
    final currentItems = _tableRows.items;
    final reportIds = <String>{
      for (final id in selectedIds)
        if (id.startsWith('reg:')) id.substring(4),
    }.toList()..sort();
    if (reportIds.isEmpty) {
      context.appWarning('请先选择“待登记入库”的任务');
      return;
    }
    if (reportIds.length != selectedIds.length) {
      context.appWarning('混选了不同步骤的任务：批量登记只处理“待登记入库”，请分开操作');
      return;
    }
    final knownReports = currentItems
        .where((task) => task.isArrivalRegistration)
        .map((task) => task.reportId ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (!knownReports.containsAll(reportIds)) {
      context.appWarning('所选任务状态已变化，请刷新后重新选择');
      return;
    }
    final changed = await context.push<bool>(
      RoutePath.warehouseProductionFinishedArrivalBatchRegistration(
        reportIds,
        returnTo: GoRouterState.of(context).matchedLocation,
        stockInBeforeInspection: route.isStockInFirst,
      ),
    );
    if (!mounted || changed != true) return;
    invalidateWarehouseTaskCounts(ref);
    _selectedIds.clear();
    await _load(_result?.page ?? 1, replaceActive: true);
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final count = selectedIds.where((id) => id.startsWith('doc:')).length;
    final registerCount = selectedIds
        .where((id) => id.startsWith('reg:'))
        .length;
    if (count > 0 && registerCount > 0) {
      return [
        Text('登记送检与最终点收请分开选择', style: Theme.of(context).textTheme.bodyMedium),
      ];
    }
    final registrationStage =
        registerCount > 0 ||
        (count == 0 &&
            _tableRows.items.any((task) => task.isArrivalRegistration));
    return [
      // 待登记任务：与预计到货同款两颗路线按钮(同名同义、同一组件)。
      if (registrationStage)
        ...inboundRouteBatchButtons(
          context,
          count: registerCount,
          canStockInFirst: _canStockInFirst,
          emptyWarning: '请先选择“待登记入库”的任务',
          onSelected: (route) => _openBatchRegistration(selectedIds, route),
        ),
      if (!registrationStage)
        Tooltip(
          message: count == 0
              ? '请选择“品质通过 · 待最终点收”的任务'
              : '按每张单全部待点收数量原子入库；短收请逐单处理',
          child: UtenButton(
            key: const Key('production-finished-inbound-batch-confirm'),
            size: UtenButtonSize.large,
            type: UtenButtonType.danger,
            icon: Icons.inventory_rounded,
            onPressed: count == 0 ? null : () => _confirmSelected(selectedIds),
            onDisabledTap: count == 0
                ? () => context.appWarning('请先选择待最终点收任务')
                : null,
            child: Text(count == 0 ? '批量全量点收入库' : '批量全量点收入库($count)'),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final permissions = ref.watch(currentPermissionsProvider);
    final canCount =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.stockDocApprove);
    return _buildTable(result, canCount: canCount);
  }

  Widget _buildTable(
    PagedResult<ProductionFinishedInboundTask>? value, {
    required bool canCount,
  }) {
    final result =
        value ??
        const PagedResult<ProductionFinishedInboundTask>(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 1,
        );
    // 2026-09-24 用户口径「表格完全置顶」：工具行/流程提示/错误行进折叠头
    // 随页滚走，body 只剩表格（primary 拾取联动控制器）。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.externalHeader != null) ...[
            widget.externalHeader!,
            const SizedBox(height: UtenSpacing.s12),
          ],
          _buildToolbar(result),
          const SizedBox(height: UtenSpacing.s8),
          const _ProcessHint(),
          if (_error != null && result.items.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            Semantics(
              liveRegion: true,
              child: Text(
                '刷新失败：$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
        ],
      ),
      body: MasterDataTableView<ProductionFinishedInboundTask>(
        rowsController: _tableRows,
        paginationRevision: _result,
        paginationScope: (
          _keyword,
          _taskStageFilter,
          _warehouseIdFilter,
          WarehouseListScope.of(context),
        ),
        tableKey:
            'features.warehouse.widgets.production_finished_inbound_tasks_view.ProductionFinishedInboundTasksViewState._buildTable.1',
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        key: const Key('production-finished-inbound-task-table'),
        columns: _columns,
        items: result.items,
        // 表头筛选桶（2026-09-16）：任务步骤固定枚举两档（服务端 task_stage）；
        // 仓库走主档 dict（待登记任务尚无仓库，会被该筛选取自然排除）。
        facets: {
          'taskStage': const [
            MasterFacetBucket(
              value: 'ARRIVAL_REGISTRATION',
              count: 0,
              label: '待登记入库',
            ),
            MasterFacetBucket(
              value: 'FINAL_COUNT',
              count: 0,
              label: '待最终点收（含短收余量）',
            ),
          ],
          'warehouseName': masterDictionaryFacets(
            ref.watch(masterNameServiceProvider).warehouseEntries,
          ),
          // 任务单号/生产计划表头值筛选（2026-09-25 单号列统一）：服务端分组计数桶。
          'taskNo': _columnFilters.bucketOf('taskNo'),
          'planNo': _columnFilters.bucketOf('planNo'),
        },
        nullCounts: const {},
        filters: {
          'taskStage': _taskStageFilter,
          'warehouseName': _warehouseIdFilter,
          'taskNo': _columnFilters['taskNo'],
          'planNo': _columnFilters['planNo'],
        },
        // 表头排序走服务端（2026-09-25 单号列统一）。
        sortColumn: _columnFilters.sortColumn,
        sortAscending: _columnFilters.sortAscending,
        onSortChange: _onSortChange,
        onFilterChanged: (key, value) {
          if (key == 'taskNo' || key == 'planNo') {
            _columnFilters.handleFilterChanged(
              key,
              value,
              onChanged: () {
                if (mounted) setState(() {});
                _load(1, replaceActive: true);
              },
            );
            return;
          }
          setState(() {
            if (key == 'taskStage') {
              _taskStageFilter = value;
            } else if (key == 'warehouseName') {
              _warehouseIdFilter = value;
            }
          });
          _load(1, replaceActive: true);
        },
        selectable: canCount,
        // 两类任务分别可选：待登记任务键 reg:<reportId>(两条路线批量登记)，
        // 待点收任务键 doc:<documentId>(批量全量点收)；只展示所选阶段的动作。
        idOf: (task) => task.isArrivalRegistration
            ? (task.reportId?.isNotEmpty == true
                  ? 'reg:${task.reportId}'
                  : null)
            : ((task.documentId ?? '').isEmpty
                  ? null
                  : 'doc:${task.documentId}'),
        selectedIds: _selectedIds,
        onSelectedIdsChanged: _setSelectedIds,
        batchActionsBuilder: canCount ? _batchActions : null,
        onRowTap: _openTask,
        rowMenuBuilder: (task) => [
          UtenMenuItem(
            label: _taskActionLabel(task, canCount: canCount),
            icon: canCount
                ? task.isArrivalRegistration
                      ? Icons.edit_location_alt_outlined
                      : Icons.inventory_rounded
                : Icons.visibility_outlined,
            onTap: () => _openTask(task),
          ),
        ],
        isLoading: _loading || value == null,
        loadingMore: _loading && value != null,
        error: result.items.isEmpty ? _error : null,
        onRetry: () => _load(result.page),
        emptyMessage: _keyword.isEmpty ? '目前没有待处理的产成品入库任务' : '没有匹配的产成品入库任务',
        currentPage: result.page,
        totalPages: result.totalPages,
        onPageChange: _load,
      ),
    );
  }

  Widget _buildToolbar(PagedResult<ProductionFinishedInboundTask> result) {
    if (widget.embedded) {
      return Semantics(
        header: true,
        label: '共有 ${result.total} 项产成品入库任务',
        child: Align(
          alignment: Alignment.centerRight,
          child: Text(
            '共 ${result.total} 项 · 单击多选，双击详情',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    final search = UtenSearchBar(
      key: const Key('production-finished-inbound-search'),
      hint: '搜索入库单 / 生产单 / 报工单 / 货品',
      initialValue: _keyword,
      onInputChanged: _onSearchInput,
      onChanged: _search,
    );
    final count = Text(
      '共 ${result.total} 项 · 单击多选，双击详情',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    return Semantics(
      header: true,
      label: '共有 ${result.total} 项产成品入库任务',
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                search,
                const SizedBox(height: UtenSpacing.s8),
                count,
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 420, child: search),
              const Spacer(),
              count,
            ],
          );
        },
      ),
    );
  }

  List<MasterColumnDef<ProductionFinishedInboundTask>> get _columns => [
    const MasterColumnDef(
      key: 'taskStage',
      label: '任务步骤',
      width: 190,
      value: _taskStageLabel,
    ),
    const MasterColumnDef(
      key: 'taskNo',
      label: '任务单号',
      width: 180,
      sortable: true, // 2026-09-25 单号列统一：表头排序 + 值筛选。
      value: _taskDisplayNo,
    ),
    MasterColumnDef(
      key: 'planNo',
      label: '生产计划',
      width: 160,
      sortable: true, // 2026-09-25 单号列统一：表头排序 + 值筛选。
      value: (task) => task.planNo ?? '—',
    ),
    MasterColumnDef(
      key: 'reportNos',
      label: '报工单',
      width: 180,
      value: (task) => task.reportNos ?? '—',
    ),
    MasterColumnDef(
      key: 'goodsSummary',
      label: '货品',
      width: 260,
      value: (task) => task.goodsSummary ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '仓库',
      width: 160,
      value: (task) =>
          task.isArrivalRegistration ? '待本步骤选择' : task.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'pendingQty',
      label: '待处理数量',
      width: 120,
      type: 'number',
      value: (task) => _quantity(task.pendingQty),
    ),
    MasterColumnDef(
      key: 'lineCount',
      label: '行数',
      width: 80,
      type: 'number',
      value: (task) => '${task.lineCount}',
    ),
    MasterColumnDef(
      key: 'documentDate',
      label: '单据日期',
      width: 120,
      type: 'date',
      value: (task) => ChinaDateTime.formatDate(task.documentDate),
    ),
    MasterColumnDef(
      key: 'createdAt',
      label: '进入队列时间',
      width: 170,
      value: (task) => ChinaDateTime.formatInstant(task.createdAt),
    ),
  ];
}

class _ProcessHint extends StatelessWidget {
  const _ProcessHint();

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        Icons.info_outline_rounded,
        size: 18,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(width: UtenSpacing.s8),
      const Expanded(
        child: Text(
          '双击行直达下一步(待登记入库→登记入库仓库与库位)；'
          '「待登记入库」多选「先入库后质检」：登记的同时逐行按库位上架，品质部到库位检验，'
          '合格由系统自动入库；多选「先质检后入库」：登记后送品质部检验，放行后再按实物最终点收；'
          '进批量登记页后只显示所选这一条路线的提交按钮。'
          '品质通过的任务可多选批量全量点收；短收、拒收仍须逐单进入确认。',
        ),
      ),
    ],
  );
}

String _taskStageLabel(ProductionFinishedInboundTask task) =>
    task.isArrivalRegistration
    ? '待登记入库'
    : task.residualTask
    ? '短收余量待点收'
    : '品质通过 · 待最终点收';

String _taskDisplayNo(ProductionFinishedInboundTask task) =>
    task.documentNo?.trim().isNotEmpty == true
    ? task.documentNo!
    : task.reportNos?.trim().isNotEmpty == true
    ? task.reportNos!
    : task.taskId;

String _taskActionLabel(
  ProductionFinishedInboundTask task, {
  required bool canCount,
}) => canCount
    ? task.isArrivalRegistration
          ? '登记入库仓库与库位'
          : '进入最终点收'
    : task.isArrivalRegistration
    ? '查看到货登记详情'
    : '查看待点收详情';

String _quantity(double value) => inboundQty(value);

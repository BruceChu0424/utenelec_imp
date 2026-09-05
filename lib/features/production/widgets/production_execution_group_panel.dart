import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_execution_workbench.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_execution_workbench_repository.dart';

/// Planning-facing ongoing list: one row per outer analysis/root plan.
class ProductionExecutionGroupPanel extends ConsumerStatefulWidget {
  const ProductionExecutionGroupPanel({super.key, required this.keyword});

  final String keyword;

  @override
  ConsumerState<ProductionExecutionGroupPanel> createState() =>
      _ProductionExecutionGroupPanelState();
}

class _ProductionExecutionGroupPanelState
    extends ConsumerState<ProductionExecutionGroupPanel> {
  List<ProductionExecutionWorkbenchGroup> _items = const [];
  int _page = 1;
  int _totalPages = 0;
  bool _loading = false;
  bool _opening = false;
  bool _reporting = false;
  String? _error;
  String? _workshopDepartmentId;
  bool _mine = false;
  String _sort = 'latestEndDate';
  bool _sortAscending = true;
  int _loadGeneration = 0;
  final Set<String> _selectedRootIds = {};

  bool get _canReportLocally {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionExecutionView) &&
        permissions.contains(Perm.productionDailyReportView) &&
        permissions.contains(Perm.productionDailyReportCreate);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant ProductionExecutionGroupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword) {
      _page = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final requestedPage = _page;
    final requestedKeyword = widget.keyword;
    final requestedWorkshop = _workshopDepartmentId;
    final requestedMine = _mine;
    final requestedSort = _sort;
    final requestedAscending = _sortAscending;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionExecutionWorkbenchRepositoryProvider)
          .groups(
            page: requestedPage,
            keyword: requestedKeyword,
            workshopDepartmentId: requestedWorkshop,
            mine: requestedMine,
            sort: requestedSort,
            order: requestedAscending ? 'asc' : 'desc',
          );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _items = result.items;
        _page = result.page;
        _totalPages = result.totalPages;
      });
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = '生产任务加载失败，请重试');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(ProductionExecutionWorkbenchGroup group) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final route = await showUtenAdaptivePanel<String>(
        context: context,
        compactHeightFactor: 0.96,
        drawerWidth: 980,
        panelElevation: 12,
        builder: (_) => _ExecutionRootDetailPanel(group: group),
      );
      if (mounted && route != null && route.isNotEmpty) {
        await context.push(route);
      }
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// 外层直接报工：拉齐所选批次的工单页，筛出可报工单后与抽屉层同口径校验
  /// （同车间、≤100），再直达生产日报新建页。整批无可报时明确告知。
  Future<void> _reportGroups(
    List<ProductionExecutionWorkbenchGroup> groups,
  ) async {
    if (_reporting) return;
    if (!_canReportLocally) {
      context.appWarning('报工需要车间任务查看、生产日报查看和生产日报新建权限');
      return;
    }
    setState(() => _reporting = true);
    try {
      final repository = ref.read(
        productionExecutionWorkbenchRepositoryProvider,
      );
      final targetReportable = groups.fold<int>(
        0,
        (sum, group) => sum + group.reportableCount,
      );
      final reportable = <ProductionExecutionWorkbenchSegment>[];
      var scanned = 0;
      for (final group in groups) {
        // 兜底 20 页：异常超大批次不至于无限拉取（正常远达不到）。
        for (var page = 1; page <= 20; page++) {
          final result = await repository.workOrders(
            rootType: group.rootType,
            rootId: group.rootId,
            page: page,
          );
          scanned += result.items.length;
          reportable.addAll(result.items.where((row) => row.canReport));
          if (page >= result.totalPages) break;
        }
        if (reportable.length >= targetReportable) break;
      }
      if (reportable.isEmpty) {
        if (mounted) {
          context.appWarning('所选批次当前没有可报工的工单（工单需备料完毕且未完结）');
        }
        return;
      }
      final workshops = reportable
          .map((row) => row.workshopDepartmentId ?? row.workshopName ?? '')
          .where((value) => value.isNotEmpty)
          .toSet();
      if (workshops.length > 1) {
        if (mounted) {
          context.appWarning(
            '一次报工只能包含同一生产车间（当前涉及 ${workshops.length} 个车间），'
            '请按车间分批办理',
          );
        }
        return;
      }
      final ids = reportable
          .map((row) => row.segmentId)
          .where((id) => id.isNotEmpty)
          .toSet();
      if (ids.length > 100) {
        if (mounted) {
          context.appWarning('一次报工最多 100 个工单（当前 ${ids.length} 个），请缩小范围分批办理');
        }
        return;
      }
      assert(scanned >= reportable.length);
      final uri = Uri(
        path: RoutePath.productionDailyReportNew(),
        queryParameters: ids.length == 1
            ? {'executionSegmentId': ids.single}
            : {'executionSegmentIds': ids.join(',')},
      );
      if (!mounted) return;
      await context.push(uri.toString());
      if (mounted) await _load();
    } catch (_) {
      if (mounted) context.appWarning('报工工单加载失败，请重试');
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 报工可用性跟随权限变化重建（超管恒可）。
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final workshops =
        ref.watch(productionWorkshopTreeProvider).valueOrNull ?? const [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
        UtenSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  key: ValueKey(_workshopDepartmentId ?? 'all-workshops'),
                  initialValue: _workshopDepartmentId ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '生产车间'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部车间')),
                    for (final workshop in workshops)
                      DropdownMenuItem(
                        value: workshop.id,
                        child: Text(workshop.name),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          setState(() {
                            _workshopDepartmentId = value?.isEmpty == true
                                ? null
                                : value;
                            _page = 1;
                          });
                          _load();
                        },
                ),
              ),
              FilterChip(
                selected: _mine,
                label: const Text('只看我的车间/负责工单'),
                avatar: const Icon(Icons.person_outline_rounded, size: 18),
                onSelected: _loading
                    ? null
                    : (value) {
                        setState(() {
                          _mine = value;
                          _page = 1;
                        });
                        _load();
                      },
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  initialValue: _sort,
                  decoration: const InputDecoration(labelText: '排序'),
                  items: const [
                    DropdownMenuItem(
                      value: 'latestEndDate',
                      child: Text('计划完工日期'),
                    ),
                    DropdownMenuItem(value: 'status', child: Text('业务状态')),
                    DropdownMenuItem(value: 'rootLabel', child: Text('分析批次')),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          if (value == null || value == _sort) return;
                          setState(() {
                            _sort = value;
                            _page = 1;
                          });
                          _load();
                        },
                ),
              ),
              IconButton(
                tooltip: _sortAscending ? '当前升序，点击改为降序' : '当前降序，点击改为升序',
                onPressed: _loading
                    ? null
                    : () {
                        setState(() {
                          _sortAscending = !_sortAscending;
                          _page = 1;
                        });
                        _load();
                      },
                icon: Icon(
                  _sortAscending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Expanded(
            child: MasterDataTableView<ProductionExecutionWorkbenchGroup>(
              columns: _columns,
              items: _items,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              onRowTap: _opening ? null : _open,
              rowKeyOf: (row) => row.id,
              selectable: _canReportLocally,
              idOf: _canReportLocally ? (row) => row.id : null,
              selectedIds: _canReportLocally
                  ? _selectedRootIds
                  : const <String>{},
              onSelectedIdsChanged: (ids) => setState(
                () => _selectedRootIds
                  ..clear()
                  ..addAll(ids),
              ),
              batchActionsBuilder: (_, ids) => [
                UtenButton(
                  key: const ValueKey('execution-group-batch-report'),
                  icon: Icons.fact_check_outlined,
                  onPressed: ids.isEmpty || _reporting || _loading
                      ? null
                      : () => _reportGroups(
                          _items
                              .where((row) => ids.contains(row.id))
                              .toList(growable: false),
                        ),
                  child: Text('批量报工(${ids.length} 批)'),
                ),
              ],
              rowMenuBuilder: (row) => [
                if (row.reportableCount > 0)
                  UtenMenuItem(
                    label: '报工（可报 ${row.reportableCount} 项）',
                    icon: Icons.fact_check_outlined,
                    enabled: !_reporting && _canReportLocally,
                    onTap: () => _reportGroups([row]),
                  ),
                UtenMenuItem(
                  label: '查看批次详情',
                  icon: Icons.open_in_new_rounded,
                  enabled: !_opening,
                  onTap: () => _open(row),
                ),
              ],
              currentPage: _page,
              totalPages: _totalPages,
              onPageChange: (page) {
                _page = page;
                _load();
              },
              isLoading: _loading,
              error: _error,
              onRetry: _load,
              emptyMessage: widget.keyword.isEmpty
                  ? '暂无进行中的物料分析或生产任务'
                  : '没有匹配的生产任务',
              toolbarActions: [
                IconButton(
                  tooltip: '刷新',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<MasterColumnDef<ProductionExecutionWorkbenchGroup>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 170,
      value: (row) => row.statusLabel,
      cellBuilder: (_, row) => _GroupStatusBadge(row: row),
    ),
    MasterColumnDef(
      key: 'root',
      label: '分析批次',
      width: 150,
      value: (row) => row.rootLabel,
    ),
    MasterColumnDef(
      key: 'orders',
      label: '关联订单',
      width: 210,
      value: (row) => _preview(
        row.salesOrderPreview,
        row.salesOrderCount,
        row.salesOrderHasMore,
      ),
    ),
    MasterColumnDef(
      key: 'workOrders',
      label: '工单号',
      width: 210,
      value: (row) => _preview(
        row.workOrderPreview,
        row.workOrderCount,
        row.workOrderHasMore,
      ),
    ),
    MasterColumnDef(
      key: 'workshops',
      label: '生产车间',
      width: 180,
      value: (row) =>
          _preview(row.workshopPreview, row.workshopCount, row.workshopHasMore),
    ),
    MasterColumnDef(
      key: 'productCode',
      label: '产品编号',
      width: 190,
      value: (row) => _preview(
        row.productCodePreview,
        row.productCount,
        row.productHasMore,
      ),
    ),
    MasterColumnDef(
      key: 'productName',
      label: '产品名称',
      width: 210,
      value: (row) => _preview(
        row.productNamePreview,
        row.productCount,
        row.productHasMore,
      ),
    ),
    MasterColumnDef(
      key: 'productColor',
      label: '产品颜色',
      width: 150,
      value: (row) => _preview(
        row.productColorPreview,
        row.productCount,
        row.productHasMore,
      ),
    ),
    MasterColumnDef(
      key: 'quantity',
      label: '产品数量与进度',
      width: 420,
      value: (row) => _preview(
        row.quantitySummary,
        row.executionUnitCount,
        row.executionUnitHasMore,
      ),
    ),
    MasterColumnDef(
      key: 'progress',
      label: '流程计数',
      width: 280,
      value: (row) =>
          '计划 ${row.planCount} · 工单 ${row.segmentCount} · '
          '待料 ${row.waitingCount} · 生产中 ${row.inProgressCount} · '
          'FQC待检 ${row.fqcPendingCount} · '
          '待点收 ${row.finishedInboundPendingCount}',
    ),
    MasterColumnDef(
      key: 'action',
      label: '操作',
      width: 190,
      value: (row) =>
          row.reportableCount > 0 ? '报工 ${row.reportableCount} 项' : '查看批次详情',
      cellBuilder: (_, row) => UtenButton(
        size: UtenButtonSize.small,
        type: row.reportableCount > 0
            ? UtenButtonType.primary
            : UtenButtonType.tonal,
        icon: row.reportableCount > 0
            ? Icons.fact_check_outlined
            : Icons.open_in_new_rounded,
        onPressed: _opening || _reporting
            ? null
            : () => row.reportableCount > 0 ? _reportGroups([row]) : _open(row),
        child: Text(
          row.reportableCount > 0 ? '报工 ${row.reportableCount} 项' : '查看详情',
        ),
      ),
    ),
  ];
}

String _preview(String? value, int count, bool hasMore) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '—';
  return hasMore ? '$text · 共 $count 项' : text;
}

class _GroupStatusBadge extends StatelessWidget {
  const _GroupStatusBadge({required this.row});

  final ProductionExecutionWorkbenchGroup row;

  @override
  Widget build(BuildContext context) {
    final type = switch (row.status) {
      'PREPARED' => UtenStatusBadgeType.success,
      'IN_PROGRESS' => UtenStatusBadgeType.info,
      'KIT_SHORT' ||
      'PREPARING' ||
      'PARTIALLY_SCHEDULED' => UtenStatusBadgeType.warning,
      'ASSIGNMENT_REQUIRED' => UtenStatusBadgeType.danger,
      _ => UtenStatusBadgeType.neutral,
    };
    return UtenStatusBadge(label: row.statusLabel, type: type);
  }
}

class _ExecutionRootDetailPanel extends ConsumerStatefulWidget {
  const _ExecutionRootDetailPanel({required this.group});

  final ProductionExecutionWorkbenchGroup group;

  @override
  ConsumerState<_ExecutionRootDetailPanel> createState() =>
      _ExecutionRootDetailPanelState();
}

class _ExecutionRootDetailPanelState
    extends ConsumerState<_ExecutionRootDetailPanel> {
  String _section = 'workOrders';
  int _workOrderPage = 1;
  int _workOrderPages = 0;
  int _documentPage = 1;
  int _documentPages = 0;
  List<ProductionExecutionWorkbenchSegment> _workOrders = const [];
  List<ProductionExecutionWorkbenchRelatedDocument> _documents = const [];
  final Set<String> _selectedWorkOrderIds = {};
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  bool get _canReportLocally {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionExecutionView) &&
        permissions.contains(Perm.productionDailyReportView) &&
        permissions.contains(Perm.productionDailyReportCreate);
  }

  String _workshopKey(ProductionExecutionWorkbenchSegment row) =>
      row.workshopDepartmentId ?? row.workshopName ?? '';

  bool _canSelectWorkOrder(ProductionExecutionWorkbenchSegment row) {
    if (!_canReportLocally || !row.canBatchReport) return false;
    if (_selectedWorkOrderIds.contains(row.segmentId) ||
        _selectedWorkOrderIds.isEmpty) {
      return true;
    }
    final selectedWorkshop = _workOrders
        .where((item) => _selectedWorkOrderIds.contains(item.segmentId))
        .map(_workshopKey)
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    return selectedWorkshop == null || _workshopKey(row) == selectedWorkshop;
  }

  void _updateWorkOrderSelection(Set<String> requested) {
    if (requested.isEmpty) {
      setState(_selectedWorkOrderIds.clear);
      return;
    }
    final rows = [
      for (final row in _workOrders)
        if (requested.contains(row.segmentId) && row.canBatchReport) row,
    ];
    if (rows.isEmpty) return;
    final existingWorkshop = _workOrders
        .where((row) => _selectedWorkOrderIds.contains(row.segmentId))
        .map(_workshopKey)
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    final workshop = existingWorkshop ?? _workshopKey(rows.first);
    final accepted = rows
        .where((row) => _workshopKey(row) == workshop)
        .map((row) => row.segmentId)
        .toSet();
    setState(() {
      _selectedWorkOrderIds
        ..clear()
        ..addAll(accepted);
    });
    if (accepted.length != requested.length) {
      context.appWarning('一次批量报工只能选择同一生产车间；其它车间工单未选中');
    }
  }

  List<String> _contextReportIds(ProductionExecutionWorkbenchSegment row) =>
      _selectedWorkOrderIds.contains(row.segmentId) &&
          _selectedWorkOrderIds.length > 1
      ? _selectedWorkOrderIds.toList(growable: false)
      : [row.segmentId];

  Widget _batchSelectionGate(
    BuildContext context,
    ProductionExecutionWorkbenchSegment row,
  ) {
    final message = !_canReportLocally
        ? '报工需要车间任务查看、生产日报查看和生产日报新建权限'
        : !row.canBatchReport
        ? (row.blockedReason ?? '当前工单不能加入批量报工')
        : '已选择其它生产车间；一次批量报工只能包含同一车间';
    return Tooltip(
      message: message,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Icon(
          Icons.lock_outline_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final requestedSection = _section;
    final requestedWorkOrderPage = _workOrderPage;
    final requestedDocumentPage = _documentPage;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(
        productionExecutionWorkbenchRepositoryProvider,
      );
      if (requestedSection == 'workOrders') {
        final page = await repository.workOrders(
          rootType: widget.group.rootType,
          rootId: widget.group.rootId,
          page: requestedWorkOrderPage,
        );
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _workOrders = page.items;
          _workOrderPage = page.page;
          _workOrderPages = page.totalPages;
          final eligible = page.items
              .where((item) => item.canBatchReport)
              .map((item) => item.segmentId)
              .toSet();
          _selectedWorkOrderIds.removeWhere((id) => !eligible.contains(id));
        });
      } else {
        final page = await repository.relatedDocuments(
          rootType: widget.group.rootType,
          rootId: widget.group.rootId,
          page: requestedDocumentPage,
        );
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _documents = page.items;
          _documentPage = page.page;
          _documentPages = page.totalPages;
        });
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = '详情加载失败，请重试');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void _selectSection(String value) {
    if (value == _section) return;
    setState(() => _section = value);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final group = widget.group;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.rootLabel,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${group.statusLabel} · ${group.quantitySummary ?? '暂无数量进度'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: UtenFilterToolbar<String>(
              segments: const [
                UtenFilterSegment(value: 'workOrders', label: '工单与进度'),
                UtenFilterSegment(value: 'documents', label: '关联单据'),
              ],
              selected: {_section},
              onSelectionChanged: _selectSection,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _section == 'workOrders'
                  ? MasterDataTableView<ProductionExecutionWorkbenchSegment>(
                      columns: _workOrderColumns,
                      items: _workOrders,
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      selectable: _canReportLocally,
                      idOf: (row) =>
                          _canSelectWorkOrder(row) ? row.segmentId : null,
                      unselectableLeadingBuilder: _batchSelectionGate,
                      selectedIds: _canReportLocally
                          ? _selectedWorkOrderIds
                          : const <String>{},
                      onSelectedIdsChanged: _updateWorkOrderSelection,
                      batchActionsBuilder: (_, ids) => [
                        UtenButton(
                          icon: Icons.fact_check_outlined,
                          onPressed: ids.isEmpty
                              ? null
                              : () => _report(ids.toList(growable: false)),
                          child: Text('批量报工(${ids.length})'),
                        ),
                      ],
                      onRowTap: _openWorkOrder,
                      canOpenRow: (row) => row.planId.isNotEmpty,
                      rowMenuBuilder: (row) {
                        final reportIds = _contextReportIds(row);
                        return [
                          UtenMenuItem(
                            label: reportIds.length > 1
                                ? '批量报工(${reportIds.length})'
                                : '报工',
                            icon: Icons.fact_check_outlined,
                            enabled:
                                _canReportLocally &&
                                (reportIds.length == 1
                                    ? row.canReport
                                    : reportIds.every(
                                        _selectedWorkOrderIds.contains,
                                      )),
                            onTap: () => _report(reportIds),
                          ),
                          const UtenMenuDivider(),
                          UtenMenuItem(
                            label: '查看生产计划',
                            icon: Icons.open_in_new_rounded,
                            enabled: row.planId.isNotEmpty,
                            onTap: () => _openWorkOrder(row),
                          ),
                        ];
                      },
                      rowKeyOf: (row) => row.segmentId,
                      currentPage: _workOrderPage,
                      totalPages: _workOrderPages,
                      onPageChange: (page) {
                        _workOrderPage = page;
                        _load();
                      },
                      isLoading: _loading,
                      error: _error,
                      onRetry: _load,
                      emptyMessage: '该批次尚未形成正式工单',
                    )
                  : MasterDataTableView<
                      ProductionExecutionWorkbenchRelatedDocument
                    >(
                      columns: _documentColumns,
                      items: _documents,
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      onRowTap: _openDocument,
                      canOpenRow: (row) => row.canOpen,
                      rowKeyOf: (row) =>
                          '${row.documentType}:${row.documentId}',
                      currentPage: _documentPage,
                      totalPages: _documentPages,
                      onPageChange: (page) {
                        _documentPage = page;
                        _load();
                      },
                      isLoading: _loading,
                      error: _error,
                      onRetry: _load,
                      emptyMessage: '无当前账号可查看的关联单据',
                    ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
      ),
    );
  }

  List<MasterColumnDef<ProductionExecutionWorkbenchSegment>>
  get _workOrderColumns => [
    MasterColumnDef(
      key: 'executionStatus',
      label: '执行状态',
      width: 130,
      value: (row) => row.executionStatusLabel,
    ),
    MasterColumnDef(
      key: 'materialStatus',
      label: '物料/备料',
      width: 180,
      value: (row) => row.materialStatusLabel,
    ),
    MasterColumnDef(
      key: 'order',
      label: '关联订单',
      width: 180,
      value: (row) => row.salesOrderNos,
    ),
    MasterColumnDef(
      key: 'segment',
      label: '工单号',
      width: 160,
      value: (row) => row.segmentCode,
    ),
    MasterColumnDef(
      key: 'workshop',
      label: '生产车间',
      width: 150,
      value: (row) => row.workshopName,
    ),
    MasterColumnDef(
      key: 'code',
      label: '产品编号',
      width: 150,
      value: (row) => row.productCode,
    ),
    MasterColumnDef(
      key: 'name',
      label: '产品名称',
      width: 180,
      value: (row) => row.productName,
    ),
    MasterColumnDef(
      key: 'color',
      label: '产品颜色',
      width: 120,
      value: (row) => row.productColorName,
    ),
    MasterColumnDef(
      key: 'qty',
      label: '计划/有效报工/实收',
      width: 230,
      value: (row) =>
          '${row.plannedQty} / ${row.reportedQty} / ${row.inboundQty} '
          '${row.productUnitName ?? ''}',
    ),
    MasterColumnDef(
      key: 'quality',
      label: 'FQC待检/通过/失败/待点收',
      width: 250,
      value: (row) =>
          '${row.fqcPendingQty} / ${row.fqcPassedQty} / '
          '${row.fqcFailedQty} / ${row.finishedInboundPendingQty}',
    ),
    MasterColumnDef(
      key: 'action',
      label: '操作',
      width: 132,
      value: (row) =>
          _canReportLocally && row.canReport ? '报工' : row.blockedReason,
      cellBuilder: (_, row) => UtenButton(
        size: UtenButtonSize.small,
        icon: Icons.fact_check_outlined,
        onPressed: _canReportLocally && row.canReport
            ? () => _report([row.segmentId])
            : null,
        onDisabledTap: _canReportLocally && row.canReport
            ? null
            : () => context.appWarning(
                !_canReportLocally
                    ? '报工需要车间任务查看、生产日报查看和生产日报新建权限'
                    : row.blockedReason ?? '当前工单尚不可报工',
              ),
        child: const Text('报工'),
      ),
    ),
  ];

  Future<void> _report(List<String> segmentIds) async {
    if (!_canReportLocally) {
      context.appWarning('报工需要车间任务查看、生产日报查看和生产日报新建权限');
      return;
    }
    final ids = segmentIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .take(100)
        .toList(growable: false);
    if (ids.isEmpty) return;
    final requested = ids.toSet();
    final workshops = _workOrders
        .where((row) => requested.contains(row.segmentId))
        .map(_workshopKey)
        .where((value) => value.isNotEmpty)
        .toSet();
    if (workshops.length > 1) {
      context.appWarning('一次报工只能包含同一生产车间，请分车间办理');
      return;
    }
    final uri = Uri(
      path: RoutePath.productionDailyReportNew(),
      queryParameters: ids.length == 1
          ? {'executionSegmentId': ids.single}
          : {'executionSegmentIds': ids.join(',')},
    );
    Navigator.pop(context, uri.toString());
  }

  Future<void> _openWorkOrder(
    ProductionExecutionWorkbenchSegment workOrder,
  ) async {
    if (workOrder.planId.isEmpty) {
      context.appWarning('当前工单缺少生产计划关联，请刷新后重试');
      return;
    }
    Navigator.pop(context, RoutePath.productionPlanDetail(workOrder.planId));
  }

  List<MasterColumnDef<ProductionExecutionWorkbenchRelatedDocument>>
  get _documentColumns => [
    MasterColumnDef(
      key: 'type',
      label: '单据类型',
      width: 180,
      value: (row) => switch (row.documentType) {
        'PURCHASE_REQUEST' => '采购申请',
        'PURCHASE_ORDER' => '采购订货',
        'SUBCONTRACT_APPLICATION' => '委外申请',
        'SUBCONTRACT_ORDER' => '委外订货',
        'PRODUCTION_PLAN' => '生产计划',
        _ => row.documentType,
      },
    ),
    MasterColumnDef(
      key: 'number',
      label: '单号',
      width: 220,
      value: (row) => row.documentNo,
    ),
    MasterColumnDef(
      key: 'route',
      label: '供给路线',
      width: 140,
      value: (row) => row.route,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 120,
      value: (row) => row.status,
    ),
  ];

  void _openDocument(ProductionExecutionWorkbenchRelatedDocument document) {
    if (!document.canOpen || document.documentId.isEmpty) return;
    final route = switch (document.documentType) {
      'PURCHASE_REQUEST' => RoutePath.purchaseDocDetail(
        'requests',
        document.documentId,
      ),
      'PURCHASE_ORDER' => RoutePath.purchaseDocDetail(
        'orders',
        document.documentId,
      ),
      'SUBCONTRACT_APPLICATION' => RoutePath.subcontractDocDetail(
        'applications',
        document.documentId,
      ),
      'SUBCONTRACT_ORDER' => RoutePath.subcontractDocDetail(
        'orders',
        document.documentId,
      ),
      'PRODUCTION_PLAN' => RoutePath.productionPlanDetail(document.documentId),
      _ => null,
    };
    if (route == null) return;
    Navigator.pop(context, route);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_execution_workbench.dart';
import '../providers/production_workshop_task_count_provider.dart';
import '../repositories/production_execution_workbench_repository.dart';

class ProductionWorkshopTasksPage extends ConsumerStatefulWidget {
  const ProductionWorkshopTasksPage({super.key});

  @override
  ConsumerState<ProductionWorkshopTasksPage> createState() =>
      _ProductionWorkshopTasksPageState();
}

class _ProductionWorkshopTasksPageState
    extends ConsumerState<ProductionWorkshopTasksPage> {
  List<ProductionExecutionWorkbenchSegment> _items = const [];
  final Set<String> _selected = {};
  bool _navigating = false;
  String _keyword = '';
  String? _status;
  int _page = 1;
  int _totalPages = 0;
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  bool get _canCreateReport {
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

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final requestedPage = _page;
    final requestedKeyword = _keyword;
    final requestedStatus = _status;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionExecutionWorkbenchRepositoryProvider)
          .workshopTasks(
            page: requestedPage,
            keyword: requestedKeyword,
            status: requestedStatus,
          );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _items = result.items;
        _page = result.page;
        _totalPages = result.totalPages;
        final available = _items
            .where((item) => item.canBatchReport)
            .map((item) => item.segmentId)
            .toSet();
        _selected.removeWhere((id) => !available.contains(id));
      });
      ref.read(productionWorkshopTaskCountProvider.notifier).refresh();
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = '车间任务加载失败，请重试');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _report(List<String> segmentIds) async {
    if (!_canCreateReport || segmentIds.isEmpty || _navigating) return;
    final requested = segmentIds.toSet();
    final workshops = _items
        .where((task) => requested.contains(task.segmentId))
        .map(_workshopKey)
        .where((value) => value.isNotEmpty)
        .toSet();
    if (workshops.length > 1) {
      context.appWarning('一次报工只能包含同一生产车间，请分车间办理', force: true);
      return;
    }
    final encoded = Uri.encodeQueryComponent(segmentIds.join(','));
    final path = segmentIds.length == 1
        ? '/production/daily-reports/new?executionSegmentId=$encoded'
        : '/production/daily-reports/new?executionSegmentIds=$encoded';
    setState(() => _navigating = true);
    try {
      await context.push(path);
      if (!mounted) return;
      setState(_selected.clear);
      await _load();
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  Future<void> _runPrimary(ProductionExecutionWorkbenchSegment task) async {
    if (task.canReport) {
      await _report([task.segmentId]);
      return;
    }
    context.appWarning(task.blockedReason ?? '当前任务尚不可操作');
  }

  Future<void> _openPlan(ProductionExecutionWorkbenchSegment task) async {
    if (_navigating) return;
    if (task.planId.isEmpty) {
      context.appWarning('当前工单缺少生产计划关联，请刷新后重试');
      return;
    }
    setState(() => _navigating = true);
    try {
      await context.push(RoutePath.productionPlanDetail(task.planId));
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  String _workshopKey(ProductionExecutionWorkbenchSegment task) =>
      task.workshopDepartmentId ?? task.workshopName ?? '';

  bool _canSelectForBatch(ProductionExecutionWorkbenchSegment task) {
    if (!_canCreateReport || !task.canBatchReport) return false;
    if (_selected.contains(task.segmentId) || _selected.isEmpty) return true;
    final selectedWorkshop = _items
        .where((item) => _selected.contains(item.segmentId))
        .map(_workshopKey)
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    return selectedWorkshop == null || _workshopKey(task) == selectedWorkshop;
  }

  void _updateBatchSelection(Set<String> requested) {
    if (requested.isEmpty) {
      setState(_selected.clear);
      return;
    }
    final requestedRows = [
      for (final task in _items)
        if (requested.contains(task.segmentId) && task.canBatchReport) task,
    ];
    if (requestedRows.isEmpty) return;
    final currentWorkshop = _items
        .where((task) => _selected.contains(task.segmentId))
        .map(_workshopKey)
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    final workshop = currentWorkshop ?? _workshopKey(requestedRows.first);
    final accepted = requestedRows
        .where((task) => _workshopKey(task) == workshop)
        .map((task) => task.segmentId)
        .toSet();
    setState(() {
      _selected
        ..clear()
        ..addAll(accepted);
    });
    if (accepted.length != requested.length) {
      context.appWarning('一次批量报工只能选择同一生产车间；其它车间工单未选中');
    }
  }

  List<String> _contextReportIds(ProductionExecutionWorkbenchSegment task) {
    if (_selected.contains(task.segmentId) && _selected.length > 1) {
      return _selected.toList(growable: false);
    }
    return [task.segmentId];
  }

  String _statusLabel(ProductionExecutionWorkbenchSegment task) =>
      task.segmentStatus == 'IN_PROGRESS'
      ? '生产中 · ${task.materialStatusLabel}'
      : task.materialStatusLabel;

  Widget _batchSelectionGate(
    BuildContext context,
    ProductionExecutionWorkbenchSegment task,
  ) {
    final message = !_canCreateReport
        ? '报工需要车间任务查看、生产日报查看和生产日报新建权限'
        : !task.canBatchReport
        ? (task.blockedReason ?? '当前工单不能加入批量报工')
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
  Widget build(BuildContext context) {
    // Route access, report creation and server row capabilities are separate
    // gates. Watch both providers so a live grant/revoke updates actions now.
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '我的车间任务',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenFilterToolbar<String>(
                  segments: const [
                    UtenFilterSegment(value: 'PREPARING', label: '备料中'),
                    UtenFilterSegment(
                      value: 'READY_TO_REPORT',
                      label: '备料完毕 / 可报工',
                    ),
                    UtenFilterSegment(value: 'IN_PROGRESS', label: '已报工跟进'),
                  ],
                  selected: _status == null ? const {} : {_status!},
                  onSelectionChanged: (value) {
                    setState(() {
                      _status = value;
                      _page = 1;
                      _selected.clear();
                    });
                    _load();
                  },
                  searchHint: '搜索订单 / 工单 / 产品 / 车间',
                  onSearchChanged: (value) {
                    _keyword = value.trim();
                    _page = 1;
                    _load();
                  },
                ),
                const SizedBox(height: UtenSpacing.s8),
                Expanded(
                  child:
                      MasterDataTableView<ProductionExecutionWorkbenchSegment>(
                        columns: _columns,
                        items: _items,
                        facets: const {},
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                        selectable: _canCreateReport,
                        idOf: (task) =>
                            _canSelectForBatch(task) ? task.segmentId : null,
                        unselectableLeadingBuilder: _batchSelectionGate,
                        rowKeyOf: (task) => task.segmentId,
                        selectedIds: _canCreateReport
                            ? _selected
                            : const <String>{},
                        onSelectedIdsChanged: _updateBatchSelection,
                        batchActionsBuilder: (_, ids) => [
                          UtenButton(
                            icon: Icons.fact_check_outlined,
                            onPressed: ids.isEmpty || _navigating
                                ? null
                                : () => _report(ids.toList()),
                            child: Text('批量报工(${ids.length})'),
                          ),
                        ],
                        rowMenuBuilder: (task) {
                          final reportIds = _contextReportIds(task);
                          return [
                            UtenMenuItem(
                              label: reportIds.length > 1
                                  ? '批量报工(${reportIds.length})'
                                  : '报工',
                              icon: Icons.fact_check_outlined,
                              enabled:
                                  _canCreateReport &&
                                  (reportIds.length == 1
                                      ? task.canReport
                                      : reportIds.every(
                                          (id) => _selected.contains(id),
                                        )),
                              onTap: () => _report(reportIds),
                            ),
                            const UtenMenuDivider(),
                            UtenMenuItem(
                              label: '查看生产计划',
                              icon: Icons.open_in_new_rounded,
                              onTap: () => _openPlan(task),
                            ),
                          ];
                        },
                        onRowTap: _openPlan,
                        canOpenRow: (task) => task.planId.isNotEmpty,
                        currentPage: _page,
                        totalPages: _totalPages,
                        onPageChange: (page) {
                          _page = page;
                          _load();
                        },
                        isLoading: _loading,
                        error: _error,
                        onRetry: _load,
                        emptyMessage: '当前车间没有待处理工单',
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<MasterColumnDef<ProductionExecutionWorkbenchSegment>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 190,
      value: (task) =>
          '${task.executionStatusLabel} · ${task.materialStatusLabel}',
      cellBuilder: (_, task) => UtenStatusBadge(
        label: _statusLabel(task),
        type: task.segmentStatus == 'IN_PROGRESS'
            ? UtenStatusBadgeType.info
            : task.issued
            ? UtenStatusBadgeType.success
            : UtenStatusBadgeType.warning,
      ),
    ),
    MasterColumnDef(
      key: 'order',
      label: '关联订单',
      width: 180,
      value: (task) => task.salesOrderNos,
    ),
    MasterColumnDef(
      key: 'segment',
      label: '工单号',
      width: 160,
      value: (task) => task.segmentCode,
    ),
    MasterColumnDef(
      key: 'workshop',
      label: '生产车间',
      width: 150,
      value: (task) => task.workshopName,
    ),
    MasterColumnDef(
      key: 'code',
      label: '产品编号',
      width: 150,
      value: (task) => task.productCode,
    ),
    MasterColumnDef(
      key: 'name',
      label: '产品名称',
      width: 180,
      value: (task) => task.productName,
    ),
    MasterColumnDef(
      key: 'color',
      label: '产品颜色',
      width: 120,
      value: (task) => task.productColorName,
    ),
    MasterColumnDef(
      key: 'qty',
      label: '产品数量',
      width: 130,
      type: 'number',
      value: (task) => '${task.plannedQty} ${task.productUnitName ?? ''}',
    ),
    MasterColumnDef(
      key: 'progress',
      label: '报工/FQC/实收',
      width: 240,
      value: (task) =>
          '${task.reportedQty} / ${task.fqcPassedQty} / ${task.inboundQty}',
    ),
    MasterColumnDef(
      key: 'action',
      label: '操作',
      width: 150,
      value: (task) => task.canReport ? '报工' : task.blockedReason,
      cellBuilder: (_, task) {
        final busy = _navigating;
        final enabled = !busy && task.canReport;
        return UtenButton(
          size: UtenButtonSize.small,
          icon: Icons.fact_check_outlined,
          onPressed: enabled ? () => _runPrimary(task) : null,
          onDisabledTap: busy
              ? null
              : () => context.appWarning(task.blockedReason ?? '当前工单尚不可报工'),
          child: const Text('报工'),
        );
      },
    ),
  ];
}

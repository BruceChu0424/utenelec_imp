// 我的车间任务（车间视角的执行工单办理台）。
//
// 2026-09-06 改版（用户口径）：分类收敛为 等待物料｜生产中｜历史任务——
//  - 等待物料 = 全部未开工段（WAITING 等料 + READY/DISPATCHED 物料齐套·可开工）；
//    齐套行可勾选，右下角「批量开工(N)」（按计划分组提交，服务端原子校验
//    齐套/完整分配/领料完成）；未齐行点击给出明确原因（物料未入库/库存不足、
//    仓库尚未完成备料出库等），双击进计划详情单独办理；
//  - 生产中 = 正在生产·可报工：进度列只在本分类显示；勾选后「批量报工(N)」
//    （一次报工=同一车间，服务端同口径校验）；
//  - 「可报工」分类退役（齐套可开工归等待物料、报工归生产中）；历史任务=已完工。
// 报工入口唯一（本页 + 计划详情），调度台不再提供报工。
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
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../providers/production_execution_refresh.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_execution_workbench.dart';
import '../models/production_flow_stage.dart';
import '../providers/production_department_provider.dart';
import '../providers/production_workshop_task_count_provider.dart';
import '../repositories/production_execution_workbench_repository.dart';
import '../repositories/production_repository.dart';
import '../widgets/production_flow_stage_cell.dart';
import '../widgets/production_material_settlement_sheet.dart';

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
  String? _workshopDepartmentId;
  int _page = 1;
  int _totalPages = 0;
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  bool get _canStart {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.productionExecutionStart);
  }

  bool get _canCreateReport {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionExecutionView) &&
        permissions.contains(Perm.productionDailyReportView) &&
        permissions.contains(Perm.productionDailyReportCreate);
  }

  bool get _canConfirmMaterialUsage =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionMaterialSettle);

  /// 当前分类是否「等待物料」（未开工段：等料 + 齐套可开工）。
  bool get _isPreparing => _status == 'PREPARING';

  /// 行是否可开工：物料齐套（READY/DISPATCHED）即可勾选开工——领料是否
  /// 全部完成由服务端开工门禁复核，未完成会给出明确报错。
  bool _canStartTask(ProductionExecutionWorkbenchSegment task) =>
      (task.segmentStatus == 'READY' || task.segmentStatus == 'DISPATCHED') &&
      (task.issued || task.zeroMaterial);

  /// 未开工行点击/勾选受限的明确原因（物料未入库、库存不足、备料未完成等）。
  String _blockedReasonOf(ProductionExecutionWorkbenchSegment task) {
    final reason = task.blockedReason?.trim();
    if (reason != null && reason.isNotEmpty) return reason;
    if (task.materialStatus == 'KIT_SHORT') {
      return '物料尚未齐套：采购/委外未入库或仓库库存不足，无法开工';
    }
    if (task.segmentStatus == 'WAITING') return '物料尚未齐套，无法开工';
    return '仓库尚未完成全部备料出库，暂不能开工';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    // 分类默认不选（ADR-066 同范式）：未选分类不请求列表、不显示数据，
    // 只刷新顶部分类徽章计数；点了分类才加载对应内容。
    if (_status == null) {
      setState(() {
        _items = const [];
        _page = 1;
        _totalPages = 0;
        _error = null;
        _loading = false;
        _selected.clear();
      });
      ref.read(productionWorkshopTaskCountProvider.notifier).refresh();
      return;
    }
    final requestedPage = _page;
    final requestedKeyword = _keyword;
    final requestedStatus = _status;
    final requestedWorkshop = _workshopDepartmentId;
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
            workshopDepartmentId: requestedWorkshop,
          );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _items = result.items;
        _page = result.page;
        _totalPages = result.totalPages;
        final available = _items
            .where(_selectableTask)
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

  /// 当前分类下可勾选的行：等待物料=齐套可开工；生产中=可报工；历史=不可选。
  bool _selectableTask(ProductionExecutionWorkbenchSegment task) => _isPreparing
      ? _canStartTask(task)
      : task.segmentStatus == 'IN_PROGRESS' && task.canBatchReport;

  /// 批量开工：按计划分组提交（计划内原子；跨计划串行）。全部完成后刷新，
  /// 部分失败时保留失败项的选择并提示首个原因。
  Future<void> _startSelected() async {
    if (!_canStart || _selected.isEmpty || _navigating) return;
    final targets = _items
        .where(
          (task) => _selected.contains(task.segmentId) && _canStartTask(task),
        )
        .toList(growable: false);
    if (targets.isEmpty) return;
    final byPlan = <String, List<ProductionExecutionWorkbenchSegment>>{};
    for (final task in targets) {
      byPlan.putIfAbsent(task.planId, () => []).add(task);
    }
    setState(() => _navigating = true);
    var started = 0;
    String? firstError;
    try {
      for (final entry in byPlan.entries) {
        try {
          await ref
              .read(productionPlanRepositoryProvider)
              .batchStartExecutionSegments(
                entry.key,
                items: [
                  for (final task in entry.value)
                    (
                      segmentId: task.segmentId,
                      expectedVersion: task.lockVersion,
                    ),
                ],
              );
          started += entry.value.length;
        } catch (error) {
          firstError ??= productionErrorMessage(error, fallback: '开工失败，请刷新后重试');
        }
      }
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
    if (!mounted) return;
    if (started > 0) {
      context.appSuccess('已开工 $started 个工单，请在「生产中」分类报工');
    }
    if (firstError != null) {
      context.appError(
        '部分工单开工失败（已开工 $started / ${targets.length}）：$firstError',
        force: true,
      );
    }
    setState(_selected.clear);
    await _load();
  }

  Future<void> _recheckMaterials(
    ProductionExecutionWorkbenchSegment task,
  ) async {
    if (!_canStart || !task.canRecheckMaterial || _navigating) return;
    setState(() => _navigating = true);
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .recheckExecutionSegmentMaterials(
            task.planId,
            task.segmentId,
            expectedVersion: task.lockVersion,
          );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      if (result.status == 'READY') {
        context.appSuccess(l10n.productionMaterialRecheckReady);
      } else {
        context.appInfo(l10n.productionMaterialRecheckWaiting);
      }
      await _load();
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  /// 报工入口唯一：勾选后右下角悬浮「批量报工(N)」进入汇总报工页，
  /// 一次提交（服务端口径：一次报工=同一车间；跨车间选择在这里给明确提示）。
  Future<void> _reportSelected() async {
    if (!_canCreateReport || _selected.isEmpty || _navigating) return;
    final requested = _selected.toList(growable: false);
    final workshops = _items
        .where((task) => requested.contains(task.segmentId))
        .map((task) => task.workshopDepartmentId ?? task.workshopName ?? '')
        .where((value) => value.isNotEmpty)
        .toSet();
    if (workshops.length > 1) {
      context.appWarning('一次报工只能包含同一生产车间；请先用表头的生产车间筛选分车间报工', force: true);
      return;
    }
    final encoded = Uri.encodeQueryComponent(requested.join(','));
    final path = requested.length == 1
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

  Future<void> _openPlan(ProductionExecutionWorkbenchSegment task) async {
    if (_navigating) return;
    // 等待物料分类里未齐的行：双击不跳详情，先把「为什么不能开工」说清楚
    //（物料未入库 / 库存不足 / 备料未完成）——点了必须有反馈。
    if (_isPreparing && !_canStartTask(task)) {
      context.appInfo(_blockedReasonOf(task));
      return;
    }
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

  Future<void> _openMaterialUsage(
    ProductionExecutionWorkbenchSegment task,
  ) async {
    if (_navigating || task.planId.isEmpty || task.segmentId.isEmpty) return;
    final permissions = ref.read(currentPermissionsProvider);
    final admin = ref.read(isSuperAdminProvider);
    setState(() => _navigating = true);
    try {
      await showProductionMaterialSettlementSheet(
        context,
        ref,
        planId: task.planId,
        executionSegmentId: task.segmentId,
        canSettle: admin || permissions.contains(Perm.productionMaterialSettle),
        canReverse:
            admin || permissions.contains(Perm.productionMaterialReverse),
        // Closing changes a whole plan; a workshop task only grants its exact material rows.
        canClose: false,
      );
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  /// 状态列：全站统一流程词表（等待物料/物料齐套·可开工/生产中%/已完工）。
  ProductionFlowStage _flowStageOf(ProductionExecutionWorkbenchSegment task) =>
      ProductionFlowStage.forSegment(
        segmentStatus: task.segmentStatus,
        zeroMaterial: task.zeroMaterial,
        materialIssued: task.issued,
        reportedQty: task.reportedQty,
        plannedQty: task.plannedQty,
      );

  @override
  Widget build(BuildContext context) {
    ref.listen(listRefreshTickProvider(productionExecutionRefreshKey), (_, _) {
      if (!_navigating) _load();
    });
    ref.onPageResume(RouteName.productionWorkshopTasks, () {
      if (!_navigating) _load();
    });
    // Route access, report creation and server row capabilities are separate
    // gates. Watch both providers so a live grant/revoke updates actions now.
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    // 顶部分类徽章：与列表/服务端分段计数同源（互斥口径，加总=总数）；
    // 「历史任务」是终态，按全站口径不挂徽章。
    final counts = ref.watch(productionWorkshopTaskCountProvider);
    final workshops =
        ref.watch(productionWorkshopTreeProvider).valueOrNull ?? const [];
    return Scaffold(
      appBar: UtenAppBar(
        title: '我的车间任务',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            // 整页刷新：回第 1 页重拉（关键词/状态/车间筛选保留）。
            onPressed: _loading
                ? null
                : () {
                    setState(() => _page = 1);
                    _load();
                  },
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
                // 分类（等待物料=等料+齐套可开工｜生产中=正在生产可报工｜历史任务）
                // 与搜索：全站标准工具条。车间筛选在表格「生产车间」列表头。
                UtenFilterToolbar<String>(
                  segments: [
                    UtenFilterSegment(
                      value: 'PREPARING',
                      label: '等待物料',
                      count: counts.preparing,
                    ),
                    UtenFilterSegment(
                      value: 'IN_PROGRESS',
                      label: '生产中',
                      count: counts.inProgress,
                    ),
                    const UtenFilterSegment(value: 'COMPLETED', label: '历史任务'),
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
                  // 分类默认不选：引导占位不发请求（与调度台大类行同范式）。
                  child: _status == null
                      ? const UtenFilterPlaceholder(
                          message: '在上方选择分类后查看任务',
                          description: '分类默认不选中；等待物料 / 生产中 / 历史任务',
                        )
                      : MasterDataTableView<
                          ProductionExecutionWorkbenchSegment
                        >(
                          columns: _columnsFor(_status!),
                          items: _items,
                          // 车间筛选在表头（生产车间列下拉，与状态值筛选同范式）；
                          // 选项来自生产车间树，选中后整页按车间重拉。
                          facets: {
                            'workshop': [
                              for (final workshop in workshops)
                                MasterFacetBucket(
                                  value: workshop.id,
                                  label: workshop.name,
                                  count: 0,
                                ),
                            ],
                          },
                          nullCounts: const {},
                          filters: {'workshop': ?_workshopDepartmentId},
                          onFilterChanged: (key, value) {
                            if (key != 'workshop') return;
                            setState(() {
                              _workshopDepartmentId =
                                  value == null || value.isEmpty ? null : value;
                              _page = 1;
                              _selected.clear();
                            });
                            _load();
                          },
                          selectable: _selectable,
                          idOf: (task) => _selectable && _selectableTask(task)
                              ? task.segmentId
                              : null,
                          rowKeyOf: (task) => task.segmentId,
                          // 未齐行的勾选位换成带原因的锁图标（悬停/长按可见），
                          // 不再呈现一个永远点不动的空复选框。
                          unselectableLeadingBuilder: (context, task) =>
                              Tooltip(
                                message: _blockedReasonOf(task),
                                child: Icon(
                                  Icons.lock_outline_rounded,
                                  size: 20,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                          selectedIds: _selectable
                              ? _selected
                              : const <String>{},
                          onSelectedIdsChanged: (requested) {
                            setState(() {
                              _selected
                                ..clear()
                                ..addAll(
                                  requested.where(
                                    (id) => _items.any(
                                      (task) =>
                                          task.segmentId == id &&
                                          _selectableTask(task),
                                    ),
                                  ),
                                );
                            });
                          },
                          batchActionsBuilder: (_, ids) => [
                            if (_isPreparing)
                              UtenButton(
                                icon: Icons.play_circle_fill_rounded,
                                onPressed: ids.isEmpty || _navigating
                                    ? null
                                    : _startSelected,
                                child: Text('批量开工(${ids.length})'),
                              )
                            else
                              UtenButton(
                                icon: Icons.fact_check_outlined,
                                onPressed: ids.isEmpty || _navigating
                                    ? null
                                    : _reportSelected,
                                child: Text('批量报工(${ids.length})'),
                              ),
                          ],
                          rowMenuBuilder: (task) => [
                            UtenMenuItem(
                              label: '物料使用情况',
                              icon: Icons.fact_check_outlined,
                              enabled: !_navigating,
                              onTap: () => _openMaterialUsage(task),
                            ),
                            if (_canStart && task.canRecheckMaterial)
                              UtenMenuItem(
                                label: AppLocalizations.of(
                                  context,
                                ).productionMaterialRecheck,
                                icon: Icons.fact_check_outlined,
                                enabled: !_navigating,
                                onTap: () => _recheckMaterials(task),
                              ),
                            if (_isPreparing && _canStartTask(task))
                              UtenMenuItem(
                                label: '查看生产计划（可单独开工）',
                                icon: Icons.open_in_new_rounded,
                                onTap: () => _openPlan(task),
                              )
                            else if (_isPreparing)
                              UtenMenuItem(
                                label: '为什么不能开工',
                                icon: Icons.help_outline_rounded,
                                onTap: () =>
                                    context.appInfo(_blockedReasonOf(task)),
                              )
                            else
                              UtenMenuItem(
                                label: '查看生产计划',
                                icon: Icons.open_in_new_rounded,
                                onTap: () => _openPlan(task),
                              ),
                          ],
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
                          emptyMessage: _isPreparing
                              ? '当前车间没有等待物料的工单'
                              : _status == 'IN_PROGRESS'
                              ? '当前车间没有生产中的工单'
                              : '该时间段内没有已完工工单',
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 分类是否可勾选（等待物料=有开工权限；生产中=有报工三码；历史=不可选）。
  bool get _selectable =>
      _isPreparing ? _canStart : (_status == 'IN_PROGRESS' && _canCreateReport);

  /// 列随分类变化（2026-09-06 用户口径）：进度列只在「生产中」显示——
  /// 等待物料阶段没有报工进度可言，历史任务已完工无需再看进度条。
  List<MasterColumnDef<ProductionExecutionWorkbenchSegment>> _columnsFor(
    String status,
  ) => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 190,
      value: (task) => _flowStageOf(task).displayLabel,
      cellBuilder: (_, task) {
        final stage = _flowStageOf(task);
        return UtenStatusBadge(
          label: stage.displayLabel,
          type: productionFlowBadgeType(stage),
        );
      },
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
      width: 170,
      value: (task) => task.workshopName,
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
    if (status == 'IN_PROGRESS')
      MasterColumnDef(
        key: 'progress',
        label: '进度',
        width: 220,
        value: (task) {
          final ratio = task.reportProgressRatio;
          return ratio == null ? '—' : '报工 ${(ratio * 100).round()}%';
        },
        cellBuilder: (_, task) => ProductionFlowProgress(
          ratio: task.reportProgressRatio,
          semanticsLabel: '报工进度',
        ),
      ),
    MasterColumnDef(
      key: 'materialUsage',
      label: '物料使用',
      width: 140,
      value: (_) => '',
      cellBuilder: (_, task) => TextButton.icon(
        key: ValueKey('workshop-material-usage-${task.segmentId}'),
        onPressed: _navigating ? null : () => _openMaterialUsage(task),
        icon: const Icon(Icons.fact_check_outlined, size: 18),
        label: Text(_canConfirmMaterialUsage ? '确认用料' : '查看用料'),
      ),
    ),
  ];
}

// 我的车间任务（车间视角的执行工单办理台）。
//
// 2026-09-06 改版（用户口径）：分类收敛为 等待物料｜生产中｜历史任务——
//  - 等待物料 = 全部未开工段（WAITING 等料 + READY/DISPATCHED 物料齐套·可开工）；
//    齐套未提交行可勾选进入「批量领料」汇总，明确提交后仓库才接到任务；
//    实际领料完成行可「批量开工」，服务端复核齐套/分配/领料完成。
//    未齐行点击给出明确原因（物料未入库/库存不足、
//    仓库尚未完成备料出库等），双击进计划详情单独办理；
//  - 生产中 = 正在生产·可报工：进度列只在本分类显示；勾选后「批量报工(N)」
//    （一次报工=同一车间，服务端同口径校验）；
//  - 「可报工」分类退役（齐套可开工归等待物料、报工归生产中）；
//  - 历史任务 = 终态段（已完工/已取消/已红冲），ADR-066 §1.3 时间门控：选中后
//    先选时间段/全部才加载（按计划完工日期 dateFrom/dateTo）。
// 报工入口唯一（本页 + 计划详情），调度台不再提供报工。
// 2026-09-10（V543 车间默认权限收紧二）：车间默认包不再含 production_plan:view，
// 「查看生产计划」行菜单/双击只对持该码（或超管）的人开放，其余人给明确提示，
// 用「确认用料/物料使用情况」看本工单（此前直接落到 /access-denied）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../providers/production_execution_refresh.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_execution_workbench.dart';
import '../models/production_flow_stage.dart';
import '../models/production_material_usage_source.dart';
import '../providers/production_department_provider.dart';
import '../providers/production_workshop_task_count_provider.dart';
import '../repositories/production_execution_workbench_repository.dart';
import '../repositories/production_repository.dart';
import '../repositories/production_material_repository.dart';
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
  String? _preparationFilter;
  String? _workshopDepartmentId;
  int _page = 1;
  int _totalPages = 0;
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  /// 历史任务段的时间门控值（ADR-066 §1.3）：未选不请求、显示引导占位。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  /// 当前分类是否「历史任务」（终态段：已完工/已取消/已红冲）。
  bool get _isHistory => _status == 'COMPLETED';

  /// 「查看生产计划」入口：计划详情路由守卫与后端 GET /plans/{id} 均要求
  /// production_plan:view；车间默认包（V541/V543）不含该码，只对显式加授者开放。
  bool get _canViewPlan =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanView);

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

  bool get _canRegisterMaterialUsage =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionMaterialSettle);

  String _materialUsageLabel(ProductionExecutionWorkbenchSegment task) {
    final l10n = AppLocalizations.of(context);
    if (task.hasPendingReturn && !task.hasAvailableMaterial) return '查看退料进度';
    // 2026-09-12 用户口径：「登记实际用料」只在生产中分类出现；等待物料行即便
    // 带未登记标记，也只给只读「查看物料使用情况」。
    final canRegister =
        _status == 'IN_PROGRESS' &&
        _canRegisterMaterialUsage &&
        (task.hasUnregisteredMaterial || task.hasSharedMaterialActivity);
    return canRegister
        ? l10n.productionMaterialRegisterUsage
        : l10n.productionMaterialViewUsage;
  }

  /// 当前分类是否「等待物料」（未开工段：等料 + 齐套可开工）。
  bool get _isPreparing => _status == 'PREPARING';

  /// 实物领齐后才能开工；齐套但未发料走独立的领料申请。
  bool _canStartTask(ProductionExecutionWorkbenchSegment task) =>
      (task.segmentStatus == 'READY' || task.segmentStatus == 'DISPATCHED') &&
      (task.issued || task.zeroMaterial);

  bool _canRequestDrawTask(ProductionExecutionWorkbenchSegment task) =>
      task.canRequestDraw &&
      !task.issued &&
      !task.zeroMaterial &&
      (task.segmentStatus == 'READY' || task.segmentStatus == 'DISPATCHED');

  /// 未开工行点击/勾选受限的明确原因（物料未入库、库存不足、备料未完成等）。
  String _blockedReasonOf(ProductionExecutionWorkbenchSegment task) {
    if (task.canSplitBatch) {
      return '本任务尚未全部齐套，可点击「分批领料」核对现有物料能配齐的生产数量；每批实际领齐后再开工';
    }
    if (task.segmentStatus == 'IN_PROGRESS') {
      if (task.remainingReportQty <= 0.000001) {
        return '${_flowStageOf(task).label}；当前可报数量为 0，不能重复报工';
      }
      return task.blockedReason ?? '当前工单暂不能批量报工，请打开详情查看来源';
    }
    if (task.materialStatus == 'KIT_SHORT') {
      return '子件还没全部备齐，打开任务可以查看缺少的物料和进度';
    }
    if (task.segmentStatus == 'WAITING') {
      return '正在核对备料，打开任务可以查看各项物料的进度';
    }
    if (!task.issued && !task.zeroMaterial) {
      return task.drawRequested
          ? '已提交领料，仓库完成全部实物发料后即可开工'
          : '物料已齐，请勾选后点击「批量领料」，核对汇总并提交；领料完成后即可开工';
    }
    final reason = task.blockedReason?.trim();
    if (reason != null && reason.isNotEmpty) return reason;
    return '当前任务暂不能开工，请打开任务查看详情';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    // 分类默认不选（ADR-066 同范式）：未选分类不请求列表、不显示数据，
    // 只刷新顶部分类徽章计数；点了分类才加载对应内容。历史任务段同理：
    // 未选时间段/全部不发请求（时间门控占位）。
    if (_status == null || (_isHistory && _historyTime.isNone)) {
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
    final requestedPreparationFilter = _isPreparing ? _preparationFilter : null;
    final requestedWorkshop = _workshopDepartmentId;
    final range = _isHistory ? _historyTime.range : null;
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
            preparationFilter: requestedPreparationFilter,
            workshopDepartmentId: requestedWorkshop,
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
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

  /// 等待物料可选待提交领料或已领齐可开工行；两个动作分别计算有效选择。
  bool _selectableTask(ProductionExecutionWorkbenchSegment task) => _isPreparing
      ? _canRequestDrawTask(task) || _canStartTask(task)
      : task.segmentStatus == 'IN_PROGRESS' && task.canBatchReport;

  Future<void> _requestDraw(
    List<ProductionExecutionWorkbenchSegment> tasks,
  ) async {
    if (!_canStart || _navigating || tasks.isEmpty) return;
    if (tasks.length > 50) {
      context.appWarning('一次最多选择 50 个工单领料');
      return;
    }
    if (tasks.map((task) => task.workshopDepartmentId).toSet().length > 1) {
      context.appWarning('一次领料只能包含同一生产车间；请用生产车间表头筛选后分别领料');
      return;
    }
    final path = Uri(
      path: RouteName.productionDrawRequest,
      queryParameters: {
        'segmentIds': tasks.map((task) => task.segmentId).join(','),
        'versions': tasks.map((task) => task.lockVersion).join(','),
      },
    ).toString();
    setState(() => _navigating = true);
    try {
      final submitted = await context.push<bool>(path);
      if (!mounted) return;
      if (submitted == true) {
        setState(
          () => _selected.removeAll(tasks.map((task) => task.segmentId)),
        );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  Future<void> _prepareBatch(ProductionExecutionWorkbenchSegment task) async {
    if (!_canStart || !task.canSplitBatch || _navigating || _loading) return;
    setState(() => _navigating = true);
    try {
      final result = await context.push<bool>(
        Uri(
          path: RouteName.productionBatchDraw,
          queryParameters: {
            'segmentId': task.segmentId,
            'version': '${task.lockVersion}',
          },
        ).toString(),
      );
      if (!mounted) return;
      if (result == true) setState(() => _selected.remove(task.segmentId));
      await _load();
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  /// 批量开工：按计划分组提交（计划内原子；跨计划串行）。全部完成后刷新，
  /// 部分失败时保留失败项的选择并提示首个原因。
  Future<void> _startSelected() async {
    if (!_canStart || _selected.isEmpty || _navigating) return;
    final targets = _items
        .where(
          (task) => _selected.contains(task.segmentId) && _canStartTask(task),
        )
        .toList(growable: false);
    await _startTasks(targets);
  }

  Future<void> _startTasks(
    List<ProductionExecutionWorkbenchSegment> targets,
  ) async {
    if (!_canStart || _navigating || targets.isEmpty) return;
    final byPlan = <String, List<ProductionExecutionWorkbenchSegment>>{};
    for (final task in targets) {
      byPlan.putIfAbsent(task.planId, () => []).add(task);
    }
    setState(() => _navigating = true);
    var started = 0;
    final startedIds = <String>{};
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
          startedIds.addAll(entry.value.map((task) => task.segmentId));
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
    setState(() => _selected.removeAll(startedIds));
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
    // Waiting tasks still need their child-material progress and related documents.
    // Opening a detail does not grant permission to start or issue materials.
    if (task.planId.isEmpty) {
      context.appWarning('当前工单缺少生产计划关联，请刷新后重试');
      return;
    }
    // 计划详情路由守卫 + 后端 GET /plans/{id} 都要求 production_plan:view；
    // 没有该码直接 push 只会落到 /access-denied，改为明确提示。
    if (!_canViewPlan) {
      context.appWarning('无生产计划查看权限，请用「确认用料/物料使用情况」查看本工单');
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

  Future<void> _openTaskDetail(ProductionExecutionWorkbenchSegment task) async {
    if (_navigating || _loading) return;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: ValueKey('workshop-task-detail-${task.segmentId}'),
        title: const Text('车间任务详情'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${task.segmentCode} · ${task.productName ?? '—'}'),
                const SizedBox(height: UtenSpacing.s12),
                Text('生产计划：${task.planNo}'),
                Text('车间：${task.workshopName ?? '—'}'),
                Text('负责人：${task.responsibleEmployeeName ?? '—'}'),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  '计划数量：${_taskQuantity(task.plannedQty)} ${task.productUnitName ?? ''}',
                ),
                Text('已报数量：${_taskQuantity(task.reportedQty)}'),
                Text('待报数量：${_taskQuantity(task.remainingReportQty)}'),
                const SizedBox(height: UtenSpacing.s12),
                Text(_flowStageOf(task).label),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  task.canSplitBatch
                      ? '现有合格物料能配齐多少，就可以先安排多少。点击“分批领料”核对本次数量；剩余任务继续等待补料。'
                      : _canRequestDrawTask(task)
                      ? '可以选择本次物料并填写领料数量。确认提交后由仓库发料，实际领齐本批后再开工。'
                      : _canStartTask(task)
                      ? '本任务已领齐或无需领料，可以确认开工；开工后支持分次报工。'
                      : task.segmentStatus == 'IN_PROGRESS'
                      ? '可按实际完成数量分次报工，实际用料和余料继续从本任务登记。'
                      : _blockedReasonOf(task),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          if (_canViewPlan && task.planId.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('plan'),
              child: const Text('查看生产计划'),
            ),
          if (task.hasMaterialActivity || task.hasSharedMaterialActivity)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('material'),
              child: Text(_materialUsageLabel(task)),
            ),
          if (_canStart && _isPreparing && _canStartTask(task))
            FilledButton.icon(
              key: ValueKey('workshop-detail-start-${task.segmentId}'),
              onPressed: () => Navigator.of(dialogContext).pop('start'),
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('开工'),
            ),
          if (_canStart && _isPreparing && _canRequestDrawTask(task))
            FilledButton.icon(
              key: ValueKey('workshop-detail-draw-${task.segmentId}'),
              onPressed: () => Navigator.of(dialogContext).pop('draw'),
              icon: const Icon(Icons.move_to_inbox_outlined),
              label: const Text('去领料'),
            ),
          if (_canStart && _isPreparing && task.canSplitBatch)
            FilledButton.icon(
              key: ValueKey('workshop-detail-batch-${task.segmentId}'),
              onPressed: () => Navigator.of(dialogContext).pop('batch'),
              icon: const Icon(Icons.call_split_rounded),
              label: const Text('分批领料'),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'draw':
        await _requestDraw([task]);
      case 'batch':
        await _prepareBatch(task);
      case 'plan':
        await _openPlan(task);
      case 'material':
        await _openMaterialUsage(task);
      case 'start':
        await _startTasks([task]);
    }
  }

  static String _taskQuantity(double value) =>
      value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

  Future<void> _openMaterialUsage(
    ProductionExecutionWorkbenchSegment task,
  ) async {
    if (_navigating ||
        !(task.hasMaterialActivity || task.hasSharedMaterialActivity) ||
        task.planId.isEmpty ||
        task.segmentId.isEmpty) {
      return;
    }
    final permissions = ref.read(currentPermissionsProvider);
    final admin = ref.read(isSuperAdminProvider);
    setState(() => _navigating = true);
    try {
      var materialSegmentId = task.segmentId;
      var sourceCanSettle = true;
      if (task.hasSharedMaterialActivity) {
        final sources = await ref
            .read(productionMaterialRepositoryProvider)
            .materialUsageSources(
              task.planId,
              executionSegmentId: task.segmentId,
            );
        if (!mounted) return;
        final available = sources
            .where((source) => source.canOpen)
            .toList(growable: false);
        if (available.isEmpty) {
          context.appWarning('原领料记录当前不可访问，请联系原领料车间核对');
          return;
        }
        final source = await showDialog<ProductionMaterialUsageSource>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('选择原领料任务'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('本批沿用前批已领物料。登记仍关联原领料记录，不会重复领料；请选择实际使用的来源。'),
                    const SizedBox(height: UtenSpacing.s12),
                    for (final source in available)
                      ListTile(
                        key: ValueKey(
                          'material-usage-source-${source.executionSegmentId}',
                        ),
                        title: Text(source.executionSegmentCode),
                        subtitle: Text(source.shared ? '前批原领料来源' : '本批领料来源'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(dialogContext).pop(source),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('返回'),
              ),
            ],
          ),
        );
        if (!mounted || source == null) return;
        materialSegmentId = source.executionSegmentId;
        sourceCanSettle = source.canSettle;
      }
      await showProductionMaterialSettlementSheet(
        context,
        ref,
        planId: task.planId,
        executionSegmentId: materialSegmentId,
        canSettle:
            _status == 'IN_PROGRESS' &&
            sourceCanSettle &&
            (admin || permissions.contains(Perm.productionMaterialSettle)),
        canReverse:
            admin || permissions.contains(Perm.productionMaterialReverse),
        // Closing changes a whole plan; a workshop task only grants its exact material rows.
        canClose: false,
      );
      if (mounted) await _load();
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  /// 历史任务时间门控变化：选定时间段/全部才发第一次请求；再次选择回第 1 页。
  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() {
      _historyTime = value;
      _page = 1;
      _selected.clear();
    });
    _load();
  }

  /// 状态列：全站统一流程词表（等待物料/物料齐套·可开工/生产中%/已完工）。
  ProductionFlowStage _flowStageOf(ProductionExecutionWorkbenchSegment task) =>
      ProductionFlowStage.forSegment(
        segmentStatus: task.segmentStatus,
        zeroMaterial: task.zeroMaterial,
        materialIssued: task.issued,
        drawRequested: task.drawRequested,
        splitReplaced: task.splitReplaced,
        reportedQty: task.reportedQty,
        plannedQty: task.plannedQty,
        remainingReportQty: task.remainingReportQty,
        fqcPendingQty: task.fqcPendingQty,
        fqcFailedQty: task.fqcFailedQty,
        finishedInboundPendingQty: task.finishedInboundPendingQty,
        inboundQty: task.inboundQty,
        hasUnregisteredMaterial: task.hasUnregisteredMaterial,
        hasPendingReturn: task.hasPendingReturn,
        hasAvailableMaterial: task.hasAvailableMaterial,
      );

  @override
  Widget build(BuildContext context) {
    ref.listen(listRefreshTickProvider(productionExecutionRefreshKey), (_, _) {
      if (!_navigating) _load();
    });
    // 2026-09-12 用户口径「从子页面回来整页要自动刷新」：返回即无条件重拉；
    // 顺手兜底清 _navigating——历史上有流程异常退出没走到 finally 时它会卡在
    // true，右下角「批量报工」就一直点不动。各流程自己的 finally 清 False 是
    // 幂等的，重复清无副作用。
    ref.onPageResume(RouteName.productionWorkshopTasks, () {
      if (_navigating && mounted) setState(() => _navigating = false);
      _load();
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
                // 计数形态：两段都是本人要推进的执行段（齐套要开工、生产中要报工），
                // 挂红徽章；历史任务不传 count。
                UtenFilterToolbar<String>(
                  segments: [
                    UtenFilterSegment(
                      value: 'PREPARING',
                      label: '等待物料',
                      count: counts.preparing,
                      countForm: UtenSegmentCountForm.actionable,
                    ),
                    UtenFilterSegment(
                      value: 'IN_PROGRESS',
                      label: '生产中',
                      count: counts.inProgress,
                      countForm: UtenSegmentCountForm.actionable,
                    ),
                    const UtenFilterSegment(value: 'COMPLETED', label: '历史任务'),
                  ],
                  selected: _status == null ? const {} : {_status!},
                  onSelectionChanged: (value) {
                    setState(() {
                      _status = value;
                      _preparationFilter = null;
                      _page = 1;
                      _selected.clear();
                      // 离开历史段时清掉时间门控值，下次进入重新选择。
                      if (!_isHistory) {
                        _historyTime = const UtenHistoryTimeValue.none();
                      }
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
                if (_isHistory) ...[
                  // 历史任务时间门控（ADR-066 §1.3）：时间段/全部，未选不加载。
                  Padding(
                    padding: const EdgeInsets.only(
                      top: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4,
                    ),
                    child: UtenHistoryTimeFilter(
                      key: const Key('workshop-history-time'),
                      value: _historyTime,
                      onChanged: _onHistoryTime,
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s8),
                Expanded(
                  // 分类默认不选：引导占位不发请求（与调度台大类行同范式）。
                  child: _status == null
                      ? const UtenFilterPlaceholder(
                          message: '在上方选择分类后查看任务',
                          description: '分类默认不选中；等待物料 / 生产中 / 历史任务',
                        )
                      : _isHistory && _historyTime.isNone
                      ? const UtenHistoryTimePlaceholder(
                          description: '按计划完工日期加载已完工 / 已取消 / 已红冲工单',
                        )
                      : MasterDataTableView<
                          ProductionExecutionWorkbenchSegment
                        >(
                          columns: _columnsFor(_status!),
                          items: _items,
                          // 车间筛选在表头（生产车间列下拉，与状态值筛选同范式）；
                          // 选项来自生产车间树，选中后整页按车间重拉。
                          facets: {
                            if (_isPreparing)
                              'status': const [
                                MasterFacetBucket(
                                  value: 'WAITING_MATERIAL',
                                  label: '车间已收到 · 等待物料',
                                  count: 0,
                                ),
                                MasterFacetBucket(
                                  value: 'DRAW_NOT_REQUESTED',
                                  label: '物料齐套 · 去领料',
                                  count: 0,
                                ),
                                MasterFacetBucket(
                                  value: 'DRAW_REQUESTED',
                                  label: '已提交领料 · 待仓库发料',
                                  count: 0,
                                ),
                                MasterFacetBucket(
                                  value: 'READY_TO_START',
                                  label: '已领齐 / 无需领料 · 可开工',
                                  count: 0,
                                ),
                              ],
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
                          filters: {
                            'workshop': ?_workshopDepartmentId,
                            if (_isPreparing) 'status': ?_preparationFilter,
                          },
                          onFilterChanged: (key, value) {
                            if (key != 'workshop' && key != 'status') return;
                            setState(() {
                              final filter = value == null || value.isEmpty
                                  ? null
                                  : value;
                              if (key == 'workshop') {
                                _workshopDepartmentId = filter;
                              } else {
                                _preparationFilter = filter;
                              }
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
                                  task.canSplitBatch
                                      ? Icons.call_split_rounded
                                      : task.segmentStatus == 'IN_PROGRESS' &&
                                            task.remainingReportQty <= 0.000001
                                      ? Icons.info_outline_rounded
                                      : Icons.lock_outline_rounded,
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
                            if (_isPreparing) ...[
                              UtenButton(
                                type: UtenButtonType.danger,
                                icon: Icons.move_to_inbox_rounded,
                                onPressed:
                                    _loading ||
                                        _navigating ||
                                        !_items.any(
                                          (task) =>
                                              ids.contains(task.segmentId) &&
                                              _canRequestDrawTask(task),
                                        )
                                    ? null
                                    : () => _requestDraw(
                                        _items
                                            .where(
                                              (task) =>
                                                  ids.contains(
                                                    task.segmentId,
                                                  ) &&
                                                  _canRequestDrawTask(task),
                                            )
                                            .toList(growable: false),
                                      ),
                                child: Text(
                                  '批量领料(${_items.where((task) => ids.contains(task.segmentId) && _canRequestDrawTask(task)).length})',
                                ),
                              ),
                              UtenButton(
                                type: UtenButtonType.danger,
                                icon: Icons.play_circle_fill_rounded,
                                onPressed:
                                    _loading ||
                                        _navigating ||
                                        !_items.any(
                                          (task) =>
                                              ids.contains(task.segmentId) &&
                                              _canStartTask(task),
                                        )
                                    ? null
                                    : _startSelected,
                                child: Text(
                                  '批量开工(${_items.where((task) => ids.contains(task.segmentId) && _canStartTask(task)).length})',
                                ),
                              ),
                            ] else
                              UtenButton(
                                type: UtenButtonType.danger,
                                icon: Icons.fact_check_outlined,
                                onPressed: ids.isEmpty || _navigating
                                    ? null
                                    : _reportSelected,
                                child: Text('批量报工(${ids.length})'),
                              ),
                          ],
                          rowMenuBuilder: (task) => [
                            if (_isPreparing && _canStart && task.canSplitBatch)
                              UtenMenuItem(
                                label: '分批生产领料',
                                icon: Icons.call_split_rounded,
                                enabled: !_loading && !_navigating,
                                onTap: () => _prepareBatch(task),
                              ),
                            if (_isPreparing &&
                                _canStart &&
                                _canRequestDrawTask(task))
                              UtenMenuItem(
                                label: '查看领料汇总',
                                icon: Icons.move_to_inbox_rounded,
                                enabled: !_navigating && !_loading,
                                onTap: () => _requestDraw([task]),
                              ),
                            if (task.hasMaterialActivity ||
                                task.hasSharedMaterialActivity)
                              UtenMenuItem(
                                label: _materialUsageLabel(task),
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
                            // 计划详情入口只对持 production_plan:view（或超管）
                            // 的人渲染；车间默认包不含该码（V541/V543）。
                            if (_isPreparing &&
                                _canStartTask(task) &&
                                _canViewPlan)
                              UtenMenuItem(
                                label: '查看生产计划（可单独开工）',
                                icon: Icons.open_in_new_rounded,
                                onTap: () => _openPlan(task),
                              ),
                            if (_isPreparing && !_canStartTask(task))
                              UtenMenuItem(
                                label: '为什么不能开工',
                                icon: Icons.help_outline_rounded,
                                onTap: () =>
                                    context.appInfo(_blockedReasonOf(task)),
                              ),
                            if (_isPreparing &&
                                !_canStartTask(task) &&
                                _canViewPlan)
                              UtenMenuItem(
                                label: '查看物料进度',
                                icon: Icons.open_in_new_rounded,
                                onTap: () => _openPlan(task),
                              ),
                            if (!_isPreparing && _canViewPlan)
                              UtenMenuItem(
                                label: '查看生产计划',
                                icon: Icons.open_in_new_rounded,
                                onTap: () => _openPlan(task),
                              ),
                          ],
                          onRowTap: _openTaskDetail,
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
                              : '该时间段内没有已完工 / 已取消 / 已红冲的工单',
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
      width: 260,
      value: (task) => _flowStageOf(task).displayLabel,
      cellBuilder: (_, task) {
        final stage = _flowStageOf(task);
        final badge = UtenStatusBadge(
          label: stage.displayLabel,
          type: productionFlowBadgeType(stage),
          icon: stage.icon,
        );
        if (_isPreparing && _canStart && _canRequestDrawTask(task)) {
          return Tooltip(
            message: '查看领料汇总，确认后提交仓库',
            child: InkWell(
              key: ValueKey('workshop-request-draw-${task.segmentId}'),
              borderRadius: BorderRadius.circular(UtenRadius.pill),
              onTap: _navigating || _loading
                  ? null
                  : () => _requestDraw([task]),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                child: badge,
              ),
            ),
          );
        }
        return task.canRecheckMaterial
            ? Tooltip(
                message: AppLocalizations.of(
                  context,
                ).productionMaterialRecheckHelp,
                child: badge,
              )
            : badge;
      },
    ),
    MasterColumnDef(
      key: 'materialUsage',
      label: '下一步',
      width: 185,
      value: (_) => '',
      cellBuilder: (_, task) => _isPreparing && _canStart && task.canSplitBatch
          ? TextButton.icon(
              key: ValueKey('workshop-batch-draw-${task.segmentId}'),
              onPressed: _navigating || _loading
                  ? null
                  : () => _prepareBatch(task),
              icon: const Icon(Icons.call_split_rounded, size: 18),
              label: const Text('分批领料'),
            )
          : !(task.hasMaterialActivity || task.hasSharedMaterialActivity)
          ? const SizedBox.shrink()
          : TextButton.icon(
              key: ValueKey('workshop-material-usage-${task.segmentId}'),
              onPressed: _navigating ? null : () => _openMaterialUsage(task),
              icon: const Icon(Icons.fact_check_outlined, size: 18),
              label: Text(_materialUsageLabel(task)),
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
      width: 170,
      value: (task) => task.workshopName,
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    // 读侧本来就返回 productCode，只是界面一直没用——同名不同编号的产品在
    // 车间任务里分不开，报工会报到别的段上。
    MasterColumnDef(
      key: 'name',
      label: '产品名称',
      width: 180,
      value: (task) => task.productName,
    ),
    MasterColumnDef(
      key: 'productCode',
      label: '编号',
      width: 130,
      value: (task) => UtenGoodsAttributeCell.text(task.productCode),
      cellBuilder: (_, task) => UtenGoodsAttributeCell(task.productCode),
    ),
    MasterColumnDef(
      key: 'color',
      label: '颜色',
      width: 100,
      value: (task) => UtenGoodsAttributeCell.text(task.productColorName),
      cellBuilder: (_, task) => UtenGoodsAttributeCell(task.productColorName),
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
  ];
}

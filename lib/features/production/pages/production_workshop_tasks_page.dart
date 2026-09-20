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
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
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

  /// 路线确认提交中，防止重复请求并显示明确反馈。
  bool _confirmingRoutes = false;
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
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionExecutionView) &&
        permissions.contains(Perm.productionExecutionStart);
  }

  bool get _canCreateReport {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionExecutionView) &&
        permissions.contains(Perm.productionDailyReportView) &&
        permissions.contains(Perm.productionDailyReportCreate);
  }

  /// 2026-09-14(V583)起本页不再登记实际用料：实耗随报工在生产日报页一起填。
  /// 这里只剩只读台账与退料进度，标签也只剩这两种。
  String _materialUsageLabel(ProductionExecutionWorkbenchSegment task) {
    final l10n = AppLocalizations.of(context);
    if (task.hasPendingReturn && !task.hasAvailableMaterial) return '查看退料进度';
    return l10n.productionMaterialViewUsage;
  }

  /// 当前分类是否「等待物料」（未开工段：等料 + 齐套可开工）。
  bool get _isPreparing => _status == 'PREPARING';

  /// 路线决定何时开工；仓库领取、车间直送是每种物料的来源，可以混合。
  static const _routeOptionMeta = {
    'FULL_KIT': ('齐套生产', '全部必需物料按计划需求到齐，仓库料实际领齐、直送料完成交接后开工。适合希望一次备齐的任务。'),
    'CONTINUOUS': (
      '持续生产',
      '每种必需物料共同支持一部分产量时即可开工；后续到货在同一工单继续领料或直送，不拆工单，不预填开工数量，按实际报工核算剩余。',
    ),
    'BATCH': ('分批生产', '按当前可齐套的数量拆批：本批先领料先生产，剩余等后续到货继续分批；每批独立报工。仅需要独立管理各批次时选择。'),
  };

  List<String> _routeOptions(ProductionExecutionWorkbenchSegment task) => [
    'FULL_KIT',
    if (!task.zeroMaterial &&
        (task.canConfirmRoute ||
            task.routeChangeable ||
            task.startRoute == null))
      'CONTINUOUS',
    if (!task.zeroMaterial &&
        task.canSplitBatch &&
        task.segmentStatus == 'WAITING' &&
        (task.canConfirmRoute ||
            task.routeChangeable ||
            task.startRoute == null))
      'BATCH',
  ];

  /// 尚未确认或服务端允许更改时，才展示路线确认入口。
  bool _routeSettableTask(ProductionExecutionWorkbenchSegment task) =>
      _isPreparing &&
      _canStart &&
      (task.canConfirmRoute || task.startRoute == null || task.routeChangeable);

  /// 首列勾选门：齐套链批量动作（批量领料 / 批量开工）∪ 路线可改选行（多选后
  /// 「批量设置路线」可一次改一批）。
  bool _kitSelectableTask(ProductionExecutionWorkbenchSegment task) =>
      _routeAllowsKitActions(task) &&
      (_canRequestDrawTask(task) || _canStartTask(task));

  /// 「批量设置路线」的作用范围与计数：勾选中 ∩ 路线可改选。
  int get _routeSettableCount => _items
      .where(
        (task) =>
            _selected.contains(task.segmentId) && _routeSettableTask(task),
      )
      .length;

  static const _routeIcons = {
    'FULL_KIT': Icons.checklist_rounded,
    'BATCH': Icons.call_split_rounded,
    'CONTINUOUS': Icons.all_inclusive_rounded,
  };

  /// 路线配色（2026-09-18 用户口径「不同生产路线给不同的颜色，不然不好区分」；
  /// 五轮口径「颜色太相近看不清，取差别大的」）：齐套=绿 / 分批=蓝 / 持续=品红，
  /// 三色色相拉开到互相一眼可分。与同行状态徽章不撞色：分批、持续路线的工单必然
  /// 还在 WAITING（琥珀），品红与琥珀、蓝都分得开；绿色的「已完工」只在历史任务
  /// 出现，而历史任务没有路线列。
  static UtenStatusBadgeType _routeBadgeType(String? route) => switch (route) {
    'BATCH' => UtenStatusBadgeType.info,
    'CONTINUOUS' => UtenStatusBadgeType.fuchsia,
    _ => UtenStatusBadgeType.success,
  };

  /// 「重新确认生产路线」纠偏弹窗的选项图标用色（与徽章同一套路线分类色）：
  /// 浅色模式用分类色本体，深色模式用亮档。
  static Color _routeDotColor(BuildContext context, String? route) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return switch (route) {
      'BATCH' => isDark ? UtenColors.infoOnDark : UtenColors.info,
      'CONTINUOUS' => isDark ? UtenColors.fuchsiaOnDark : UtenColors.fuchsia,
      _ => isDark ? UtenColors.successOnDark : UtenColors.success,
    };
  }

  /// 一行的「下一步」清单，按先后顺序排。
  ///
  /// 2026-09-17 用户口径：「下一步」这一列改成下拉框，点开显示我们自己写的列表框。
  /// 行右键菜单与该下拉共用这一份清单——两处不会再各写一遍而慢慢长歪。
  /// [_NextStep.primary] 的才是「真正要做的下一步」，下拉收起时显示第一条 primary；
  /// 重新核对备料 / 为什么不能开工 / 查看计划属于只读与求助，只在列表里出现。
  /// 报工不在清单里：2026-09-06 口径——报工统一是「勾选 + 右下角悬浮按钮」。
  List<_NextStep> _nextSteps(ProductionExecutionWorkbenchSegment task) {
    final busy = _navigating || _loading;
    return [
      if (_routeSettableTask(task))
        _NextStep(
          primary: task.startRoute == null,
          item: UtenMenuItem(
            label: task.startRoute == null ? '路线确认' : '更改生产路线',
            icon: Icons.alt_route_rounded,
            enabled: !busy,
            onTap: () => _confirmRoute(task),
          ),
        ),
      if (_isPreparing && _canStart && _canStartTask(task))
        _NextStep(
          primary: true,
          item: UtenMenuItem(
            label: '开工',
            icon: Icons.play_circle_outline,
            enabled: !busy,
            onTap: () => _startTasks([task]),
          ),
        ),
      if (_canStart && _canRequestDrawTask(task))
        _NextStep(
          primary: true,
          item: UtenMenuItem(
            label: task.segmentStatus == 'IN_PROGRESS'
                ? '继续领料(查看领料汇总)'
                : '去领料(查看领料汇总)',
            icon: Icons.move_to_inbox_rounded,
            enabled: !busy,
            onTap: () => _requestDraw([task]),
          ),
        ),
      if (_isPreparing &&
          _canStart &&
          task.startRoute == 'BATCH' &&
          task.canSplitBatch)
        _NextStep(
          primary: true,
          item: UtenMenuItem(
            label: '分批生产领料',
            icon: Icons.call_split_rounded,
            enabled: !busy,
            onTap: () => _prepareBatch(task),
          ),
        ),
      if (task.hasMaterialActivity || task.hasSharedMaterialActivity)
        _NextStep(
          primary: true,
          item: UtenMenuItem(
            label: _materialUsageLabel(task),
            icon: Icons.fact_check_outlined,
            enabled: !_navigating,
            onTap: () => _openMaterialUsage(task),
          ),
        ),
      // 重新核对备料=齐套提升：分批/未开工的持续生产路线不走这里(V599)。
      if (_canStart &&
          task.canRecheckMaterial &&
          (task.startRoute == 'FULL_KIT' ||
              (task.startRoute == 'CONTINUOUS' && task.continuousSupply)))
        _NextStep(
          item: UtenMenuItem(
            label: AppLocalizations.of(context).productionMaterialRecheck,
            icon: Icons.fact_check_outlined,
            enabled: !_navigating,
            onTap: () => _recheckMaterials(task),
          ),
        ),
      if (_isPreparing &&
          (!_canStartTask(task) || !_routeAllowsKitActions(task)))
        _NextStep(
          item: UtenMenuItem(
            label: '为什么不能开工',
            icon: Icons.help_outline_rounded,
            onTap: () => context.appInfo(_blockedReasonOf(task)),
          ),
        ),
      // 计划详情入口只对持 production_plan:view（或超管）的人渲染；
      // 车间默认包不含该码（V541/V543）。
      if (_canViewPlan)
        _NextStep(
          item: UtenMenuItem(
            label: _isPreparing
                ? (_canStartTask(task) && _routeAllowsKitActions(task)
                      ? '查看生产计划（可单独开工）'
                      : '查看物料进度')
                : '查看生产计划',
            icon: Icons.open_in_new_rounded,
            onTap: () => _openPlan(task),
          ),
        ),
    ];
  }

  List<UtenContextMenuEntry> _nextStepEntries(
    ProductionExecutionWorkbenchSegment task,
  ) => _nextSteps(task).map((step) => step.item).toList(growable: false);

  /// 路线只展示已确认事实；选择和确认在一个面板内完成。
  Widget _routeCell(ProductionExecutionWorkbenchSegment task) {
    if (task.startRoute == null) {
      return const UtenStatusBadge(
        label: '待确认',
        type: UtenStatusBadgeType.warning,
        icon: Icons.alt_route_rounded,
      );
    }
    return Tooltip(
      message: _routeOptionMeta[task.startRoute]?.$2 ?? task.startRouteLabel,
      child: UtenStatusBadge(
        label: task.startRouteLabel,
        type: _routeBadgeType(task.startRoute),
        icon: _routeIcons[task.startRoute],
      ),
    );
  }

  Future<void> _confirmRoute(ProductionExecutionWorkbenchSegment task) async {
    if (!_routeSettableTask(task) || _navigating || _loading) return;
    final options = _routeOptions(task);
    final current = task.startRoute;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RouteBatchSetSheet(
        key: ValueKey('workshop-route-confirm-${task.segmentId}'),
        count: 1,
        options: options,
        initialRoute: options.contains(current)
            ? current
            : options.contains('FULL_KIT')
            ? 'FULL_KIT'
            : null,
        taskLabel: '${task.segmentCode} · ${task.productName ?? '—'}',
      ),
    );
    if (chosen == null || !mounted) return;
    await _submitRoutes([task], chosen);
  }

  /// 桌面右键、触屏和键盘共用同一份下一步菜单。
  Widget _nextStepCell(ProductionExecutionWorkbenchSegment task) {
    final steps = _nextSteps(task);
    if (steps.isEmpty) return const Text('—');
    final primary = steps.where((step) => step.primary).firstOrNull;
    return Builder(
      builder: (buttonContext) => TextButton.icon(
        key: ValueKey('workshop-next-step-${task.segmentId}'),
        onPressed: _navigating || _loading
            ? null
            : () {
                final box = buttonContext.findRenderObject()! as RenderBox;
                showUtenContextMenu(
                  context,
                  globalPosition: box.localToGlobal(Offset(0, box.size.height)),
                  entries: steps
                      .map((step) => step.item)
                      .toList(growable: false),
                );
              },
        icon: const Icon(Icons.expand_more_rounded, size: 18),
        label: Text(
          primary?.item.label ?? '查看详情',
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 逐单提交已确认路线；版本变化保留失败原因，完成后刷新服务端事实。
  Future<void> _submitRoutes(
    List<ProductionExecutionWorkbenchSegment> targets,
    String route,
  ) async {
    if (targets.isEmpty) return;
    setState(() {
      _navigating = true;
      _confirmingRoutes = true;
    });
    var applied = 0;
    String? firstError;
    try {
      for (final task in targets) {
        try {
          await ref
              .read(productionPlanRepositoryProvider)
              .confirmExecutionSegmentRoute(
                task.planId,
                task.segmentId,
                expectedVersion: task.lockVersion,
                route: route,
              );
          applied += 1;
        } catch (error) {
          firstError ??= productionErrorMessage(
            error,
            fallback: '确认生产路线失败，请刷新后重试',
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _navigating = false;
          _confirmingRoutes = false;
        });
      }
    }
    if (!mounted) return;
    final label = _routeOptionMeta[route]?.$1 ?? route;
    if (applied > 0) {
      context.appSuccess(
        applied == 1 ? '已确认生产路线：$label' : '已确认 $applied 个工单的生产路线：$label',
      );
    }
    if (firstError != null) {
      context.appError(
        '部分工单路线未改成功（已改 $applied / ${targets.length}）：$firstError',
        force: true,
      );
    }
    await _load();
  }

  /// 多选后统一确认路线，只提交每行允许的选项。
  Future<void> _batchSetRoutes() async {
    if (!_canStart || _navigating || _loading) return;
    final targets = _items
        .where(
          (task) =>
              _selected.contains(task.segmentId) && _routeSettableTask(task),
        )
        .toList(growable: false);
    if (targets.isEmpty) return;
    final union = <String>{};
    for (final task in targets) {
      union.addAll(_routeOptions(task));
    }
    final options = [
      for (final route in const ['FULL_KIT', 'CONTINUOUS', 'BATCH'])
        if (union.contains(route)) route,
    ];
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _RouteBatchSetSheet(
        key: const Key('workshop-route-batch-sheet'),
        count: targets.length,
        options: options,
      ),
    );
    if (chosen == null || !mounted) return;
    final applicable = targets
        .where(
          (t) => t.startRoute != chosen && _routeOptions(t).contains(chosen),
        )
        .toList(growable: false);
    final skipped = targets.length - applicable.length;
    await _submitRoutes(applicable, chosen);
    if (skipped > 0 && mounted) {
      final label = _routeOptionMeta[chosen]?.$1 ?? chosen;
      context.appInfo('$skipped 个勾选工单的事实不允许「$label」或路线已冻结，未改');
    }
  }

  /// 服务端同时复核已确认路线、实际投料及共同可支持产量。
  bool _canStartTask(ProductionExecutionWorkbenchSegment task) =>
      _routeAllowsKitActions(task) &&
      task.canStart &&
      (task.segmentStatus == 'READY' || task.segmentStatus == 'DISPATCHED');

  bool _routeAllowsKitActions(ProductionExecutionWorkbenchSegment task) =>
      task.startRoute == 'FULL_KIT' || task.startRoute == 'CONTINUOUS';

  /// 服务端确认的续领包括持续到料和齐套开工后的真实退料补领，不依赖历史 issued 标志。
  bool _canRequestDrawTask(ProductionExecutionWorkbenchSegment task) =>
      _routeAllowsKitActions(task) &&
      task.canRequestDraw &&
      !task.zeroMaterial &&
      (task.segmentStatus == 'READY' ||
          task.segmentStatus == 'DISPATCHED' ||
          task.segmentStatus == 'IN_PROGRESS');

  /// 未开工行点击/勾选受限的明确原因（物料未入库、库存不足、备料未完成等）。
  String _blockedReasonOf(ProductionExecutionWorkbenchSegment task) {
    if (_isPreparing && !_canStart) {
      return '缺少开工权限（production_execution:view + start）：不能开工、领料或改选生产路线；'
          '可查看物料进度，办理请联系车间负责人';
    }
    if (task.startRoute == null) {
      return '请先确认生产路线，再按所选路线备料和开工';
    }
    if (task.startRoute == 'BATCH') {
      return '请按本批物料共同支持的产量办理分批生产领料；各批独立开工和报工';
    }
    if (task.startRoute == 'CONTINUOUS' &&
        task.segmentStatus != 'IN_PROGRESS') {
      return task.canRequestDraw
          ? '已有物料可领，请先领料；每种必需物料共同支持部分产量后即可开工'
          : '等待各项必需物料共同支持部分产量；仓库料须实际发料，直送料须完成交接';
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
      return '正在核对备料，请查看任务物料进度；预计到货和待检物料不计入可开工数量';
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

  /// 等待物料可勾选待确认路线或可办理领料/开工的行；生产中勾选用于报工。
  bool _selectableTask(ProductionExecutionWorkbenchSegment task) => _isPreparing
      ? _kitSelectableTask(task) || _routeSettableTask(task)
      : task.segmentStatus == 'IN_PROGRESS' && task.canBatchReport;

  /// 「批量领料」的计数与提交目标（同一谓词）：勾选中 ∩ 齐套链路线放行 ∩ 可提交领料。
  /// 2026-09-18 二轮勾选门放宽后未确认路线的行可勾选，这里必须保持路线门，
  /// 否则会把「先确认路线」的行喂给服务端 409、并拖垮同计划的批量开工（计划内原子）。
  List<ProductionExecutionWorkbenchSegment> _selectedDrawTasks(
    Set<String> ids,
  ) => _items
      .where(
        (task) =>
            ids.contains(task.segmentId) &&
            _routeAllowsKitActions(task) &&
            _canRequestDrawTask(task),
      )
      .toList(growable: false);

  /// 「批量开工」的计数与提交目标（同一谓词）：勾选中 ∩ 齐套链路线放行 ∩ 可开工。
  List<ProductionExecutionWorkbenchSegment> _selectedStartTasks(
    Set<String> ids,
  ) => _items
      .where(
        (task) =>
            ids.contains(task.segmentId) &&
            _routeAllowsKitActions(task) &&
            _canStartTask(task),
      )
      .toList(growable: false);

  Future<void> _requestDraw(
    List<ProductionExecutionWorkbenchSegment> tasks,
  ) async {
    if (!_canStart || _navigating || tasks.isEmpty) return;
    // 双保险：调用方按 _selectedDrawTasks 过滤，这里再挡一次路线未放行的行。
    tasks = tasks
        .where(
          (task) => _routeAllowsKitActions(task) && _canRequestDrawTask(task),
        )
        .toList(growable: false);
    if (tasks.isEmpty) return;
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
    if (!_canStart ||
        task.startRoute != 'BATCH' ||
        !task.canSplitBatch ||
        _navigating ||
        _loading) {
      return;
    }
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
  Future<void> _startTasks(
    List<ProductionExecutionWorkbenchSegment> targets,
  ) async {
    if (!_canStart || _navigating || targets.isEmpty) return;
    // 双保险：未确认/分批路线的行服务端必拒（V599），混进一个会拖垮同计划整批。
    targets = targets
        .where((task) => _routeAllowsKitActions(task) && _canStartTask(task))
        .toList(growable: false);
    if (targets.isEmpty) return;
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
                Row(
                  children: [
                    Text(
                      '生产路线：',
                      style: Theme.of(dialogContext).textTheme.bodyMedium,
                    ),
                    if (task.startRoute == null)
                      Text(
                        '待确认（先确认路线再开工）',
                        style: Theme.of(dialogContext).textTheme.bodyMedium
                            ?.copyWith(
                              color: Theme.of(
                                dialogContext,
                              ).colorScheme.onSurfaceVariant,
                            ),
                      )
                    else
                      UtenStatusBadge(
                        label: task.startRouteLabel,
                        type: _routeBadgeType(task.startRoute),
                        icon: _routeIcons[task.startRoute],
                      ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  '计划数量：${_taskQuantity(task.plannedQty)} ${task.productUnitName ?? ''}',
                ),
                Text('已报数量：${_taskQuantity(task.reportedQty)}'),
                Text('待报数量（含品质恢复）：${_taskQuantity(task.remainingReportQty)}'),
                if (task.continuousSupply)
                  const Text('本次可报数量须按实际投料核对，请以报工页面的来源上限为准。'),
                const SizedBox(height: UtenSpacing.s12),
                Text(_flowStageOf(task).label),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  task.startRoute == null
                      ? '请先确认路线。齐套或持续生产共用原工单；只有各批独立管理时才选择分批。'
                      : task.continuousSupply
                      ? '每种必需物料共同支持部分产量后即可开工；仓库料分次领取，直送料按实际交接投入，后续均在本任务继续。'
                      : task.startRoute == 'BATCH' && task.canSplitBatch
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
          if (_canStart &&
              _isPreparing &&
              _routeAllowsKitActions(task) &&
              _canStartTask(task))
            FilledButton.icon(
              key: ValueKey('workshop-detail-start-${task.segmentId}'),
              onPressed: () => Navigator.of(dialogContext).pop('start'),
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('开工'),
            ),
          if (_canStart && _canRequestDrawTask(task))
            FilledButton.icon(
              key: ValueKey('workshop-detail-draw-${task.segmentId}'),
              onPressed: () => Navigator.of(dialogContext).pop('draw'),
              icon: const Icon(Icons.move_to_inbox_outlined),
              label: Text(task.segmentStatus == 'IN_PROGRESS' ? '继续领料' : '去领料'),
            ),
          if (_canStart &&
              _isPreparing &&
              task.startRoute == 'BATCH' &&
              task.canSplitBatch)
            FilledButton.icon(
              key: ValueKey('workshop-detail-batch-${task.segmentId}'),
              onPressed: () => Navigator.of(dialogContext).pop('batch'),
              icon: const Icon(Icons.call_split_rounded),
              label: const Text('分批领料'),
            ),
          if (_routeSettableTask(task))
            FilledButton.icon(
              key: ValueKey('workshop-detail-route-${task.segmentId}'),
              onPressed: () => Navigator.of(dialogContext).pop('route'),
              icon: const Icon(Icons.alt_route_rounded),
              label: Text(task.startRoute == null ? '路线确认' : '更改生产路线'),
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
      case 'route':
        await _confirmRoute(task);
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
        // V583：实耗登记搬到生产日报页(报工时物料子行一起填)，本页只读台账。
        // 只留查看与冲销/撤回，避免两处都能记账、数字互相打架。
        canSettle: false,
        canReverse:
            admin || permissions.contains(Perm.productionMaterialReverse),
        // 已实领即按服务端能力办理真实退料，不要求为了退料先开工；已提交申请也可撤回重提。
        canRequestReturn:
            sourceCanSettle &&
            (admin || permissions.contains(Perm.productionMaterialSettle)),
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
  /// 路线确认后 WAITING 的等待方式按路线区分（齐套等到齐/分批等部分到货/
  /// 持续等部分物料——物料分析「未下达按路线显示第一步」同款）。
  ProductionFlowStage _flowStageOf(ProductionExecutionWorkbenchSegment task) =>
      ProductionFlowStage.forSegment(
        segmentStatus: task.segmentStatus,
        zeroMaterial: task.zeroMaterial,
        materialIssued: task.issued,
        drawRequested: task.drawRequested,
        splitReplaced: task.splitReplaced,
        continuousSupply: task.continuousSupply,
        pendingLineSideOnly: task.pendingLineSideOnly,
        startRoute: task.startRoute,
        routeConfirmationRequired: task.startRoute == null,
        canStartNow: task.canStart,
        canRequestDraw: task.canRequestDraw,
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
                              // 多选时复用同一确认面板。
                              if (_selected.length >= 2 &&
                                  _routeSettableCount >= 1)
                                UtenButton(
                                  key: const Key('workshop-batch-set-routes'),
                                  type: UtenButtonType.secondary,
                                  icon: Icons.done_all_rounded,
                                  onPressed:
                                      _loading ||
                                          _navigating ||
                                          _routeSettableCount == 0
                                      ? null
                                      : _batchSetRoutes,
                                  child: Text('批量确认路线($_routeSettableCount)'),
                                ),
                              UtenButton(
                                type: UtenButtonType.danger,
                                icon: Icons.move_to_inbox_rounded,
                                onPressed:
                                    _loading ||
                                        _navigating ||
                                        _selectedDrawTasks(ids).isEmpty
                                    ? null
                                    : () =>
                                          _requestDraw(_selectedDrawTasks(ids)),
                                child: Text(
                                  '批量领料(${_selectedDrawTasks(ids).length})',
                                ),
                              ),
                              UtenButton(
                                type: UtenButtonType.danger,
                                icon: Icons.play_circle_fill_rounded,
                                onPressed:
                                    _loading ||
                                        _navigating ||
                                        _selectedStartTasks(ids).isEmpty
                                    ? null
                                    : () =>
                                          _startTasks(_selectedStartTasks(ids)),
                                child: Text(
                                  '批量开工(${_selectedStartTasks(ids).length})',
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
                          rowMenuBuilder: _nextStepEntries,
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
                // 确认生产路线期间的全屏加载遮罩（组件自己推 root Overlay，挂载
                // 位置随意；物料分析 bucketActionBusyMessage 同款）：批量「确认
                // 路线(N)」串行逐单提交与单行提交共用 [_confirmingRoutes] 通道。
                if (_confirmingRoutes)
                  const UtenBusyOverlay(
                    semanticsKey: Key('workshop-route-confirm-busy'),
                    title: '正在确认生产路线',
                    description: '正在提交所选工单的生产路线，完成后自动刷新。',
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
        if (_isPreparing &&
            _canStart &&
            _routeAllowsKitActions(task) &&
            _canRequestDrawTask(task)) {
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
    // 路线事实与办理入口分列，进行中也能看见原路线。
    if (status != 'COMPLETED')
      MasterColumnDef(
        key: 'route',
        label: '生产路线',
        width: 210,
        info:
            '先确认齐套、持续或分批生产。持续生产允许仓库分次领料与同车间直送混合，'
            '同一工单只开一次工。每项物料的真实来源不因路线改变，已有领料、报工或预留后不可改路线。',
        value: (task) => task.startRouteLabel,
        cellBuilder: (_, task) => _routeCell(task),
      ),
    if (status != 'COMPLETED')
      MasterColumnDef(
        key: 'nextStep',
        label: '下一步',
        width: 240,
        value: (task) => _nextSteps(
          task,
        ).where((step) => step.primary).firstOrNull?.item.label,
        cellBuilder: (_, task) => _nextStepCell(task),
      ),
    // 2026-09-16 用户口径：产品名称 / 编号 / 颜色紧跟「下一步」列——先看清是
    // 哪个产品，再往右读订单 / 工单 / 车间。三列口径仍按全站统一（各占一列）。
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

/// 「下一步」清单里的一条：[primary]=true 表示这一行真正要做的动作；
/// 只读与求助条目只出现在行右键菜单里。
class _NextStep {
  const _NextStep({required this.item, this.primary = false});

  final UtenMenuItem item;
  final bool primary;
}

/// 单个或多个工单共用的路线确认面板，选择只改变草稿，确认才提交。
class _RouteBatchSetSheet extends StatefulWidget {
  const _RouteBatchSetSheet({
    super.key,
    required this.count,
    required this.options,
    this.initialRoute,
    this.taskLabel,
  });

  final String? initialRoute;
  final String? taskLabel;
  final int count;
  final List<String> options;

  @override
  State<_RouteBatchSetSheet> createState() => _RouteBatchSetSheetState();
}

class _RouteBatchSetSheetState extends State<_RouteBatchSetSheet> {
  late String? _chosen = widget.initialRoute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _chosen == null
        ? null
        : _ProductionWorkshopTasksPageState._routeOptionMeta[_chosen];
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            left: UtenSpacing.s16,
            right: UtenSpacing.s16,
            top: UtenSpacing.s16,
            // 键盘/输入法弹出时让面板跟着上移（与其它底部面板同款）。
            bottom: MediaQuery.of(context).viewInsets.bottom + UtenSpacing.s16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.count == 1 ? '路线确认' : '批量确认生产路线',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                widget.taskLabel ??
                    '为勾选的 ${widget.count} 个工单确认同一路线；不适用的工单会跳过并提示。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              const Text('一般选择齐套或持续生产；仅需独立管理各批次时选择分批。'),
              const SizedBox(height: UtenSpacing.s8),
              UtenDropdownField(
                key: const Key('workshop-route-batch-field'),
                label: '生产路线',
                required: true,
                allowClear: false,
                value: _chosen,
                hintText: '请选择生产路线',
                items: [
                  for (final option in widget.options)
                    UtenDropdownItem(
                      value: option,
                      label:
                          _ProductionWorkshopTasksPageState
                              ._routeOptionMeta[option]
                              ?.$1 ??
                          option,
                    ),
                ],
                onChanged: (value) => setState(() => _chosen = value),
              ),
              if (meta != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _ProductionWorkshopTasksPageState._routeIcons[_chosen],
                      size: 16,
                      color: _ProductionWorkshopTasksPageState._routeDotColor(
                        context,
                        _chosen,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Expanded(
                      child: Text(
                        '${meta.$1}：${meta.$2}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: UtenSpacing.s16),
              Align(
                alignment: Alignment.centerRight,
                child: UtenButton(
                  key: const Key('workshop-route-batch-apply'),
                  type: UtenButtonType.danger,
                  onPressed: _chosen == null
                      ? null
                      : () => Navigator.of(context).pop(_chosen),
                  child: const Text('确认路线'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

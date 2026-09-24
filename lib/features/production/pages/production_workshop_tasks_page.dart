// 我的车间任务（车间视角的执行工单办理台）。
//
// 2026-09-20 用户口径（终版，勿再改回弹窗流）：等待物料的「下一步」就是选定
// 生产路线——列内直接下拉（齐套 / 持续 / 分批），**选中即提交**，没有草稿、
// 没有确认按钮、没有任何弹窗或两步流程。未确认的行显示「选择生产路线」占位，
// 不预填假默认值（ADR-093：路线必须是车间明确确认的事实）。「生产中」分类
// 不显示「下一步」列（报工走勾选 + 右下角悬浮按钮，路线以只读徽章展示）。
// 2026-09-21 追加口径「我明明多选了，选中一个，为什么批量设路线还要重新选」：被改的
// 行已勾选且勾选集里还有别的可设路线行时，一次下拉 = 对全部勾选行提交(与
// 「批量设路线」菜单同一套筛选：不支持该路线或已是该路线的行自动跳过)；
// 没勾选的行照旧只改自己。路线记忆预填只是展示，勾选行不会因预填被算作已选。
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
import '../../../components/inputs/uten_field_hint_icon.dart';
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
import '../widgets/workshop_task_material_table.dart';
import '../../../shared/badges/badge_registry.dart';

/// 一块跑批遮罩的画面: 测试锚点 key + 标题 + 说明。标题在同一次动作里可换
/// (提交段 -> 刷新段), UtenBusyOverlay 支持帧后热更文案。
typedef _WorkshopBusy = ({Key semanticsKey, String title, String description});

/// 一批路线确认的结果: 成功条数与首个失败原因(部分失败时提示用)。
typedef _RouteConfirmOutcome = ({int applied, String? error});

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

  /// 跑批遮罩的唯一通道(2026-09-21 用户口径「批量开工/批量领料/批量设路线
  /// 应该和别的页面一样有中间的加载弹窗」): 非空 = 正在跑一段纯网络任务,
  /// 全屏居中遮罩按这里的文案显示。同一时刻只会有一块。
  ///
  /// 纪律(UtenBusyOverlay 组件契约): **只许盖纯网络段**。本页凡是要跳到别的
  /// 页面或者中途弹窗的动作(批量领料、分批领料、批量报工、看生产计划、看用料
  /// 记录)一律不进这个通道——遮罩是直接插进 root Overlay 的裸 entry, Navigator
  /// 每推一次路由都会把它重新抬到最顶, 挂着跳页会把目标页整片盖住且点不动。
  /// 那几条链路的加载反馈由各自的目标页自己给(如领料汇总页的首屏加载卡片)。
  _WorkshopBusy? _busy;

  /// 路线确认(批量设路线 + 行内「下一步」下拉选中即提交)。
  static const _busyRoutes = (
    semanticsKey: Key('workshop-route-confirm-busy'),
    title: '正在确认生产路线',
    description: '正在提交所选工单的生产路线，完成后自动刷新。',
  );

  /// 批量开工(含行右键菜单、详情弹窗里的单行开工, 都走同一个方法)。
  static const _busyStart = (
    semanticsKey: Key('workshop-batch-start-busy'),
    title: '正在开工',
    description: '正在按生产计划逐批提交开工，完成后自动刷新。',
  );

  /// 重新核对备料(与开工同类: 一次纯网络提交, 不跳页不弹窗)。
  static const _busyRecheck = (
    semanticsKey: Key('workshop-recheck-busy'),
    title: '正在重新核对备料',
    description: '正在按当前生产路线复核物料到位情况，完成后自动刷新。',
  );

  /// 网络段之后的整页重拉段: 换文案不撤遮罩, 免得提示已经弹出来、表格还停在
  /// 旧事实(表格组件在有数据时刷新是零画面的)。
  ///
  /// 文案不许说「已提交」「已完成」: 这一段在整批全失败时照样要跑, 到底成了
  /// 几条要等遮罩撤下后的提示才知道; 重新核对备料也不是一次提交。
  static _WorkshopBusy _busyRefreshing(_WorkshopBusy action) => (
    semanticsKey: action.semanticsKey,
    title: '正在刷新任务列表',
    description: '正在按服务端最新事实重新拉取任务与物料，完成后给出结果。',
  );

  bool _navigating = false;

  /// 批量报工去了日报新建页：回来时清空勾选(原设计在 push 返回后清；保存后
  /// 新建页 replace 成详情，push 的 Future 不再返回，改由「返回即刷新」兑现)。
  bool _clearSelectionOnResume = false;
  String _keyword = '';
  String? _status;
  String? _preparationFilter;

  /// 「下一步」表头筛选（ADR-095）：UNCONFIRMED / FULL_KIT / CONTINUOUS / BATCH。
  String? _routeFilter;
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

  /// 路线只决定「什么时候可以开工」；仓库领取、同车间直送是每种物料各自的来源，
  /// 可以混合。开工前随时可换（ADR-095）：已备料、已领料、直送已投入的事实一件不动。
  static const _routeOptionMeta = {
    'FULL_KIT': (
      '齐套生产',
      '每种必需物料都按计划需求实领到车间（仓库料领齐、直送料完成交接）后才开工。'
          '已备了一部分料的任务改选齐套：已备物料保留、继续补齐，全部实领后开工。',
    ),
    'CONTINUOUS': (
      '持续生产',
      '每种必需物料共同支持一部分产量时即可开工；后续到料(采购、委外、自制子件直送或入库)'
          '在同一工单继续领料或投入，不拆工单，不预填开工数量，按实际报工核算剩余。',
    ),
    'BATCH': (
      '分批生产',
      '按当前可齐套的数量拆出独立的子批：本批先领料先生产，剩余继续等待再拆；'
          '各批独立开工与报工。只在各批需要独立管理时选择，且须在尚未备料时决定。',
    ),
  };

  /// 当前可选的路线(ADR-096：每种任务都支持三条，含无需物料的任务)：齐套 / 持续
  /// 恒可选；分批要拆出独立子任务，只在服务端判定「未动过」(canSplitBatch)时出现，
  /// 否则悬停说明见 [_routeChangeHint]。
  List<String> _routeOptions(ProductionExecutionWorkbenchSegment task) => [
    'FULL_KIT',
    'CONTINUOUS',
    if (task.canSplitBatch) 'BATCH',
  ];

  /// 开工前随时可换（ADR-095）：未确认（canConfirmRoute）或服务端允许更改
  /// （routeChangeable：未开工且无报工）时，「下一步」下拉开放选择，选中即提交。
  bool _routeSettableTask(ProductionExecutionWorkbenchSegment task) =>
      _isPreparing &&
      _canStart &&
      (task.canConfirmRoute || task.startRoute == null || task.routeChangeable);

  /// 下拉悬停说明：当前路线含义 + 为什么某些选项不在（分批需未备料）。
  String _routeChangeHint(ProductionExecutionWorkbenchSegment task) {
    final current = task.startRoute;
    final buffer = StringBuffer(
      current == null
          ? '选择生产路线：齐套 / 持续 / 分批，选中即确认。'
          : '当前：${_routeOptionMeta[current]?.$1}——${_routeOptionMeta[current]?.$2}',
    );
    if (current != null) buffer.write(' 开工前可随时改选，已备物料不变。');
    final followers = _checkedRouteFollowers(task);
    if (followers.isNotEmpty) {
      buffer.write(
        ' 本行已勾选：在这里选路线会一并确认全部 ${followers.length + 1} 个勾选行'
        '(不支持该路线或已是该路线的行自动跳过)。',
      );
    }
    if (!task.canSplitBatch) {
      buffer.write(
        task.materialKindCount > 0 && task.materialCoveredKindCount > 0
            ? ' 本任务已备了部分物料，不能再拆分批（分批要拆出独立子任务，须在未备料时决定）。'
            : ' 本任务不满足独立分批条件(须为已安排车间、尚未备料或绑定供给的物料分析任务)。',
      );
    }
    return buffer.toString();
  }

  /// 勾选中可设路线的行(批量设路线的目标)。
  List<ProductionExecutionWorkbenchSegment> _selectedRouteTasks(
    Set<String> ids,
  ) => _items
      .where((task) => ids.contains(task.segmentId) && _routeSettableTask(task))
      .toList(growable: false);

  /// 与 [task] 一起被勾选的其它可设路线行；[task] 自己没勾选时为空(下拉只改
  /// 自己)。悬停说明与 [_routeSubmitTargets] 共用，两处口径不会漂。
  List<ProductionExecutionWorkbenchSegment> _checkedRouteFollowers(
    ProductionExecutionWorkbenchSegment task,
  ) {
    if (!_selected.contains(task.segmentId)) return const [];
    return _selectedRouteTasks(
      _selected,
    ).where((row) => row.segmentId != task.segmentId).toList(growable: false);
  }

  /// 「下一步」下拉的提交目标(2026-09-21 用户口径「我明明多选了，选中一个，
  /// 为什么批量设路线还要重新选」)：被改的行已勾选且勾选集里还有别的可设路线
  /// 行时，一次下拉 = 对全部勾选行提交，筛选与 [_showBatchRouteMenu] 同一套
  /// (不支持该路线或已是该路线的行自动跳过)；没勾选的行照旧只改自己。被改的
  /// 行本身永远在内——它正是触发提交的那一行。
  List<ProductionExecutionWorkbenchSegment> _routeSubmitTargets(
    ProductionExecutionWorkbenchSegment task,
    String route,
  ) {
    final followers = _checkedRouteFollowers(task)
        .where(
          (row) =>
              row.startRoute != route && _routeOptions(row).contains(route),
        )
        .toList(growable: false);
    if (followers.isEmpty) return [task];
    return _items
        .where(
          (row) =>
              row.segmentId == task.segmentId ||
              followers.any((f) => f.segmentId == row.segmentId),
        )
        .toList(growable: false);
  }

  /// 「批量设路线」菜单(2026-09-20 用户口径「能够批量选择路线，现在必须一个一个选」)：
  /// 三条路线各显示能改的行数(不支持该路线或已是该路线的行自动跳过)，另有一条
  /// 「按预填默认值确认」把每行各自记忆的路线一次确认。选中即提交，没有弹窗。
  Future<void> _showBatchRouteMenu(
    BuildContext anchorContext,
    List<ProductionExecutionWorkbenchSegment> targets,
  ) async {
    if (targets.isEmpty || _navigating || _loading) return;
    final box = anchorContext.findRenderObject() as RenderBox?;
    final origin = box == null
        ? Offset.zero
        : box.localToGlobal(Offset(0, box.size.height));
    List<ProductionExecutionWorkbenchSegment> eligible(String route) => targets
        .where(
          (task) =>
              task.startRoute != route && _routeOptions(task).contains(route),
        )
        .toList(growable: false);
    final defaults = targets
        .where(
          (task) =>
              task.startRoute == null &&
              task.suggestedStartRoute != null &&
              _routeOptions(task).contains(task.suggestedStartRoute),
        )
        .toList(growable: false);
    await showUtenContextMenu(
      context,
      globalPosition: origin,
      entries: [
        for (final route in const ['FULL_KIT', 'CONTINUOUS', 'BATCH'])
          UtenMenuItem(
            label: '${_routeOptionMeta[route]!.$1}(${eligible(route).length})',
            icon: _routeIcons[route],
            enabled: eligible(route).isNotEmpty,
            onTap: () => _submitRoutes(eligible(route), route),
          ),
        const UtenMenuDivider(),
        UtenMenuItem(
          label: '按预填默认值确认(${defaults.length})',
          icon: Icons.history_rounded,
          enabled: defaults.isNotEmpty,
          onTap: () => _submitRememberedRoutes(defaults),
        ),
      ],
    );
  }

  /// 按每行各自的路线记忆逐组确认(同一路线的行一起提交, 每组各自提示)。
  /// 遮罩由本方法整段持有: 逐组之间不撤不闪, 最后的整页重拉也在遮罩内。
  Future<void> _submitRememberedRoutes(
    List<ProductionExecutionWorkbenchSegment> targets,
  ) async {
    if (targets.isEmpty) return;
    final byRoute = <String, List<ProductionExecutionWorkbenchSegment>>{};
    for (final task in targets) {
      byRoute.putIfAbsent(task.suggestedStartRoute!, () => []).add(task);
    }
    final outcomes = await _runBusy(_busyRoutes, () async {
      final results = <(String, _RouteConfirmOutcome)>[];
      for (final entry in byRoute.entries) {
        results.add((entry.key, await _confirmRoutes(entry.value, entry.key)));
        if (!mounted) break;
      }
      return results;
    });
    if (!mounted) return;
    for (final (route, outcome) in outcomes) {
      _reportRouteOutcome(outcome, byRoute[route]!.length, route);
    }
  }

  /// 首列勾选门之一：齐套链批量动作(批量领料 / 批量开工)。可设路线的行另由
  /// [_routeSettableTask] 放进勾选集，供「批量设路线」使用。
  bool _kitSelectableTask(ProductionExecutionWorkbenchSegment task) =>
      _routeAllowsKitActions(task) &&
      (_canRequestDrawTask(task) || _canStartTask(task));

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

  /// 一行的行右键菜单清单（桌面右键、触屏长按和键盘共用）。
  ///
  /// 2026-09-20 用户口径：路线不在菜单里——等待物料的路线在「下一步」列的下拉
  /// 里**选中即提交**，不经过任何弹窗。报工也不在清单里：报工统一是
  /// 「勾选 + 右下角悬浮按钮」。
  List<UtenContextMenuEntry> _nextStepEntries(
    ProductionExecutionWorkbenchSegment task,
  ) {
    final busy = _navigating || _loading;
    return [
      if (_isPreparing && _canStart && _canStartTask(task))
        UtenMenuItem(
          label: '开工',
          icon: Icons.play_circle_outline,
          enabled: !busy,
          onTap: () => _startTasks([task]),
        ),
      if (_canStart && _canRequestDrawTask(task))
        UtenMenuItem(
          label: task.segmentStatus == 'IN_PROGRESS'
              ? '继续领料(查看领料汇总)'
              : '去领料(查看领料汇总)',
          icon: Icons.move_to_inbox_rounded,
          enabled: !busy,
          onTap: () => _requestDraw([task]),
        ),
      if (_isPreparing &&
          _canStart &&
          task.startRoute == 'BATCH' &&
          task.canSplitBatch)
        UtenMenuItem(
          label: '分批生产领料',
          icon: Icons.call_split_rounded,
          enabled: !busy,
          onTap: () => _prepareBatch(task),
        ),
      if (task.hasMaterialActivity || task.hasSharedMaterialActivity)
        UtenMenuItem(
          label: _materialUsageLabel(task),
          icon: Icons.fact_check_outlined,
          enabled: !_navigating,
          onTap: () => _openMaterialUsage(task),
        ),
      // 重新核对备料=按路线补跑一次备料：分批路线等拆批，不走这里(V599)。
      if (_canStart &&
          task.canRecheckMaterial &&
          (task.startRoute == 'FULL_KIT' || task.startRoute == 'CONTINUOUS'))
        UtenMenuItem(
          label: AppLocalizations.of(context).productionMaterialRecheck,
          icon: Icons.fact_check_outlined,
          enabled: !_navigating,
          onTap: () => _recheckMaterials(task),
        ),
      if (_isPreparing &&
          (!_canStartTask(task) || !_routeAllowsKitActions(task)))
        UtenMenuItem(
          label: '为什么不能开工',
          icon: Icons.help_outline_rounded,
          onTap: () => context.appInfo(_blockedReasonOf(task)),
        ),
      // 计划详情入口只对持 production_plan:view（或超管）的人渲染；
      // 车间默认包不含该码（V541/V543）。
      if (_canViewPlan)
        UtenMenuItem(
          label: _isPreparing
              ? (_canStartTask(task) && _routeAllowsKitActions(task)
                    ? '查看生产计划（可单独开工）'
                    : '查看物料进度')
              : '查看生产计划',
          icon: Icons.open_in_new_rounded,
          onTap: () => _openPlan(task),
        ),
    ];
  }

  /// 路线只读徽章：「生产中」列与等待物料里路线已冻结的行回显用；可改选行的选择
  /// 在「下一步」下拉完成。ADR-095 起开工前随时可换，冻结只剩两种情况：已开工，
  /// 或已有报工——悬停必须说清原因（2026-09-20 用户口径「有些不能解锁」）。
  Widget _routeCell(ProductionExecutionWorkbenchSegment task) {
    if (task.startRoute == null) {
      return Tooltip(
        message: _canStart
            ? '生产路线待确认：请在本行「下一步」下拉中选择'
            : '缺少开工权限（production_execution:view + start），不能确认生产路线',
        child: const UtenStatusBadge(
          label: '待确认',
          type: UtenStatusBadgeType.warning,
          icon: Icons.alt_route_rounded,
        ),
      );
    }
    final description =
        _routeOptionMeta[task.startRoute]?.$2 ?? task.startRouteLabel;
    return Tooltip(
      message: switch (task.segmentStatus) {
        'IN_PROGRESS' => '工单已开工，生产路线固定；$description',
        _ when !_canStart =>
          '缺少开工权限（production_execution:view + start），'
              '不能更改生产路线；$description',
        _ =>
          '生产路线已冻结：本工单已有报工记录，更改路线不能改写已发生的生产事实。'
              '如确需更改，请先红冲相关报工；$description',
      },
      child: UtenStatusBadge(
        label: task.startRouteLabel,
        type: _routeBadgeType(task.startRoute),
        icon: _routeIcons[task.startRoute],
      ),
    );
  }

  /// 「下一步」格（2026-09-20 用户口径，终版）：等待物料的下一步就是选定生产
  /// 路线——列内直接下拉（齐套 / 持续 / 分批），**选中即提交**，没有草稿、没有
  /// 确认按钮、没有任何弹窗。本行已勾选且勾选集里还有别的可设路线行时，选中即
  /// 对全部勾选行提交([_routeSubmitTargets])。未确认的行预填**路线记忆**（V602 恢复：同产品最近
  /// 一次确认的路线，仅在当前可选范围内），旁挂黄标「已按上次选择预填，请核对」
  /// ——预填只是展示，不写任何事实，选中才提交（ADR-093 明确确认口径不破）。
  /// 路线已冻结的行只读回显徽章；路线色标竖线沿用五轮配色口径（齐套=绿 / 分批=蓝 / 持续=品红）。
  Widget _nextStepCell(ProductionExecutionWorkbenchSegment task) {
    if (!_routeSettableTask(task)) return _routeCell(task);
    final options = _routeOptions(task);
    final current = task.startRoute;
    final remembered =
        current == null && options.contains(task.suggestedStartRoute)
        ? task.suggestedStartRoute
        : null;
    return Row(
      children: [
        if (current != null) ...[
          Container(
            key: ValueKey('workshop-route-bar-${task.segmentId}'),
            width: 8,
            height: 16,
            decoration: BoxDecoration(
              color: _routeDotColor(context, current),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: UtenSpacing.s4),
        ],
        Expanded(
          child: Tooltip(
            message: current == null && remembered != null
                ? '${_routeMemoryHint(task)}，点开核对后选择确认。${_routeChangeHint(task)}'
                : _routeChangeHint(task),
            child: UtenDropdownField(
              key: ValueKey('workshop-next-step-${task.segmentId}'),
              dense: true,
              allowClear: false,
              searchable: false,
              value: current ?? remembered,
              hintText: '选择生产路线',
              items: [
                for (final option in options)
                  UtenDropdownItem(
                    value: option,
                    label: _routeOptionMeta[option]?.$1 ?? option,
                  ),
                // 当前路线后来不在收窄选项里（如持续生产的直送资格消失）：
                // 保标签可见但不作为新选项，仍可改选其它路线。
                if (current != null && !options.contains(current))
                  UtenDropdownItem(
                    value: current,
                    label:
                        _routeOptionMeta[current]?.$1 ?? task.startRouteLabel,
                    visible: false,
                  ),
              ],
              onChanged: (chosen) {
                if (chosen == null || chosen == current) return;
                if (!options.contains(chosen)) return;
                if (_navigating || _loading) return;
                // 本行已勾选且还有别的勾选行 → 一次下拉对全部勾选行提交。
                _submitRoutes(_routeSubmitTargets(task, chosen), chosen);
              },
            ),
          ),
        ),
        if (remembered != null)
          UtenFieldHintIcon(
            key: ValueKey('workshop-route-memory-${task.segmentId}'),
            autofillMessage: _routeMemoryHint(task),
          ),
      ],
    );
  }

  /// 路线记忆的来源说明(ADR-096)：同产品上次的选择，或你上次的选择。
  static String _routeMemoryHint(ProductionExecutionWorkbenchSegment task) =>
      task.suggestedStartRouteSource == 'OPERATOR'
      ? '已按你上次选择的路线预填，请核对'
      : '已按本产品上次选择的路线预填，请核对';

  /// 跑一段纯网络任务, 全程挂全屏居中遮罩: 提交与提交后的整页重拉算同一段,
  /// 中间不撤不闪(表格组件在已有数据时刷新是零画面的, 撤早了就成了「提示已经
  /// 弹出、表格还是旧事实」的裸奔窗口)。
  ///
  /// 结果提示一律由调用方在本方法返回**之后**再发: 遮罩必须先撤下, 否则提示被
  /// 盖在遮罩底下, widget test 的 pumpAndSettle 也永远落不定(遮罩里的转圈是无限
  /// 动画)。[body] 里绝不能跳页或弹窗, 理由见 [_busy]。
  Future<T> _runBusy<T>(_WorkshopBusy action, Future<T> Function() body) async {
    setState(() {
      _busy = action;
      _navigating = true;
    });
    try {
      final result = await body();
      if (mounted) {
        // 两个标志一起置: 兜底复位(返回即刷新/刷新按钮)可能在 await 期间把
        // _navigating 清掉了, 刷新段要把它一并恢复, 免得遮罩在、按钮却可点。
        setState(() {
          _busy = _busyRefreshing(action);
          _navigating = true;
        });
        await _reloadAfterChange();
      }
      return result;
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _navigating = false;
        });
      }
    }
  }

  /// 逐单提交已确认路线; 版本变化保留失败原因。只跑网络, 遮罩与刷新由
  /// [_runBusy] 统一持有, 提示由调用方在遮罩撤下后再发。
  Future<_RouteConfirmOutcome> _confirmRoutes(
    List<ProductionExecutionWorkbenchSegment> targets,
    String route,
  ) async {
    var applied = 0;
    String? firstError;
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
    return (applied: applied, error: firstError);
  }

  void _reportRouteOutcome(
    _RouteConfirmOutcome outcome,
    int total,
    String route,
  ) {
    final label = _routeOptionMeta[route]?.$1 ?? route;
    if (outcome.applied > 0) {
      context.appSuccess(
        outcome.applied == 1
            ? '已确认生产路线：$label'
            : '已确认 ${outcome.applied} 个工单的生产路线：$label',
      );
    }
    if (outcome.error != null) {
      context.appError(
        '部分工单路线未改成功(已改 ${outcome.applied} / $total)：${outcome.error}',
        force: true,
      );
    }
  }

  /// 单行下拉选中即提交, 或「批量设路线」菜单按路线提交: 提交与刷新同在遮罩内。
  Future<void> _submitRoutes(
    List<ProductionExecutionWorkbenchSegment> targets,
    String route,
  ) async {
    if (targets.isEmpty) return;
    final outcome = await _runBusy(
      _busyRoutes,
      () => _confirmRoutes(targets, route),
    );
    if (!mounted) return;
    _reportRouteOutcome(outcome, targets.length, route);
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
      if (task.canRequestDraw) {
        return '已有物料可领，请先领料；每种必需物料共同支持部分产量后即可开工';
      }
      if (task.materialShortMakeKindCount > 0) {
        return '还有 ${task.materialShortMakeKindCount} 种物料由自制子件工单供给，子件做完可能直送本车间'
            '也可能入库后领料，交到本任务后才算到料；打开任务详情可看每种物料的到料数量';
      }
      if (task.materialShortKindCount > 0) {
        return '还有 ${task.materialShortKindCount} 种物料未到货（采购/委外未入库）；'
            '打开任务详情可看每种物料的到料数量';
      }
      return '等待各项必需物料共同支持部分产量；仓库料须实际发料，直送料须完成交接';
    }
    if (task.segmentStatus == 'IN_PROGRESS') {
      if (task.remainingReportQty <= 0.000001) {
        return '${_flowStageOf(task).label}；当前可报数量为 0，不能重复报工';
      }
      return task.blockedReason ?? '当前工单暂不能批量报工，请打开详情查看来源';
    }
    if (task.materialStatus == 'KIT_SHORT') {
      if (task.materialKindCount > 0) {
        return '齐套生产：已备 ${task.materialCoveredKindCount}/${task.materialKindCount} 种物料，'
            '还有 ${task.materialShortKindCount} 种未到(${task.materialShortMakeKindCount > 0 ? '含自制子件 ${task.materialShortMakeKindCount} 种' : '采购/委外未入库'})；'
            '全部到齐并实领后才能开工，打开任务详情可看每种物料的到料数量';
      }
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

  /// 写操作之后(本页提交、子页面办完返回)的整页重拉: 列表与顶部分类徽章一起刷新。
  ///
  /// 2026-09-24 用户口径「点批量领料、批量开工，左上角分类应该刷新；现在徽章要手动
  /// 刷新页面才出来」「批量报工成功回到生产中，分类或者整个页面应该刷新」: 分类徽章
  /// 随全站徽章汇总带回(ADR-108), 只重拉列表时它要等下一轮 60s 轮询才动。这里显式
  /// 重拉一次汇总(单飞合并; 网络层写后兜底补拉会被这次取数吸收, 不重复请求)。
  /// 纯切换分类/翻页/搜索不走这里——数据没变, 不为徽章多打请求。
  Future<void> _reloadAfterChange() {
    refreshBadges(ref);
    return _load();
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
      return;
    }
    final requestedPage = _page;
    final requestedKeyword = _keyword;
    final requestedStatus = _status;
    final requestedPreparationFilter = _isPreparing ? _preparationFilter : null;
    final requestedRouteFilter = _isPreparing ? _routeFilter : null;
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
            routeFilter: requestedRouteFilter,
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

  /// 等待物料勾选用于设路线、领料或开工；生产中只要求任务可报工。
  /// 多来源任务仍可单独进入报工页选来源，自动批量资格在提交多选时检查。
  bool _selectableTask(ProductionExecutionWorkbenchSegment task) => _isPreparing
      ? _kitSelectableTask(task) || _routeSettableTask(task)
      : task.segmentStatus == 'IN_PROGRESS' && task.canReport;

  /// 勾选框右下角的小锁(2026-09-20 用户口径「最前面可以锁住，物料不齐就是锁住」)：
  /// 行能勾选去批量设路线，但物料不齐/未选路线时不能领料、开工——锁住并说明原因。
  Widget? _leadingLockOf(
    BuildContext context,
    ProductionExecutionWorkbenchSegment task,
  ) {
    if (!_isPreparing || _kitSelectableTask(task)) return null;
    return Tooltip(
      message: _blockedReasonOf(task),
      child: Icon(
        Icons.lock_rounded,
        key: ValueKey('workshop-leading-lock-${task.segmentId}'),
        size: 12,
        color: Theme.of(context).brightness == Brightness.dark
            ? UtenColors.warningOnDark
            : UtenColors.warningText,
      ),
    );
  }

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
      await _reloadAfterChange();
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
      await _reloadAfterChange();
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
    // 跨计划是逐计划串行往返(计划内才是单事务原子), 多计划时要等几秒——这段
    // 全程挂遮罩, 否则屏幕上只有一个变灰的按钮, 用户会对着没变的旧行再点一次。
    final outcome = await _runBusy(_busyStart, () async {
      var started = 0;
      final startedIds = <String>{};
      String? firstError;
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
      if (mounted && startedIds.isNotEmpty) {
        setState(() => _selected.removeAll(startedIds));
      }
      return (started: started, error: firstError);
    });
    if (!mounted) return;
    if (outcome.started > 0) {
      context.appSuccess('已开工 ${outcome.started} 个工单，请在「生产中」分类报工');
    }
    if (outcome.error != null) {
      context.appError(
        '部分工单开工失败(已开工 ${outcome.started} / ${targets.length})：${outcome.error}',
        force: true,
      );
    }
  }

  Future<void> _recheckMaterials(
    ProductionExecutionWorkbenchSegment task,
  ) async {
    if (!_canStart || !task.canRecheckMaterial || _navigating) return;
    try {
      // 与开工同类的纯网络段: 一次提交 + 一次整页重拉, 全程挂遮罩。
      final result = await _runBusy(
        _busyRecheck,
        () => ref
            .read(productionPlanRepositoryProvider)
            .recheckExecutionSegmentMaterials(
              task.planId,
              task.segmentId,
              expectedVersion: task.lockVersion,
            ),
      );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      if (result.status == 'READY') {
        context.appSuccess(l10n.productionMaterialRecheckReady);
      } else {
        context.appInfo(l10n.productionMaterialRecheckWaiting);
      }
    } catch (error) {
      if (mounted) context.appApiError(error);
    }
  }

  /// 报工入口唯一：勾选后右下角悬浮「批量报工(N)」进入汇总报工页，
  /// 一次提交（服务端口径：一次报工=同一车间；跨车间选择在这里给明确提示）。
  Future<void> _reportSelected() async {
    if (!_canCreateReport || _selected.isEmpty || _navigating) return;
    final requested = _selected.toList(growable: false);
    if (requested.length > 1 &&
        _items.any(
          (task) => requested.contains(task.segmentId) && !task.canBatchReport,
        )) {
      context.appWarning(
        '所选任务含需确认报工来源的工单，请单独勾选该任务，再选择本次对应的订单或公共备货来源',
        force: true,
      );
      return;
    }
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
    setState(() {
      _navigating = true;
      _clearSelectionOnResume = true;
    });
    try {
      // 日报新建页保存后 context.replace 成详情页：go_router 的 replace 会丢弃
      // 这个 push 的 completer，下面的 await 就此不再返回、finally 也不会执行。
      // 那条路上的列表刷新、清勾选与 _navigating 复位由「返回即刷新」(pageResume
      // 以栈顶路由为落点)承担；这里的收尾只覆盖用户不保存直接返回的情况。
      await context.push(path);
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _clearSelectionOnResume = false;
      });
      await _reloadAfterChange();
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
      if (mounted) await _reloadAfterChange();
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
          width: 760,
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
                if (task.startRoute == 'CONTINUOUS')
                  const Text('本次可报数量须按实际投料核对，请以报工页面的来源上限为准。'),
                const SizedBox(height: UtenSpacing.s12),
                Text(_flowStageOf(task).label),
                const SizedBox(height: UtenSpacing.s8),
                // 逐种物料(ADR-095/096)：自制子件只有交到本任务后才算已领(直送或经仓库)；
                // 齐套生产到齐前不预留，「仓库已到」按齐套口径显示实物。
                Text(
                  '物料：${_materialSummaryText(task)}'
                  '${task.zeroMaterial || task.materialKindCount == 0 ? '' : '；已投料可产 ${_taskQuantity(task.materialSupportedOutputQty)} ${task.productUnitName ?? ''}'}',
                  style: Theme.of(
                    dialogContext,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (!task.zeroMaterial && task.materialKindCount > 0) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  WorkshopTaskMaterialTable(
                    key: ValueKey('workshop-task-materials-${task.segmentId}'),
                    segmentId: task.segmentId,
                  ),
                ],
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  task.startRoute == null
                      ? '请先确认路线。齐套或持续生产共用原工单；只有各批独立管理时才选择分批。'
                      : task.startRoute == 'CONTINUOUS'
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
      if (mounted) await _reloadAfterChange();
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
        startRoute: task.startRoute,
        routeConfirmationRequired: task.startRoute == null,
        canStartNow: task.canStart,
        canRequestDraw: task.canRequestDraw,
        // 2026-09-20 用户口径「物料没有齐不能显示齐，车间内流转的要流转了才算」：
        // 未开工段的文案只按服务端逐种物料事实生成（ADR-095）。
        materials: _materialFactsOf(task),
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

  static ProductionMaterialFacts _materialFactsOf(
    ProductionExecutionWorkbenchSegment task,
  ) => ProductionMaterialFacts(
    kindCount: task.materialKindCount,
    issuedKindCount: task.materialIssuedKindCount,
    shortKindCount: task.materialShortKindCount,
    shortMakeKindCount: task.materialShortMakeKindCount,
    drawableKindCount: task.materialDrawableKindCount,
    awaitingWarehouseKindCount: task.materialAwaitingWarehouseKindCount,
    lineSidePendingKindCount: task.materialLineSidePendingKindCount,
    supportedOutputQty: task.materialSupportedOutputQty,
  );

  /// 「物料」列的分段摘要(ADR-095/096)：已领 a/n 种；缺 k 种(自制子件 j)红；
  /// 可领 m 种绿；待发 p 种灰(2026-09-20 用户口径「缺X种变红色、可领X种变绿色」)。
  /// 零料任务显示「无需物料」。数字只来自服务端逐种事实，不由页面猜。
  static List<(String, _MaterialSummaryTone)> _materialSummaryParts(
    ProductionExecutionWorkbenchSegment task,
  ) {
    if (task.zeroMaterial || task.materialKindCount == 0) {
      return const [('无需物料', _MaterialSummaryTone.plain)];
    }
    final parts = <(String, _MaterialSummaryTone)>[
      (
        '已领 ${task.materialIssuedKindCount}/${task.materialKindCount} 种',
        _MaterialSummaryTone.plain,
      ),
    ];
    if (task.materialShortKindCount > 0) {
      parts.add((
        task.materialShortMakeKindCount > 0
            ? '缺 ${task.materialShortKindCount} 种(自制子件 ${task.materialShortMakeKindCount})'
            : '缺 ${task.materialShortKindCount} 种',
        _MaterialSummaryTone.short,
      ));
    }
    if (task.materialDrawableKindCount > 0) {
      parts.add((
        '可领 ${task.materialDrawableKindCount} 种',
        _MaterialSummaryTone.drawable,
      ));
    }
    if (task.materialAwaitingWarehouseKindCount > 0) {
      parts.add((
        '待发 ${task.materialAwaitingWarehouseKindCount} 种',
        _MaterialSummaryTone.muted,
      ));
    }
    return parts;
  }

  /// 纯文本摘要(列宽测算、排序键、无障碍标签)。
  static String _materialSummaryText(
    ProductionExecutionWorkbenchSegment task,
  ) => _materialSummaryParts(task).map((part) => part.$1).join(' · ');

  /// 「物料」列悬停：逐桶解释 + 已投料可产量。
  static String _materialSummaryTooltip(
    ProductionExecutionWorkbenchSegment task,
  ) {
    if (task.zeroMaterial || task.materialKindCount == 0) {
      return '本任务不需要领用物料，可直接开工';
    }
    final lines = <String>[
      '共 ${task.materialKindCount} 种物料：',
      '已领到车间 ${task.materialIssuedKindCount} 种'
          '${task.materialPartialIssuedKindCount > 0 ? '（另 ${task.materialPartialIssuedKindCount} 种只领了一部分）' : ''}',
      if (task.materialDrawableKindCount > 0)
        '已备好可提交领料 ${task.materialDrawableKindCount} 种',
      if (task.materialAwaitingWarehouseKindCount > 0)
        '已提交领料、待仓库发出 ${task.materialAwaitingWarehouseKindCount} 种',
      if (task.materialLineSidePendingKindCount > 0)
        '车间直送料已到、开工时自动投入 ${task.materialLineSidePendingKindCount} 种',
      if (task.materialPreparingKindCount > 0)
        '已预留、领料指令生成中 ${task.materialPreparingKindCount} 种',
      if (task.materialShortKindCount > 0)
        '未到 ${task.materialShortKindCount} 种'
            '${task.materialShortMakeKindCount > 0 ? '(其中 ${task.materialShortMakeKindCount} 种由自制子件工单供给，做完直送本车间或入库后领料)' : '(采购/委外未入库)'}',
      '已投料可产 ${_taskQuantity(task.materialSupportedOutputQty)}'
          '${task.productUnitName ?? ''}'
          '，已预留可产 ${_taskQuantity(task.materialPreparedOutputQty)}${task.productUnitName ?? ''}',
      '双击本行查看每种物料的数量',
    ];
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    // 2026-09-12 用户口径「从子页面回来整页要自动刷新」：子页面里做过任何写操作
    // (本端写修订号前进)或离开超过 30 秒就重拉(ADR-108; 纯查看后返回不再整页重拉)。
    // 生产执行刷新信号(bumpListRefresh)在本页栈顶时立即重拉, 被盖住时留到返回再拉。
    // 返回时连同顶部分类徽章一起重拉(报工审核、领料提交等都在子页面里办完)。
    ref.onPageResume(
      RouteName.productionWorkshopTasks,
      () {
        if (!_navigating && _busy == null) _reloadAfterChange();
      },
      refreshKeys: const [productionExecutionRefreshKey],
      // 每次返回都兜底清 _navigating——历史上有流程异常退出没走到 finally 时它会
      // 卡在 true，右下角「批量报工」就一直点不动。各流程自己的 finally 清 False
      // 是幂等的，重复清无副作用。
      onReturn: () {
        if (mounted &&
            (_navigating || _busy != null || _clearSelectionOnResume)) {
          setState(() {
            _navigating = false;
            // 遮罩也必须在这里兜底清掉：漏清一次就是一块盖死整屏、连刷新按钮都
            // 点不到的蒙版(它带 ModalBarrier(dismissible: false))，比卡住一个
            // 灰按钮严重得多。
            _busy = null;
            if (_clearSelectionOnResume) _selected.clear();
            _clearSelectionOnResume = false;
          });
        }
      },
    );
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
                    // 刷新兼作自愈：批量报工/领料等流程页保存后用 replace / go
                    // 收尾时，go_router 不会完成本页原 push 的 Future，各流程的
                    // finally 走不到、_navigating 卡在 true——勾选/开工/报工会
                    // 静默不动。「返回即刷新」是第一道复位，这里是用户手里的
                    // 第二道，否则只剩浏览器刷新(2026-09-20 用户反馈)。
                    setState(() {
                      _page = 1;
                      _navigating = false;
                      // 同上：遮罩是这条人工自愈路径必须能解掉的东西。
                      _busy = null;
                    });
                    // 顶部分类徽章随徽章汇总带回, 手动刷新时一并重拉。
                    refreshBadges(ref);
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
                // 计数形态(ADR-100 三形态, 2026-09-21): 「等待物料」红徽章 ——
                // 料没到位, 要车间工去催料/领料, 不动手这批工单就一直卡着;
                // 「生产中」黄徽章 —— 活已经在机台上跑, 报工是做完以后的事,
                // 此刻没人在等谁动手, 跟着红色一起喊就是假警报。
                // 历史任务不传 count: 已结束的东西不数(准则 §四之七)。
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
                      countForm: UtenSegmentCountForm.inProgress,
                    ),
                    const UtenFilterSegment(value: 'COMPLETED', label: '历史任务'),
                  ],
                  selected: _status == null ? const {} : {_status!},
                  onSelectionChanged: (value) {
                    setState(() {
                      _status = value;
                      _preparationFilter = null;
                      _routeFilter = null;
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
                                  // 持续生产分次到料的行也落在本桶（部分已备可领），
                                  // 桶名不宣称齐套（2026-09-20 用户口径）。
                                  label: '物料可领 · 去领料',
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
                            // 「下一步」表头筛选（2026-09-20 用户口径）：按路线分桶，
                            // 服务端 routeFilter 在分页前生效。
                            if (_isPreparing)
                              'nextStep': const [
                                MasterFacetBucket(
                                  value: 'UNCONFIRMED',
                                  label: '待选生产路线',
                                  count: 0,
                                ),
                                MasterFacetBucket(
                                  value: 'FULL_KIT',
                                  label: '齐套生产',
                                  count: 0,
                                ),
                                MasterFacetBucket(
                                  value: 'CONTINUOUS',
                                  label: '持续生产',
                                  count: 0,
                                ),
                                MasterFacetBucket(
                                  value: 'BATCH',
                                  label: '分批生产',
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
                            if (_isPreparing) 'nextStep': ?_routeFilter,
                          },
                          onFilterChanged: (key, value) {
                            if (key != 'workshop' &&
                                key != 'status' &&
                                key != 'nextStep') {
                              return;
                            }
                            setState(() {
                              final filter = value == null || value.isEmpty
                                  ? null
                                  : value;
                              switch (key) {
                                case 'workshop':
                                  _workshopDepartmentId = filter;
                                case 'status':
                                  _preparationFilter = filter;
                                default:
                                  _routeFilter = filter;
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
                          leadingOverlayBuilder: _leadingLockOf,
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
                              // 批量设路线(ADR-096)：勾选多行 → 菜单里点一条路线
                              // 即提交。勾选多行后在任一勾选行的「下一步」下拉选
                              // 路线也是对全部勾选行提交(同一套筛选)，本菜单是不
                              // 经过某一行、直接按路线提交的第二入口。
                              Builder(
                                builder: (menuContext) => UtenButton(
                                  key: const Key('workshop-batch-route'),
                                  type: UtenButtonType.danger,
                                  icon: Icons.alt_route_rounded,
                                  onPressed:
                                      _loading ||
                                          _navigating ||
                                          _selectedRouteTasks(ids).isEmpty
                                      ? null
                                      : () => _showBatchRouteMenu(
                                          menuContext,
                                          _selectedRouteTasks(ids),
                                        ),
                                  child: Text(
                                    '批量设路线(${_selectedRouteTasks(ids).length})',
                                  ),
                                ),
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
                // 跑批期间的全屏加载遮罩(组件自己推 root Overlay, 挂载位置随意;
                // 物料分析 bucketActionBusyMessage 同款)。批量设路线 / 批量开工 /
                // 重新核对备料共用 [_busy] 这一条通道, 同一时刻只会有一块。
                if (_busy != null)
                  UtenBusyOverlay(
                    semanticsKey: _busy!.semanticsKey,
                    title: _busy!.title,
                    description: _busy!.description,
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
    // 路线徽章列只留「生产中」（只读事实）。等待物料的路线就是「下一步」本身
    // ——下拉选中即提交（2026-09-20 用户口径），不再另设一格重复显示同一事实。
    if (status == 'IN_PROGRESS')
      MasterColumnDef(
        key: 'route',
        label: '生产路线',
        width: 210,
        info:
            '生产中工单的路线已定：已有领料、报工或预留后不可更改。'
            '持续生产在同一工单继续领料/直送补料；齐套按一次备齐开工。',
        value: (task) => task.startRouteLabel,
        cellBuilder: (_, task) => _routeCell(task),
      ),
    // 「下一步」列只在「等待物料」出现（2026-09-20 用户口径：生产中不显示）：
    // 单元格就是生产路线下拉，点开三选一，选中即提交，没有任何弹窗。
    if (status == 'PREPARING')
      MasterColumnDef(
        key: 'nextStep',
        label: '下一步',
        width: 240,
        info:
            '等待物料的下一步=选定生产路线，下拉选中即提交：齐套生产=全部物料到齐'
            '并实际领齐后开工；持续生产=每种物料共同支持部分产量即可开工，后续到货'
            '在同一工单继续领料/直送；分批生产=按当前可齐套量拆批，各批独立开工与'
            '报工。勾选多行后在任一勾选行选路线=对全部勾选行一起提交(不支持该路线'
            '或已是该路线的行自动跳过)。已开工或已有报工后路线冻结，只读回显。',
        value: (task) => task.startRoute == null
            ? '选择生产路线'
            : _routeOptionMeta[task.startRoute]?.$1 ?? task.startRouteLabel,
        cellBuilder: (_, task) => _nextStepCell(task),
      ),
    // 「物料」列（ADR-095，2026-09-20 用户口径「车间内流转的货品数量怎么统计、
    // 显示在哪里」）：逐种事实的一行摘要，悬停逐桶解释，双击行看每种物料的数量。
    // 生产中也显示——持续生产在原任务继续领料/直送，仍要看还缺什么。
    if (status != 'COMPLETED')
      MasterColumnDef(
        key: 'material',
        label: '物料',
        width: 230,
        info:
            '每种物料只落一个桶：已领到车间 / 缺(等采购委外到货或等自制子件完成)/ '
            '可领(已备好待提交领料)/ 待发(已提交待仓库发料)。自制子件做完可能直送'
            '本车间也可能入库后领料，只有真正交到本任务后才算「已领」。缺=红、可领=绿。'
            '双击行查看每种物料的数量。',
        value: _materialSummaryText,
        cellBuilder: (context, task) {
          final theme = Theme.of(context);
          final dark = theme.brightness == Brightness.dark;
          final base = theme.textTheme.bodySmall;
          Color? toneColor(_MaterialSummaryTone tone) => switch (tone) {
            _MaterialSummaryTone.short =>
              dark ? UtenColors.errorOnDark : UtenColors.errorText,
            _MaterialSummaryTone.drawable =>
              dark ? UtenColors.successOnDark : UtenColors.successText,
            _MaterialSummaryTone.muted => theme.colorScheme.onSurfaceVariant,
            _MaterialSummaryTone.plain => null,
          };
          final parts = _materialSummaryParts(task);
          return Tooltip(
            message: _materialSummaryTooltip(task),
            child: Text.rich(
              TextSpan(
                style: base,
                children: [
                  for (var index = 0; index < parts.length; index++) ...[
                    if (index > 0) const TextSpan(text: ' · '),
                    TextSpan(
                      text: parts[index].$1,
                      style: toneColor(parts[index].$2) == null
                          ? null
                          : TextStyle(
                              color: toneColor(parts[index].$2),
                              fontWeight: FontWeight.w700,
                            ),
                    ),
                  ],
                ],
              ),
              key: ValueKey('workshop-material-summary-${task.segmentId}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
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
    // 2026-09-23 用户口径：产品数量紧跟颜色——看完「哪个产品、什么颜色」就看
    // 「做多少」，再往右才是订单 / 工单 / 车间。
    MasterColumnDef(
      key: 'qty',
      label: '产品数量',
      width: 130,
      type: 'number',
      value: (task) => '${task.plannedQty} ${task.productUnitName ?? ''}',
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

/// 「物料」列分段的着色档：缺料=红、可领=绿、待发=灰、其余默认。
enum _MaterialSummaryTone { plain, short, drawable, muted }

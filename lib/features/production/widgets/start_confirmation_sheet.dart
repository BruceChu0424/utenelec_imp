// 开工确认表 (ADR-131 §5.4, 合并 ADR-093/096 的生产路线确认)。
//
// 车间在「我的车间任务」勾选任务点「开工」, 其中有要先确认的行 (待认料或生产
// 路线还没选) 时弹出本表: 按产品一行, 选用料 (车间内料仓里的哪种料, 可多选;
// 或「不用内料仓的料, 按工单领料」)、需要时勾「还要按工单领别的料」、选生产
// 路线; 单个重量只读。
//
// 「确认并开工」依次: 一个请求写下全部认料 (按车间) → 对还没选路线的工单逐个
// 确认路线 (现有接口) → 按计划批量开工 (现有接口)。三步各自幂等, 中途失败时
// 表格与已填内容原样保留, 再点一次从没办完的那一步接着办 (认料同内容同一个
// 请求号, 已确认的路线与已开工的工单不再重复提交)。
//
// 网络段的全屏遮罩由本表自己持有 (发请求的是本表); 关闭本表之前一定先撤遮罩
// 并等一帧, 否则遮罩会盖住回到的任务页。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_repository.dart';
import '../repositories/workshop_material_choice_repository.dart';

/// 能在本表里直接开工的两条路线 (分批生产要先拆批, 在任务列表里办)。
const _startRoutes = ['CONTINUOUS', 'FULL_KIT'];

const _routeLabels = {
  'CONTINUOUS': '持续生产',
  'FULL_KIT': '齐套生产',
  'BATCH': '分批生产',
};

/// 开工确认表办完 (或办到一半被关掉) 时交回任务页的结果。
class StartConfirmationOutcome {
  const StartConfirmationOutcome({
    this.startedSegmentIds = const {},
    this.plannedStartCount = 0,
    this.drawSegmentIds = const [],
    this.batchSegmentIds = const [],
    this.wrote = false,
    this.error,
  });

  /// 已开工的工单。
  final Set<String> startedSegmentIds;

  /// 本次打算开工的工单数 (部分失败时提示「已开工 a / 共 b」用)。
  final int plannedStartCount;

  /// 已记下用料、开工前要先按工单领料的工单 (转到现有领料申请)。
  final List<String> drawSegmentIds;

  /// 已记下用料、生产路线是分批生产的工单 (在列表里点「分批生产领料」)。
  final List<String> batchSegmentIds;

  /// 有没有写下任何事实 (认料、路线、开工); 没有就不用刷新任务页。
  final bool wrote;

  /// 关表时还没办完的原因; null = 全部办完。
  final String? error;
}

/// 弹出开工确认表。[tasks] 是要先确认的行 (needsStartConfirmation);
/// [alsoStart] 是同一次勾选里不用确认、直接一起开工的行。
Future<StartConfirmationOutcome?> showStartConfirmationSheet(
  BuildContext context, {
  required List<ProductionExecutionWorkbenchSegment> tasks,
  List<ProductionExecutionWorkbenchSegment> alsoStart = const [],
}) {
  // 八列 (产品/编号/任务数/用料/另领/路线/单重/确认后) 合计约 1450 宽,
  // 侧板放得下时不必横向滚动去找路线列。
  final width = math.min(1560.0, MediaQuery.sizeOf(context).width * 0.94);
  return showUtenAdaptivePanel<StartConfirmationOutcome>(
    context: context,
    compactHeightFactor: 0.94,
    drawerWidth: width,
    barrierDismissible: false,
    enableDrag: false,
    panelElevation: 16,
    barrierColor: Colors.black.withValues(alpha: .38),
    barrierLabel: '关闭开工确认表',
    transitionDuration: const Duration(milliseconds: 300),
    builder: (_) => StartConfirmationSheet(tasks: tasks, alsoStart: alsoStart),
  );
}

/// 一格「用料」的选择: 用哪几种料, 或不用内料仓的料。
@immutable
class _MaterialSelection {
  const _MaterialSelection({this.none = false, this.materials = const []});

  final bool none;
  final List<WorkshopMaterialRef> materials;

  bool get isEmpty => !none && materials.isEmpty;
}

/// 表里一行 = 一个车间里的一个产品 (本次勾选的该产品全部工单)。
class _StartRow extends EditableGridRow {
  _StartRow({
    required this.pending,
    required this.tasks,
    required _MaterialSelection selection,
    required bool materialPrefilled,
    required String? route,
    required bool routePrefilled,
  }) : selection = ValueNotifier(selection),
       materialPrefilled = ValueNotifier(materialPrefilled),
       route = ValueNotifier(route),
       routePrefilled = ValueNotifier(routePrefilled);

  final WorkshopMaterialPendingChoice pending;
  final List<ProductionExecutionWorkbenchSegment> tasks;
  final ValueNotifier<_MaterialSelection> selection;
  final ValueNotifier<bool> alsoOrder = ValueNotifier(false);
  final ValueNotifier<String?> route;

  /// 用料还是预填值、没被人改过 (黄框提醒核对)。
  final ValueNotifier<bool> materialPrefilled;

  /// 路线还是按路线记忆预填、没被人改过。
  final ValueNotifier<bool> routePrefilled;

  late final Listenable changes = Listenable.merge([
    selection,
    materialPrefilled,
    alsoOrder,
    route,
    routePrefilled,
  ]);

  String get id => pending.productGoodsId;

  /// 这一行里还有没选生产路线的工单。
  bool get routeNeeded => tasks.any((task) => task.startRoute == null);

  /// 某个工单实际要走的路线 (已确认的不动, 没选的用本行下拉)。
  String? routeOf(ProductionExecutionWorkbenchSegment task) =>
      task.startRoute ?? route.value;

  @override
  void dispose() {
    selection.dispose();
    materialPrefilled.dispose();
    alsoOrder.dispose();
    route.dispose();
    routePrefilled.dispose();
    super.dispose();
  }
}

/// 一行确认后怎么办。
enum _RowPlan { incomplete, start, draw, batch }

class StartConfirmationSheet extends ConsumerStatefulWidget {
  const StartConfirmationSheet({
    super.key,
    required this.tasks,
    this.alsoStart = const [],
  });

  final List<ProductionExecutionWorkbenchSegment> tasks;
  final List<ProductionExecutionWorkbenchSegment> alsoStart;

  @override
  ConsumerState<StartConfirmationSheet> createState() =>
      _StartConfirmationSheetState();
}

class _StartConfirmationSheetState
    extends ConsumerState<StartConfirmationSheet> {
  final _grid = UtenEditableGridController<_StartRow>();

  /// 本次打开表格的请求号前缀: 同一张表里同样的内容重试用同一个请求号,
  /// 下次再打开是新的操作。
  final String _nonce = const Uuid().v4();

  bool _loading = true;
  String? _loadError;

  /// 本次勾选里不用确认、直接一起开工的工单 (含服务端说已不用确认的行)。
  List<ProductionExecutionWorkbenchSegment> _extraStart = const [];

  bool _busy = false;

  /// 最近一次提交是「确认并开工」还是「按工单领料 (暂不开工)」。
  bool _busyStartNow = true;
  String? _submitError;

  // 已办完的步骤 (重试时跳过)。
  final Set<String> _chosenKeys = {};
  final Map<String, int> _versions = {};
  final Set<String> _routeConfirmed = {};
  final Set<String> _started = {};
  bool _wrote = false;

  List<_StartRow> get _rows => _grid.rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final pending = await ref
          .read(workshopMaterialChoiceRepositoryProvider)
          .pending(widget.tasks.map((task) => task.segmentId).toList());
      if (!mounted) return;
      _applyPending(pending);
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = productionErrorMessage(error, fallback: '开工确认表没有读出来，请重试');
      });
    }
  }

  void _applyPending(List<WorkshopMaterialPendingChoice> pending) {
    final byId = {for (final task in widget.tasks) task.segmentId: task};
    final covered = <String>{};
    final rows = <_StartRow>[];
    for (final item in pending) {
      final tasks = [
        for (final id in item.segmentIds)
          if (byId[id] != null) byId[id]!,
      ];
      if (tasks.isEmpty) continue;
      covered.addAll(tasks.map((task) => task.segmentId));
      rows.add(_rowFor(item, tasks));
    }
    // 服务端没列出的行: 还没选路线的照样放进表里只选路线; 路线已定的说明
    // 已不用确认, 直接一起开工。
    final extra = <ProductionExecutionWorkbenchSegment>[...widget.alsoStart];
    for (final task in widget.tasks) {
      if (covered.contains(task.segmentId)) continue;
      if (task.startRoute == null) {
        rows.add(
          _rowFor(
            WorkshopMaterialPendingChoice(
              workshopDepartmentId: task.workshopDepartmentId ?? '',
              workshopName: task.workshopName,
              productGoodsId: 'segment-${task.segmentId}',
              productCode: task.productCode,
              productName: task.productName,
              segmentIds: [task.segmentId],
              taskCount: 1,
              choiceRequired: false,
            ),
            [task],
          ),
        );
      } else {
        extra.add(task);
      }
    }
    _extraStart = extra;
    _grid.replaceAll(rows);
  }

  _StartRow _rowFor(
    WorkshopMaterialPendingChoice item,
    List<ProductionExecutionWorkbenchSegment> tasks,
  ) {
    final prefilled = item.choiceRequired && item.prefill.isNotEmpty;
    // 路线记忆: 这一行没选路线的工单记忆一致且能直接开工时才预填。
    final remembered = {
      for (final task in tasks)
        if (task.startRoute == null) task.suggestedStartRoute,
    };
    final route =
        remembered.length == 1 && _startRoutes.contains(remembered.first)
        ? remembered.first
        : null;
    return _StartRow(
      pending: item,
      tasks: tasks,
      selection: prefilled
          ? _MaterialSelection(materials: item.prefill)
          : const _MaterialSelection(),
      materialPrefilled: prefilled,
      route: route,
      routePrefilled: route != null,
    );
  }

  // ---------------------------------------------------------------- 判定

  _RowPlan _planOf(_StartRow row) {
    if (row.pending.choiceRequired) {
      final selection = row.selection.value;
      if (selection.isEmpty) return _RowPlan.incomplete;
      if (selection.none && row.pending.alsoOrderMaterialsAllowed) {
        return _RowPlan.draw;
      }
      if (!selection.none &&
          row.pending.alsoOrderMaterialsAllowed &&
          row.alsoOrder.value) {
        return _RowPlan.draw;
      }
    }
    if (row.routeNeeded && row.route.value == null) return _RowPlan.incomplete;
    return row.tasks.any((task) => _startRoutes.contains(row.routeOf(task)))
        ? _RowPlan.start
        : _RowPlan.batch;
  }

  /// 缺什么没填 (只看 [rows]); 全填好返回 null。
  String? _missingOf(List<_StartRow> rows) {
    final noMaterial = rows
        .where(
          (row) => row.pending.choiceRequired && row.selection.value.isEmpty,
        )
        .length;
    final noRoute = rows
        .where((row) => row.routeNeeded && row.route.value == null)
        .length;
    if (noMaterial == 0 && noRoute == 0) return null;
    return [
      if (noMaterial > 0) '还有 $noMaterial 个产品没选用料',
      if (noRoute > 0) '还有 $noRoute 个产品没选生产路线',
    ].join('，');
  }

  List<_StartRow> get _drawRows =>
      _rows.where((row) => _planOf(row) == _RowPlan.draw).toList();

  /// 「确认并开工」要开工的工单 (表里能开工的 + 一起开工的)。
  List<ProductionExecutionWorkbenchSegment> _startTargets() => [
    for (final row in _rows)
      if (_planOf(row) == _RowPlan.start)
        for (final task in row.tasks)
          if (_startRoutes.contains(row.routeOf(task))) task,
    ..._extraStart,
  ];

  // ---------------------------------------------------------------- 编辑

  /// 勾选多行后改任一勾选行 = 对全部勾选行生效; 没勾选的行只改自己。
  List<_StartRow> _targetsFor(_StartRow row) =>
      _grid.isSelected(row) && _grid.selectedCount > 1
      ? _grid.selectedRows
      : [row];

  void _applySelection(_StartRow source, _MaterialSelection selection) {
    for (final row in _targetsFor(source)) {
      if (!row.pending.choiceRequired) continue;
      if (!identical(row, source) && !selection.none) {
        final offered = row.pending.options.map((o) => o.ref).toSet();
        if (!selection.materials.every(offered.contains)) continue;
      }
      row.materialPrefilled.value = false;
      if (selection.none) row.alsoOrder.value = false;
      row.selection.value = selection;
    }
  }

  void _applyAlsoOrder(_StartRow source, bool value) {
    for (final row in _targetsFor(source)) {
      final selection = row.selection.value;
      final eligible =
          row.pending.choiceRequired &&
          row.pending.alsoOrderMaterialsAllowed &&
          !selection.none &&
          !selection.isEmpty;
      if (eligible) row.alsoOrder.value = value;
    }
  }

  void _applyRoute(_StartRow source, String route) {
    for (final row in _targetsFor(source)) {
      if (!row.routeNeeded) continue;
      row.routePrefilled.value = false;
      row.route.value = route;
    }
  }

  Future<void> _pickMaterials(_StartRow row) async {
    if (_busy || !row.pending.choiceRequired) return;
    final l10n = AppLocalizations.of(context);
    final picked = await showDialog<_MaterialSelection>(
      context: context,
      builder: (_) => _MaterialPickerDialog(
        productName: row.pending.productName ?? '这个产品',
        options: row.pending.options,
        initial: row.selection.value,
        noneLabel: l10n.wmNotFromStore,
        rowId: row.id,
      ),
    );
    if (!mounted || picked == null) return;
    _applySelection(row, picked);
  }

  // ---------------------------------------------------------------- 提交

  WorkshopMaterialProductChoice _choiceOf(_StartRow row) {
    final selection = row.selection.value;
    if (selection.none) {
      return WorkshopMaterialProductChoice(
        productGoodsId: row.pending.productGoodsId,
        kind: workshopMaterialChoiceKindNone,
      );
    }
    return WorkshopMaterialProductChoice(
      productGoodsId: row.pending.productGoodsId,
      kind: workshopMaterialChoiceKindMaterial,
      materials: selection.materials,
      alsoOrderMaterials:
          row.pending.alsoOrderMaterialsAllowed && row.alsoOrder.value,
      prefillSource: row.materialPrefilled.value
          ? row.pending.prefillSource
          : null,
    );
  }

  int _versionOf(ProductionExecutionWorkbenchSegment task) =>
      _versions[task.segmentId] ?? task.lockVersion;

  Future<void> _writeChoices(List<_StartRow> rows) async {
    final byWorkshop = <String, List<WorkshopMaterialProductChoice>>{};
    for (final row in rows) {
      if (!row.pending.choiceRequired) continue;
      byWorkshop
          .putIfAbsent(row.pending.workshopDepartmentId, () => [])
          .add(_choiceOf(row));
    }
    final repository = ref.read(workshopMaterialChoiceRepositoryProvider);
    for (final entry in byWorkshop.entries) {
      final canonical = entry.value.map((choice) => choice.canonical).toList()
        ..sort();
      final key = businessIdempotencyKey(
        'wm-choose',
        '$_nonce|${entry.key}|${canonical.join(';')}',
      );
      if (_chosenKeys.contains(key)) continue;
      await repository.choose(
        workshopDepartmentId: entry.key,
        choices: entry.value,
        idempotencyKey: key,
      );
      _chosenKeys.add(key);
      _wrote = true;
    }
  }

  Future<void> _confirmRoutes(List<_StartRow> rows) async {
    final plans = ref.read(productionPlanRepositoryProvider);
    for (final row in rows) {
      final route = row.route.value;
      if (route == null) continue;
      for (final task in row.tasks) {
        if (task.startRoute != null ||
            _routeConfirmed.contains(task.segmentId)) {
          continue;
        }
        final view = await plans.confirmExecutionSegmentRoute(
          task.planId,
          task.segmentId,
          expectedVersion: _versionOf(task),
          route: route,
        );
        _versions[task.segmentId] = view.lockVersion;
        _routeConfirmed.add(task.segmentId);
        _wrote = true;
      }
    }
  }

  /// 按计划批量开工 (计划内原子、计划间串行); 返回第一个失败原因。
  Future<String?> _startAll() async {
    final byPlan = <String, List<ProductionExecutionWorkbenchSegment>>{};
    for (final task in _startTargets()) {
      if (_started.contains(task.segmentId)) continue;
      byPlan.putIfAbsent(task.planId, () => []).add(task);
    }
    final plans = ref.read(productionPlanRepositoryProvider);
    String? firstError;
    for (final entry in byPlan.entries) {
      try {
        await plans.batchStartExecutionSegments(
          entry.key,
          items: [
            for (final task in entry.value)
              (segmentId: task.segmentId, expectedVersion: _versionOf(task)),
          ],
        );
        _started.addAll(entry.value.map((task) => task.segmentId));
        _wrote = true;
      } catch (error) {
        firstError ??= productionErrorMessage(error, fallback: '开工失败，请重试');
      }
    }
    return firstError;
  }

  Future<void> _submit({required bool startNow}) async {
    if (_busy || _loading) return;
    final rows = startNow ? _rows : _drawRows;
    final missing = _missingOf(rows);
    if (missing != null) {
      setState(() => _submitError = missing);
      return;
    }
    setState(() {
      _busy = true;
      _busyStartNow = startNow;
      _submitError = null;
    });
    String? failure;
    try {
      await _writeChoices(rows);
      await _confirmRoutes(rows);
      if (startNow) failure = await _startAll();
    } catch (error) {
      failure = productionErrorMessage(
        error,
        fallback: startNow ? '开工没有办完，请重试' : '用料没有记下，请重试',
      );
    }
    if (!mounted) return;
    // 先撤遮罩并等这一帧画完, 再关表或显示错误 (遮罩是 root Overlay 裸图层)。
    setState(() => _busy = false);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (failure != null) {
      setState(() => _submitError = failure);
      return;
    }
    Navigator.of(context).pop(_outcome(rows, startNow: startNow));
  }

  StartConfirmationOutcome _outcome(
    List<_StartRow> rows, {
    required bool startNow,
    String? error,
  }) {
    final draw = <String>[];
    final batch = <String>[];
    if (error == null) {
      for (final row in rows) {
        final plan = _planOf(row);
        if (plan == _RowPlan.draw) {
          draw.addAll(row.tasks.map((task) => task.segmentId));
        } else if (startNow) {
          batch.addAll(
            row.tasks
                .where((task) => !_startRoutes.contains(row.routeOf(task)))
                .map((task) => task.segmentId),
          );
        }
      }
    }
    return StartConfirmationOutcome(
      startedSegmentIds: Set<String>.unmodifiable(_started),
      plannedStartCount: startNow ? _startTargets().length : 0,
      drawSegmentIds: draw,
      batchSegmentIds: batch,
      wrote: _wrote,
      error: error,
    );
  }

  void _close() {
    if (_busy) return;
    Navigator.of(context).pop(
      _wrote
          ? _outcome(
              _rows,
              startNow: _busyStartNow,
              error: _submitError ?? '开工确认表已关闭，没办完的工单还在列表里',
            )
          : null,
    );
  }

  // ---------------------------------------------------------------- 画面

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return PopScope<StartConfirmationOutcome>(
      canPop: !_busy && !_wrote,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(l10n.wmStartSheetTitle),
          actions: [
            IconButton(
              key: const Key('start-confirmation-close'),
              tooltip: '关闭',
              onPressed: _busy ? null : _close,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: UtenSpacing.s8),
                      UtenButton(
                        type: UtenButtonType.tonal,
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            : Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _notice(theme),
                        const SizedBox(height: UtenSpacing.s12),
                        if (_rows.isNotEmpty)
                          UtenEditableGrid<_StartRow>(
                            tableKey:
                                'features.production.widgets.start_confirmation_sheet.StartConfirmationSheetState.build.1',
                            controller: _grid,
                            columns: _columns(l10n),
                            showAddRow: false,
                            showRowDelete: false,
                            selectable: true,
                            selectionEnabled: !_busy,
                            showColumnSettings: false,
                            showRemoveRowsAction: false,
                            emptyMessage: '没有要确认的产品',
                          )
                        else
                          const Text('这些工单已经不用确认，可以直接开工。'),
                        if (_submitError != null)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: UtenSpacing.s12,
                            ),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _submitError!,
                                key: const Key('start-confirmation-error'),
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: UtenSpacing.s16),
                        _actions(l10n),
                        const SizedBox(height: UtenSpacing.s16),
                      ],
                    ),
                  ),
                  if (_busy)
                    UtenBusyOverlay(
                      semanticsKey: const Key('start-confirmation-busy'),
                      title: _busyStartNow ? '正在确认用料并开工' : '正在记下用料',
                      description: _busyStartNow
                          ? '正在依次记下用料、确认生产路线并开工，办完自动关闭。'
                          : '正在记下用料并确认生产路线，办完转去领料。',
                    ),
                ],
              ),
      ),
    );
  }

  Widget _notice(ThemeData theme) {
    final color = theme.colorScheme.primary;
    final extra = _extraStart.length;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .06),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: color),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '每个产品只要选一次用料，以后同一产品开工自动带出。'
              '勾选多行后在任一勾选行里选，会对全部勾选行一起生效。'
              '${extra > 0 ? '另有 $extra 个工单不用确认，会一起开工。' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(AppLocalizations l10n) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _grid,
        for (final row in _rows) row.changes,
      ]),
      builder: (context, _) {
        final startCount = _loading ? 0 : _startTargets().length;
        final drawRows = _drawRows;
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          children: [
            UtenButton(
              key: const Key('start-confirmation-submit'),
              icon: Icons.play_circle_fill_rounded,
              onPressed: _busy || startCount == 0
                  ? null
                  : () => _submit(startNow: true),
              child: Text(l10n.wmStartConfirm(startCount)),
            ),
            if (drawRows.isNotEmpty)
              UtenButton(
                key: const Key('start-confirmation-order-instead'),
                type: UtenButtonType.secondary,
                icon: Icons.move_to_inbox_rounded,
                onPressed: _busy ? null : () => _submit(startNow: false),
                child: Text(l10n.wmOrderInstead),
              ),
          ],
        );
      },
    );
  }

  List<EditableGridColumn<_StartRow>> _columns(AppLocalizations l10n) => [
    EditableGridColumn(
      key: 'product',
      label: '产品名称',
      width: 180,
      textOf: (row) => row.pending.productName ?? '',
      cellBuilder: (context, row) => UtenGoodsIdentityCell(
        name: row.pending.productName,
        emptyPlaceholder: '未命名产品',
      ),
    ),
    EditableGridColumn(
      key: 'productCode',
      label: '编号',
      width: 120,
      frozenTextOf: (row) => row.pending.productCode ?? '',
      cellBuilder: (context, row) =>
          UtenGoodsAttributeCell(row.pending.productCode),
    ),
    EditableGridColumn(
      key: 'taskCount',
      exactValueOf: (row) => row.tasks.length.toString(),
      exactListenableOf: (row) => row.changes,
      label: '本次任务数',
      width: 100,
      numeric: true,
      frozenTextOf: (row) => '${row.tasks.length}',
      cellBuilder: (context, row) =>
          Text('${row.tasks.length}', textAlign: TextAlign.right),
    ),
    EditableGridColumn(
      key: 'material',
      label: '用料',
      width: 280,
      required: true,
      headerInfo:
          '选这个产品用车间内料仓里的哪种料，每个产品只选一次，以后自动带出。'
          '同时用两种料 (双色 / 双料) 就都勾上；不用内料仓的料就选最下面一项，'
          '按工单领料。',
      frozenTextOf: (row) => _selectionText(row),
      cellBuilder: (context, row) => _materialCell(context, row, l10n),
    ),
    EditableGridColumn(
      key: 'alsoOrder',
      label: l10n.wmAlsoOrderMaterials,
      width: 190,
      headerInfo:
          '只对没有 BOM 的产品出现。像嵌件注塑件这样，除了塑料还要领嵌件的，'
          '勾上它：塑料从车间内料仓用，嵌件照常按工单领料，领完再开工。',
      frozenTextOf: (row) => row.alsoOrder.value ? '要' : '',
      cellBuilder: (context, row) => _alsoOrderCell(row),
    ),
    EditableGridColumn(
      key: 'route',
      label: '生产路线',
      width: 170,
      required: true,
      headerInfo:
          '齐套生产 = 全部物料到齐并领齐后开工；持续生产 = 每种物料共同支持一部分'
          '产量即可开工，后续到料在同一工单继续领。分批生产请在任务列表的「下一步」'
          '里选。已经选过路线的工单这里只显示。',
      frozenTextOf: (row) => _routeText(row),
      cellBuilder: (context, row) => _routeCell(row),
    ),
    EditableGridColumn(
      key: 'weight',
      label: l10n.wmUnitWeightGrams,
      width: 150,
      headerInfo: '来自 BOM 的单个重量，只读。没填的不影响开工，盘点结算前补上就行。',
      frozenTextOf: (row) => _weightText(row, l10n),
      cellBuilder: (context, row) => ValueListenableBuilder<_MaterialSelection>(
        valueListenable: row.selection,
        builder: (context, _, _) => Text(
          _weightText(row, l10n),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    EditableGridColumn(
      key: 'plan',
      label: '确认后',
      width: 200,
      frozenTextOf: (row) => _planText(_planOf(row)),
      cellBuilder: (context, row) => ListenableBuilder(
        listenable: row.changes,
        builder: (context, _) => _planCell(context, _planOf(row)),
      ),
    ),
  ];

  String _labelOfRef(_StartRow row, WorkshopMaterialRef ref) {
    for (final option in row.pending.options) {
      if (option.ref == ref) return option.label;
    }
    return '已选的料';
  }

  String _selectionText(_StartRow row) {
    if (!row.pending.choiceRequired) return '用料已定';
    final selection = row.selection.value;
    if (selection.none) return AppLocalizations.of(context).wmNotFromStore;
    return selection.materials.map((ref) => _labelOfRef(row, ref)).join('、');
  }

  Widget _materialCell(
    BuildContext context,
    _StartRow row,
    AppLocalizations l10n,
  ) {
    if (!row.pending.choiceRequired) {
      return Tooltip(
        message: '这个产品的用料已经定了 (按 BOM 或上次选的料)，这次只需确认生产路线',
        child: Text(
          '用料已定',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([row.selection, row.materialPrefilled]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final empty = row.selection.value.isEmpty;
        final prefilled = row.materialPrefilled.value;
        final prefillHint = prefilled
            ? (row.pending.prefillSource == workshopMaterialPrefillLegacyText
                  ? '按老库材质预填，请核对'
                  : '按上次选的料预填，请核对')
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              key: ValueKey('start-sheet-material-${row.id}'),
              borderRadius: BorderRadius.circular(UtenRadius.control),
              onTap: _busy ? null : () => _pickMaterials(row),
              child: InputDecorator(
                isEmpty: empty,
                decoration: applyRequiredEmpty(
                  applyAutofillHint(
                    const UtenInputDecoration(
                      // 选择格统一规格（UtenEditableGridCellSpec，2026-10-08）：
                      // 与同行输入格等高；单行省略号防选料文案折行撑高行。
                      InputDecoration(
                        isDense: true,
                        contentPadding:
                            UtenEditableGridCellSpec.pickerCellPadding,
                        hintText: '选择用料',
                        hintMaxLines: 1,
                        suffixIcon: Icon(
                          Icons.arrow_drop_down_rounded,
                          size: 20,
                        ),
                      ),
                    ),
                    theme,
                    autofilled: prefilled && !empty,
                  ),
                  theme,
                  requiredEmpty: empty,
                ),
                child: Text(
                  empty ? '' : _selectionText(row),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (prefillHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  prefillHint,
                  key: ValueKey('start-sheet-prefill-${row.id}'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.brightness == Brightness.dark
                        ? UtenColors.warningOnDark
                        : UtenColors.warningText,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _alsoOrderCell(_StartRow row) {
    if (!row.pending.choiceRequired || !row.pending.alsoOrderMaterialsAllowed) {
      return const Text('—');
    }
    return ListenableBuilder(
      listenable: Listenable.merge([row.selection, row.alsoOrder]),
      builder: (context, _) {
        final selection = row.selection.value;
        if (selection.none || selection.isEmpty) return const Text('—');
        return Align(
          alignment: Alignment.centerLeft,
          child: Checkbox(
            key: ValueKey('start-sheet-also-order-${row.id}'),
            value: row.alsoOrder.value,
            onChanged: _busy
                ? null
                : (value) => _applyAlsoOrder(row, value ?? false),
          ),
        );
      },
    );
  }

  String _routeText(_StartRow row) {
    if (row.routeNeeded) {
      final route = row.route.value;
      return route == null ? '' : _routeLabels[route] ?? route;
    }
    return row.tasks
        .map((task) => _routeLabels[task.startRoute] ?? '')
        .toSet()
        .join('、');
  }

  Widget _routeCell(_StartRow row) {
    if (!row.routeNeeded) {
      return Text(
        _routeText(row),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([row.route, row.routePrefilled]),
      builder: (context, _) => UtenDropdownField(
        key: ValueKey('start-sheet-route-${row.id}'),
        dense: true,
        required: true,
        allowClear: false,
        searchable: false,
        enabled: !_busy,
        value: row.route.value,
        hintText: '选择生产路线',
        autofilled: row.routePrefilled.value,
        warningMessage: row.routePrefilled.value ? '已按上次选择的路线预填，请核对' : null,
        items: [
          for (final option in _startRoutes)
            UtenDropdownItem(value: option, label: _routeLabels[option]!),
        ],
        onChanged: (value) {
          if (value == null) return;
          _applyRoute(row, value);
        },
      ),
    );
  }

  String _weightText(_StartRow row, AppLocalizations l10n) {
    if (row.pending.choiceRequired && row.selection.value.none) return '—';
    if (row.pending.bomWeights.isEmpty) {
      return row.pending.choiceRequired ? l10n.wmWeightPending : '—';
    }
    return row.pending.bomWeights
        .map(
          (weight) => weight.unitWeightGrams == null
              ? l10n.wmWeightPending
              : '${_grams(weight.unitWeightGrams!)} 克',
        )
        .join('、');
  }

  static String _grams(double value) {
    final fixed = value.toStringAsFixed(3);
    final trimmed = fixed.replaceFirst(RegExp(r'0+$'), '');
    return trimmed.endsWith('.')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  String _planText(_RowPlan plan) => switch (plan) {
    _RowPlan.incomplete => '待选',
    _RowPlan.start => '确认后开工',
    _RowPlan.draw => '先按工单领料，暂不开工',
    _RowPlan.batch => '分批生产：回列表分批领料',
  };

  Widget _planCell(BuildContext context, _RowPlan plan) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final color = switch (plan) {
      _RowPlan.incomplete => theme.colorScheme.onSurfaceVariant,
      _RowPlan.start =>
        dark ? UtenColors.successOnDark : UtenColors.successText,
      _RowPlan.draw => dark ? UtenColors.warningOnDark : UtenColors.warningText,
      _RowPlan.batch => theme.colorScheme.onSurfaceVariant,
    };
    return Text(
      _planText(plan),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontWeight: FontWeight.w600),
    );
  }
}

/// 「用料」多选: 内料仓收的料可勾多种 (双色 / 双料), 或选最下面一项
/// 「不用内料仓的料」(与其它选项互斥, 选项里列出内料仓收的全部料名)。
class _MaterialPickerDialog extends StatefulWidget {
  const _MaterialPickerDialog({
    required this.productName,
    required this.options,
    required this.initial,
    required this.noneLabel,
    required this.rowId,
  });

  final String productName;
  final List<WorkshopMaterialOption> options;
  final _MaterialSelection initial;
  final String noneLabel;
  final String rowId;

  @override
  State<_MaterialPickerDialog> createState() => _MaterialPickerDialogState();
}

class _MaterialPickerDialogState extends State<_MaterialPickerDialog> {
  late bool _none = widget.initial.none;
  late final List<WorkshopMaterialRef> _chosen = [...widget.initial.materials];

  bool get _valid => _none || _chosen.isNotEmpty;

  void _toggle(WorkshopMaterialRef ref, bool on) {
    setState(() {
      _none = false;
      if (on) {
        if (!_chosen.contains(ref)) _chosen.add(ref);
      } else {
        _chosen.remove(ref);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = widget.options.map((option) => option.label).join('、');
    return AlertDialog(
      title: Text('「${widget.productName}」用哪种料'),
      content: SizedBox(
        width: 440,
        height: math.min(
          MediaQuery.sizeOf(context).height * 0.6,
          120.0 + 64.0 * (widget.options.length + 1),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.options.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: Text(
                    '本车间内料仓还没有收任何料；这个产品只能先按工单领料。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              for (final option in widget.options)
                CheckboxListTile(
                  key: ValueKey(
                    'start-sheet-option-${widget.rowId}-${option.ref.key}',
                  ),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: !_none && _chosen.contains(option.ref),
                  onChanged: (value) => _toggle(option.ref, value ?? false),
                  title: Text(option.label),
                  subtitle: option.goodsCode == null
                      ? null
                      : Text(option.goodsCode!),
                ),
              if (widget.options.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                  child: Text(
                    '同时用两种料 (双色 / 双料) 就都勾上。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const Divider(),
              CheckboxListTile(
                key: ValueKey('start-sheet-option-${widget.rowId}-none'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _none,
                onChanged: (value) => setState(() {
                  _none = value ?? false;
                  if (_none) _chosen.clear();
                }),
                title: Text(widget.noneLabel),
                subtitle: Text(
                  names.isEmpty ? '本车间内料仓还没有收料' : '本车间内料仓收的料：$names',
                ),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('start-sheet-material-confirm'),
          onPressed: _valid
              ? () => Navigator.of(context).pop(
                  _MaterialSelection(
                    none: _none,
                    materials: _none
                        ? const []
                        : List<WorkshopMaterialRef>.unmodifiable(_chosen),
                  ),
                )
              : null,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

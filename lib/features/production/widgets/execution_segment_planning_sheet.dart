import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../department/models/department_node.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/production_execution_planning.dart';
import '../providers/production_department_provider.dart';

enum ProductionPlanningSheetMode { draft, confirm }

/// Opens the V155 execution-segment planner.
///
/// Desktop uses an 840 px right drawer; compact screens use a nearly full
/// height bottom sheet. Material cards are intentionally always expanded.
Future<ProductionPlanningConfirmRequest?> showExecutionSegmentPlanningSheet(
  BuildContext context,
  WidgetRef ref, {
  required ProductionPlanningPreview preview,
  required MasterNameService names,
  required String warehouseName,
  required ProductionPlanningSheetMode mode,
  ProductionPlanningDraftView? initialDraft,
  bool initialDraftRebased = false,
  List<String> initialFocusMaterialIds = const <String>[],
}) {
  final sheet = _ExecutionPlanningSheet(
    preview: preview,
    names: names,
    warehouseName: warehouseName,
    mode: mode,
    initialDraft: initialDraft,
    initialDraftRebased: initialDraftRebased,
    initialFocusMaterialIds: initialFocusMaterialIds,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<ProductionPlanningConfirmRequest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.96,
          child: sheet,
        ),
      ),
    );
  }
  return showGeneralDialog<ProductionPlanningConfirmRequest>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: UtenAnim.normal,
    pageBuilder: (ctx, _, _) {
      final width = MediaQuery.sizeOf(ctx).width;
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Theme.of(ctx).colorScheme.surface,
          elevation: 12,
          child: SizedBox(
            width: width < 920 ? width * 0.94 : 840,
            height: double.infinity,
            child: sheet,
          ),
        ),
      );
    },
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: UtenAnim.standard)),
      child: child,
    ),
  );
}

class _ExecutionGridRow extends EditableGridRow {
  _ExecutionGridRow({
    required this.source,
    required this.clientSegmentKey,
    required double plannedQty,
    required this.status,
    required this.onChanged,
    this.deferUntilManualRelease = false,
    this.workshopDepartmentId,
    this.teamDepartmentId,
    this.responsible,
    this.planBeginDate,
    this.planEndDate,
  }) : qty = TextEditingController(text: _fmt(plannedQty)) {
    qty.addListener(onChanged);
  }

  factory _ExecutionGridRow.fromDraft(
    ProductionExecutionSegmentConfirm draft,
    ProductionExecutionSegmentPreview source,
    VoidCallback onChanged,
    MasterNameService names,
  ) {
    final responsibleId = draft.responsibleEmployeeId;
    return _ExecutionGridRow(
      source: source,
      clientSegmentKey: draft.clientSegmentKey,
      plannedQty: draft.plannedQty,
      status: draft.requestedStatus,
      deferUntilManualRelease: draft.deferUntilManualRelease,
      workshopDepartmentId: draft.workshopDepartmentId,
      teamDepartmentId: draft.teamDepartmentId,
      responsible: responsibleId == null
          ? null
          : UtenEmployeePickerItem(
              id: responsibleId,
              name: names.employee(responsibleId),
            ),
      planBeginDate: DateTime.tryParse(draft.planBeginDate ?? ''),
      planEndDate: DateTime.tryParse(draft.planEndDate ?? ''),
      onChanged: onChanged,
    );
  }

  factory _ExecutionGridRow.fromPreview(
    ProductionExecutionSegmentPreview source,
    VoidCallback onChanged,
    MasterNameService names,
  ) {
    final responsibleId = source.responsibleEmployeeId;
    return _ExecutionGridRow(
      source: source,
      clientSegmentKey: source.clientSegmentKey,
      plannedQty: source.plannedQty,
      status: source.suggestedStatus,
      workshopDepartmentId: source.workshopDepartmentId,
      teamDepartmentId: source.teamDepartmentId,
      responsible: responsibleId == null
          ? null
          : UtenEmployeePickerItem(
              id: responsibleId,
              name: names.employee(responsibleId),
            ),
      planBeginDate: DateTime.tryParse(source.planBeginDate ?? ''),
      planEndDate: DateTime.tryParse(source.planEndDate ?? ''),
      onChanged: onChanged,
    );
  }

  final ProductionExecutionSegmentPreview source;
  final String clientSegmentKey;
  final TextEditingController qty;
  final VoidCallback onChanged;

  String status;
  bool deferUntilManualRelease;
  String? workshopDepartmentId;
  String? teamDepartmentId;
  UtenEmployeePickerItem? responsible;
  DateTime? planBeginDate;
  DateTime? planEndDate;

  double? get parsedQty => double.tryParse(qty.text.trim());

  String get dispatchDecision => status == 'READY'
      ? 'READY'
      : deferUntilManualRelease
      ? 'DEFERRED'
      : 'AUTO_WAIT';

  void setDispatchDecision(String decision) {
    status = decision == 'READY' ? 'READY' : 'WAITING';
    deferUntilManualRelease = decision == 'DEFERRED';
  }

  @override
  void dispose() {
    qty.removeListener(onChanged);
    qty.dispose();
    super.dispose();
  }

  static String _fmt(double value) => formatProductionPlanningQuantity(value);
}

class _MaterialDisplayRow {
  const _MaterialDisplayRow({
    required this.goodsId,
    required this.unitId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    required this.perProductQty,
    required this.requirementMode,
    required this.requiredQty,
    required this.availableBeforeQty,
    required this.allocatedQty,
    required this.shortageQty,
    required this.supplyRoute,
    this.colorId,
    this.bookStock,
    this.reservedQty,
    this.safetyStock,
    this.openPoTotal,
    this.openPoOnTime,
    this.earliestArrivalDate,
    this.timelyShortage,
    this.materialStatus,
  });

  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String unitId;
  final double perProductQty;
  final String requirementMode;
  final double requiredQty;
  final double availableBeforeQty;
  final double allocatedQty;
  final double shortageQty;
  final String supplyRoute;
  final double? bookStock;
  final double? reservedQty;
  final double? safetyStock;
  final double? openPoTotal;
  final double? openPoOnTime;
  final String? earliestArrivalDate;
  final double? timelyShortage;
  final String? materialStatus;
}

class _ProductGroup {
  const _ProductGroup({
    required this.source,
    required this.totalQty,
    required this.readyQty,
    required this.waitingQty,
    required this.materials,
  });

  final ProductionExecutionSegmentPreview source;
  final double totalQty;
  final double readyQty;
  final double waitingQty;
  final List<_MaterialDisplayRow> materials;

  int get shortageKinds =>
      materials.where((material) => material.shortageQty > _epsilon).length;
}

class _ExecutionPlanningSheet extends ConsumerStatefulWidget {
  const _ExecutionPlanningSheet({
    required this.preview,
    required this.names,
    required this.warehouseName,
    required this.mode,
    this.initialDraft,
    this.initialDraftRebased = false,
    this.initialFocusMaterialIds = const <String>[],
  });

  final ProductionPlanningPreview preview;
  final MasterNameService names;
  final String warehouseName;
  final ProductionPlanningSheetMode mode;
  final ProductionPlanningDraftView? initialDraft;
  final bool initialDraftRebased;
  final List<String> initialFocusMaterialIds;

  @override
  ConsumerState<_ExecutionPlanningSheet> createState() =>
      _ExecutionPlanningSheetState();
}

class _ExecutionPlanningSheetState
    extends ConsumerState<_ExecutionPlanningSheet> {
  late final UtenEditableGridController<_ExecutionGridRow> _grid;
  late final List<_ProductGroup> _productGroups;
  bool _generatePurchaseRequest = false;
  bool _dirty = false;
  bool _allowPop = false;
  bool _showAllProductGroups = true;
  int _nextManualKey = 1;

  @override
  void initState() {
    super.initState();
    final initialDraft = widget.initialDraft;
    _showAllProductGroups = widget.initialFocusMaterialIds.isEmpty;
    _generatePurchaseRequest =
        initialDraft?.generatePurchaseRequest ?? _purchaseShortageKinds > 0;
    _productGroups = _buildProductGroups(
      widget.preview.executionSegments,
      widget.preview.materials,
    );
    final sources = <String, ProductionExecutionSegmentPreview>{
      for (final source in widget.preview.executionSegments)
        source.sourcePlanItemId: source,
    };
    _grid = UtenEditableGridController(
      initial: initialDraft == null
          ? [
              for (final source in widget.preview.executionSegments)
                _ExecutionGridRow.fromPreview(source, _markDirty, widget.names),
            ]
          : [
              for (final segment in initialDraft.segments)
                if (sources[segment.sourcePlanItemId] case final source?)
                  _ExecutionGridRow.fromDraft(
                    segment,
                    source,
                    _markDirty,
                    widget.names,
                  ),
            ],
    )..addListener(_gridShapeChanged);
  }

  @override
  void dispose() {
    _grid.removeListener(_gridShapeChanged);
    _grid.dispose();
    super.dispose();
  }

  List<_ProductGroup> get _visibleProductGroups {
    if (_showAllProductGroups) return _productGroups;
    final focused = widget.initialFocusMaterialIds.toSet();
    final matches = _productGroups
        .where(
          (group) => group.materials.any(
            (material) => focused.contains(material.goodsId),
          ),
        )
        .toList(growable: false);
    return matches.isEmpty ? _productGroups : matches;
  }

  int get _purchaseShortageKinds {
    final keys = <String>{};
    for (final segment in widget.preview.executionSegments) {
      for (final material in segment.materials) {
        if (material.shortageQty > _epsilon && material.supplyRoute == 'BUY') {
          keys.add('${material.goodsId}|${material.colorId ?? ''}');
        }
      }
    }
    return keys.length;
  }

  int get _readyCount =>
      _grid.rows.where((row) => row.status == 'READY').length;

  int get _waitingCount => _grid.rows
      .where((row) => row.status == 'WAITING' && !row.deferUntilManualRelease)
      .length;

  int get _deferredCount =>
      _grid.rows.where((row) => row.deferUntilManualRelease).length;

  int get _unassignedCount =>
      _grid.rows.where((row) => row.workshopDepartmentId == null).length;

  String get _earliestCompletion {
    final dates =
        _grid.rows
            .where((row) => row.status == 'READY')
            .map((row) => row.planEndDate)
            .whereType<DateTime>()
            .toList()
          ..sort();
    return dates.isEmpty ? '待排定' : _dateText(dates.first)!;
  }

  void _markDirty() {
    if (!mounted) return;
    setState(() => _dirty = true);
  }

  void _gridShapeChanged() {
    if (!mounted) return;
    setState(() => _dirty = true);
  }

  Future<void> _requestClose() async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('放弃本次排产调整？'),
          content: const Text('已修改的数量、车间、班组或日期不会被保存。'),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续编辑'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃并关闭'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    _finish();
  }

  void _finish([ProductionPlanningConfirmRequest? result]) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 滑窗经 showGeneralDialog 推在 root navigator；关闭须对齐 rootNavigator，
      // 否则嵌套 navigator 下会误 pop 内层路由或让全屏路由孤立留栈（详细排产关闭后变全屏 bug）。
      if (mounted) Navigator.of(context, rootNavigator: true).pop(result);
    });
  }

  Future<void> _pickDate(_ExecutionGridRow row, bool begin) async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: (begin ? row.planBeginDate : row.planEndDate) ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 3650)),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (begin) {
        row.planBeginDate = selected;
        if (row.planEndDate != null && row.planEndDate!.isBefore(selected)) {
          row.planEndDate = selected;
        }
      } else {
        row.planEndDate = selected;
      }
      _dirty = true;
    });
  }

  Future<void> _addSplit() async {
    final sources = <String, ProductionExecutionSegmentPreview>{};
    for (final segment in widget.preview.executionSegments) {
      sources.putIfAbsent(segment.sourcePlanItemId, () => segment);
    }
    final source = await showDialog<ProductionExecutionSegmentPreview>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择要继续拆分的产品'),
        children: [
          for (final item in sources.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, item),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(item.productName ?? item.productCode ?? '未命名产品'),
                subtitle: Text(
                  '${item.productCode ?? item.productGoodsId} · '
                  '订单行 ${item.sourceLineNo ?? '—'}',
                ),
              ),
            ),
        ],
      ),
    );
    if (source == null || !mounted) return;
    final originalTotal =
        _sourceTotals(
          widget.preview.executionSegments,
        )[source.sourcePlanItemId] ??
        0;
    final currentTotal = _grid.rows
        .where((row) => row.source.sourcePlanItemId == source.sourcePlanItemId)
        .fold<double>(0, (sum, row) => sum + (row.parsedQty ?? 0));
    _grid.addRow(
      _ExecutionGridRow(
        source: source,
        clientSegmentKey:
            '${source.sourcePlanItemId}-manual-${_nextManualKey++}',
        plannedQty: (originalTotal - currentTotal).clamp(0, double.infinity),
        status: 'WAITING',
        workshopDepartmentId: source.workshopDepartmentId,
        teamDepartmentId: source.teamDepartmentId,
        planBeginDate: DateTime.tryParse(source.planBeginDate ?? ''),
        planEndDate: DateTime.tryParse(source.planEndDate ?? ''),
        onChanged: _markDirty,
      ),
    );
  }

  void _resetProposal() {
    _grid.replaceAll([
      for (final source in widget.preview.executionSegments)
        _ExecutionGridRow.fromPreview(source, _markDirty, widget.names),
    ]);
    setState(() {
      _generatePurchaseRequest = _purchaseShortageKinds > 0;
      _dirty = false;
    });
  }

  void _confirm() {
    if (widget.preview.hasBlockingBomGaps) {
      context.appError('仍有成品或自制组件缺少 BOM，补齐前不能保存或下达排产方案');
      return;
    }
    if (!widget.preview.executionSegmentationReady) {
      context.appError('服务端未能形成可追溯执行分段，请刷新物料或补齐 BOM 后重试');
      return;
    }
    if (_grid.isEmpty) {
      context.appError('至少保留一个执行分段');
      return;
    }

    final originalTotals = _sourceTotals(widget.preview.executionSegments);

    final currentTotals = <String, double>{};
    for (final row in _grid.rows) {
      final qty = row.parsedQty;
      final name = row.source.productName ?? row.source.productCode ?? '未命名产品';
      if (!_hasValidPlanningQuantityScale(row.qty.text)) {
        context.appError('$name 的实排数量最多保留四位小数');
        return;
      }
      if (qty == null || !qty.isFinite || qty <= 0) {
        context.appError('$name 的计划数量必须大于 0');
        return;
      }
      if (row.planBeginDate != null &&
          row.planEndDate != null &&
          row.planEndDate!.isBefore(row.planBeginDate!)) {
        context.appError('$name 的完工日期不能早于开工日期');
        return;
      }
      currentTotals.update(
        row.source.sourcePlanItemId,
        (value) => value + qty,
        ifAbsent: () => qty,
      );
    }

    for (final entry in originalTotals.entries) {
      final actual = currentTotals[entry.key] ?? 0;
      if ((actual - entry.value).abs() > _epsilon) {
        final product = widget.preview.executionSegments.firstWhere(
          (item) => item.sourcePlanItemId == entry.key,
        );
        final name = product.productName ?? product.productCode ?? '未命名产品';
        context.appError(
          '$name 的执行分段合计必须等于订单未排数量 ${_fmt(entry.value)}，'
          '当前为 ${_fmt(actual)}',
        );
        return;
      }
    }
    if (currentTotals.keys.any((key) => !originalTotals.containsKey(key))) {
      context.appError('存在不属于当前预览的执行行，请刷新后重试');
      return;
    }

    final routes = buildProductionMaterialSupplyRoutes(
      widget.preview.executionSegments,
    );

    final segments = [
      for (final row in _grid.rows)
        ProductionExecutionSegmentConfirm(
          clientSegmentKey: row.clientSegmentKey,
          sourcePlanItemId: row.source.sourcePlanItemId,
          requestedStatus: row.status,
          deferUntilManualRelease: row.deferUntilManualRelease,
          plannedQty: row.parsedQty!,
          workshopDepartmentId: row.workshopDepartmentId,
          teamDepartmentId: row.teamDepartmentId,
          responsibleEmployeeId: row.responsible?.id,
          planBeginDate: _dateText(row.planBeginDate),
          planEndDate: _dateText(row.planEndDate),
          bomFingerprint: row.source.bomFingerprint,
        ),
    ];
    final canonical = [
      widget.preview.planId,
      widget.preview.warehouseId,
      widget.preview.fingerprint,
      _generatePurchaseRequest,
      for (final segment in segments)
        [
          segment.clientSegmentKey,
          segment.sourcePlanItemId,
          segment.requestedStatus,
          segment.deferUntilManualRelease,
          segment.plannedQty,
          segment.workshopDepartmentId,
          segment.teamDepartmentId,
          segment.responsibleEmployeeId,
          segment.planBeginDate,
          segment.planEndDate,
          segment.bomFingerprint,
        ].join('|'),
    ].join('::');

    _finish(
      ProductionPlanningConfirmRequest(
        warehouseId: widget.preview.warehouseId,
        idempotencyKey: businessIdempotencyKey(
          'production-planning',
          '$canonical::ATTEMPT::${const Uuid().v4()}',
        ),
        previewFingerprint: widget.preview.fingerprint,
        generatePurchaseRequest:
            _purchaseShortageKinds > 0 && _generatePurchaseRequest,
        routes: routes,
        segments: segments,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workshops = ref.watch(productionWorkshopTreeProvider).valueOrNull;
    return PopScope<ProductionPlanningConfirmRequest?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _header(theme),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _stats(theme),
                      if (widget.initialDraft != null) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        _notice(
                          theme,
                          color: widget.initialDraftRebased
                              ? theme.colorScheme.tertiary
                              : Colors.green,
                          icon: widget.initialDraftRebased
                              ? Icons.sync_problem_outlined
                              : Icons.edit_note_outlined,
                          text: widget.initialDraftRebased
                              ? '已载入原草案的数量、先后顺序、车间和日期；库存可用量发生变化，'
                                    '下方物料建议按最新库存重算。保存时服务端会再次校验，可开工行不齐套将拒绝提交。'
                              : '已载入当前有效草案，可继续调整后覆盖保存；不会修改历史计划或生成正式单据。',
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s8),
                      if (_waitingCount > 0)
                        _notice(
                          theme,
                          color: theme.colorScheme.error,
                          icon: Icons.inventory_2_outlined,
                          text:
                              '待料执行段不会锁定任何零散物料；只有整套物料补齐后，'
                              '系统才会在同一事务内锁料、生成对应领料单并转为可开工。',
                        ),
                      if (_unassignedCount > 0) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        _notice(
                          theme,
                          color: theme.colorScheme.tertiary,
                          icon: Icons.factory_outlined,
                          text:
                              '有 $_unassignedCount 个执行段尚未指定车间。可以先生成待派工计划，'
                              '但派工前必须补齐车间、班组和负责人并复核产能。',
                        ),
                      ],
                      if (!widget.preview.balancedKitCoverage) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        _notice(
                          theme,
                          color: theme.colorScheme.primary,
                          icon: Icons.rule_folder_outlined,
                          text:
                              '本次按完整齐套数量拆分，未将“某些料有、某些料没有”的零散库存'
                              '误判为可生产数量。',
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s12),
                      if (_dirty) ...[
                        _notice(
                          theme,
                          color: theme.colorScheme.tertiary,
                          icon: Icons.info_outline_rounded,
                          text:
                              '下方物料卡是进入页面时的最新系统齐套快照，不会用本地估算冒充重算结果；'
                              '保存或正式下达时服务端会按调整后的实排数量重新校验，陈旧或不齐套方案会被拒绝。',
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _showAllProductGroups
                                  ? '产品与物料明细（系统初始齐套快照，全部展开）'
                                  : '对应物料详情（${_visibleProductGroups.length} 个产品）',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (!_showAllProductGroups)
                            TextButton.icon(
                              onPressed: () =>
                                  setState(() => _showAllProductGroups = true),
                              icon: const Icon(
                                Icons.unfold_more_rounded,
                                size: 18,
                              ),
                              label: const Text('显示全部'),
                            ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      for (final group in _visibleProductGroups) ...[
                        _productCard(theme, group),
                        const SizedBox(height: UtenSpacing.s8),
                      ],
                      const SizedBox(height: UtenSpacing.s4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '执行子计划（${_grid.length} 行）',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _addSplit,
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('新增拆分'),
                          ),
                          TextButton.icon(
                            onPressed: _resetProposal,
                            icon: const Icon(
                              Icons.restart_alt_rounded,
                              size: 18,
                            ),
                            label: const Text('恢复系统方案'),
                          ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      UtenEditableGrid<_ExecutionGridRow>(
                        controller: _grid,
                        columns: _columns(workshops),
                        createBlankRow: () =>
                            throw UnsupportedError('请通过“新增拆分”选择来源产品'),
                        showAddRow: false,
                        emptyMessage: '没有执行子计划',
                      ),
                      if (_purchaseShortageKinds > 0) ...[
                        const SizedBox(height: UtenSpacing.s12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: true,
                          title: const Text('自动生成采购申请（必需）'),
                          subtitle: Text(
                            '按 $_purchaseShortageKinds 种未覆盖外购物料的净缺口生成采购申请；'
                            '申请与执行分段同事务提交，失败会整体回滚，'
                            '避免待料任务成为无人可处理的孤立缺口。',
                          ),
                          onChanged: null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              _footer(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Icon(
              Icons.account_tree_outlined,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.mode == ProductionPlanningSheetMode.draft
                      ? '详细预排'
                      : '正式排产下达',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  widget.mode == ProductionPlanningSheetMode.draft
                      ? '发料仓：${widget.warehouseName} · '
                            '保存后仅形成预排草案，不锁料、不开单。'
                      : '发料仓：${widget.warehouseName} · '
                            '确认后将锁料并生成适用的关联单据。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: _requestClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _stats(ThemeData theme) {
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: [
        _stat(theme, '可立即生产', '$_readyCount 个', Icons.play_circle_outline),
        _stat(
          theme,
          '待料子计划',
          '$_waitingCount 个',
          Icons.hourglass_bottom_rounded,
          warning: _waitingCount > 0,
        ),
        _stat(
          theme,
          '采购缺料',
          '$_purchaseShortageKinds 种',
          Icons.shopping_cart_outlined,
          warning: _purchaseShortageKinds > 0,
        ),
        _stat(theme, '最早计划完工', _earliestCompletion, Icons.event_available),
      ],
    );
  }

  Widget _stat(
    ThemeData theme,
    String label,
    String value,
    IconData icon, {
    bool warning = false,
  }) {
    final color = warning ? theme.colorScheme.error : theme.colorScheme.primary;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 172, maxWidth: 196),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(label, style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _productCard(ThemeData theme, _ProductGroup group) {
    final source = group.source;
    final zeroMaterialText = productionZeroMaterialReasonText(
      source.materialRequirementMode,
      source.zeroMaterialReason,
    );
    final statusColor = group.waitingQty <= _epsilon
        ? Colors.green
        : group.readyQty > _epsilon
        ? Colors.orange
        : theme.colorScheme.error;
    final statusText = group.waitingQty <= _epsilon
        ? '齐套'
        : group.readyQty > _epsilon
        ? '部分齐套'
        : '缺料';
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.mdAll,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: UtenSpacing.s8,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.productName ?? source.productCode ?? '未命名产品',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      [
                            source.productCode,
                            if (source.productSpec?.trim().isNotEmpty == true)
                              '规格 ${source.productSpec}',
                            widget.names.color(source.productColorId),
                            '订单行 ${source.sourceLineNo ?? '—'}',
                          ]
                          .where((value) => value != null && value != '—')
                          .join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: UtenSpacing.s8,
                  children: [
                    _pill(theme, '订单量 ${_fmt(group.totalQty)}'),
                    _pill(theme, '可排 ${_fmt(group.readyQty)}'),
                    _pill(
                      theme,
                      '$statusText · 缺 ${group.shortageKinds} 种',
                      color: statusColor,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            MasterDataTableView<_MaterialDisplayRow>(
              embedded: true,
              columns: _materialColumns(),
              items: group.materials,
              facets: const <String, List<MasterFacetBucket>>{},
              nullCounts: const <String, int>{},
              filters: const <String, String?>{},
              onFilterChanged: (_, _) {},
              rowColor: (row) => row.shortageQty > _epsilon
                  ? theme.colorScheme.error.withValues(alpha: 0.06)
                  : Colors.green.withValues(alpha: 0.04),
              emptyMessage: zeroMaterialText ?? '该产品没有可用 BOM 物料，不能排产',
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              zeroMaterialText ??
                  (group.shortageKinds == 0
                      ? '全部物料齐套，可锁料并生成领料单。'
                      : '缺 ${group.shortageKinds} 种物料；待料部分保持零锁料，采购到货后按完整套数回补。'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<MasterColumnDef<_MaterialDisplayRow>> _materialColumns() => [
    MasterColumnDef(
      key: 'material',
      label: '编号 · 货品名称（规格）/ 颜色',
      width: 270,
      value: (row) {
        final color = widget.names.color(row.colorId);
        final code = row.goodsCode?.trim();
        final resolvedName = row.goodsName?.trim();
        final name = resolvedName == null || resolvedName.isEmpty
            ? widget.names.goods(row.goodsId)
            : resolvedName;
        final spec = row.spec?.trim();
        return <String>[
          if (code != null && code.isNotEmpty) code,
          spec == null || spec.isEmpty ? name : '$name（$spec）',
          if (color != '—') color,
        ].join(' · ');
      },
    ),
    MasterColumnDef(
      key: 'unit',
      label: '单位',
      width: 72,
      value: (row) => widget.names.unit(row.unitId),
    ),
    MasterColumnDef(
      key: 'per',
      label: '用量口径',
      width: 186,
      value: (row) => formatProductionPlanningGroupedMaterialUsage(
        row.requirementMode,
        row.perProductQty,
      ),
    ),
    MasterColumnDef(
      key: 'required',
      label: '总需求',
      width: 92,
      type: 'number',
      value: (row) => _fmt(row.requiredQty),
    ),
    MasterColumnDef(
      key: 'bookStock',
      label: '账面库存',
      width: 92,
      type: 'number',
      value: (row) => _fmtOptional(row.bookStock),
    ),
    MasterColumnDef(
      key: 'reserved',
      label: '其他单据占用',
      width: 112,
      type: 'number',
      value: (row) => _fmtOptional(row.reservedQty),
    ),
    MasterColumnDef(
      key: 'safety',
      label: '安全库存',
      width: 92,
      type: 'number',
      value: (row) => _fmtOptional(row.safetyStock),
    ),
    MasterColumnDef(
      key: 'available',
      label: '本仓可分配',
      width: 92,
      type: 'number',
      value: (row) => _fmt(row.availableBeforeQty),
    ),
    MasterColumnDef(
      key: 'allocated',
      label: '本次候选锁定',
      width: 110,
      type: 'number',
      value: (row) => _fmt(row.allocatedQty),
    ),
    MasterColumnDef(
      key: 'shortage',
      label: '净缺口',
      width: 92,
      type: 'number',
      value: (row) => _fmt(row.shortageQty),
    ),
    MasterColumnDef(
      key: 'openPo',
      label: '全部在途',
      width: 92,
      type: 'number',
      value: (row) => _fmtOptional(row.openPoTotal),
    ),
    MasterColumnDef(
      key: 'openPoOnTime',
      label: '按期可到',
      width: 92,
      type: 'number',
      value: (row) => _fmtOptional(row.openPoOnTime),
    ),
    MasterColumnDef(
      key: 'arrival',
      label: '最早到货',
      width: 112,
      value: (row) => row.earliestArrivalDate ?? '—',
    ),
    MasterColumnDef(
      key: 'timelyShortage',
      label: '需求日前缺口',
      width: 112,
      type: 'number',
      value: (row) => _fmtOptional(row.timelyShortage),
    ),
    MasterColumnDef(
      key: 'route',
      label: '供应方式',
      width: 88,
      value: (row) => switch (row.supplyRoute) {
        'BUY' => '外购',
        'SUBCONTRACT' => '委外',
        'MAKE' => '自制',
        _ => '未配置',
      },
    ),
    MasterColumnDef(
      key: 'status',
      label: '物料状态',
      width: 108,
      value: (row) => _materialStatusText(row),
    ),
  ];

  List<EditableGridColumn<_ExecutionGridRow>> _columns(
    List<DepartmentNode>? workshops,
  ) {
    return [
      EditableGridColumn(
        key: 'code',
        label: '临时分段号',
        width: 130,
        cellBuilder: (_, row) => Text(
          row.clientSegmentKey,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      EditableGridColumn(
        key: 'product',
        label: '生产产品',
        width: 230,
        cellBuilder: (context, row) {
          final source = row.source;
          final details = <String>[
            if (source.productCode?.trim().isNotEmpty == true)
              source.productCode!,
            if (source.productSpec?.trim().isNotEmpty == true)
              '规格 ${source.productSpec}',
            if (source.productColorId?.trim().isNotEmpty == true)
              widget.names.color(source.productColorId),
            '订单行 ${source.sourceLineNo ?? '—'}',
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                source.productName ?? source.productCode ?? '未命名产品',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                details.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          );
        },
      ),
      EditableGridColumn(
        key: 'qty',
        label: '实排数量',
        width: 105,
        numeric: true,
        cellBuilder: (_, row) => TextField(
          controller: row.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true),
        ),
      ),
      EditableGridColumn(
        key: 'status',
        label: '排产决策',
        width: 196,
        cellBuilder: (_, row) => DropdownButtonFormField<String>(
          key: ValueKey('${row.clientSegmentKey}-${row.dispatchDecision}'),
          initialValue: row.dispatchDecision,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true),
          items: const [
            DropdownMenuItem(value: 'READY', child: Text('优先生产')),
            DropdownMenuItem(value: 'AUTO_WAIT', child: Text('待料 · 齐套自动转产')),
            DropdownMenuItem(value: 'DEFERRED', child: Text('人工暂缓 · 手动恢复')),
          ],
          onChanged: (value) => setState(() {
            row.setDispatchDecision(value ?? 'AUTO_WAIT');
            _dirty = true;
          }),
        ),
      ),
      EditableGridColumn(
        key: 'workshop',
        label: '生产车间',
        width: 175,
        cellBuilder: (_, row) => _workshopField(row, workshops),
      ),
      EditableGridColumn(
        key: 'team',
        label: '生产班组',
        width: 165,
        cellBuilder: (_, row) => _teamField(row, workshops),
      ),
      EditableGridColumn(
        key: 'responsible',
        label: '负责人',
        width: 210,
        cellBuilder: (_, row) => UtenEmployeePicker(
          key: ValueKey('${row.clientSegmentKey}-${row.responsible?.id ?? ''}'),
          initial: row.responsible,
          hint: '选择负责人',
          loader: (keyword) async {
            final result = await ref
                .read(employeeRepositoryProvider)
                .list(
                  size: 30,
                  search: keyword,
                  statuses: const {'active', 'probation'},
                  departmentId:
                      row.teamDepartmentId ?? row.workshopDepartmentId,
                  includeSubtree:
                      row.teamDepartmentId != null ||
                      row.workshopDepartmentId != null,
                );
            return [
              for (final employee in result.items)
                UtenEmployeePickerItem(
                  id: employee.id,
                  name: employee.fullName,
                  departmentName: employee.departmentName,
                ),
            ];
          },
          onChanged: (item) {
            row.responsible = item;
            _markDirty();
          },
        ),
      ),
      EditableGridColumn(
        key: 'begin',
        label: '计划开工',
        width: 132,
        cellBuilder: (_, row) =>
            _dateCell(row.planBeginDate, onTap: () => _pickDate(row, true)),
      ),
      EditableGridColumn(
        key: 'end',
        label: '计划完工',
        width: 132,
        cellBuilder: (_, row) =>
            _dateCell(row.planEndDate, onTap: () => _pickDate(row, false)),
      ),
    ];
  }

  Widget _workshopField(
    _ExecutionGridRow row,
    List<DepartmentNode>? workshops,
  ) {
    final options = workshops ?? const <DepartmentNode>[];
    final currentMissing =
        row.workshopDepartmentId != null &&
        !options.any((item) => item.id == row.workshopDepartmentId);
    return DropdownButtonFormField<String>(
      key: ValueKey(
        '${row.clientSegmentKey}-${row.workshopDepartmentId}-${options.length}',
      ),
      initialValue: row.workshopDepartmentId ?? '',
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      items: [
        const DropdownMenuItem(value: '', child: Text('待分配')),
        if (currentMissing)
          DropdownMenuItem(
            value: row.workshopDepartmentId!,
            child: Text(widget.names.department(row.workshopDepartmentId)),
          ),
        for (final workshop in options)
          DropdownMenuItem(value: workshop.id, child: Text(workshop.name)),
      ],
      onChanged: (value) => setState(() {
        row.workshopDepartmentId = value == null || value.isEmpty
            ? null
            : value;
        row.teamDepartmentId = null;
        row.responsible = null;
        _dirty = true;
      }),
    );
  }

  Widget _teamField(_ExecutionGridRow row, List<DepartmentNode>? workshops) {
    final workshop = (workshops ?? const <DepartmentNode>[])
        .where((item) => item.id == row.workshopDepartmentId)
        .firstOrNull;
    final teams = workshop?.children ?? const <DepartmentNode>[];
    final currentMissing =
        row.teamDepartmentId != null &&
        !teams.any((item) => item.id == row.teamDepartmentId);
    return DropdownButtonFormField<String>(
      key: ValueKey(
        '${row.clientSegmentKey}-${row.workshopDepartmentId}-'
        '${row.teamDepartmentId}-${teams.length}',
      ),
      initialValue: row.teamDepartmentId ?? '',
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      items: [
        const DropdownMenuItem(value: '', child: Text('待分配')),
        if (currentMissing)
          DropdownMenuItem(
            value: row.teamDepartmentId!,
            child: Text(widget.names.department(row.teamDepartmentId)),
          ),
        for (final team in teams)
          DropdownMenuItem(value: team.id, child: Text(team.name)),
      ],
      onChanged: row.workshopDepartmentId == null
          ? null
          : (value) => setState(() {
              row.teamDepartmentId = value == null || value.isEmpty
                  ? null
                  : value;
              row.responsible = null;
              _dirty = true;
            }),
    );
  }

  Widget _dateCell(DateTime? value, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: UtenRadius.smAll,
      child: InputDecorator(
        decoration: const InputDecoration(
          isDense: true,
          suffixIcon: Icon(Icons.date_range_rounded, size: 16),
        ),
        child: Text(_dateText(value) ?? '待排定'),
      ),
    );
  }

  Widget _footer(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          children: [
            Text(
              '优先生产 $_readyCount · 待料自动转产 $_waitingCount · '
              '人工暂缓 $_deferredCount · ${_grid.length} 个执行段',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _requestClose,
              child: const Text('取消'),
            ),
            UtenButton(
              icon: Icons.account_tree_outlined,
              onPressed:
                  widget.preview.executionSegmentationReady &&
                      !widget.preview.hasBlockingBomGaps
                  ? _confirm
                  : null,
              onDisabledTap: widget.preview.hasBlockingBomGaps
                  ? () => context.appWarning('请先补齐全部成品及自制组件 BOM，再保存或下达排产方案')
                  : null,
              child: Text(
                widget.mode == ProductionPlanningSheetMode.draft
                    ? '保存预排草案'
                    : '正式下达',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(ThemeData theme, String text, {Color? color}) {
    final valueColor = color ?? theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: valueColor.withValues(alpha: 0.08),
        borderRadius: UtenRadius.pillAll,
        border: Border.all(color: valueColor.withValues(alpha: 0.24)),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: valueColor,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _notice(
    ThemeData theme, {
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

List<_ProductGroup> _buildProductGroups(
  List<ProductionExecutionSegmentPreview> segments,
  List<ProductionPlanningMaterial> planningMaterials,
) {
  final planningByMaterial = <String, ProductionPlanningMaterial>{
    for (final material in planningMaterials)
      _materialKey(material.goodsId, material.colorId): material,
  };
  final grouped = <String, List<ProductionExecutionSegmentPreview>>{};
  for (final segment in segments) {
    grouped.putIfAbsent(segment.sourcePlanItemId, () => []).add(segment);
  }
  return [
    for (final entries in grouped.values)
      _buildProductGroup(entries, planningByMaterial),
  ];
}

_ProductGroup _buildProductGroup(
  List<ProductionExecutionSegmentPreview> segments,
  Map<String, ProductionPlanningMaterial> planningByMaterial,
) {
  final totalProductQty = segments.fold<double>(
    0,
    (sum, item) => sum + item.plannedQty,
  );
  final materialGroups = <String, List<ProductionExecutionMaterialPreview>>{};
  for (final segment in segments) {
    for (final material in segment.materials) {
      final key =
          '${material.goodsId}|${material.colorId ?? ''}|${material.unitId}';
      materialGroups.putIfAbsent(key, () => []).add(material);
    }
  }
  return _ProductGroup(
    source: segments.first,
    totalQty: totalProductQty,
    readyQty: segments
        .where((item) => item.suggestedStatus == 'READY')
        .fold(0, (sum, item) => sum + item.plannedQty),
    waitingQty: segments
        .where((item) => item.suggestedStatus == 'WAITING')
        .fold(0, (sum, item) => sum + item.plannedQty),
    materials: [
      for (final entries in materialGroups.values)
        _materialDisplayRow(
          entries,
          planningByMaterial[_materialKey(
            entries.first.goodsId,
            entries.first.colorId,
          )],
          totalProductQty,
        ),
    ],
  );
}

_MaterialDisplayRow _materialDisplayRow(
  List<ProductionExecutionMaterialPreview> entries,
  ProductionPlanningMaterial? planning,
  double totalProductQty,
) {
  final requiredQty = entries.fold<double>(
    0,
    (sum, item) => sum + item.requiredQty,
  );
  final requirementMode =
      entries.any((item) => item.requirementMode == 'EXACT_SNAPSHOT')
      ? 'EXACT_SNAPSHOT'
      : 'LINEAR';
  return _MaterialDisplayRow(
    goodsId: entries.first.goodsId,
    goodsCode: planning?.goodsCode,
    goodsName: planning?.goodsName,
    spec: planning?.spec,
    colorId: entries.first.colorId,
    unitId: entries.first.unitId,
    perProductQty: aggregateProductionPlanningMaterialUsage(
      entries,
      totalProductQty,
    ),
    requirementMode: requirementMode,
    requiredQty: requiredQty,
    availableBeforeQty: entries.fold(
      0,
      (maximum, item) =>
          item.availableBeforeQty > maximum ? item.availableBeforeQty : maximum,
    ),
    allocatedQty: entries.fold(
      0,
      (sum, item) => sum + item.candidateAllocatedQty,
    ),
    shortageQty: entries.fold(0, (sum, item) => sum + item.shortageQty),
    supplyRoute: entries.first.supplyRoute,
    bookStock: planning?.bookStock,
    reservedQty: planning?.salesReserved,
    safetyStock: planning?.safetyStock,
    openPoTotal: planning?.openPoTotal,
    openPoOnTime: planning?.openPoOnTime,
    earliestArrivalDate: planning?.earliestArrivalDate,
    timelyShortage: planning?.timelyShortage,
    materialStatus: planning?.materialStatus,
  );
}

String _materialKey(String goodsId, String? colorId) =>
    '$goodsId|${colorId ?? ''}';

Map<String, double> _sourceTotals(
  List<ProductionExecutionSegmentPreview> segments,
) {
  final totals = <String, double>{};
  for (final segment in segments) {
    totals.update(
      segment.sourcePlanItemId,
      (value) => value + segment.plannedQty,
      ifAbsent: () => segment.plannedQty,
    );
  }
  return totals;
}

String? _dateText(DateTime? value) {
  if (value == null) return null;
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

String _fmt(double value) => formatProductionPlanningQuantity(value);

String _fmtOptional(double? value) => value == null ? '—' : _fmt(value);

String _materialStatusText(_MaterialDisplayRow row) {
  if (row.shortageQty <= _epsilon) return '立即齐套';
  return switch (row.materialStatus?.toUpperCase()) {
    'READY_BY_DATE' => '到货后齐套',
    'INBOUND_LATE' => '在途晚到',
    'PARTIAL_SHORTAGE' => '部分缺料',
    'SHORTAGE' => '缺料',
    'READY_NOW' => '立即齐套',
    _ =>
      row.openPoOnTime != null &&
              row.timelyShortage != null &&
              row.timelyShortage! <= _epsilon
          ? '到货后齐套'
          : '缺料',
  };
}

bool _hasValidPlanningQuantityScale(String raw) {
  final value = raw.trim();
  return RegExp(
    r'^(?:[0-9]+|[0-9]+\.[0-9]{1,4}|\.[0-9]{1,4})$',
  ).hasMatch(value);
}

const double _epsilon = 0.000001;

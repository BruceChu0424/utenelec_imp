import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/network/read_scope_revision.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/account_action_owner.dart';
import '../models/production_draw_request.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_draw_request_repository.dart';
import '../repositories/production_execution_workbench_repository.dart';
import 'workshop_task_material_table.dart';

/// Read-only facts and exact source selection. Warehouse submission remains
/// exclusively in the existing draw-request review page.
Future<Set<String>?> showWorkshopTaskMaterialDialog(
  BuildContext context, {
  required ProductionExecutionWorkbenchSegment task,
  required bool canRequestDraw,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
}) => UtenDialog.showAndWaitForExit<Set<String>>(
  context,
  builder: (_) => WorkshopTaskMaterialDialog(
    task: task,
    canRequestDraw: canRequestDraw,
    isCurrent: isCurrent,
    ownerChanges: ownerChanges,
  ),
);

class WorkshopTaskMaterialDialog extends ConsumerStatefulWidget {
  const WorkshopTaskMaterialDialog({
    super.key,
    required this.task,
    required this.canRequestDraw,
    this.isCurrent,
    this.ownerChanges,
  });

  final ProductionExecutionWorkbenchSegment task;
  final bool canRequestDraw;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  ConsumerState<WorkshopTaskMaterialDialog> createState() =>
      _WorkshopTaskMaterialDialogState();
}

class _WorkshopTaskMaterialDialogState
    extends ConsumerState<WorkshopTaskMaterialDialog> {
  late final AccountActionOwner _owner;
  ModalRoute<Set<String>>? _route;
  List<ProductionWorkshopTaskMaterial>? _materials;
  ProductionDrawRequestPreview? _preview;
  final Set<String> _selectedDemandIds = {};
  bool _loading = true;
  bool _drawLoading = false;
  bool _invalidated = false;
  String? _materialError;
  String? _drawError;
  String _filter = 'all';
  int _materialsGeneration = 0;
  int _drawGeneration = 0;

  @override
  void initState() {
    super.initState();
    _owner = AccountActionOwner(
      ref,
      isCurrent: widget.isCurrent,
      targetChanges: widget.ownerChanges,
      onInvalidated: _invalidate,
    );
    ref.listenManual(readScopeRevisionProvider, (previous, next) {
      if (previous != next) _invalidate();
    });
    _loadMaterials();
    if (widget.canRequestDraw) _loadDrawPreview();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<Set<String>>(context);
  }

  @override
  void dispose() {
    _owner.dispose();
    super.dispose();
  }

  bool get _current => mounted && !_invalidated && _owner.isCurrent;

  void _invalidate() {
    if (!mounted || _invalidated) return;
    setState(() {
      _invalidated = true;
      _materials = null;
      _preview = null;
      _selectedDemandIds.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = _route;
      if (mounted && route != null && route.isActive) {
        route.navigator?.removeRoute(route);
      }
    });
  }

  Future<void> _loadMaterials() async {
    final generation = ++_materialsGeneration;
    setState(() {
      _loading = true;
      _materialError = null;
    });
    try {
      final materials = await ref
          .read(productionExecutionWorkbenchRepositoryProvider)
          .workshopTaskMaterials(widget.task.segmentId);
      if (!_current || generation != _materialsGeneration) return;
      setState(() {
        _materials = materials;
        _retainValidSelection();
      });
    } catch (_) {
      if (!_current || generation != _materialsGeneration) return;
      setState(() => _materialError = '物料明细加载失败');
    } finally {
      if (_current && generation == _materialsGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadDrawPreview() async {
    final generation = ++_drawGeneration;
    setState(() {
      _drawLoading = true;
      _drawError = null;
    });
    try {
      final preview = await ref
          .read(productionDrawRequestRepositoryProvider)
          .preview([
            ProductionDrawRequestItem(
              segmentId: widget.task.segmentId,
              expectedVersion: widget.task.lockVersion,
            ),
          ]);
      if (!_current || generation != _drawGeneration) return;
      setState(() {
        _preview = preview;
        _retainValidSelection();
      });
    } catch (_) {
      if (!_current || generation != _drawGeneration) return;
      setState(() => _drawError = '可领物料核对失败');
    } finally {
      if (_current && generation == _drawGeneration) {
        setState(() => _drawLoading = false);
      }
    }
  }

  Set<String> get _selectableDemandIds {
    final actualDemands =
        (_materials ?? const <ProductionWorkshopTaskMaterial>[])
            .map((row) => row.demandId)
            .toSet();
    return {
      for (final line in _preview?.lines ?? const <ProductionDrawRequestLine>[])
        if (line.segmentId == widget.task.segmentId &&
            line.qty > 0 &&
            line.demandId != null &&
            actualDemands.contains(line.demandId))
          line.demandId!,
    };
  }

  void _retainValidSelection() {
    // The two reads may complete in either order; do not erase a retained
    // selection while either authoritative input is still unavailable.
    if (_materials != null && _preview != null) {
      _selectedDemandIds.retainAll(_selectableDemandIds);
    }
  }

  bool get _canSelect =>
      widget.canRequestDraw &&
      !_loading &&
      !_drawLoading &&
      _materialError == null &&
      _drawError == null &&
      _current;

  void _continueToDraw() {
    if (!_canSelect || _selectedDemandIds.isEmpty) return;
    final ids = {
      for (final line in _preview!.lines)
        if (line.segmentId == widget.task.segmentId &&
            line.qty > 0 &&
            _selectedDemandIds.contains(line.demandId))
          line.drawItemId,
    };
    if (ids.isNotEmpty) Navigator.of(context).pop(ids);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shortWindow =
        MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom <
        480;
    final selectable = _selectableDemandIds;
    final visibleMaterials =
        (_materials ?? const <ProductionWorkshopTaskMaterial>[])
            .where(
              (row) => switch (_filter) {
                'drawable' => selectable.contains(row.demandId),
                'short' => row.shortageQty > 0,
                _ => true,
              },
            )
            .toList(growable: false);
    final allSelected =
        selectable.isNotEmpty && selectable.every(_selectedDemandIds.contains);
    return UtenAlertDialog(
      key: ValueKey('workshop-material-dialog-${widget.task.segmentId}'),
      maxWidth: 1040,
      scrollable: false,
      insetPadding: shortWindow ? const EdgeInsets.all(UtenSpacing.s12) : null,
      titlePadding: shortWindow ? const EdgeInsets.all(UtenSpacing.s12) : null,
      contentPadding: shortWindow
          ? const EdgeInsets.fromLTRB(12, 0, 12, 8)
          : null,
      actionsPadding: shortWindow ? const EdgeInsets.all(UtenSpacing.s8) : null,
      title: shortWindow
          ? Semantics(
              header: true,
              child: Text('任务物料 · ${widget.task.segmentCode}'),
            )
          : const Text('任务物料'),
      subtitle: shortWindow
          ? null
          : Text(
              [widget.task.productName, widget.task.segmentCode]
                  .whereType<String>()
                  .where((part) => part.isNotEmpty)
                  .join(' · '),
            ),
      headingIcon: shortWindow ? null : Icons.inventory_2_outlined,
      showCloseButton: true,
      content: _invalidated
          ? const SizedBox.shrink()
          : SizedBox(
              width: 1040,
              height: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_materials != null) ...[
                    Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final (value, label) in [
                          ('all', '全部 ${_materials!.length}'),
                          if (widget.canRequestDraw)
                            ('drawable', '可领 ${selectable.length}'),
                          (
                            'short',
                            '缺料 ${_materials!.where((row) => row.shortageQty > 0).length}',
                          ),
                        ])
                          ChoiceChip(
                            label: Text(label),
                            selected: _filter == value,
                            onSelected: (_) => setState(() => _filter = value),
                          ),
                        if (widget.canRequestDraw)
                          TextButton.icon(
                            key: const Key('workshop-material-select-all'),
                            onPressed: !_canSelect || selectable.isEmpty
                                ? null
                                : () => setState(() {
                                    if (allSelected) {
                                      _selectedDemandIds.clear();
                                    } else {
                                      _selectedDemandIds.addAll(selectable);
                                    }
                                  }),
                            icon: Icon(
                              allSelected
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded,
                            ),
                            label: Text(allSelected ? '取消全选' : '全选可领'),
                          ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                  ],
                  Expanded(
                    child: _loading
                        ? const Padding(
                            padding: EdgeInsets.all(UtenSpacing.s24),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : _materialError != null
                        ? _retryRow(
                            _materialError!,
                            _loadMaterials,
                            key: const Key('workshop-material-facts-retry'),
                          )
                        : visibleMaterials.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s24),
                            child: Text(
                              _materials?.isEmpty == true
                                  ? '本任务无需领料'
                                  : '暂无对应物料',
                              style: theme.textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          )
                        : WorkshopTaskMaterialTable(
                            segmentId: widget.task.segmentId,
                            unitFallback: widget.task.productUnitName,
                            materialRows: visibleMaterials,
                            compact: true,
                            showAllInitially: true,
                            compactScrollable: true,
                            selectableDemandIds: _canSelect
                                ? selectable
                                : const {},
                            selectedDemandIds: _selectedDemandIds,
                            onSelectedDemandIdsChanged: !widget.canRequestDraw
                                ? null
                                : (next) {
                                    if (!_canSelect) return;
                                    setState(() {
                                      _selectedDemandIds
                                        ..clear()
                                        ..addAll(next.intersection(selectable));
                                    });
                                  },
                          ),
                  ),
                  if (_drawLoading)
                    const LinearProgressIndicator(
                      key: Key('workshop-material-preview-loading'),
                    ),
                  if (_drawError != null)
                    _retryRow(
                      _drawError!,
                      _loadDrawPreview,
                      key: const Key('workshop-material-preview-retry'),
                    ),
                ],
              ),
            ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (widget.canRequestDraw)
          UtenButton(
            key: const Key('workshop-material-continue'),
            icon: Icons.inventory_2_outlined,
            onPressed: _canSelect && _selectedDemandIds.isNotEmpty
                ? _continueToDraw
                : null,
            child: Text('去领料（${_selectedDemandIds.length} 种）'),
          ),
      ],
    );
  }

  Widget _retryRow(String message, VoidCallback onRetry, {required Key key}) =>
      Row(
        children: [
          Expanded(child: Text(message)),
          TextButton(key: key, onPressed: onRetry, child: const Text('重试')),
        ],
      );
}

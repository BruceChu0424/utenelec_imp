import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../warehouse/models/stock_doc.dart';
import '../../warehouse/providers/warehouse_count_refresh.dart';
import '../models/production_material_return.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_material_repository.dart';
import 'production_material_return_request_sheet.dart';

Future<bool?> showProductionMaterialSettlementSheet(
  BuildContext context,
  WidgetRef ref, {
  required String planId,
  String? executionSegmentId,
  required bool canSettle,
  required bool canReverse,
  required bool canClose,
}) {
  return showUtenAdaptivePanel<bool>(
    context: context,
    compactHeightFactor: 0.94,
    drawerWidth: 840,
    barrierDismissible: false,
    enableDrag: false,
    panelElevation: 16,
    barrierColor: Colors.black.withValues(alpha: .38),
    barrierLabel: '关闭用料记录面板',
    transitionDuration: const Duration(milliseconds: 300),
    builder: (_) => _MaterialSettlementSheet(
      planId: planId,
      executionSegmentId: executionSegmentId,
      canSettle: canSettle,
      canReverse: canReverse,
      canClose: canClose,
    ),
  );
}

class _SettlementGridRow extends EditableGridRow {
  _SettlementGridRow(this.source);

  final ProductionMaterialClearanceRow source;
  final TextEditingController consumed = TextEditingController();
  final TextEditingController loss = TextEditingController();
  final TextEditingController wip = TextEditingController();
  bool consumptionSuggested = false;

  void fillAsConsumed() {
    if (consumed.text.trim().isNotEmpty) return;
    final remaining =
        source.availableToSettleQty -
        _positive(loss.text) -
        _positive(wip.text);
    if (remaining <= 0) return;
    consumed.text = _number(remaining);
    consumptionSuggested = true;
  }

  @override
  void dispose() {
    consumed.dispose();
    loss.dispose();
    wip.dispose();
    super.dispose();
  }
}

class _SettlementIntent {
  _SettlementIntent(this.lines, this.reason) : key = const Uuid().v4();
  final String key;
  final List<ProductionMaterialSettlementLine> lines;
  final String? reason;
}

class _MaterialSettlementSheet extends ConsumerStatefulWidget {
  const _MaterialSettlementSheet({
    required this.planId,
    this.executionSegmentId,
    required this.canSettle,
    required this.canReverse,
    required this.canClose,
  });

  final String planId;
  final String? executionSegmentId;
  final bool canSettle;
  final bool canReverse;
  final bool canClose;

  @override
  ConsumerState<_MaterialSettlementSheet> createState() =>
      _MaterialSettlementSheetState();
}

class _MaterialSettlementSheetState
    extends ConsumerState<_MaterialSettlementSheet> {
  final _reason = TextEditingController();
  late final UtenEditableGridController<_SettlementGridRow> _grid;
  List<ProductionMaterialClearanceRow> _clearance = const [];
  List<ProductionMaterialSettlementSource> _sources = const [];
  List<ProductionMaterialReturnDocument> _returns = const [];
  bool _showLossAndWip = false;
  int get _lossAndWipItems => _grid.rows
      .where(
        (row) => _positive(row.loss.text) > 0 || _positive(row.wip.text) > 0,
      )
      .length;
  ProductionMaterialCapabilities _capabilities =
      const ProductionMaterialCapabilities();
  bool get _canSettle => widget.canSettle && _capabilities.canSettle;
  bool get _canRegister => _canSettle && _grid.rows.isNotEmpty;
  bool get _canReverse => widget.canReverse && _capabilities.canReverse;
  bool get _canClose => widget.canClose && _capabilities.canClose;
  bool get _canReturn => widget.canSettle && _capabilities.canRequestReturn;
  bool _loading = true;
  bool _busy = false;
  bool _closed = false;
  String? _error;
  String? _submitError;
  _SettlementIntent? _settlementIntent;
  bool _settlementUncertain = false;
  bool get _editingLocked => _busy || _settlementUncertain;

  @override
  void initState() {
    super.initState();
    _grid = UtenEditableGridController();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_settlementUncertain) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(productionMaterialRepositoryProvider);
      final results = await Future.wait([
        repo.clearance(
          widget.planId,
          executionSegmentId: widget.executionSegmentId,
        ),
        repo.settlementSources(
          widget.planId,
          executionSegmentId: widget.executionSegmentId,
        ),
        repo.capabilities(
          widget.planId,
          executionSegmentId: widget.executionSegmentId,
        ),
        if (widget.executionSegmentId != null)
          repo.returnRequests(
            widget.planId,
            executionSegmentId: widget.executionSegmentId,
          ),
      ]);
      if (!mounted) return;
      final clearance = results[0] as List<ProductionMaterialClearanceRow>;
      _grid.replaceAll([
        for (final row in clearance)
          if (row.issuedQty > 0 && row.availableToSettleQty > 0)
            _SettlementGridRow(row),
      ]);
      setState(() {
        _clearance = clearance;
        _sources = results[1] as List<ProductionMaterialSettlementSource>;
        _capabilities = results[2] as ProductionMaterialCapabilities;
        _returns = results.length > 3
            ? results[3] as List<ProductionMaterialReturnDocument>
            : const [];
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取材料台账失败，请稍后重试';
      });
    }
  }

  void _fillAllConsumed() {
    for (final row in _grid.rows) {
      if (row.source.availableToSettleQty > 0) row.fillAsConsumed();
    }
    setState(() {});
  }

  Future<void> _submit() async {
    if (!_canRegister) return;
    if (_busy) return;
    if (!_settlementUncertain) {
      final lines = <ProductionMaterialSettlementLine>[];
      var requiresReason = false;
      for (final row in _grid.rows) {
        final consumed = _positive(row.consumed.text);
        final loss = _positive(row.loss.text);
        final wip = _positive(row.wip.text);
        final total = consumed + loss + wip;
        if (total > row.source.availableToSettleQty + 0.0000001) {
          context.appError(
            '${row.source.goodsName ?? row.source.goodsCode ?? '物料'} '
            '本次登记 ${_number(total)}，超过可继续登记 ${_number(row.source.availableToSettleQty)} ${row.source.unitName ?? ''}',
          );
          return;
        }
        if (consumed > 0) {
          lines.add(
            ProductionMaterialSettlementLine(
              demandId: row.source.demandId,
              settlementType: 'CONSUMED',
              qtyBase: consumed,
            ),
          );
        }
        if (loss > 0) {
          requiresReason = true;
          lines.add(
            ProductionMaterialSettlementLine(
              demandId: row.source.demandId,
              settlementType: 'APPROVED_LOSS',
              qtyBase: loss,
            ),
          );
        }
        if (wip > 0) {
          requiresReason = true;
          lines.add(
            ProductionMaterialSettlementLine(
              demandId: row.source.demandId,
              settlementType: 'LEGAL_WIP',
              qtyBase: wip,
            ),
          );
        }
      }
      if (lines.isEmpty) {
        context.appWarning('请填写本次实际消耗、批准损耗或在制占用数量');
        return;
      }
      final reason = _reason.text.trim();
      if (requiresReason && reason.isEmpty) {
        context.appError('登记损耗或在制占用时必须填写原因');
        return;
      }
      // Two production batches can legitimately consume the same quantity. A
      // new confirmed intention gets a new key; a lost response retains this one.
      _settlementIntent = _SettlementIntent(
        List.unmodifiable(lines),
        reason.isEmpty ? null : reason,
      );
    }
    final intent = _settlementIntent!;
    setState(() {
      _busy = true;
      _submitError = null;
    });
    try {
      await ref
          .read(productionMaterialRepositoryProvider)
          .settle(
            widget.planId,
            idempotencyKey: intent.key,
            lines: intent.lines,
            reason: intent.reason,
            executionSegmentId: widget.executionSegmentId,
          );
      if (!mounted) return;
      _settlementIntent = null;
      _settlementUncertain = false;
      context.appSuccess('用料已登记，待登记数量已更新');
      _closed = true;
      _reason.clear();
      refreshAfterProductionPlanGenerated(ref);
      await _load();
      if (!mounted) return;
      setState(() => _busy = false);
      if (_error == null) await _offerRemaining();
    } on ApiException catch (error) {
      if (mounted) {
        final uncertain =
            error is NetworkException ||
            error is NetworkTimeoutException ||
            error.code == 'INTERNAL' ||
            (error.httpStatus != null && error.httpStatus! >= 500);
        setState(() {
          _settlementUncertain = uncertain;
          if (!uncertain) _settlementIntent = null;
          _submitError = uncertain
              ? '暂未确认本次用料登记结果。请点击“重试本次登记”，原数量和说明已保留。'
              : error.fieldErrors?.firstOrNull?.message ?? error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _settlementUncertain = true;
          _submitError = '暂未确认本次用料登记结果。请点击“重试本次登记”，原数量和说明已保留。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reverse(ProductionMaterialSettlementSource source) async {
    if (!_canReverse) return;
    final qty = TextEditingController(text: _number(source.reversibleQtyBase));
    final reason = TextEditingController();
    final dialog = DialogRoute<(double, String)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('冲销用料登记'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                errorBuilder: utenTextFieldErrorBuilder,
                controller: qty,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: UtenInputDecoration(
                  InputDecoration(
                    label: fieldLabel(
                      '冲销数量（${source.unitName ?? '单位待核实'}）',
                      Theme.of(dialogContext),
                      info:
                          '最多 ${_number(source.reversibleQtyBase)} ${source.unitName ?? '单位待核实'}',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextFormField(
                errorBuilder: utenTextFieldErrorBuilder,
                controller: reason,
                maxLength: 500,
                decoration: const UtenInputDecoration(
                  InputDecoration(labelText: '冲销原因', hintText: '例如：误报、数量录入错误'),
                ),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = _positive(qty.text);
              final text = reason.text.trim();
              if (value <= 0 ||
                  value > source.reversibleQtyBase + 0.0000001 ||
                  text.isEmpty) {
                return;
              }
              Navigator.pop(dialogContext, (value, text));
            },
            child: const Text('确认冲销'),
          ),
        ],
      ),
    );
    final result = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(dialog);
    // Popping returns before the exit animation removes the form from the tree.
    await dialog.completed;
    qty.dispose();
    reason.dispose();
    if (result == null || !mounted) return;
    final canonical =
        '${widget.planId}|${source.postingId}|${source.reversedQtyBase}|${source.reversibleQtyBase}|${result.$1.toStringAsFixed(6)}|${result.$2}';
    setState(() => _busy = true);
    try {
      await ref
          .read(productionMaterialRepositoryProvider)
          .reverseSettlement(
            widget.planId,
            idempotencyKey: businessIdempotencyKey(
              'material-settle-reverse',
              canonical,
            ),
            reason: result.$2,
            executionSegmentId: widget.executionSegmentId,
            lines: [
              ProductionMaterialSettlementLine(
                demandId: source.demandId,
                settlementType: source.settlementType,
                qtyBase: result.$1,
                sourcePostingId: source.postingId,
              ),
            ],
          );
      if (!mounted) return;
      context.appSuccess('原用料登记已冲销');
      _closed = true;
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('冲销失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closePlan() async {
    if (!_canClose) return;
    if (_busy || !_allCleared) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('完成生产任务'),
        content: const Text(
          '系统将再次检查成品完工数量和每种材料的消耗、退库、批准损耗或在制占用。'
          '两边全部平衡后才会关闭任务，确认继续？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('检查并完成'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(productionMaterialRepositoryProvider).close(widget.planId);
      if (!mounted) return;
      setState(() => _closed = true);
      context.appSuccess('生产任务已完成，材料与成品数量均已结清');
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('任务尚未满足完成条件');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startReturn() async {
    if (!_canReturn || _editingLocked) return;
    var segmentId = widget.executionSegmentId;
    if (segmentId == null) {
      final candidates = <String, ProductionMaterialClearanceRow>{};
      for (final row in _clearance) {
        if (row.executionSegmentId != null && row.maxReturnQty > 0) {
          candidates.putIfAbsent(row.executionSegmentId!, () => row);
        }
      }
      if (candidates.isEmpty) {
        context.appWarning('请从我的车间任务选择具体工单核对退料');
        return;
      }
      segmentId = candidates.length == 1
          ? candidates.keys.first
          : await showDialog<String>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('选择退料车间任务'),
                children: [
                  for (final entry in candidates.entries)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, entry.key),
                      child: Text(
                        entry.value.executionSegmentCode ?? entry.key,
                      ),
                    ),
                ],
              ),
            );
      if (!mounted || segmentId == null) return;
    }
    final submitted = await showProductionMaterialReturnRequestSheet(
      context,
      planId: widget.planId,
      executionSegmentId: segmentId,
    );
    if (!mounted || submitted != true) return;
    _closed = true;
    await _load();
  }

  Future<void> _offerRemaining() async {
    final remaining = _clearance
        .where((row) => row.availableToSettleQty > 0)
        .toList();
    if (remaining.isEmpty) return;
    final requestReturn = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本次剩余物料'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('本次用料已登记。以下材料仍在车间，可留待后续分批生产；准备退回仓库的部分，请先核对实际退料数量。'),
                const SizedBox(height: UtenSpacing.s12),
                for (final row in remaining)
                  Padding(
                    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                    child: Text(
                      '${row.goodsName ?? row.goodsCode ?? '物料'}：${_number(row.availableToSettleQty)} ${row.unitName ?? '单位待核实'}',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('留待后续生产'),
          ),
          if (_canReturn)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('核对退仓'),
            ),
        ],
      ),
    );
    if (mounted && requestReturn == true) await _startReturn();
  }

  Future<void> _cancelReturn(ProductionMaterialReturnDocument document) async {
    if (!_canReturn || _editingLocked) return;
    var reasonText = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('撤回 ${document.documentNo}'),
        content: SizedBox(
          width: 420,
          child: TextField(
            onChanged: (value) => reasonText = value.trim(),
            maxLength: 500,
            decoration: const UtenInputDecoration(
              InputDecoration(labelText: '撤回原因'),
              info: '仅待收料申请可以撤回，撤回后数量重新可用于本工单登记或申请退仓。',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          TextButton(
            onPressed: () {
              if (reasonText.length < 2) {
                context.appWarning('请填写至少 2 个字的撤回原因');
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('确认撤回'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(productionMaterialRepositoryProvider)
          .cancelReturn(
            widget.planId,
            document.documentId,
            idempotencyKey: businessIdempotencyKey(
              'return-cancel',
              '${document.documentId}|$reasonText',
            ),
            reason: reasonText,
          );
      if (!mounted) return;
      _closed = true;
      invalidateWarehouseTaskCounts(ref);
      bumpListRefresh(ref, StockDocType.wdraw.refreshKey);
      refreshAfterProductionPlanGenerated(ref);
      context.appSuccess('退仓申请已撤回，数量已恢复可登记或可退仓');
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('暂未确认撤回结果，请刷新后核对');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _allCleared =>
      _clearance.isNotEmpty && _clearance.every((row) => row.canClose);

  int get _returnableItems =>
      _clearance.where((row) => row.maxReturnQty > 0).length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_editingLocked,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(_canRegister ? '登记实际用料' : '用料记录'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _editingLocked ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: _editingLocked
                  ? null
                  : () => Navigator.pop(context, _closed),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
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
            : SingleChildScrollView(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _stats(theme),
                    const SizedBox(height: UtenSpacing.s8),
                    _notice(theme),
                    const SizedBox(height: UtenSpacing.s12),
                    if (_grid.rows.isNotEmpty) ...[
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: UtenSpacing.s8,
                        children: [
                          Text(
                            '待登记材料（${_grid.length} 项）',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (_canRegister)
                            TextButton.icon(
                              onPressed: _editingLocked
                                  ? null
                                  : _fillAllConsumed,
                              icon: const Icon(
                                Icons.done_all_rounded,
                                size: 18,
                              ),
                              label: const Text('将待登记量填入实耗'),
                            ),
                        ],
                      ),
                      if (_canRegister)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _editingLocked
                                ? null
                                : () => setState(
                                    () => _showLossAndWip = !_showLossAndWip,
                                  ),
                            icon: Icon(
                              _showLossAndWip
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                            ),
                            label: Text(
                              _showLossAndWip
                                  ? '收起损耗 / 在制'
                                  : _lossAndWipItems > 0
                                  ? '损耗 / 在制（已填 $_lossAndWipItems 项）'
                                  : '填写损耗 / 在制',
                            ),
                          ),
                        ),
                      const SizedBox(height: UtenSpacing.s4),
                      UtenEditableGrid<_SettlementGridRow>(
                        controller: _grid,
                        columns: _columns(),
                        createBlankRow: () =>
                            throw UnsupportedError('材料行只能来自需求台账'),
                        showAddRow: false,
                        showRowDelete: false,
                      ),
                    ],
                    if (_canRegister) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      TextField(
                        controller: _reason,
                        enabled: !_editingLocked,
                        maxLength: 500,
                        decoration: const UtenInputDecoration(
                          InputDecoration(
                            labelText: '本次说明',
                            hintText: '仅登记实耗时可选填',
                            prefixIcon: Icon(Icons.notes_rounded),
                          ),
                          info: '登记损耗或在制时必须填写原因。',
                        ),
                      ),
                    ],
                    if (_submitError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: UtenSpacing.s8),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _submitError!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ),
                    if (_canRegister || _canClose || _canReturn) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      Wrap(
                        spacing: UtenSpacing.s8,
                        runSpacing: UtenSpacing.s8,
                        children: [
                          if (_canRegister)
                            UtenButton(
                              icon: Icons.fact_check_outlined,
                              isLoading: _busy,
                              onPressed: _busy ? null : _submit,
                              child: Text(
                                _settlementUncertain ? '重试本次登记' : '提交用料登记',
                              ),
                            ),
                          if (_canReturn && _returnableItems > 0)
                            UtenButton(
                              type: UtenButtonType.secondary,
                              icon: Icons.keyboard_return_rounded,
                              onPressed: _editingLocked ? null : _startReturn,
                              child: const Text('余料退库'),
                            ),
                          if (_canClose)
                            UtenButton(
                              type: UtenButtonType.tonal,
                              icon: Icons.task_alt_rounded,
                              onPressed: _editingLocked || !_allCleared
                                  ? null
                                  : _closePlan,
                              child: const Text('检查并完成任务'),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s16),
                    if (_returns.isNotEmpty) _returnHistory(theme),
                    _ledger(theme),
                    _history(theme),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _stats(ThemeData theme) {
    final cards = [
      ('材料明细', '${_clearance.length} 项', Icons.inventory_2_outlined),
      (
        '已平衡',
        '${_clearance.where((row) => row.canClose).length} 项',
        Icons.check_circle_outline,
      ),
      ('待登记', '${_grid.length} 项', Icons.pending_actions_outlined),
      ('可退料', '$_returnableItems 项', Icons.keyboard_return_outlined),
    ];
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: [
        for (final card in cards)
          SizedBox(
            width: 188,
            child: Container(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: UtenRadius.mdAll,
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(card.$3, color: theme.colorScheme.primary),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(card.$1, style: theme.textTheme.labelMedium),
                        Text(
                          card.$2,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _notice(ThemeData theme) {
    final color = _allCleared
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _allCleared ? Icons.verified_outlined : Icons.info_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              _allCleared
                  ? '当前材料已平衡，可展开台账查看记录。完成任务仍需满足成品合格入库要求。'
                  : _grid.rows.isEmpty
                  ? '当前没有已领未登记的材料，可展开台账查看记录。'
                  : '填写这次实际用掉的材料；剩余可留待后续生产，也可核对数量后退仓。待仓库收料的数量暂不可登记或重复退仓。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  List<EditableGridColumn<_SettlementGridRow>> _columns() => [
    EditableGridColumn(
      key: 'material',
      label: '物料',
      width: 220,
      cellBuilder: (context, row) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row.source.goodsName ?? row.source.goodsCode ?? '未命名物料',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            [
              row.source.goodsCode,
              row.source.executionSegmentCode,
              row.source.colorName,
              row.source.unitName == null
                  ? '单位待核实'
                  : '单位：${row.source.unitName}',
            ].where((value) => value?.isNotEmpty == true).join(' · '),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    ),
    EditableGridColumn(
      key: 'unit',
      label: '单位',
      width: 76,
      cellBuilder: (_, row) => Text(row.source.unitName ?? '待核实'),
    ),
    _numberColumn(
      'uncleared',
      '可继续登记',
      (row) => row.source.availableToSettleQty,
    ),
    _inputColumn(
      'consume',
      '本次实耗',
      (row) => row.consumed,
      hint: '填写本次实际用掉的材料。黄色建议量为待登记量减本次损耗、在制，请核对；提交后才记账。',
    ),
    if (_showLossAndWip) ...[
      _inputColumn(
        'loss',
        '本次损耗',
        (row) => row.loss,
        hint: '填写实际损耗的基本数量，并说明原因。系统不会按理论用量自动认定损耗。',
      ),
      _inputColumn(
        'wip',
        '本次在制',
        (row) => row.wip,
        hint: '填写仍在本工单生产过程中的材料基本数量，并说明原因。',
      ),
    ],
  ];

  EditableGridColumn<_SettlementGridRow> _numberColumn(
    String key,
    String label,
    double Function(_SettlementGridRow) value,
  ) => EditableGridColumn(
    key: key,
    label: label,
    width: 92,
    numeric: true,
    cellBuilder: (_, row) =>
        Text(_number(value(row)), textAlign: TextAlign.right),
  );

  /// 列级通用说明放列头 ⓘ（[hint]，2026-09-10 全站口径）；格内只保留行特有的
  /// 「建议量」黄标（consume 列 consumptionSuggested），并把黄标图标计入量宽。
  EditableGridColumn<_SettlementGridRow> _inputColumn(
    String key,
    String label,
    TextEditingController Function(_SettlementGridRow) controller, {
    required String hint,
  }) => EditableGridColumn(
    key: key,
    label: label,
    width: 138,
    numeric: true,
    headerInfo: hint,
    chromeWidth: key == 'consume' ? UtenEditableGridCellSpec.hintIconWidth : 0,
    cellBuilder: (_, row) => TextField(
      key: ValueKey('material-$key-${row.source.demandId}'),
      controller: controller(row),
      enabled:
          _canSettle && !_editingLocked && row.source.availableToSettleQty > 0,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) {
        if (key == 'consume' && row.consumptionSuggested) {
          setState(() => row.consumptionSuggested = false);
        }
      },
      decoration: applyAutofillHint(
        const UtenInputDecoration(
          InputDecoration(isDense: true, hintText: '0'),
        ),
        Theme.of(context),
        autofilled: key == 'consume' && row.consumptionSuggested,
      ),
    ),
  );

  Widget _ledger(ThemeData theme) => ExpansionTile(
    key: const ValueKey('material-clearance-ledger'),
    tilePadding: EdgeInsets.zero,
    title: const Text('材料数量台账'),
    subtitle: const Text('每项：已领 = 实耗 + 已退 + 损耗 + 在制 + 待登记'),
    children: [
      if (_clearance.isEmpty) const ListTile(title: Text('尚未生成物料需求台账')),
      for (final row in _clearance)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
          title: Text(
            [
                  row.goodsName ?? row.goodsCode ?? '物料',
                  row.colorName,
                  row.executionSegmentCode,
                ]
                .whereType<String>()
                .where((value) => value.isNotEmpty)
                .join(' · '),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Wrap(
              spacing: UtenSpacing.s16,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final entry in [
                  ('需求', row.requiredQty),
                  ('已领', row.issuedQty),
                  ('实耗', row.consumedQty),
                  ('已退', row.returnedQty),
                  ('损耗', row.approvedLossQty),
                  ('在制', row.legalWipQty),
                  ('待登记', row.unclearedQty),
                  ('待仓库收料', row.pendingReturnQty),
                  ('可继续登记', row.availableToSettleQty),
                  ('可退料', row.maxReturnQty),
                ])
                  Text(
                    '${entry.$1} ${_number(entry.$2)} ${row.unitName ?? '（单位待核实）'}',
                  ),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _history(ThemeData theme) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        '有效登记与冲销（${_sources.length} 条）',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: const Text('错误记录只能按原记录冲销，不能直接删除或覆盖'),
      children: [
        if (_sources.isEmpty)
          const ListTile(title: Text('暂无材料结清记录'))
        else
          for (final source in _sources)
            ListTile(
              dense: true,
              leading: Icon(switch (source.settlementType) {
                'APPROVED_LOSS' => Icons.warning_amber_rounded,
                'LEGAL_WIP' => Icons.precision_manufacturing_outlined,
                _ => Icons.check_circle_outline,
              }),
              title: Text(
                '${source.goodsName ?? source.goodsCode ?? '物料'} · '
                '${_settlementLabel(source.settlementType)} '
                '${_number(source.postedQtyBase)} ${source.unitName ?? '单位待核实'}',
              ),
              subtitle: Text(
                [
                  if ((source.reason ?? '').isNotEmpty) source.reason,
                  if (source.reversedQtyBase > 0)
                    '已冲销 ${_number(source.reversedQtyBase)} ${source.unitName ?? '单位待核实'}',
                  if ((source.executionSegmentCode ?? '').isNotEmpty)
                    '子计划 ${source.executionSegmentCode}',
                  source.createdAt,
                ].whereType<String>().join(' · '),
              ),
              trailing:
                  _canReverse && !_editingLocked && source.reversibleQtyBase > 0
                  ? TextButton(
                      onPressed: () => _reverse(source),
                      child: const Text('冲销'),
                    )
                  : null,
            ),
      ],
    );
  }

  Widget _returnHistory(ThemeData theme) => ExpansionTile(
    key: const ValueKey('material-return-history'),
    tilePadding: EdgeInsets.zero,
    initiallyExpanded: _returns.any((document) => document.pending),
    title: Text(
      '退仓申请（待仓库收料 ${_returns.where((document) => document.pending).length} 单）',
    ),
    subtitle: const Text('仓库核对后整单确认收料；数量不符时撤回申请，核对后重新提交。'),
    children: [
      for (final document in _returns)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
          title: Text(
            '${document.documentNo} · ${document.warehouseName} · ${document.statusLabel}',
          ),
          subtitle: Text(
            document.lines
                .map(
                  (line) =>
                      '${line.goodsName} ${line.colorName} ${_number(line.qty)} ${line.unitName}',
                )
                .join('\n'),
          ),
          trailing: document.pending && _canReturn
              ? TextButton(
                  onPressed: _editingLocked
                      ? null
                      : () => _cancelReturn(document),
                  child: const Text('撤回申请'),
                )
              : null,
        ),
    ],
  );
}

double _positive(String text) {
  final value = double.tryParse(text.trim()) ?? 0;
  return value > 0 ? value : 0;
}

String _number(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');

String _settlementLabel(String type) => switch (type) {
  'APPROVED_LOSS' => '批准损耗',
  'LEGAL_WIP' => '在制占用',
  _ => '实际消耗',
};

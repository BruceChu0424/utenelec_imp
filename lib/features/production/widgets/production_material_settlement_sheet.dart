import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../warehouse/models/stock_doc.dart';
import '../../warehouse/repositories/stock_doc_repository.dart';
import '../repositories/production_material_repository.dart';

Future<bool?> showProductionMaterialSettlementSheet(
  BuildContext context,
  WidgetRef ref, {
  required String planId,
  required bool canSettle,
  required bool canReverse,
  required bool canClose,
}) {
  return showUtenAdaptivePanel<bool>(
    context: context,
    compactHeightFactor: 0.94,
    drawerWidth: 840,
    panelElevation: 16,
    barrierColor: Colors.black.withValues(alpha: .38),
    barrierLabel: '关闭材料结清面板',
    transitionDuration: const Duration(milliseconds: 300),
    builder: (_) => _MaterialSettlementSheet(
      planId: planId,
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

  void fillAsConsumed() {
    consumed.text = _number(source.unclearedQty);
    loss.clear();
    wip.clear();
  }

  @override
  void dispose() {
    consumed.dispose();
    loss.dispose();
    wip.dispose();
    super.dispose();
  }
}

class _MaterialSettlementSheet extends ConsumerStatefulWidget {
  const _MaterialSettlementSheet({
    required this.planId,
    required this.canSettle,
    required this.canReverse,
    required this.canClose,
  });

  final String planId;
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
  List<ProductionMaterialSettlementSource> _sources = const [];
  bool _loading = true;
  bool _busy = false;
  bool _closed = false;
  String? _error;

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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(productionMaterialRepositoryProvider);
      final results = await Future.wait([
        repo.clearance(widget.planId),
        repo.settlementSources(widget.planId),
      ]);
      if (!mounted) return;
      _grid.replaceAll([
        for (final row in results[0] as List<ProductionMaterialClearanceRow>)
          _SettlementGridRow(row),
      ]);
      setState(() {
        _sources = results[1] as List<ProductionMaterialSettlementSource>;
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
      if (row.source.unclearedQty > 0) row.fillAsConsumed();
    }
    setState(() {});
  }

  Future<void> _submit() async {
    if (!widget.canSettle) return;
    if (_busy) return;
    final lines = <ProductionMaterialSettlementLine>[];
    var requiresReason = false;
    for (final row in _grid.rows) {
      final consumed = _positive(row.consumed.text);
      final loss = _positive(row.loss.text);
      final wip = _positive(row.wip.text);
      final total = consumed + loss + wip;
      if (total > row.source.unclearedQty + 0.0000001) {
        context.appError(
          '${row.source.goodsName ?? row.source.goodsCode ?? '物料'} '
          '本次结清 ${_number(total)}，超过未结清 ${_number(row.source.unclearedQty)}',
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
    final canonical = [
      widget.planId,
      reason,
      for (final line in lines)
        '${line.demandId}:${line.settlementType}:${line.qtyBase.toStringAsFixed(6)}',
    ].join('|');
    setState(() => _busy = true);
    try {
      await ref
          .read(productionMaterialRepositoryProvider)
          .settle(
            widget.planId,
            idempotencyKey: businessIdempotencyKey(
              'material-settle',
              canonical,
            ),
            lines: lines,
            reason: reason.isEmpty ? null : reason,
          );
      if (!mounted) return;
      context.appSuccess('材料使用已入账，未结清数量已重新计算');
      _reason.clear();
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('材料结清失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reverse(ProductionMaterialSettlementSource source) async {
    if (!widget.canReverse) return;
    final qty = TextEditingController(text: _number(source.reversibleQtyBase));
    final reason = TextEditingController();
    final result = await showDialog<(double, String)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('冲销材料结清记录'),
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
                decoration: InputDecoration(
                  labelText: '冲销数量',
                  helper: UtenFieldMessage.helper(
                    '最多 ${_number(source.reversibleQtyBase)}',
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextFormField(
                errorBuilder: utenTextFieldErrorBuilder,
                controller: reason,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: '冲销原因',
                  hintText: '例如：误报、数量录入错误',
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
    qty.dispose();
    reason.dispose();
    if (result == null || !mounted) return;
    final canonical =
        '${widget.planId}|${source.postingId}|${result.$1.toStringAsFixed(6)}|${result.$2}';
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
      context.appSuccess('材料结清记录已冲销');
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
    if (!widget.canClose) return;
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
    try {
      final sources = await ref
          .read(stockDocRepositoryProvider(StockDocType.wdraw))
          .returnableSources(planId: widget.planId);
      if (!mounted) return;
      if (sources.isEmpty) {
        context.appWarning('当前没有可退回的已领良品');
        return;
      }
      final draws = <String, ReturnableMaterialSource>{};
      for (final source in sources) {
        draws.putIfAbsent(source.drawId, () => source);
      }
      final selected = draws.length == 1
          ? draws.values.first
          : await showDialog<ReturnableMaterialSource>(
              context: context,
              builder: (dialogContext) => SimpleDialog(
                title: const Text('选择原领料单'),
                children: [
                  for (final source in draws.values)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(dialogContext, source),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.outbound_outlined),
                        title: Text(source.drawNo),
                        subtitle: Text(
                          '${sources.where((item) => item.drawId == source.drawId).length} 种物料可退',
                        ),
                      ),
                    ),
                ],
              ),
            );
      if (selected == null || !mounted) return;
      Navigator.of(context).pop(_closed);
      context.push(RoutePath.stockWdrawNewFromDraw(selected.drawId));
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('读取可退料领料单失败');
    }
  }

  bool get _allCleared =>
      _grid.rows.isNotEmpty && _grid.rows.every((row) => row.source.canClose);

  double get _totalUncleared =>
      _grid.rows.fold(0, (sum, row) => sum + row.source.unclearedQty);

  double get _totalReturnable =>
      _grid.rows.fold(0, (sum, row) => sum + row.source.maxReturnQty);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('材料使用、退库与结清'),
            Text(
              '数量守恒：已领 = 实耗 + 良品退库 + 批准损耗 + 合法在制',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context, _closed),
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '材料结清台账(${_grid.length} 种)',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (widget.canSettle)
                        TextButton.icon(
                          onPressed: _busy ? null : _fillAllConsumed,
                          icon: const Icon(Icons.done_all_rounded, size: 18),
                          label: const Text('未结清全部填入实耗'),
                        ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  UtenEditableGrid<_SettlementGridRow>(
                    controller: _grid,
                    columns: _columns(),
                    createBlankRow: () => throw UnsupportedError('材料行只能来自需求台账'),
                    showAddRow: false,
                    showRowDelete: false,
                    emptyMessage: '尚未生成物料需求台账',
                  ),
                  if (widget.canSettle) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      controller: _reason,
                      maxLength: 500,
                      decoration: const InputDecoration(
                        labelText: '本次说明',
                        hintText: '损耗、报废、留作在制时必须填写；仅登记实际消耗可选填',
                        prefixIcon: Icon(Icons.notes_rounded),
                      ),
                    ),
                  ],
                  if (widget.canSettle || widget.canClose) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s8,
                      children: [
                        if (widget.canSettle)
                          UtenButton(
                            icon: Icons.fact_check_outlined,
                            isLoading: _busy,
                            onPressed: _busy ? null : _submit,
                            child: const Text('提交本次材料结清'),
                          ),
                        if (widget.canSettle)
                          UtenButton(
                            type: UtenButtonType.secondary,
                            icon: Icons.keyboard_return_rounded,
                            onPressed: _busy ? null : _startReturn,
                            child: const Text('余料退库'),
                          ),
                        if (widget.canClose)
                          UtenButton(
                            type: UtenButtonType.tonal,
                            icon: Icons.task_alt_rounded,
                            onPressed: _busy || !_allCleared
                                ? null
                                : _closePlan,
                            child: const Text('检查并完成任务'),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: UtenSpacing.s16),
                  _history(theme),
                ],
              ),
            ),
    );
  }

  Widget _stats(ThemeData theme) {
    final cards = [
      ('物料种类', '${_grid.length}', Icons.inventory_2_outlined),
      (
        '已结清',
        '${_grid.rows.where((row) => row.source.canClose).length}',
        Icons.check_circle_outline,
      ),
      ('待处理数量', _number(_totalUncleared), Icons.pending_actions_outlined),
      ('最多可退', _number(_totalReturnable), Icons.keyboard_return_outlined),
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
                  ? '所有材料已平衡；系统仍会核对成品累计合格入库数量，二者同时满足后才能完成任务。'
                  : '有余料时先走“余料退库”，仓库点收后再刷新；损耗和在制必须说明原因。'
                        '系统不允许用“实耗”掩盖未归还余料，也不允许结清数量超过已领数量。',
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
            ].where((value) => value?.isNotEmpty == true).join(' · '),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    ),
    _numberColumn('required', '需求', (row) => row.source.requiredQty),
    _numberColumn('issued', '已领', (row) => row.source.issuedQty),
    _numberColumn('returned', '已退', (row) => row.source.returnedQty),
    _numberColumn('settled', '已实耗', (row) => row.source.consumedQty),
    _numberColumn('lossDone', '已损耗', (row) => row.source.approvedLossQty),
    _numberColumn('wipDone', '已在制', (row) => row.source.legalWipQty),
    _numberColumn('uncleared', '未结清', (row) => row.source.unclearedQty),
    _inputColumn('consume', '本次实耗', (row) => row.consumed),
    _inputColumn('loss', '本次损耗', (row) => row.loss),
    _inputColumn('wip', '本次在制', (row) => row.wip),
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

  EditableGridColumn<_SettlementGridRow> _inputColumn(
    String key,
    String label,
    TextEditingController Function(_SettlementGridRow) controller,
  ) => EditableGridColumn(
    key: key,
    label: label,
    width: 108,
    numeric: true,
    cellBuilder: (_, row) => TextField(
      controller: controller(row),
      enabled: widget.canSettle && !_busy && row.source.unclearedQty > 0,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(isDense: true, hintText: '0'),
    ),
  );

  Widget _history(ThemeData theme) {
    final active = _sources
        .where((source) => source.reversibleQtyBase > 0)
        .toList();
    return ExpansionTile(
      initiallyExpanded: active.isNotEmpty,
      tilePadding: EdgeInsets.zero,
      title: Text(
        '已提交记录(${_sources.length})',
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
                '${_number(source.postedQtyBase)}',
              ),
              subtitle: Text(
                [
                  if ((source.reason ?? '').isNotEmpty) source.reason,
                  if (source.reversedQtyBase > 0)
                    '已冲销 ${_number(source.reversedQtyBase)}',
                  if ((source.executionSegmentCode ?? '').isNotEmpty)
                    '子计划 ${source.executionSegmentCode}',
                  source.createdAt,
                ].whereType<String>().join(' · '),
              ),
              trailing:
                  widget.canReverse && !_busy && source.reversibleQtyBase > 0
                  ? TextButton(
                      onPressed: () => _reverse(source),
                      child: const Text('冲销'),
                    )
                  : null,
            ),
      ],
    );
  }
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

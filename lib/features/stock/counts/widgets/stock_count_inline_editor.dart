import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/idempotency_key.dart';
import '../../../../shared/formatters/exact_decimal.dart';
import '../../../../shared/badges/badge_registry.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/stock_count_request.dart';
import '../repositories/stock_count_request_repository.dart';
import 'stock_count_candidate_picker.dart';

bool _same(String? left, String? right) =>
    financeExactTrimmed(left) == financeExactTrimmed(right);

String? _massWeight(String qty, String factor) {
  final exact = financeExactMultiplyTexts([qty, factor]);
  if (exact == null) return null;
  final parts = exact.split('.');
  final fraction = parts.length > 1 ? parts[1] : '';
  if (fraction.length <= 4) return financeExactTrimmed(exact);
  final coefficient = BigInt.parse('${parts[0]}$fraction');
  final divisor = BigInt.from(10).pow(fraction.length - 4);
  return financeExactTrimmed(
    financeExactDecimalFromUnits(
      (coefficient + divisor ~/ BigInt.two) ~/ divisor,
    ),
  );
}

class StockCountEditRow {
  StockCountEditRow(this.snapshot, VoidCallback changed) {
    qty.addListener(changed);
    weight.addListener(changed);
  }
  final CountStockRow snapshot;
  final qty = TextEditingController();
  final weight = TextEditingController();
  String get targetQty =>
      qty.text.trim().isEmpty ? snapshot.qty : qty.text.trim();
  bool get qtyChanged =>
      qty.text.trim().isNotEmpty && !_same(targetQty, snapshot.qty);
  String? get targetWeightKg => snapshot.weightExact
      ? _massWeight(targetQty, snapshot.kgPerBaseUnit!)
      : weight.text.trim().isEmpty
      ? null
      : weight.text.trim();
  bool get weightChanged => snapshot.weightExact
      ? qtyChanged
      : weight.text.trim().isNotEmpty &&
            !_same(weight.text.trim(), snapshot.weightKg);
  bool get changed => qtyChanged || weightChanged;
  String? get validation {
    if (!changed) return null;
    if (!RegExp(r'^\d{1,14}(\.\d{1,4})?$').hasMatch(targetQty)) {
      return '实盘数量须为非负数，最多 4 位小数';
    }
    final value = targetWeightKg;
    if (weightChanged &&
        value != null &&
        !RegExp(r'^\d{1,14}(\.\d{1,4})?$').hasMatch(value)) {
      return '实盘重量须为非负数，最多 4 位小数';
    }
    if (snapshot.weightExact &&
        (!_same(targetQty, '0') && _same(value, '0') || value == null)) {
      return '实盘重量小于 0.0001 kg，请核对单位精度后再送审';
    }
    if (!snapshot.weightExact &&
        !_same(targetQty, '0') &&
        weightChanged &&
        _same(value, '0')) {
      return '有库存时实盘重量须大于 0，未知重量请留空';
    }
    if (!snapshot.weightExact &&
        _same(targetQty, '0') &&
        weightChanged &&
        !_same(value, '0')) {
      return '数量为 0 时重量必须为 0';
    }
    return null;
  }

  Map<String, dynamic> payload(bool workshop) => {
    'goodsId': snapshot.goodsId,
    'colorId': snapshot.colorId,
    'unitId': snapshot.unitId,
    'expectedQty': snapshot.qty,
    'expectedWeightKg': snapshot.weightKg,
    'expectedWeightEstimated': snapshot.weightEstimated,
    'targetQty': targetQty,
    if (weightChanged) 'targetWeightKg': targetWeightKg,
    'weightChanged': weightChanged,
    'goodsVersion': snapshot.goodsVersion,
    if (workshop && snapshot.issueMethod == 'ORDER')
      'materialSetupBasis': 'OWN',
  };
  void dispose() {
    qty.dispose();
    weight.dispose();
  }
}

/// Page-owned edit buffer; original inventory rows remain the server's official values.
class StockCountInlineController extends ChangeNotifier {
  StockCountInlineController(this.repository);
  final StockCountRequestRepository repository;
  final reason = TextEditingController();
  final Map<String, StockCountEditRow> rows = {};
  final Map<String, CountStockRow> addedRows = {};
  final Set<String> _loadedGoods = {};
  StockCountWarehouse? warehouse;
  String? error;
  bool busy = false;
  bool _submitting = false;
  bool _disposed = false;
  int _generation = 0;
  String _nonce = '';
  bool get active => warehouse != null;
  int get changedCount => rows.values.where((row) => row.changed).length;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void begin(StockCountWarehouse selected) {
    clear();
    warehouse = selected;
    _nonce = const Uuid().v4();
    _notify();
  }

  void clear() {
    _generation++;
    for (final row in rows.values) {
      row.dispose();
    }
    rows.clear();
    addedRows.clear();
    _loadedGoods.clear();
    warehouse = null;
    error = null;
    busy = false;
    reason.clear();
    _notify();
  }

  void add(CountStockRow snapshot) {
    if (!active || !snapshot.canEdit || busy) return;
    rows.putIfAbsent(snapshot.key, () => StockCountEditRow(snapshot, _notify));
    addedRows[snapshot.key] = snapshot;
    _notify();
  }

  Future<void> ensureRows(Iterable<String> goods) async {
    final selected = warehouse;
    if (selected == null || _submitting) return;
    final ids = goods
        .where((id) => id.isNotEmpty && !_loadedGoods.contains(id))
        .toSet()
        .toList();
    if (ids.isEmpty) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      final snapshots = <CountStockRow>[];
      for (var offset = 0; offset < ids.length; offset += 50) {
        final chunk = ids.sublist(offset, (offset + 50).clamp(0, ids.length));
        var page = 1;
        while (true) {
          final result = await repository.candidates(
            warehouseId: selected.id,
            goodsIds: chunk,
            page: page,
            size: 100,
          );
          if (_disposed ||
              generation != _generation ||
              warehouse?.id != selected.id) {
            return;
          }
          snapshots.addAll(result.items);
          if (page >= result.totalPages) break;
          page++;
        }
      }
      for (final row in snapshots) {
        if (row.canEdit) {
          rows.putIfAbsent(row.key, () => StockCountEditRow(row, _notify));
        }
      }
      _loadedGoods.addAll(ids);
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error = e is ApiException ? e.message : '盘点快照未读到，请重试';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  Future<StockCountRequest> submit() async {
    final selected = warehouse;
    if (selected == null || busy) throw StateError('当前不能送审');
    final changed = rows.values.where((row) => row.changed).toList()
      ..sort((a, b) => a.snapshot.key.compareTo(b.snapshot.key));
    if (changed.isEmpty) throw const FormatException('请至少填写一项变化后的实盘数量或重量');
    for (final row in changed) {
      if (row.validation != null) {
        throw FormatException('${row.snapshot.goodsName}：${row.validation}');
      }
    }
    final explanation = reason.text.trim();
    if (explanation.isEmpty) throw const FormatException('请填写盘点说明');
    final lines = [for (final row in changed) row.payload(selected.isWorkshop)];
    final key = businessIdempotencyKey(
      'stock-count',
      '$_nonce|${selected.id}|$explanation|$lines',
    );
    busy = true;
    _submitting = true;
    error = null;
    _notify();
    try {
      return await repository.submit(
        warehouseId: selected.id,
        reason: explanation,
        idempotencyKey: key,
        lines: lines,
      );
    } finally {
      if (!_disposed) {
        busy = false;
        _submitting = false;
        _notify();
      }
    }
  }

  List<MasterColumnDef<T>> columns<T>(String Function(T row) keyOf) => [
    MasterColumnDef<T>(
      key: 'countTargetQty',
      label: '实盘数量',
      width: 155,
      value: (item) => rows[keyOf(item)]?.qty.text,
      cellBuilderHandlesSemantics: true,
      exactValueOf: (item) => rows[keyOf(item)]?.targetQty,
      exactListenableOf: (item) => rows[keyOf(item)]?.qty,
      cellBuilder: (context, item) =>
          StockCountInlineCell(controller: this, rowKey: keyOf(item)),
    ),
    MasterColumnDef<T>(
      key: 'countTargetWeight',
      label: '实盘重量 (kg)',
      width: 175,
      value: (item) => rows[keyOf(item)]?.targetWeightKg,
      cellBuilderHandlesSemantics: true,
      exactValueOf: (item) => rows[keyOf(item)]?.targetWeightKg,
      exactListenableOf: (item) =>
          rows[keyOf(item)]?.snapshot.weightExact == true
          ? rows[keyOf(item)]?.qty
          : rows[keyOf(item)]?.weight,
      cellBuilder: (context, item) => StockCountInlineCell(
        controller: this,
        rowKey: keyOf(item),
        weight: true,
      ),
    ),
  ];
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    for (final row in rows.values) {
      row.dispose();
    }
    reason.dispose();
    super.dispose();
  }
}

class StockCountInlineCell extends StatelessWidget {
  const StockCountInlineCell({
    super.key,
    required this.controller,
    required this.rowKey,
    this.weight = false,
  });
  final StockCountInlineController controller;
  final String rowKey;
  final bool weight;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final row = controller.rows[rowKey];
      if (row == null) return Text(controller.busy ? '读取快照…' : '不可编辑');
      if (weight && row.snapshot.weightExact) {
        return Text('${financeExactTrimmed(row.targetWeightKg) ?? '—'}（自动）');
      }
      return TextField(
        key: ValueKey('stock-count-${weight ? 'weight' : 'qty'}-$rowKey'),
        controller: weight ? row.weight : row.qty,
        enabled: !controller.busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          isDense: true,
          hintText: weight ? row.snapshot.weightKg ?? '未称' : row.snapshot.qty,
          errorText: row.validation == null ? null : '请核对',
        ),
      );
    },
  );
}

/// One toolbar shared by both existing inventory tables; no replacement table or separate count layout.
class StockCountModeToolbar extends StatefulWidget {
  const StockCountModeToolbar({
    super.key,
    required this.controller,
    required this.allowed,
    required this.goodsIds,
    required this.onStart,
    required this.onSubmitted,
    this.warehouseId,
    this.fixedWarehouse = false,
  });
  final StockCountInlineController controller;
  final bool allowed;
  final String? warehouseId;
  final bool fixedWarehouse;
  final Iterable<String> Function() goodsIds;
  final Future<void> Function(StockCountWarehouse warehouse) onStart;
  final Future<void> Function() onSubmitted;
  @override
  State<StockCountModeToolbar> createState() => _StockCountModeToolbarState();
}

class _StockCountModeToolbarState extends State<StockCountModeToolbar> {
  bool _starting = false;
  Future<void> _start() async {
    if (_starting || !widget.allowed) return;
    setState(() => _starting = true);
    try {
      final scope = await widget.controller.repository.scope(
        warehouseId: widget.fixedWarehouse ? widget.warehouseId : null,
      );
      if (!mounted) return;
      if (!scope.canSubmit) {
        context.appWarning('当前没有提交盘点的权限');
        return;
      }
      StockCountWarehouse? selected;
      for (final warehouse in scope.warehouses) {
        if (warehouse.id == widget.warehouseId) selected = warehouse;
      }
      if (selected == null && widget.fixedWarehouse) {
        context.appWarning('当前内料仓不在可盘点范围内');
        return;
      }
      selected ??= await showDialog<StockCountWarehouse>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('盘点请选择具体仓库'),
          children: [
            if (scope.warehouses.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('当前没有可盘点的仓库'),
              ),
            for (final warehouse in scope.warehouses)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, warehouse),
                child: Text('${warehouse.name} · ${warehouse.reviewerLabel}审核'),
              ),
          ],
        ),
      );
      if (!mounted || selected == null) return;
      widget.controller.begin(selected);
      await widget.onStart(selected);
      await widget.controller.ensureRows(widget.goodsIds());
    } catch (error) {
      if (mounted) {
        context.appError(
          error is ApiException ? error.message : '盘点模式未能开启，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _exit() async {
    if (widget.controller.busy) return;
    if (widget.controller.changedCount > 0) {
      final leave = await UtenDialog.show(
        context,
        title: '退出盘点模式',
        content: const Text('尚未送审的实盘输入将丢弃。'),
        confirmLabel: '丢弃并退出',
        cancelLabel: '继续填写',
      );
      if (leave != true) return;
    }
    widget.controller.clear();
  }

  Future<void> _save() async {
    if (!widget.allowed) return;
    try {
      final reviewer = widget.controller.warehouse!.reviewerLabel;
      final request = await widget.controller.submit();
      if (!mounted) return;
      widget.controller.clear();
      context.appSuccess('盘点 ${request.requestNo} 已送$reviewer审核，正式库存尚未改变');
      refreshBadgesIn(ProviderScope.containerOf(context));
      await widget.onSubmitted();
    } catch (error) {
      if (mounted) {
        context.appError(
          error is ApiException
              ? error.message
              : error is FormatException
              ? error.message
              : '送审结果未确认，输入已保留，可原样重试',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      if (!widget.allowed) return const SizedBox.shrink();
      final controller = widget.controller;
      if (!controller.active) {
        return Wrap(
          spacing: UtenSpacing.s8,
          children: [
            UtenButton(
              key: const Key('stock-count-mode'),
              type: UtenButtonType.secondary,
              icon: Icons.fact_check_outlined,
              onPressed: _starting ? null : _start,
              child: Text(_starting ? '正在开启盘点…' : '盘点模式'),
            ),
            TextButton(
              onPressed: () => context.push(RouteName.stockCountRequests),
              child: const Text('我的盘点'),
            ),
          ],
        );
      }
      return Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${controller.warehouse!.name} · ${controller.warehouse!.reviewerLabel}审核 · 已改 ${controller.changedCount} 项',
          ),
          SizedBox(
            width: 240,
            child: TextField(
              key: const Key('stock-count-reason'),
              controller: controller.reason,
              enabled: !controller.busy,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '盘点说明',
                hintText: '例如上线清点或例行盘点',
              ),
            ),
          ),
          UtenButton(
            key: const Key('stock-count-add'),
            type: UtenButtonType.secondary,
            onPressed: controller.busy
                ? null
                : () async {
                    final row = await showStockCountCandidatePicker(
                      context,
                      warehouse: controller.warehouse!,
                    );
                    if (mounted && row != null && controller.active) {
                      controller.add(row);
                    }
                  },
            child: const Text('添加零库存物料'),
          ),
          UtenButton(
            key: const Key('stock-count-save'),
            onPressed: controller.busy || controller.changedCount == 0
                ? null
                : _save,
            child: const Text('保存并送审'),
          ),
          TextButton(
            onPressed: controller.busy ? null : _exit,
            child: const Text('退出盘点'),
          ),
          if (controller.error != null)
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () => controller.ensureRows(widget.goodsIds()),
              child: Text('${controller.error} · 重试'),
            ),
        ],
      );
    },
  );
}

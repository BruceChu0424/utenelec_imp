import 'package:flutter/material.dart';
import '../../../../components/inputs/uten_input_decoration.dart';
import '../../../../components/inputs/uten_field_message.dart';
import '../../../../components/inputs/uten_table_cell_spec.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
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
  int _session = 0;
  String _nonce = '';

  /// 刚送审、等审核的展示态(2026-10-10 用户口径)：送审后不立即清空——表格保留
  /// 刚提交的内容并加「待审核」状态列，账面/现存照旧可见(审核通过前服务端不动库存，
  /// V766 送审只写申请三表)。退出盘点才清空。
  StockCountRequest? _lastSubmitted;
  StockCountRequest? get lastSubmitted => _lastSubmitted;
  bool get reviewing => _lastSubmitted != null;

  /// 本次送审包含的行 key；「待审核」状态列只盖这些行。
  Set<String> _submittedKeys = const {};
  bool rowSubmitted(String key) => _submittedKeys.contains(key);

  bool get active => warehouse != null;
  int get session => _session;
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
    _session++;
    for (final row in rows.values) {
      row.dispose();
    }
    rows.clear();
    addedRows.clear();
    _loadedGoods.clear();
    warehouse = null;
    error = null;
    busy = false;
    _lastSubmitted = null;
    _submittedKeys = const {};
    reason.clear();
    _notify();
  }

  void add(CountStockRow snapshot) {
    addAll([snapshot]);
  }

  void addAll(Iterable<CountStockRow> snapshots, {int? expectedSession}) {
    if (!active ||
        busy ||
        (expectedSession != null && expectedSession != _session)) {
      return;
    }
    for (final snapshot in snapshots) {
      if (!snapshot.canEdit) continue;
      final row = rows.putIfAbsent(
        snapshot.key,
        () => StockCountEditRow(snapshot, _notify),
      );
      // Repeat selection must preserve both the edited values and their basis.
      addedRows.putIfAbsent(snapshot.key, () => row.snapshot);
    }
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
        error = e is ApiException ? e.message : '盘点数据没有读到，请重试';
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
    // 盘点说明选填(2026-10-02 用户口径, V795/ADR-151)：原样提交，空白归一与
    // 500 字上限都由服务端判定，前端不另设必填。
    final explanation = reason.text.trim();
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
      final request = await repository.submit(
        warehouseId: selected.id,
        reason: explanation,
        idempotencyKey: key,
        lines: lines,
      );
      // 送审成功进入「待审核」展示态：行保留为只读回执，直到退出盘点(见 [reviewing])。
      _lastSubmitted = request;
      _submittedKeys = {for (final row in changed) row.snapshot.key};
      return request;
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

/// 实盘格 = 常驻输入框（2026-10-08 用户口径：默认就能直接输入，不再点按切换）。
/// 本格即全站表格输入格统一规格的出处（UtenEditableGridCellSpec，ADR-161 修订）；
/// 「（自动）」= 质量单位按换算自动得重量，不收输入。空值以占位提示展示账面数，
/// 校验失败红框。
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
      // 待审核展示态：刚送审的行是只读回执，不再是输入框(账面照旧、审核通过前库存不动)。
      if (controller.reviewing) {
        if (row == null) return const SizedBox.shrink();
        if (weight && row.snapshot.weightExact) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${financeExactTrimmed(row.targetWeightKg) ?? '—'}（自动）',
            ),
          );
        }
        final typed = (weight ? row.weight.text : row.qty.text).trim();
        final fallback = weight
            ? (row.snapshot.weightKg ?? '未称')
            : row.snapshot.qty;
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(typed.isEmpty ? fallback : typed),
        );
      }
      if (row == null) return Text(controller.busy ? '读取中…' : '不可编辑');
      if (weight && row.snapshot.weightExact) {
        return Text('${financeExactTrimmed(row.targetWeightKg) ?? '—'}（自动）');
      }
      final text = weight ? row.weight : row.qty;
      return TextField(
        key: ValueKey('stock-count-${weight ? 'weight' : 'qty'}-$rowKey'),
        controller: text,
        enabled: !controller.busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        // 紧凑格：共享规格单一事实源（2026-10-08 起全站表格输入格同源，
        // 见 UtenEditableGridCellSpec），无额外叠层。
        // 2026-10-10「数量+单位」内联口径：实盘数量输入框单位放后缀（重量列
        // 单位已在列头 kg）。
        decoration: UtenInputDecoration(
          InputDecoration(
            isDense: true,
            contentPadding: UtenEditableGridCellSpec.contentPadding,
            suffixText: weight ? null : row.snapshot.unitName,
            hintText: weight ? row.snapshot.weightKg ?? '未称' : row.snapshot.qty,
            error: row.validation == null
                ? null
                : const UtenFieldMessage.error('请核对'),
          ),
        ),
      );
    },
  );
}

/// Right-bottom floating count actions shared by both existing inventory tables;
/// no replacement table or separate count layout. 盘点说明输入在「保存并送审」确认
/// 弹窗里(2026-10-10 用户口径, 会话页同款), 组件负责动作按钮; 送审成功后进入
/// 「待审核」只读展示态, 直到退出盘点。
class StockCountModeToolbar extends ConsumerStatefulWidget {
  const StockCountModeToolbar({
    super.key,
    required this.controller,
    required this.allowed,
    required this.goodsIds,
    required this.onStart,
    required this.onSubmitted,
    required this.inactiveActionsBuilder,
    required this.warehouseId,
  });
  final StockCountInlineController controller;
  final bool allowed;

  /// 固定盘点目标仓（内料仓页把自己的 binWarehouseId 传进来；null 时提示不可盘）。
  final String? warehouseId;

  /// 宿主自己的非盘点态动作组（如内料仓页把「库存盘点/盘点历史」并进既有悬浮组）。
  /// 即时库存页已改为本页右下悬浮按钮直达独立盘点会话页，不再用本组件。
  final List<Widget> Function(VoidCallback? start, VoidCallback history)
  inactiveActionsBuilder;
  final Iterable<String> Function() goodsIds;
  final Future<void> Function(StockCountWarehouse warehouse) onStart;
  final Future<void> Function() onSubmitted;
  @override
  ConsumerState<StockCountModeToolbar> createState() =>
      _StockCountModeToolbarState();
}

class _StockCountModeToolbarState extends ConsumerState<StockCountModeToolbar> {
  bool _starting = false;
  Future<void> _start() async {
    if (_starting || !widget.allowed) return;
    setState(() => _starting = true);
    try {
      final scope = await widget.controller.repository.scope(
        warehouseId: widget.warehouseId,
      );
      if (!mounted || !widget.allowed) return;
      if (!scope.canSubmit) {
        context.appWarning('当前没有提交盘点的权限');
        return;
      }
      StockCountWarehouse? selected;
      for (final warehouse in scope.warehouses) {
        if (widget.warehouseId != null && warehouse.id == widget.warehouseId) {
          selected = warehouse;
        }
      }
      if (selected == null) {
        context.appWarning('当前内料仓不在可盘点范围内');
        return;
      }
      widget.controller.begin(selected);
      await widget.onStart(selected);
      if (!mounted || !widget.allowed) return;
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
    // 待审核展示态没有未保存输入，退出不再确认(内容已送审，看不看随人)。
    if (!widget.controller.reviewing && widget.controller.changedCount > 0) {
      final leave = await UtenDialog.show(
        context,
        title: '退出盘点模式',
        content: const Text('还没送审的实盘数字会被清空。'),
        confirmLabel: '清空并退出',
        cancelLabel: '继续填写',
      );
      if (leave != true) return;
    }
    widget.controller.clear();
  }

  Future<void> _save() async {
    if (!widget.allowed) return;
    final controller = widget.controller;
    final warehouse = controller.warehouse;
    if (warehouse == null) return;
    for (final row in controller.rows.values.where((row) => row.changed)) {
      if (row.validation != null) {
        context.appError('${row.snapshot.goodsName}：${row.validation}');
        return;
      }
    }
    // 2026-10-10 用户口径：说明不放页面常驻，放「保存并送审」确认弹窗选填
    // (V795, 空白归一与 500 字上限由服务端判定)；文本仍走 controller，
    // 与盘点会话页同款。取消时输入与说明都原样保留。
    final confirmed = await UtenDialog.show(
      context,
      title: '保存并送审',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '本次送审 ${controller.changedCount} 项实盘变化，送审后保留在本页等待审核，'
            '审核通过前正式库存不变。',
          ),
          const SizedBox(height: UtenSpacing.s12),
          TextField(
            key: const Key('stock-count-reason'),
            controller: controller.reason,
            maxLines: 2,
            decoration: const UtenInputDecoration(
              InputDecoration(
                isDense: true,
                labelText: '盘点说明(选填)',
                hintText: '例如上线清点或例行盘点，最多 500 字',
              ),
            ),
          ),
        ],
      ),
      confirmLabel: '确认送审',
      cancelLabel: '取消',
    );
    if (confirmed != true || !mounted) return;
    try {
      // 送审成功后 controller 进入「待审核」展示态(行保留为只读回执)，不再清空。
      final request = await controller.submit();
      if (!mounted) return;
      context.appSuccess(
        '盘点 ${request.requestNo} 已送${warehouse.reviewerLabel}审核，正式库存尚未改变',
      );
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

  void _history() {
    if (!mounted || !widget.allowed) return;
    context.push(RouteName.stockCountRequests);
  }

  List<Widget> _activeActions(StockCountInlineController controller) {
    // 待审核展示态：只剩退出与盘点历史，不再提供保存/添加(内容已送审)。
    if (controller.reviewing) {
      return [
        UtenButton(
          key: const Key('stock-count-exit'),
          size: UtenButtonSize.large,
          type: UtenButtonType.secondary,
          onPressed: _exit,
          child: const Text('退出盘点'),
        ),
        UtenButton(
          key: const Key('stock-count-history'),
          size: UtenButtonSize.large,
          type: UtenButtonType.secondary,
          onPressed: _history,
          child: const Text('盘点历史'),
        ),
      ];
    }
    return [
      UtenButton(
        key: const Key('stock-count-exit'),
        size: UtenButtonSize.large,
        type: UtenButtonType.secondary,
        onPressed: controller.busy ? null : _exit,
        child: const Text('退出盘点'),
      ),
      UtenButton(
        key: const Key('stock-count-add'),
        size: UtenButtonSize.large,
        type: UtenButtonType.secondary,
        onPressed: controller.busy
            ? null
            : () async {
                if (!widget.allowed || !controller.active) return;
                final session = controller.session;
                final rows = await showStockCountCandidatePicker(
                  context,
                  ref,
                  warehouse: controller.warehouse!,
                );
                if (mounted &&
                    widget.allowed &&
                    controller.active &&
                    rows.isNotEmpty) {
                  controller.addAll(rows, expectedSession: session);
                }
              },
        child: const Text('添加物料'),
      ),
      UtenButton(
        key: const Key('stock-count-save'),
        size: UtenButtonSize.large,
        onPressed: controller.busy || controller.changedCount == 0
            ? null
            : _save,
        child: const Text('保存并送审'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      if (!widget.allowed) return const SizedBox.shrink();
      final controller = widget.controller;
      if (!controller.active) {
        return UtenFloatingActionGroup(
          children: widget.inactiveActionsBuilder(
            _starting ? null : _start,
            _history,
          ),
        );
      }
      return UtenFloatingActionGroup(children: _activeActions(controller));
    },
  );
}

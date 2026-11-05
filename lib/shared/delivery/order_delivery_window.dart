import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../../components/feedback/uten_floating_window.dart';
import '../../components/inputs/uten_dropdown_field.dart';
import '../../components/inputs/uten_field_hint_icon.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../../features/basic_data/widgets/master_data_table_view.dart';
import '../providers/sensitive_read_boundary_provider.dart';
import '../widgets/uten_tree_table_cell.dart';
import 'order_delivery_plan.dart';
import 'order_delivery_repository.dart';

final _deliveryWindowSessions =
    <
      Object,
      ({
        GlobalKey<UtenFloatingWindowState> key,
        Future<OrderDeliveryPlan?> result,
      })
    >{};

/// Uses a page-owned, non-modal floating surface; closing never modifies the order.
Future<OrderDeliveryPlan?> showOrderDeliveryWindow(
  BuildContext context, {
  required String goodsId,
  required String goodsName,
  String quantity = '1',
  String? unitId,
  String? unitRate,
  String? orderId,
  String? orderItemId,
  String readContext = 'SALES',
  OrderDeliveryPlan? plan,
  bool readOnly = false,
  bool Function()? isCurrent,
  GlobalKey<UtenFloatingWindowState>? windowKey,
}) {
  final result = Completer<OrderDeliveryPlan?>();
  late OverlayEntry entry;
  void finish(OrderDeliveryPlan? value) {
    if (result.isCompleted) return;
    entry.remove();
    entry.dispose();
    result.complete(value);
  }

  entry = OverlayEntry(
    builder: (_) => Positioned.fill(
      child: _OrderDeliveryWindow(
        goodsId: goodsId,
        goodsName: goodsName,
        quantity: quantity,
        unitId: unitId,
        unitRate: unitRate,
        orderId: orderId,
        orderItemId: orderItemId,
        readContext: readContext,
        initial: plan,
        readOnly: readOnly,
        isCurrent: isCurrent,
        windowKey: windowKey,
        onClose: () => finish(null),
        onConfirm: (value) => finish(value),
      ),
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  return result.future;
}

class _DeliveryRow {
  const _DeliveryRow(
    this.node,
    this.depth,
    this.ancestors,
    this.last,
    this.covered, {
    this.filtered = false,
  });
  final OrderDeliveryBomNode node;
  final int depth;
  final List<bool> ancestors;
  final bool last, covered, filtered;

  _DeliveryRow forFilter() =>
      _DeliveryRow(node, depth, ancestors, last, covered, filtered: true);
}

class _OrderDeliveryWindow extends ConsumerStatefulWidget {
  const _OrderDeliveryWindow({
    required this.goodsId,
    required this.goodsName,
    required this.quantity,
    this.unitId,
    this.unitRate,
    this.orderId,
    this.orderItemId,
    this.readContext = 'SALES',
    required this.onClose,
    required this.onConfirm,
    this.initial,
    this.readOnly = false,
    this.isCurrent,
    this.windowKey,
  });
  final String goodsId, goodsName;
  final String quantity;
  final String? unitId, unitRate;
  final String? orderId, orderItemId;
  final String readContext;
  final OrderDeliveryPlan? initial;
  final bool readOnly;
  final bool Function()? isCurrent;
  final GlobalKey<UtenFloatingWindowState>? windowKey;
  final VoidCallback onClose;
  final ValueChanged<OrderDeliveryPlan> onConfirm;
  @override
  ConsumerState<_OrderDeliveryWindow> createState() =>
      _OrderDeliveryWindowState();
}

class _OrderDeliveryWindowState extends ConsumerState<_OrderDeliveryWindow> {
  late OrderDeliveryPlan _plan;
  late SensitiveReadBoundary _boundary;
  ProviderSubscription<SensitiveReadBoundary>? _subscription;
  final _collapsed = <String>{};
  OrderDeliveryBomNode? _root;
  bool _loading = true;
  bool _confirming = false;
  String? _error;
  int _generation = 0;
  Timer? _ownerGuard;
  bool get _current =>
      mounted &&
      ref.read(sensitiveReadBoundaryProvider) == _boundary &&
      (widget.isCurrent?.call() ?? true);
  bool get _editable =>
      !widget.readOnly &&
      _plan.supported &&
      !_loading &&
      !_confirming &&
      _error == null;

  @override
  void initState() {
    super.initState();
    _plan = widget.initial ?? OrderDeliveryPlan.assembled();
    _boundary = ref.read(sensitiveReadBoundaryProvider);
    _subscription = ref.listenManual(sensitiveReadBoundaryProvider, (_, next) {
      if (next != _boundary && mounted) widget.onClose();
    });
    _ownerGuard = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && !_current) widget.onClose();
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _ownerGuard?.cancel();
    _subscription?.close();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(orderDeliveryRepositoryProvider);
      if (widget.readOnly &&
          (widget.orderId == null || widget.orderItemId == null)) {
        setState(() {
          _loading = false;
          _error = '缺少订单明细读取上下文，不能用当前BOM替代历史结构';
        });
        return;
      }
      final bom = widget.readOnly
          ? await repository.frozenBom(
              orderId: widget.orderId!,
              itemId: widget.orderItemId!,
              context: widget.readContext,
            )
          : await repository.bom(widget.goodsId);
      if (!_current || generation != _generation) return;
      setState(() {
        _root = bom.root;
        if (widget.readOnly && bom.plan != null) _plan = bom.plan!;
        if (bom.missing || bom.root == null) {
          _error = bom.missingReason ?? '此记录未保留冻结BOM，不能按当前资料反推';
        }
        if (!widget.readOnly) {
          _plan = _plan.copyWith(bomFingerprint: bom.fingerprint);
        }
        _loading = false;
      });
    } catch (error) {
      if (!_current || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'BOM读取失败，请重试';
      });
    }
  }

  List<_DeliveryRow> _rows() {
    final result = <_DeliveryRow>[];
    void visit(
      OrderDeliveryBomNode node,
      int depth,
      List<bool> ancestors,
      bool last,
      bool covered,
    ) {
      result.add(_DeliveryRow(node, depth, ancestors, last, covered));
      final whole = depth == 0
          ? _plan.mode == 'ASSEMBLED'
          : _plan.modeAt(node.path) != 'CHILDREN';
      for (var i = 0; i < node.children.length; i++) {
        visit(
          node.children[i],
          depth + 1,
          [...ancestors, !last],
          i == node.children.length - 1,
          covered || whole,
        );
      }
    }

    if (_root != null) {
      visit(_root!, 0, const [], true, false);
      final present = _all(_root!).map((node) => node.key).toSet();
      final orphanKeys = <String>{};
      for (final entry in [..._plan.nodeModes, ..._plan.processes]) {
        final path = OrderDeliveryPlan.pathOf(entry);
        if (present.contains(OrderDeliveryPlan.pathKey(path)) ||
            !orphanKeys.add(OrderDeliveryPlan.pathKey(path))) {
          continue;
        }
        result.add(
          _DeliveryRow(
            OrderDeliveryBomNode.fromJson({
              'path': path,
              'goodsId': '',
              'code': path.join('/'),
              'name': '已保存路径不在当前BOM中',
              'childrenState': 'MISSING',
            }),
            0,
            const [],
            true,
            true,
          ),
        );
      }
    }
    return result;
  }

  List<_DeliveryRow> _unfilteredRows(List<_DeliveryRow> all) => all.where((
    row,
  ) {
    // Saved orphan settings remain visible even when the current root is folded.
    if (row.depth == 0) return true;
    for (var depth = 0; depth < row.node.path.length; depth++) {
      if (_collapsed.contains(
        OrderDeliveryPlan.pathKey(row.node.path.take(depth)),
      )) {
        return false;
      }
    }
    return true;
  }).toList();

  Iterable<OrderDeliveryBomNode> _all(OrderDeliveryBomNode node) sync* {
    yield node;
    for (final child in node.children) {
      yield* _all(child);
    }
  }

  Future<void> _confirm() async {
    if (!_editable || !_current || _root == null) return;
    final nodes = {for (final node in _all(_root!)) node.key: node};
    for (final entry in _plan.nodeModes.where(
      (entry) => entry['mode'] == 'CHILDREN',
    )) {
      final node =
          nodes[OrderDeliveryPlan.pathKey(OrderDeliveryPlan.pathOf(entry))];
      if (node == null || node.cannotSplit != null || node.children.isEmpty) {
        context.appWarning('交付路径已变化或下级未完整读取，请重新核对拆分选择');
        return;
      }
    }
    setState(() => _confirming = true);
    try {
      final preview = await ref
          .read(orderDeliveryRepositoryProvider)
          .preview(
            goodsId: widget.goodsId,
            quantity: widget.quantity,
            plan: _plan,
            unitId: widget.unitId,
            unitRate: widget.unitRate,
          );
      if (!mounted || !_current) return;
      final issues = preview['issues'] as List? ?? const [];
      if (issues.isNotEmpty) {
        context.appWarning(
          (issues.first as Map)['message']?.toString() ?? '交付规则需要重新核对',
        );
        return;
      }
      final confirmed = OrderDeliveryPlan.read(preview['deliveryPlan']);
      if (confirmed == null) {
        context.appWarning('未收到服务端确认的交付配置');
        return;
      }
      widget.onConfirm(confirmed);
    } catch (error) {
      if (mounted && _current) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return UtenFloatingWindow(
      key: widget.windowKey,
      title: widget.readOnly ? '交付方式(只读)' : '设置交付方式',
      initialSize: const Size(1060, 680),
      minSize: const Size(320, 300),
      onClose: _confirming ? () {} : widget.onClose,
      headerTrailing: const UtenFieldHintIcon(
        dense: true,
        info:
            '编辑读取最新权威BOM，查看使用该订单保存的冻结结构；缺少历史结构时明确显示缺失。查看下级不等于拆分交付，父件整件时不重复计料。最终数量及路径有效性由服务端确认。',
      ),
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 210,
                      child: UtenDropdownField(
                        label: '交付方式',
                        value: _plan.supported ? _plan.mode : null,
                        hintText: _plan.supported ? null : '交付配置待核对',
                        enabled: _editable,
                        items: [
                          const UtenDropdownItem(
                            value: 'ASSEMBLED',
                            label: '整装交付',
                          ),
                          UtenDropdownItem(
                            value: 'BOM',
                            label: '按BOM层级交付',
                            enabled:
                                _root?.cannotSplit == null &&
                                (_root?.children.isNotEmpty ?? false),
                          ),
                        ],
                        onChanged: (value) {
                          if (_editable && value != null) {
                            setState(() => _plan = _plan.copyWith(mode: value));
                          }
                        },
                      ),
                    ),
                    SizedBox(
                      width: 210,
                      child: UtenDropdownField(
                        label: '包装安排',
                        value: _plan.supported ? _plan.packaging : null,
                        hintText: _plan.supported ? null : '交付配置待核对',
                        enabled: _editable,
                        info: '包装方式不自动删除原BOM物料或附件；由服务端按本单交付规则核对。',
                        items: const [
                          UtenDropdownItem(value: 'ORIGINAL', label: '沿用原包装'),
                          UtenDropdownItem(value: 'BULK', label: '仓库整批打包'),
                          UtenDropdownItem(value: 'PENDING', label: '待确认'),
                        ],
                        onChanged: (value) {
                          if (_editable && value != null) {
                            setState(
                              () => _plan = _plan.copyWith(packaging: value),
                            );
                          }
                        },
                      ),
                    ),
                    UtenButton(
                      type: UtenButtonType.ghost,
                      onPressed: _loading
                          ? null
                          : () => setState(_collapsed.clear),
                      child: const Text('全部展开'),
                    ),
                    UtenButton(
                      type: UtenButtonType.ghost,
                      onPressed: _loading || _root == null
                          ? null
                          : () => setState(
                              () => _collapsed.addAll(
                                _all(_root!).map((node) => node.key),
                              ),
                            ),
                      child: const Text('全部收起'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _error != null && _root == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: UtenSpacing.s12),
                              UtenButton(
                                onPressed: _loading ? null : _load,
                                child: const Text('重新读取'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : MasterDataTableView<_DeliveryRow>(
                        tableKey: 'sales.order.delivery.bom',
                        primary: true,
                        items: rows,
                        facets: const {},
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                        unfilteredRows: _unfilteredRows,
                        filterContextRows: (all, matched) {
                          final keys = <String>{};
                          for (final row in matched) {
                            for (
                              var depth = 0;
                              depth <= row.node.path.length;
                              depth++
                            ) {
                              keys.add(
                                OrderDeliveryPlan.pathKey(
                                  row.node.path.take(depth),
                                ),
                              );
                            }
                          }
                          return all
                              .where((row) => keys.contains(row.node.key))
                              .map((row) => row.forFilter())
                              .toList();
                        },
                        idOf: (row) => row.node.key,
                        showPaginationControls: false,
                        error: _error,
                        onRetry: () => unawaited(_load()),
                        emptyMessage: _loading ? '正在读取BOM' : '尚未维护BOM，可保持整装交付',
                        columns: [
                          MasterColumnDef<_DeliveryRow>(
                            key: 'name',
                            label: '组件名称',
                            width: 340,
                            value: (row) => row.node.name,
                            filterFromRows: true,
                            fillsCellHeight: true,
                            cellBuilderHandlesSemantics: true,
                            cellBuilder: (_, row) => UtenTreeTableCell.compact(
                              title: row.node.name,
                              depth: row.depth,
                              hasChildren: row.node.hasChildren,
                              expanded:
                                  row.filtered ||
                                  !_collapsed.contains(row.node.key),
                              dotted: true,
                              ancestorContinuations: row.ancestors,
                              isLastChild: row.last,
                              onToggle: row.node.hasChildren && !row.filtered
                                  ? () => setState(() {
                                      _collapsed.contains(row.node.key)
                                          ? _collapsed.remove(row.node.key)
                                          : _collapsed.add(row.node.key);
                                    })
                                  : null,
                            ),
                          ),
                          MasterColumnDef<_DeliveryRow>(
                            key: 'code',
                            label: '编号',
                            width: 130,
                            value: (row) => row.node.code,
                            filterFromRows: true,
                          ),
                          MasterColumnDef<_DeliveryRow>(
                            key: 'usage',
                            label: '设计使用数量',
                            width: 130,
                            info:
                                '保留原BOM设计用量及计量方式；按包装和固定批耗不能当作线性单耗。生产损耗和学习耗用不等于客户交付数量。',
                            value: (row) =>
                                '${row.node.qtyExact ?? '—'} ${row.node.unitName ?? ''}',
                            filterFromRows: true,
                          ),
                          MasterColumnDef<_DeliveryRow>(
                            key: 'basis',
                            label: '计量方式',
                            width: 160,
                            value: (row) => switch (row.node.consumptionBasis) {
                              'PER_UNIT' => '按每件',
                              'PER_PACKAGE' =>
                                '按包装 / 基准${row.node.basisOutputQtyExact ?? '待核对'}',
                              'FIXED_BATCH' => '固定批耗',
                              _ => row.depth == 0 ? '根产品' : '待核对',
                            },
                            filterFromRows: true,
                          ),
                          MasterColumnDef<_DeliveryRow>(
                            key: 'delivery',
                            label: '本单交付层级',
                            width: 220,
                            info: '已覆盖的下级只供查看，不重复计数。无完整下级不能选择按下级交付。',
                            value: (row) =>
                                row.node.cannotSplit ??
                                (row.covered
                                    ? '随上层整件'
                                    : row.depth == 0
                                    ? _plan.label
                                    : _plan.modeAt(row.node.path) == 'CHILDREN'
                                    ? '按下级交付'
                                    : '整件交付'),
                            filterFromRows: true,
                            cellBuilder: (_, row) =>
                                row.node.goodsId.isEmpty && !widget.readOnly
                                ? UtenButton(
                                    type: UtenButtonType.ghost,
                                    onPressed: !_editable
                                        ? null
                                        : () => setState(() {
                                            _plan = _plan.copyWith(
                                              nodeModes: _plan.nodeModes
                                                  .where(
                                                    (entry) =>
                                                        OrderDeliveryPlan.pathKey(
                                                          OrderDeliveryPlan.pathOf(
                                                            entry,
                                                          ),
                                                        ) !=
                                                        row.node.key,
                                                  )
                                                  .toList(),
                                              processes: _plan.processes
                                                  .where(
                                                    (entry) =>
                                                        OrderDeliveryPlan.pathKey(
                                                          OrderDeliveryPlan.pathOf(
                                                            entry,
                                                          ),
                                                        ) !=
                                                        row.node.key,
                                                  )
                                                  .toList(),
                                            );
                                          }),
                                    child: const Text('移除失效设置'),
                                  )
                                : row.node.cannotSplit != null
                                ? Text(row.node.cannotSplit!)
                                : row.depth == 0 || !row.node.hasChildren
                                ? Text(
                                    row.covered
                                        ? '随上层整件'
                                        : row.depth == 0
                                        ? _plan.label
                                        : '整件交付',
                                  )
                                : Row(
                                    children: [
                                      Checkbox(
                                        key: ValueKey(
                                          'delivery-split-${row.node.key}',
                                        ),
                                        value:
                                            _plan.modeAt(row.node.path) ==
                                            'CHILDREN',
                                        onChanged:
                                            !_editable ||
                                                row.covered ||
                                                _plan.mode == 'ASSEMBLED' ||
                                                row.node.children.isEmpty
                                            ? null
                                            : (value) => setState(
                                                () => _plan = _plan.setNode(
                                                  row.node.path,
                                                  value == true
                                                      ? 'CHILDREN'
                                                      : 'WHOLE',
                                                ),
                                              ),
                                      ),
                                      Flexible(
                                        child: Text(
                                          row.covered ? '随上层整件' : '按下级交付',
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                          MasterColumnDef<_DeliveryRow>(
                            key: 'process',
                            label: '本单激光要求',
                            width: 150,
                            info: '本单新增的工艺要求，不能代替或取消货品原有工艺。取消组装不取消已确认的加工要求。',
                            value: (row) =>
                                _plan.laserAt(row.node.path) ||
                                    row.node.requiredOperations.contains(
                                      'LASER',
                                    )
                                ? '需要激光打印'
                                : '未追加',
                            filterFromRows: true,
                            cellBuilder: (_, row) => Checkbox(
                              key: ValueKey('delivery-laser-${row.node.key}'),
                              value:
                                  _plan.laserAt(row.node.path) ||
                                  row.node.requiredOperations.contains('LASER'),
                              onChanged:
                                  !_editable ||
                                      row.node.requiredOperations.contains(
                                        'LASER',
                                      )
                                  ? null
                                  : (value) => setState(
                                      () => _plan = _plan.setLaser(
                                        row.node.path,
                                        value == true,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
          if (_loading || _confirming)
            UtenBusyOverlay(
              title: _confirming ? '正在核对交付配置' : '正在读取交付BOM',
              showDoNotLeaveHint: false,
            ),
        ],
      ),
      actions: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _confirming ? null : widget.onClose,
              child: Text(widget.readOnly ? '关闭' : '取消'),
            ),
            if (!widget.readOnly) ...[
              const SizedBox(width: UtenSpacing.s8),
              UtenButton(
                onPressed: _editable ? _confirm : null,
                child: const Text('确认'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shared order/production cell. Each caller retains its own immutable order-line plan.
class OrderDeliveryPlanCell extends StatefulWidget {
  const OrderDeliveryPlanCell({
    super.key,
    required this.plan,
    this.goodsId,
    this.goodsName = '货品',
    this.quantity = '1',
    this.unitId,
    this.unitRate,
    this.orderId,
    this.orderItemId,
    this.readContext = 'SALES',
    this.readOnly = true,
    this.onChanged,
    this.isCurrent,
    this.sessionKey,
    this.onOpenChanged,
  });
  final OrderDeliveryPlan? plan;
  final String? goodsId, unitId, unitRate;
  final String? orderId, orderItemId;
  final String readContext;
  final String goodsName, quantity;
  final bool readOnly;
  final ValueChanged<OrderDeliveryPlan>? onChanged;
  final bool Function()? isCurrent;
  final Object? sessionKey;
  final ValueChanged<bool>? onOpenChanged;
  @override
  State<OrderDeliveryPlanCell> createState() => _OrderDeliveryPlanCellState();
}

class _OrderDeliveryPlanCellState extends State<OrderDeliveryPlanCell> {
  bool _opening = false;
  final _windowKey = GlobalKey<UtenFloatingWindowState>();
  Future<void> _open() async {
    if (_opening) {
      _windowKey.currentState?.expand();
      return;
    }
    final goodsId = widget.goodsId;
    final hasReadScope =
        widget.readOnly && widget.orderId != null && widget.orderItemId != null;
    if (goodsId?.isNotEmpty != true && !hasReadScope) return;
    final quantity = widget.quantity;
    final unitId = widget.unitId;
    final unitRate = widget.unitRate;
    final ownerCurrent = widget.isCurrent;
    final onChanged = widget.onChanged;
    final ownerRoute = ModalRoute.of(context);
    bool current() =>
        (ownerRoute?.isCurrent ?? true) &&
        (ownerCurrent?.call() ??
            (mounted &&
                widget.goodsId == goodsId &&
                widget.quantity == quantity &&
                widget.unitId == unitId &&
                widget.unitRate == unitRate));
    _opening = true;
    var announcedOpen = false;
    try {
      final sessionIdentity = widget.sessionKey;
      final existing = sessionIdentity == null
          ? null
          : _deliveryWindowSessions[sessionIdentity];
      if (existing != null) {
        existing.key.currentState?.expand();
        return;
      }
      widget.onOpenChanged?.call(true);
      announcedOpen = true;
      final pending = showOrderDeliveryWindow(
        context,
        goodsId: goodsId ?? '',
        goodsName: widget.goodsName,
        quantity: quantity,
        unitId: unitId,
        unitRate: unitRate,
        orderId: widget.orderId,
        orderItemId: widget.orderItemId,
        readContext: widget.readContext,
        plan: widget.plan,
        readOnly: widget.readOnly,
        isCurrent: current,
        windowKey: _windowKey,
      );
      if (sessionIdentity != null) {
        _deliveryWindowSessions[sessionIdentity] = (
          key: _windowKey,
          result: pending,
        );
      }
      final updated = await pending;
      if (sessionIdentity != null &&
          identical(
            _deliveryWindowSessions[sessionIdentity]?.result,
            pending,
          )) {
        _deliveryWindowSessions.remove(sessionIdentity);
      }
      if (updated != null && current()) onChanged?.call(updated);
    } finally {
      if (announcedOpen) widget.onOpenChanged?.call(false);
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed:
        widget.goodsId?.isNotEmpty == true ||
            widget.readOnly &&
                widget.orderId != null &&
                widget.orderItemId != null
        ? _open
        : null,
    child: Text(orderDeliveryLabel(widget.plan)),
  );
}

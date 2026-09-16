// 销售订货单「排产进度」面板——销售端看业务链另一端。
//
// 数据源 GET /sales/orders/{id}/plan-progress：每行 订货/可发/已排/已产/已发 + 链路状态
// + 关联生产计划溯源（plan_order_item_links；含合并排产预建的草稿计划，标「草稿」）。
// 有计划查看权限（production_plan:view）时点计划单号/执行子计划可跳生产计划详情。
//
// 2026-08-19 起由模态底表改为内嵌面板（SalesPlanProgressPanel），
// 在「订单进度详情页」中作为产品进度区使用（弹窗已下线，见该页文档）。
//
// 2026-09-12 交互改版（与全站批量页统一口径）：
// - 行单击只切换勾选，不再弹进度弹窗——弹窗只由「查看进度」列按钮触发；
// - 宿主传入 [SalesShipmentActionScope] 时进入统一悬浮模式：面板内不再渲染
//   「全选可发产品/去发货/刷新」工具条与说明文字，勾选数与去发货动作经 scope
//   交给宿主页渲染到右下 UtenFloatingActionGroup（订单进度详情页）；不传 scope
//   的旧宿主（销售订货单详情页）继续用面板自带工具条，行为不变。
// 2026-09-13 面板不再提供「本次发货数量」输入列：只展示「本次可发」，去发货
//   按可发量预填跳转出货页，实际发货数量在出货单明细里填写（出货页终校验 ≤可发）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/progress_ratio.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';
import '../providers/sales_completion_count_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

/// 宿主与产品进度面板「去发货」动作的桥（统一悬浮口径，2026-09-12）。
///
/// 宿主（订单进度详情页）创建并传入面板；面板在可发货态/勾选数/忙碌态变化时
/// 更新字段并通知监听，宿主用 [ListenableBuilder] 据此重建右下
/// UtenFloatingActionGroup（「已选 N 项」胶囊 + 红色「去发货(N)」大按钮）。
/// 按钮点击分别回调 [createShipment] / [clearSelection]，由面板完成数量校验、
/// 出货页跳转与选择清理；[reload] 供宿主右上角整页刷新联动本面板。
///
/// 字段更新可能发生在 FutureBuilder 的 build 期间，通知统一推迟到帧末
/// （postFrameCallback），避免 ListenableBuilder 在 build 期收到通知。
class SalesShipmentActionScope extends ChangeNotifier {
  /// 是否展示「去发货」动作（可发货 + 有出货权限 + 面板可用）。
  bool shippingEnabled = false;

  /// 当前勾选的可发产品数（悬浮按钮文案与就绪态）。
  int selectedCount = 0;

  /// 面板忙碌（正在跳转出货页），期间禁用动作。
  bool busy = false;

  Future<bool> Function()? _onCreateShipment;
  VoidCallback? _onClearSelection;
  Future<void> Function()? _onReload;

  /// 面板绑定动作实现（面板 initState/didUpdateWidget 调用；dispose 时解绑）。
  void _bind({
    required Future<bool> Function() onCreateShipment,
    required VoidCallback onClearSelection,
    required Future<void> Function() onReload,
  }) {
    _onCreateShipment = onCreateShipment;
    _onClearSelection = onClearSelection;
    _onReload = onReload;
  }

  void _unbind() {
    _onCreateShipment = null;
    _onClearSelection = null;
    _onReload = null;
    shippingEnabled = false;
    selectedCount = 0;
    busy = false;
    _scheduleNotify();
  }

  /// 校验所选行「本次发货数量」并跳转新建出货页；返回是否已发起跳转。
  Future<bool> createShipment() async =>
      await (_onCreateShipment?.call() ?? Future<bool>.value(false));

  /// 清空勾选（悬浮组「已选 N 项」胶囊的清除动作）。
  void clearSelection() => _onClearSelection?.call();

  /// 重读产品进度（宿主整页刷新联动）。
  Future<void> reload() async =>
      await (_onReload?.call() ?? Future<void>.value());

  bool _notifyScheduled = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 帧末通知监听（面板可能在 build 期间同步字段，通知不能落在 build 期）。
  /// 仅限本库内面板调用；notifyListeners 只在 scope 自身实例成员里触发。
  /// 宿主页可能在帧末回调前 dispose 本 scope（如测试卸载），已 disposed 直接跳过。
  void _scheduleNotify() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }
}

/// 按单排产进度面板（内嵌整页使用；自带加载/错误/空态）。
class SalesPlanProgressPanel extends ConsumerStatefulWidget {
  const SalesPlanProgressPanel({
    super.key,
    required this.orderId,
    this.canShip = false,
    this.onChanged,
    this.shipmentActions,
  });

  final String orderId;
  final bool canShip;
  final Future<void> Function()? onChanged;

  /// 统一悬浮模式桥：非空时面板不渲染自带工具条，「去发货」交宿主右下悬浮组
  /// （见 [SalesShipmentActionScope]）；null = 旧宿主自带工具条模式。
  final SalesShipmentActionScope? shipmentActions;

  @override
  ConsumerState<SalesPlanProgressPanel> createState() =>
      _SalesPlanProgressPanelState();
}

class _SalesPlanProgressPanelState
    extends ConsumerState<SalesPlanProgressPanel> {
  late Future<List<OrderPlanProgressLine>> _future;
  final _selected = <String>{};
  List<OrderPlanProgressLine>? _lines;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    _future = _read();
    widget.shipmentActions?._bind(
      onCreateShipment: _createShipment,
      onClearSelection: _clearSelection,
      onReload: _refresh,
    );
    _syncScope();
  }

  @override
  void didUpdateWidget(covariant SalesPlanProgressPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orderId != widget.orderId) {
      _selected.clear();
      _future = _read();
    }
    if (oldWidget.shipmentActions != widget.shipmentActions) {
      oldWidget.shipmentActions?._unbind();
      widget.shipmentActions?._bind(
        onCreateShipment: _createShipment,
        onClearSelection: _clearSelection,
        onReload: _refresh,
      );
    }
    _syncScope();
  }

  @override
  void dispose() {
    widget.shipmentActions?._unbind();
    super.dispose();
  }

  Future<List<OrderPlanProgressLine>> _read() => ref
      .read(salesRepositoryProvider(SalesDocType.order))
      .planProgress(widget.orderId);

  Future<void> _refresh() async {
    setState(() {
      _selected.clear();
      _future = _read();
    });
    _syncScope();
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(() => _selected.clear());
    _syncScope();
  }

  bool get _canShipEffective {
    if (!widget.canShip) return false;
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        (permissions.contains(Perm.salesShipmentView) &&
            permissions.contains(Perm.salesShipmentCreate));
  }

  /// 把可发货态/勾选数/忙碌态同步到悬浮桥（有 scope 时）。
  /// build 期间调用须传 [shippingEnabled]（用 build 里已 watch 的值，避免
  /// build 期 ref.read）；通知推迟到帧末，避免监听方在 build 期重建。
  void _syncScope({bool? shippingEnabled}) {
    final scope = widget.shipmentActions;
    if (scope == null) return;
    final enabled = shippingEnabled ?? _canShipEffective;
    var changed = false;
    if (scope.shippingEnabled != enabled) {
      scope.shippingEnabled = enabled;
      changed = true;
    }
    if (scope.selectedCount != _selected.length) {
      scope.selectedCount = _selected.length;
      changed = true;
    }
    if (scope.busy != _navigating) {
      scope.busy = _navigating;
      changed = true;
    }
    if (changed) {
      widget.shipmentActions?._scheduleNotify();
    }
  }

  /// 按所选行的「本次可发」预填并跳转新建出货页（实际发货数量在出货单明细里
  /// 填写，出货页仍做 ≤可发 终校验）。返回 true=已发起跳转。
  Future<bool> _createShipment() async {
    if (_navigating || !_canShipEffective || _selected.isEmpty) return false;
    final lines = _lines;
    if (lines == null) return false;
    final selected =
        lines.where((line) => _selected.contains(line.orderItemId)).toList()
          ..sort((a, b) => a.orderItemId.compareTo(b.orderItemId));
    final entries = <String>[];
    for (final line in selected) {
      final available = line.shippableQty ?? 0;
      if (available <= 0) continue;
      entries.add('${line.orderItemId}:${_fmt(available)}');
    }
    if (entries.isEmpty) {
      context.appWarning('请先勾选本次可发数量大于 0 的产品');
      return false;
    }
    setState(() => _navigating = true);
    _syncScope();
    try {
      await context.push(
        Uri(
          path: '/sales/shipments/new',
          queryParameters: {
            'sourceOrderId': widget.orderId,
            'orderItems': entries.join(','),
          },
        ).toString(),
      );
      if (!mounted) return true;
      _refresh();
      ref.invalidate(salesAttentionCountProvider);
      await widget.onChanged?.call();
      return true;
    } finally {
      if (mounted) {
        setState(() => _navigating = false);
        _syncScope();
      }
    }
  }

  /// 旧宿主自带工具条的「去发货」：与悬浮模式同一条跳转路径。
  Future<void> _openShipment() async {
    await _createShipment();
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final canShip =
        widget.canShip &&
        (ref.watch(isSuperAdminProvider) ||
            (permissions.contains(Perm.salesShipmentView) &&
                permissions.contains(Perm.salesShipmentCreate)));
    return FutureBuilder<List<OrderPlanProgressLine>>(
      future: _future,
      builder: (_, snap) {
        if (snap.hasError) {
          return UtenEmpty(
            message: '产品进度加载失败',
            actionLabel: '重新加载',
            onAction: _refresh,
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final lines = snap.data!;
        _lines = lines;
        _syncScope(shippingEnabled: canShip);
        return _ProgressList(
          lines: lines,
          canShip: canShip,
          unifiedFloating: widget.shipmentActions != null,
          selected: _selected,
          busy: _navigating || snap.connectionState == ConnectionState.waiting,
          onRefresh: _refresh,
          onCreate: _openShipment,
          onSelected: (ids) {
            setState(() {
              _selected
                ..clear()
                ..addAll(ids);
            });
            _syncScope();
          },
        );
      },
    );
  }
}

/// 数量展示统一：整数不带小数位，小数保留两位。
String _fmt(double? v) => v == null
    ? '—'
    : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

class _ProgressList extends ConsumerWidget {
  const _ProgressList({
    required this.lines,
    required this.canShip,
    required this.selected,
    required this.busy,
    required this.onSelected,
    required this.onCreate,
    required this.onRefresh,
    required this.unifiedFloating,
  });

  final List<OrderPlanProgressLine> lines;
  final bool canShip;
  final bool busy;
  final Set<String> selected;
  final ValueChanged<Set<String>> onSelected;
  final VoidCallback onCreate;
  final VoidCallback onRefresh;

  /// 统一悬浮模式：不渲染面板工具条与说明文字（去发货在宿主右下悬浮组）。
  final bool unifiedFloating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canViewPlan =
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.productionPlanView) ||
        ref.watch(isSuperAdminProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!unifiedFloating) ...[
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (canShip)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      key: const Key('sales-progress-select-all'),
                      value:
                          selected.isNotEmpty &&
                          selected.length ==
                              lines
                                  .where((line) => (line.shippableQty ?? 0) > 0)
                                  .length,
                      onChanged: busy
                          ? null
                          : (value) => onSelected(
                              value == true
                                  ? lines
                                        .where(
                                          (line) =>
                                              (line.shippableQty ?? 0) > 0,
                                        )
                                        .map((line) => line.orderItemId)
                                        .toSet()
                                  : <String>{},
                            ),
                    ),
                    Text('全选可发产品 · 已选 ${selected.length} 项'),
                  ],
                ),
              if (canShip)
                UtenButton(
                  key: const Key('sales-progress-create-shipment'),
                  type: UtenButtonType.danger,
                  icon: Icons.local_shipping_outlined,
                  onPressed: busy || selected.isEmpty ? null : onCreate,
                  child: const Text('去发货'),
                ),
              TextButton.icon(
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新产品进度'),
              ),
            ],
          ),
          Text(
            '已产按合格入库计算，可发量已扣除正在办理的出货。勾选产品后点「去发货」，本次发货数量在出货单中填写，保存后仍由财务放行。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        if (lines.isEmpty)
          const Padding(
            padding: EdgeInsets.all(UtenSpacing.s24),
            child: Center(child: Text('(无明细)')),
          ),
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 900
              ? _table(context, theme, canViewPlan)
              : Column(
                  children: [
                    for (final line in lines)
                      _lineCard(context, theme, line, canViewPlan),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _table(BuildContext context, ThemeData theme, bool canViewPlan) =>
      MasterDataTableView<OrderPlanProgressLine>(
        key: const Key('sales-product-progress-table'),
        embedded: true,
        columns: [
          MasterColumnDef(
            key: 'product',
            // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
            label: '产品名称',
            width: 190,
            value: (line) => line.goodsName ?? line.goodsCode ?? '—',
          ),
          MasterColumnDef(
            key: 'goodsCode',
            label: '编号',
            width: 130,
            value: (line) => UtenGoodsAttributeCell.text(line.goodsCode),
            cellBuilder: (_, line) => UtenGoodsAttributeCell(line.goodsCode),
          ),
          MasterColumnDef(
            key: 'colorName',
            label: '颜色',
            width: 96,
            value: (line) => UtenGoodsAttributeCell.text(line.colorName),
            cellBuilder: (_, line) => UtenGoodsAttributeCell(line.colorName),
          ),
          MasterColumnDef(
            key: 'spec',
            label: '规格',
            width: 120,
            value: (line) => UtenGoodsAttributeCell.text(line.spec),
            cellBuilder: (_, line) => UtenGoodsAttributeCell(line.spec),
          ),
          MasterColumnDef(
            key: 'unit',
            label: '单位',
            width: 65,
            value: (line) => line.unitName,
          ),
          MasterColumnDef(
            key: 'qty',
            label: '订货',
            width: 90,
            type: 'number',
            value: (line) => _fmt(line.qty),
          ),
          MasterColumnDef(
            key: 'planned',
            label: '已排',
            width: 90,
            type: 'number',
            value: (line) => _fmt(line.plannedQty),
          ),
          MasterColumnDef(
            key: 'produced',
            label: '已生产入库',
            width: 120,
            type: 'number',
            info: '只统计已实际合格入库的产品，待品质判定和待仓库点收不算入库。',
            value: (line) => _fmt(line.producedQty),
          ),
          MasterColumnDef(
            key: 'shipped',
            label: '已发',
            width: 90,
            type: 'number',
            value: (line) => _fmt(line.shippedQty),
          ),
          MasterColumnDef(
            key: 'available',
            label: '本次可发',
            width: 110,
            type: 'number',
            info: '可用于新建出货单的合格实物量，已扣除正在办理的出货；实际发货数量在出货单中填写。',
            value: (line) => _fmt(line.shippableQty),
            cellBuilder: (context, line) => Text(
              _fmt(line.shippableQty),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.error,
              ),
            ),
          ),
          MasterColumnDef(
            key: 'pending',
            label: '办理中',
            width: 100,
            type: 'number',
            value: (line) => _fmt(line.pendingShipmentQty),
          ),
          MasterColumnDef(
            key: 'progress',
            label: '生产入库进度',
            width: 160,
            value: (line) => '${_fmt(line.producedQty)} / ${_fmt(line.qty)}',
            cellBuilder: (context, line) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${_fmt(line.producedQty)} / ${_fmt(line.qty)}'),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: (line.qty ?? 0) > 0
                      ? ((line.producedQty ?? 0) / line.qty!).clamp(0, 1)
                      : 0,
                ),
              ],
            ),
          ),
          MasterColumnDef(
            key: 'detail',
            label: '进度来源',
            width: 110,
            value: (_) => '查看进度',
            cellBuilder: (context, line) => TextButton(
              onPressed: busy
                  ? null
                  : () => _showLineProgress(context, theme, line, canViewPlan),
              child: const Text('查看进度'),
            ),
          ),
        ],
        items: lines,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        selectable: canShip,
        selectedIds: selected,
        idOf: (line) => (line.shippableQty ?? 0) > 0 ? line.orderItemId : null,
        rowKeyOf: (line) => line.orderItemId,
        // 单击行只切换勾选（embedded+selectable 语义），进度弹窗只由
        // 「查看进度」列按钮触发——2026-09-12 反馈「单击选中别弹窗」。
        onSelectedIdsChanged: busy ? null : onSelected,
        showSelectionSummary: false,
      );

  Future<void> _showLineProgress(
    BuildContext context,
    ThemeData theme,
    OrderPlanProgressLine line,
    bool canViewPlan,
  ) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('${line.goodsName ?? line.goodsCode ?? '产品'} · 进度来源'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: _lineCard(
            dialogContext,
            theme,
            line,
            canViewPlan,
            showSelection: false,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _lineCard(
    BuildContext context,
    ThemeData theme,
    OrderPlanProgressLine l,
    bool canViewPlan, {
    bool showSelection = true,
  }) {
    final chainColor = chainStatusColor(l.chainStatus, theme);
    return Card(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (canShip && showSelection)
                  Checkbox(
                    key: ValueKey('sales-progress-select-${l.orderItemId}'),
                    value: selected.contains(l.orderItemId),
                    onChanged: busy || (l.shippableQty ?? 0) <= 0
                        ? null
                        : (checked) {
                            final next = Set<String>.of(selected);
                            if (checked == true) {
                              next.add(l.orderItemId);
                            } else {
                              next.remove(l.orderItemId);
                            }
                            onSelected(next);
                          },
                  ),
                Expanded(
                  child: Text(
                    '${l.goodsName ?? l.goodsCode ?? '—'}'
                    '${l.spec != null && l.spec!.isNotEmpty ? ' · ${l.spec}' : ''}'
                    '${l.colorName != null ? ' · ${l.colorName}' : ''}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: chainColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    chainStatusLabel(
                      l.chainStatus,
                      plannedQty: l.plannedQty,
                      qty: l.qty,
                    ),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: chainColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              children: [
                _num(theme, '订货', l.qty),
                _num(theme, '本次可发', l.shippableQty, highlight: true),
                _num(theme, '办理中', l.pendingShipmentQty),
                _num(theme, '已排', l.plannedQty, highlight: true),
                // V545：剩余未排量（服务端派生）——部分排产时销售一眼看到还差多少没排。
                _num(theme, '未排', l.unplannedQty),
                _num(theme, '已产', l.producedQty, highlight: true),
                _num(theme, '已发', l.shippedQty),
                _num(theme, '剩余', _remaining(l.qty, l.shippedQty)),
              ],
            ),
            if (canShip && showSelection && (l.shippableQty ?? 0) > 0) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '发货数量在「去发货」打开的出货单中填写',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s8),
            _progress(theme, '生产入库', l.producedQty ?? 0, l.qty ?? 0),
            const SizedBox(height: UtenSpacing.s4),
            _progress(theme, '已发客户', l.shippedQty ?? 0, l.qty ?? 0),
            const SizedBox(height: UtenSpacing.s8),
            _materialAnalysisProgress(theme, l),
            if (l.links.isNotEmpty) ...[
              const Divider(height: UtenSpacing.s16),
              for (final p in l.links) _planRow(context, theme, p, canViewPlan),
            ] else ...[
              const Divider(height: UtenSpacing.s16),
              Text(
                (l.submittedPlanQty ?? 0) > (l.approvedPlannedQty ?? 0)
                    ? '生产计划已提交待批准，批准后在此显示下达计划'
                    : l.materialAnalysisId != null ||
                          l.materialAnalysisStatus != null
                    ? '已进入物料分析，尚未生成生产计划'
                    : '待物料分析',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _progress(
    ThemeData theme,
    String label,
    double quantity,
    double total,
  ) => Row(
    children: [
      SizedBox(width: 76, child: Text(label, style: theme.textTheme.bodySmall)),
      Expanded(
        child: LinearProgressIndicator(
          value: total > 0 ? (quantity / total).clamp(0, 1) : 0,
        ),
      ),
      const SizedBox(width: UtenSpacing.s8),
      Text(
        '${_fmt(quantity)} / ${_fmt(total)}',
        style: theme.textTheme.bodySmall,
      ),
    ],
  );

  Widget _materialAnalysisProgress(
    ThemeData theme,
    OrderPlanProgressLine line,
  ) {
    final submitted = line.submittedPlanQty ?? 0;
    final approved = line.approvedPlannedQty ?? line.plannedQty ?? 0;
    final hasAnalysis =
        line.materialAnalysisId != null ||
        line.materialAnalysisStatus != null ||
        line.analyzedQty != null ||
        line.readyNowQty != null ||
        line.readyByDateQty != null ||
        line.readinessRatio != null ||
        line.submittedPlanQty != null ||
        line.materialAnalyzedAt != null;
    final (label, icon, color) = submitted > approved
        ? ('已提交待批准', Icons.approval_outlined, theme.colorScheme.tertiary)
        : approved > 0
        ? ('已批准下达', Icons.verified_outlined, theme.colorScheme.primary)
        : !hasAnalysis
        ? (
            '待分析',
            Icons.pending_actions_outlined,
            theme.colorScheme.onSurfaceVariant,
          )
        : switch (line.materialAnalysisStatus?.toUpperCase()) {
            'READY' || 'CONFIRMED' => (
              '已齐套，待生成计划',
              Icons.inventory_2_outlined,
              theme.colorScheme.primary,
            ),
            'STALE' => (
              '分析已过期，待刷新',
              Icons.sync_problem_outlined,
              theme.colorScheme.error,
            ),
            _ => (
              '备料中',
              Icons.hourglass_bottom_outlined,
              theme.colorScheme.secondary,
            ),
          };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(UtenRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: UtenSpacing.s4),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (hasAnalysis)
            Text(
              '分析 ${_fmt(line.analyzedQty)} · '
              '当前可生产 ${_fmt(line.readyNowQty)} · '
              '预计可生产 ${_fmt(line.readyByDateQty)} · '
              '齐套 ${_ratio(line.readinessRatio)} · '
              '已提交 ${_fmt(line.submittedPlanQty)} · '
              '已批准 ${_fmt(line.approvedPlannedQty ?? line.plannedQty)}',
              style: theme.textTheme.bodySmall,
            ),
          if (line.materialAnalyzedAt != null)
            Text(
              '最后分析 ${_dateTime(line.materialAnalyzedAt!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  String _dateTime(String value) =>
      value.replaceFirst('T', ' ').split('.').first;

  String _ratio(double? value) {
    if (value == null) return '—';
    final normalized = normalizeProgressRatio(value);
    return '${(normalized.clamp(0, 1) * 100).toStringAsFixed(0)}%';
  }

  Widget _planRow(
    BuildContext context,
    ThemeData theme,
    OrderPlanLink p,
    bool canViewPlan,
  ) {
    final statusText = p.planStatus == 0
        ? '草稿'
        : p.planStatus == 1
        ? (p.planClosed ? '已审·已结案' : '已审核')
        : '红冲';
    final statusColor = p.planStatus == 0
        ? theme.colorScheme.onSurfaceVariant
        : p.planStatus == 1
        ? Colors.green
        : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => _openProductionPlan(
                    context,
                    planId: p.planId,
                    canViewPlan: canViewPlan,
                  ),
                  child: Text(
                    p.planNo ?? '—',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: canViewPlan ? theme.colorScheme.primary : null,
                      decoration: canViewPlan ? TextDecoration.underline : null,
                    ),
                  ),
                ),
              ),
              Text(
                statusText,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Text(
                '排 ${_fmt(p.allocatedQty)} · 产 ${_fmt(p.producedQty)} · 入 ${_fmt(p.inboundQty)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          for (final segment in p.executionSegments)
            _executionSegmentRow(
              context,
              theme,
              segment,
              planId: p.planId,
              canViewPlan: canViewPlan,
            ),
        ],
      ),
    );
  }

  Widget _executionSegmentRow(
    BuildContext context,
    ThemeData theme,
    OrderExecutionSegmentProgress segment, {
    required String planId,
    required bool canViewPlan,
  }) {
    final statusLabel = switch (segment.status) {
      'READY' => '备料中',
      'WAITING' => '待料',
      'DISPATCHED' => '历史工单备料中',
      'IN_PROGRESS' => '生产中',
      'COMPLETED' => '已完成',
      'CANCELLED' => '已取消',
      'REVERSED' => '已红冲',
      _ => segment.status ?? '未知状态',
    };
    final statusColor = switch (segment.status) {
      'COMPLETED' => theme.colorScheme.primary,
      'WAITING' => theme.colorScheme.tertiary,
      'CANCELLED' || 'REVERSED' => theme.colorScheme.error,
      _ => theme.colorScheme.secondary,
    };
    final assignment = [
      segment.workshopName,
      segment.teamName,
    ].where((value) => value?.isNotEmpty == true).join(' · ');
    final dates = [
      segment.planBeginDate,
      segment.planEndDate,
    ].where((value) => value?.isNotEmpty == true).join(' → ');

    return Semantics(
      button: true,
      enabled: canViewPlan,
      label:
          '${segment.segmentCode ?? '执行子计划'}，$statusLabel，'
          '分摊 ${_fmt(segment.allocatedQty)}，'
          '报工 ${_fmt(segment.reportedQty)}，'
          '入库 ${_fmt(segment.inboundQty)}',
      child: Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: InkWell(
          borderRadius: BorderRadius.circular(UtenRadius.sm),
          onTap: () => _openProductionPlan(
            context,
            planId: planId,
            canViewPlan: canViewPlan,
            executionSegmentId: segment.executionSegmentId,
          ),
          child: Container(
            padding: const EdgeInsets.all(UtenSpacing.s8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(UtenRadius.sm),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        segment.segmentCode ?? '执行子计划',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      statusLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Icon(
                      canViewPlan
                          ? Icons.chevron_right_rounded
                          : Icons.lock_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '分摊 ${_fmt(segment.allocatedQty)} · '
                  '报工 ${_fmt(segment.reportedQty)} · '
                  '入库 ${_fmt(segment.inboundQty)}',
                  style: theme.textTheme.bodySmall,
                ),
                if (assignment.isNotEmpty || dates.isNotEmpty)
                  Text(
                    [
                      assignment,
                      dates,
                    ].where((value) => value.isNotEmpty).join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (segment.delayed)
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Expanded(
                        child: Text(
                          segment.delayReason ?? '已超过计划完工日期',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openProductionPlan(
    BuildContext context, {
    required String planId,
    required bool canViewPlan,
    String? executionSegmentId,
  }) async {
    if (!canViewPlan) {
      context.appWarning('当前账号没有生产计划查看权限', force: true);
      return;
    }
    final normalizedPlanId = planId.trim();
    if (normalizedPlanId.isEmpty) {
      context.appWarning('未找到可打开的生产计划', force: true);
      return;
    }
    final router = GoRouter.of(context);
    final location = Uri(
      path: RoutePath.productionPlanDetail(normalizedPlanId),
      queryParameters: executionSegmentId == null
          ? null
          : {'executionSegmentId': executionSegmentId},
    ).toString();
    try {
      await router.push(location);
    } catch (_) {
      if (context.mounted) {
        context.appError('生产计划打开失败，请稍后重试', force: true);
      }
    }
  }

  /// 剩余 = 订货 − 已发（还欠客户多少，负数/缺失一律按 0 处理）。
  double? _remaining(double? qty, double? shipped) {
    if (qty == null) return null;
    final left = qty - (shipped ?? 0);
    return left > 0 ? left : 0;
  }

  Widget _num(
    ThemeData theme,
    String label,
    double? v, {
    bool highlight = false,
  }) {
    return SizedBox(
      width: 76,
      child: Column(
        children: [
          Text(
            _fmt(v),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w400,
              color: highlight ? theme.colorScheme.primary : null,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

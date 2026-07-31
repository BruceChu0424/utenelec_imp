// UtenEditableGrid - 编辑页明细可编辑 Excel 表（采购/销售/委外/仓库/钱流 共用）
//
// 设计目标（plans/witty-imagining-reef.md Workstream B1）：
// - 灭"重绘风暴"：行 model 持有 TextEditingController/ValueNotifier（跨重建存活，绝不在
//   build 里 new）；金额单元与表尾合计用 ValueListenableBuilder 订阅通知器，
//   敲一个字只重绘那一格 + 合计，不重绘行/表/页。表级 ChangeNotifier 仅在增删行时触发。
// - sticky 表头 + 横向滚动；表体 content-tall（shrinkWrap）：横滚条始终贴最后一行下。
// - Excel 交互：表头全左对齐；每个单元格右竖线分隔；按住列右边界竖线左右拖拽调宽窄
//   （复用 MasterDataTableView 的 grip 范式，下限 48 防拖没）。
// - "添加行"(加1) + "添加多行"(对话框填 N，1-50)；行尾删除。
// - 全尺寸 Excel（手机横向滚动，与报表一致）；不做列隐藏，单套代码。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// 行模型基类。行持有自己的 TextEditingController / ValueNotifier（跨重建存活）。
/// 删行/清空/替换时由 [UtenEditableGridController] 调 [dispose] 释放，避免泄漏。
abstract class EditableGridRow {
  /// 该行对表尾合计的贡献（默认 0；金额行用 [AmountRowMixin] 覆盖为金额）。
  double get amountValue => 0;

  /// 订阅金额变化（默认无操作；[AmountRowMixin] 覆盖为订阅 amountNotifier）。
  /// 返回取消订阅的回调。controller 在增删行时重连所有行。
  VoidCallback listenAmount(VoidCallback cb) => () {};

  /// 释放行持有的控制器/通知器。子类覆盖时先释己方资源再 super.dispose()。
  void dispose() {}
}

/// 带金额自动计算的行 mixin：暴露 [amountNotifier]，金额单元与表尾合计订阅它。
/// 行的 qty/price 等控制器变更时调 [recalcAmount] 重算金额（不触发 setState，只动通知器）。
mixin AmountRowMixin on EditableGridRow {
  final ValueNotifier<double> amountNotifier = ValueNotifier<double>(0);

  @override
  double get amountValue => amountNotifier.value;

  @override
  VoidCallback listenAmount(VoidCallback cb) {
    amountNotifier.addListener(cb);
    return () => amountNotifier.removeListener(cb);
  }

  /// 重算并更新金额（仅在值变化时通知，避免无谓刷新）。
  void recalcAmount(double Function() compute) {
    final v = compute();
    if (v != amountNotifier.value) amountNotifier.value = v;
  }

  @override
  void dispose() {
    amountNotifier.dispose();
    super.dispose();
  }
}

/// 一列定义：[key]（标识）、[label]（表头）、[width]（初始列宽，可被用户拖拽覆盖）、
/// [cellBuilder]（单元格控件，从行 model 取控制器/通知器）、[numeric]（金额/数量→数据右对齐+tabular）。
class EditableGridColumn<T extends EditableGridRow> {
  const EditableGridColumn({
    required this.key,
    required this.label,
    required this.width,
    required this.cellBuilder,
    this.numeric = false,
  });

  final String key;
  final String label;
  final double width;
  final Widget Function(BuildContext context, T row) cellBuilder;
  final bool numeric;
}

/// 行列表 + 合计通知器的持有者。所有改行操作走这里（[rows] 私有），
/// 自动 dispose 被删行；表级 [notifyListeners] 仅在增删行时触发（驱动行数重绘）。
class UtenEditableGridController<T extends EditableGridRow>
    extends ChangeNotifier {
  UtenEditableGridController({List<T>? initial})
    : _rows = List.of(initial ?? const []);

  final List<T> _rows;

  List<T> get rows => List.unmodifiable(_rows);
  int get length => _rows.length;
  bool get isEmpty => _rows.isEmpty;
  T operator [](int i) => _rows[i];

  void addRow(T row) {
    _rows.add(row);
    _total.reattachTo(_rows);
    notifyListeners();
  }

  void addRows(Iterable<T> rows) {
    _rows.addAll(rows);
    _total.reattachTo(_rows);
    notifyListeners();
  }

  void insertAt(int i, T row) {
    _rows.insert(i, row);
    _total.reattachTo(_rows);
    notifyListeners();
  }

  void removeAt(int i) {
    _rows[i].dispose();
    _rows.removeAt(i);
    _total.reattachTo(_rows);
    notifyListeners();
  }

  /// 替换全部行（旧行逐个 dispose）。用于"从上游引入"整体覆盖。
  void replaceAll(Iterable<T> rows) {
    for (final r in _rows) {
      r.dispose();
    }
    _rows
      ..clear()
      ..addAll(rows);
    _total.reattachTo(_rows);
    notifyListeners();
  }

  void clear() {
    for (final r in _rows) {
      r.dispose();
    }
    _rows.clear();
    _total.reattachTo(_rows);
    notifyListeners();
  }

  final _GridTotalNotifier<T> _total = _GridTotalNotifier<T>();

  /// 表尾合计订阅源（金额行贡献之和）。页脚用 ValueListenableBuilder 订阅。
  ValueListenable<double> get totalListenable => _total;
  double get total => _total.value;

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    _total.dispose();
    super.dispose();
  }
}

/// 聚合各行金额通知器：增删行时重连（reattachTo）；任一行金额变化→重求和→通知。
class _GridTotalNotifier<T extends EditableGridRow> extends ChangeNotifier
    implements ValueListenable<double> {
  double _value = 0;
  final List<VoidCallback> _unsubs = [];

  @override
  double get value => _value;

  void reattachTo(List<T> rows) {
    for (final u in _unsubs) {
      u();
    }
    _unsubs.clear();
    _setValue(rows.fold(0.0, (s, r) => s + r.amountValue));
    for (final r in rows) {
      _unsubs.add(
        r.listenAmount(
          () => _setValue(rows.fold(0.0, (s, x) => s + x.amountValue)),
        ),
      );
    }
  }

  void _setValue(double v) {
    if (v != _value) {
      _value = v;
      notifyListeners();
    }
  }
}

/// 可编辑 Excel 明细表。sticky 表头（左对齐 + 列右边界可拖拽调宽）+ 竖线分隔 +
/// 横向滚动 + content-tall 表体（横滚条贴末行）+ 增删行。
class UtenEditableGrid<T extends EditableGridRow> extends StatefulWidget {
  const UtenEditableGrid({
    super.key,
    required this.controller,
    required this.columns,
    required this.createBlankRow,
    this.footer,
    this.showRowDelete = true,
    this.showAddRow = true,
    this.addRowLabel = '添加行',
    this.addRowsLabel = '添加多行',
    this.emptyMessage = '暂无明细，点击下方按钮添加',
  });

  final UtenEditableGridController<T> controller;
  final List<EditableGridColumn<T>> columns;

  /// 构造一个空行（"添加行"/"添加多行"用）。
  final T Function() createBlankRow;

  /// 表尾（通常放合计：ValueListenableBuilder(controller.totalListenable)）。null=不显示。
  final Widget? footer;

  final bool showRowDelete;

  /// 是否显示底部「添加行/添加多行」栏。编辑页用 true（默认）；「从上游引入」选明细等
  /// 只读勾选场景传 false 隐藏。
  final bool showAddRow;
  final String addRowLabel;
  final String addRowsLabel;
  final String emptyMessage;

  @override
  State<UtenEditableGrid<T>> createState() => _UtenEditableGridState<T>();
}

class _UtenEditableGridState<T extends EditableGridRow>
    extends State<UtenEditableGrid<T>> {
  // 表头/表体横滚同步（双 ScrollController + _syncing 防回环）。
  late final ScrollController _headerH;
  late final ScrollController _bodyH;
  bool _syncing = false;

  // 当前列宽（可被用户拖拽覆盖）；列集合变化时按 columns.width 重置。
  List<double> _widths = const [];

  /// 列宽拖拽命中区半宽（贴列右边界，半溢出到相邻列）。
  static const double _gripHalf = 4;

  /// 列宽下限（防拖没）。
  static const double _minColWidth = 48;

  /// 删除列宽（行尾 × 按钮）。
  static const double _deleteColWidth = 48;

  @override
  void initState() {
    super.initState();
    _headerH = ScrollController();
    _bodyH = ScrollController();
    _headerH.addListener(() => _sync(_headerH, _bodyH));
    _bodyH.addListener(() => _sync(_bodyH, _headerH));
    _widths = widget.columns
        .map((c) => c.width.clamp(_minColWidth, double.infinity))
        .toList();
  }

  @override
  void didUpdateWidget(covariant UtenEditableGrid<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列集合变了（数量或 key 序列不同，如切换 docType）→ 按新 columns.width 重置列宽。
    if (!_sameColumnKeys(oldWidget.columns, widget.columns)) {
      _widths = widget.columns
          .map((c) => c.width.clamp(_minColWidth, double.infinity))
          .toList();
    }
  }

  bool _sameColumnKeys(
    List<EditableGridColumn<T>> a,
    List<EditableGridColumn<T>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key) return false;
    }
    return true;
  }

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing || !dst.hasClients) return;
    _syncing = true;
    dst.jumpTo(src.offset);
    _syncing = false;
  }

  /// 拖拽改第 [index] 列宽：按本次横向增量更新，下限 [_minColWidth] 防拖没。
  void _resizeColumn(int index, double dx) {
    final next = _widths[index] + dx;
    if (next < _minColWidth) return;
    setState(() => _widths[index] = next);
  }

  double get _totalWidth =>
      _widths.fold(0.0, (s, w) => s + w) +
      (widget.showRowDelete ? _deleteColWidth : 0);

  @override
  void dispose() {
    _headerH.dispose();
    _bodyH.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _totalWidth;
    final divider = BorderSide(
      color: theme.colorScheme.outlineVariant,
      width: 0.5,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // sticky 表头：横向跟随表体同步，竖向固定；每列左对齐 + 右竖线 + 可拖拽调宽。
        Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: SingleChildScrollView(
            controller: _headerH,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total,
              child: Row(
                children: [
                  for (var i = 0; i < widget.columns.length; i++)
                    SizedBox(
                      width: _widths[i],
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          border: Border(
                            right: BorderSide(color: theme.colorScheme.outline),
                          ),
                        ),
                        child: Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: UtenSpacing.s12,
                                vertical: UtenSpacing.s8,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  widget.columns[i].label,
                                  style:
                                      (theme.textTheme.labelMedium ??
                                              const TextStyle())
                                          .copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                ),
                              ),
                            ),
                            // 列宽拖拽手柄：贴列右边界、半溢出到相邻列的命中区。
                            Positioned(
                              right: -_gripHalf,
                              top: 0,
                              bottom: 0,
                              width: _gripHalf * 2,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onHorizontalDragUpdate: (d) =>
                                    _resizeColumn(i, d.delta.dx),
                                child: const MouseRegion(
                                  cursor: SystemMouseCursors.resizeColumn,
                                  child: SizedBox.expand(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (widget.showRowDelete)
                    SizedBox(
                      width: _deleteColWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          border: Border(
                            right: BorderSide(color: theme.colorScheme.outline),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          color: theme.colorScheme.outlineVariant,
        ),
        // 表体：content-tall（shrinkWrap），横向可滚，横滚条始终贴最后一行下。
        Scrollbar(
          controller: _bodyH,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _bodyH,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total,
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final rows = widget.controller.rows;
                  if (rows.isEmpty) {
                    return _EmptyRows(message: widget.emptyMessage);
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _DataRow<T>(
                      index: i,
                      row: rows[i],
                      columns: widget.columns,
                      widths: _widths,
                      showDelete: widget.showRowDelete,
                      deleteColWidth: _deleteColWidth,
                      divider: divider,
                      onDelete: () => widget.controller.removeAt(i),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        if (widget.footer != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s8,
            ),
            child: DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium ?? const TextStyle(),
              child: widget.footer!,
            ),
          ),
        if (widget.showAddRow)
          _AddRowBar(
            onAddOne: () => widget.controller.addRow(widget.createBlankRow()),
            onAddMany: () async {
              final n = await _showAddRowsDialog(context);
              if (n != null && n > 0) {
                widget.controller.addRows(
                  List.generate(n, (_) => widget.createBlankRow()),
                );
              }
            },
            addRowLabel: widget.addRowLabel,
            addRowsLabel: widget.addRowsLabel,
          ),
      ],
    );
  }

  Future<int?> _showAddRowsDialog(BuildContext context) {
    final ctrl = TextEditingController(text: '5');
    return showDialog<int>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('添加多行'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '行数',
              hintText: '1 - 50',
              suffixText: '行',
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final n = int.tryParse(ctrl.text.trim()) ?? 0;
                Navigator.pop(ctx, n.clamp(1, 50));
              },
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
  }
}

class _DataRow<T extends EditableGridRow> extends StatelessWidget {
  const _DataRow({
    required this.index,
    required this.row,
    required this.columns,
    required this.widths,
    required this.showDelete,
    required this.deleteColWidth,
    required this.divider,
    required this.onDelete,
  });
  final int index;
  final T row;
  final List<EditableGridColumn<T>> columns;
  final List<double> widths;
  final bool showDelete;
  final double deleteColWidth;
  final BorderSide divider;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOdd = index.isOdd;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isOdd ? theme.colorScheme.surfaceContainerLowest : null,
        border: Border(bottom: divider),
      ),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            SizedBox(
              width: widths[i],
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border(right: divider)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s8,
                    vertical: UtenSpacing.s4,
                  ),
                  child: Align(
                    alignment: columns[i].numeric
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontFeatures: columns[i].numeric
                            ? const [FontFeature.tabularFigures()]
                            : null,
                      ),
                      child: columns[i].cellBuilder(context, row),
                    ),
                  ),
                ),
              ),
            ),
          if (showDelete)
            SizedBox(
              width: deleteColWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border(right: divider)),
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: '删除该行',
                  onPressed: onDelete,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyRows extends StatelessWidget {
  const _EmptyRows({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Center(
        child: Text(
          message,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _AddRowBar extends StatelessWidget {
  const _AddRowBar({
    required this.onAddOne,
    required this.onAddMany,
    required this.addRowLabel,
    required this.addRowsLabel,
  });
  final VoidCallback onAddOne;
  final VoidCallback onAddMany;
  final String addRowLabel;
  final String addRowsLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s4),
      child: Wrap(
        spacing: UtenSpacing.s8,
        children: [
          TextButton.icon(
            onPressed: onAddOne,
            icon: const Icon(Icons.add_circle_outline, size: 20),
            label: Text(addRowLabel),
          ),
          TextButton.icon(
            onPressed: onAddMany,
            icon: const Icon(Icons.playlist_add, size: 20),
            label: Text(addRowsLabel),
          ),
        ],
      ),
    );
  }
}

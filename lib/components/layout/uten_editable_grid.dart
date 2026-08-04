// UtenEditableGrid - 编辑页明细可编辑 Excel 表（采购/销售/委外/仓库/钱流 共用）
//
// 设计目标（plans/witty-imagining-reef.md Workstream B1）：
// - 灭"重绘风暴"：行 model 持有 TextEditingController/ValueNotifier（跨重建存活，绝不在
//   build 里 new）；金额单元与表尾合计用 ValueListenableBuilder 订阅通知器，
//   敲一个字只重绘那一格 + 合计，不重绘行/表/页。表级 ChangeNotifier 仅在增删行时触发。
// - sticky 表头（页面上滑把表头顶到视口顶才吸附，随表体尾部推出，不原地固定）+ 横向滚动；
//   表体 content-tall：内容不超高时横滚条贴最后一行下；超高时横滚条钉视口底，随拖随用。
// - Excel 交互：表头全左对齐；每个单元格右竖线分隔；按住列右边界竖线左右拖拽调宽窄
//   （复用 MasterDataTableView 的 grip 范式，下限 48 防拖没）。
// - "添加行"(加1) + "添加多行"(对话框填 N，1-50)；行尾删除。
// - 全尺寸 Excel（手机横向滚动，与报表一致）；不做列隐藏，单套代码。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_dialog.dart';

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
    this.required = false,
  });

  final String key;
  final String label;
  final double width;
  final Widget Function(BuildContext context, T row) cellBuilder;
  final bool numeric;

  /// 该列是否必填：表头文案后显红 *；单元为空时由 [RequiredCellFrame] 描红边。
  final bool required;
}

/// 必填单元的**实时**红框：订阅 [listenable]，当 [isEmpty] 为真时给 [child] 描红边，
/// 填好后红边消失。替代各 feature 重复的提交态 `_invalidFrame`——本件随单元内容即时变化，
/// 不依赖"保存拦截"触发。
///
/// 用法（包住必填单元控件）：
/// ```
/// RequiredCellFrame(
///   listenable: row.qty,                 // TextEditingController / ValueNotifier
///   isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
///   child: TextField(controller: row.qty, ...),
/// )
/// ```
class RequiredCellFrame extends StatefulWidget {
  const RequiredCellFrame({
    super.key,
    required this.listenable,
    required this.isEmpty,
    required this.child,
  });

  /// 单元内容的变更源（控制器/通知器）。空判只在其触发时重算。
  final Listenable listenable;

  /// 判断本单元是否"为空/缺失"。返回 true → 描红边。
  final bool Function() isEmpty;

  final Widget child;

  @override
  State<RequiredCellFrame> createState() => _RequiredCellFrameState();
}

class _RequiredCellFrameState extends State<RequiredCellFrame> {
  bool _empty = false;

  @override
  void initState() {
    super.initState();
    _empty = widget.isEmpty();
    widget.listenable.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant RequiredCellFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.listenable, oldWidget.listenable)) {
      oldWidget.listenable.removeListener(_onChange);
      widget.listenable.addListener(_onChange);
    }
    // 谓词/child 可能随重建变化，重算一次空态。
    final e = widget.isEmpty();
    if (e != _empty) _empty = e;
  }

  void _onChange() {
    final e = widget.isEmpty();
    if (e != _empty) setState(() => _empty = e);
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_empty) return widget.child;
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;
    // 关键：把红框交给「内部输入框自己的边框」来画，而不是在外层叠一个 DecoratedBox。
    // 旧实现在 child 外面包 DecoratedBox 画红框，但里面的 TextField / InputDecorator 自带
    // 灰色 OutlineInputBorder 会画在前面，盖住红边中段，只剩四角露红。这里用 Theme 覆盖后代
    // inputDecorationTheme 的各类边框为红色，让 child 自身的边框变红，消除层叠错位。
    // 一处改，全模块 grid（销售/采购/委外/生产/钱流/仓库）必填格统一生效。
    OutlineInputBorder redBorder({bool focused = false}) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(
        color: errorColor,
        width: focused ? 2 : 1.5,
      ),
    );
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          enabledBorder: redBorder(),
          focusedBorder: redBorder(focused: true),
          border: redBorder(),
          errorBorder: redBorder(),
          focusedErrorBorder: redBorder(focused: true),
        ),
      ),
      child: widget.child,
    );
  }
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

  /// 批量删除（按对象身份，删除前 dispose）。用于批量模式多选删除。
  void removeRows(List<T> victims) {
    if (victims.isEmpty) return;
    final kill = <T>{};
    for (final v in victims) {
      if (_rows.contains(v) && kill.add(v)) {
        v.dispose();
      }
    }
    if (kill.isEmpty) return;
    _rows.removeWhere(kill.contains);
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

  // ======================= 多选 / 复制粘贴 =======================
  // grid 组件内置操作条（全选/复制/批量删除/粘贴）常驻显示，选择状态集中在 controller。
  final Set<T> _selected = <T>{};
  final List<T> _copyBuffer = <T>[];

  bool isSelected(T row) => _selected.contains(row);
  int get selectedCount => _selected.length;
  bool get allSelected =>
      _rows.isNotEmpty && _rows.every(_selected.contains);
  bool get hasBuffer => _copyBuffer.isNotEmpty;

  void toggleSelect(T row) {
    if (!_selected.add(row)) _selected.remove(row);
    notifyListeners();
  }

  void selectAll() {
    if (_rows.every(_selected.contains)) {
      _selected.clear();
    } else {
      _selected.addAll(_rows);
    }
    notifyListeners();
  }

  /// 复制选中行到缓冲（克隆快照；旧缓冲先 dispose）。
  void copySelected(T Function(T) clone) {
    if (_selected.isEmpty) return;
    for (final r in _copyBuffer) {
      r.dispose();
    }
    _copyBuffer
      ..clear()
      ..addAll(_selected.map(clone));
    notifyListeners();
  }

  /// 粘贴缓冲（每条再克隆出独立行）count 份。
  void paste(T Function(T) clone, {int count = 1}) {
    if (_copyBuffer.isEmpty) return;
    final pasted = <T>[];
    for (var i = 0; i < count; i++) {
      for (final src in _copyBuffer) {
        pasted.add(clone(src));
      }
    }
    addRows(pasted);
  }

  /// 批量删除选中行（按身份 dispose + 移除；清空选中）。
  void batchDelete() {
    if (_selected.isEmpty) return;
    final victims = _selected.toList();
    _selected.clear();
    removeRows(victims);
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
    for (final r in _copyBuffer) {
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

/// 可编辑 Excel 明细表。sticky 表头（上滑到视口顶才吸附，不原地固定）+ 竖线分隔 +
/// 横向滚动 + content-tall 表体（内容矮→横滚条贴末行；内容高→横滚条钉视口底）+ 增删行。
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
    this.confirmDelete = true,
    this.deleteConfirmLabel = '确认删除该行明细？',
    this.cloneRow,
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

  /// 删除行前是否弹确认框（默认开）。
  final bool confirmDelete;
  final String deleteConfirmLabel;

  /// 行克隆函数（深拷贝一行）；非空时操作条显「复制/粘贴」。各 feature 注入自家行克隆实现。
  final T Function(T)? cloneRow;

  @override
  State<UtenEditableGrid<T>> createState() => _UtenEditableGridState<T>();
}

class _UtenEditableGridState<T extends EditableGridRow>
    extends State<UtenEditableGrid<T>> {
  // 表头/表体/钉底横滚条 三向横滚同步（三 ScrollController + _syncing 防回环）。
  late final ScrollController _headerH;
  late final ScrollController _bodyH;
  late final ScrollController _pinnedH;
  bool _syncing = false;

  /// 选择列宽（批量模式行首 checkbox）。
  static const double _selectColWidth = 44;

  // —— sticky 表头 / 钉底横滚条 测量与位置状态 ——
  /// 网格 Stack / 表头单元 / 表体区 的测量键（post-frame 量全局位置用）。
  final GlobalKey _gridKey = GlobalKey();
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _bodyKey = GlobalKey();

  /// 表头覆盖层在网格内的 local top（0=自然位，表头就在网格顶；
  /// 页面上滑把表头顶到视口顶后=吸附位；表体尾部上推时随尾部推出）。
  final ValueNotifier<double> _headerY = ValueNotifier<double>(0);

  /// 钉底横滚条底边的 local top；null=不钉（内容不超高或表体滚出视口，
  /// 用末行下的自然滚动条）。
  final ValueNotifier<double?> _pinnedBarY = ValueNotifier<double?>(null);

  /// 表头实测高度（流内占位用；首帧用兜底值，post-frame 实测修正）。
  double _headerHeight = 40;

  /// 钉底横滚条占位高度（滚动条 thumb 在其底部绘制）。
  static const double _pinnedBarHeight = 16;

  /// 页面滚动监听（最近的祖先 Scrollable 的 position，单据编辑页的页面 ListView）。
  ScrollPosition? _pagePos;

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
    _pinnedH = ScrollController();
    _headerH.addListener(() => _sync(_headerH));
    _bodyH.addListener(() => _sync(_bodyH));
    _pinnedH.addListener(() => _sync(_pinnedH));
    _widths = widget.columns
        .map((c) => c.width.clamp(_minColWidth, double.infinity))
        .toList();
    // 增删行改变表体高度 → sticky 表头/钉底横滚条位置需重算。
    widget.controller.addListener(_onControllerChanged);
    _scheduleStickyUpdate();
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
    // 行控制器换实例 → 重挂监听（增删行驱动 sticky 位置重算）。
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面上下滑（最近的祖先 Scrollable）时驱动 sticky 表头/钉底横滚条位置重算。
    final pos = Scrollable.maybeOf(context)?.position;
    if (!identical(pos, _pagePos)) {
      _pagePos?.removeListener(_scheduleStickyUpdate);
      _pagePos = pos;
      _pagePos?.addListener(_scheduleStickyUpdate);
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

  /// 三向横滚同步：表头 / 表体 / 钉底横滚条 任一滚动 → 其余两个 jumpTo 跟随
  /// （[_syncing] 防回环；未挂载的控制器跳过，挂上后由下一次同步追平）。
  void _sync(ScrollController src) {
    if (_syncing || !src.hasClients) return;
    _syncing = true;
    for (final d in [_headerH, _bodyH, _pinnedH]) {
      if (!identical(d, src) && d.hasClients) d.jumpTo(src.offset);
    }
    _syncing = false;
  }

  /// 布局完成后重算 sticky 表头与钉底横滚条位置（渲染对象须完成 layout 才能量）。
  void _scheduleStickyUpdate() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateSticky();
    });
  }

  /// controller 变化（增删行 / 批量模式切换 / 选择变化）→ 重建本 State
  /// （表头全选 checkbox、_totalWidth 列宽需随之刷新）+ 重算 sticky。
  void _onControllerChanged() {
    if (!mounted) return;
    _scheduleStickyUpdate();
    setState(() {});
  }

  /// 量网格/表头/表体与页面视口的全局位置，算出两个覆盖层的位置：
  /// - sticky 表头 local top：0=自然位（表头就在网格顶，不原地固定）；页面上滑把表头
  ///   顶到视口顶后钉住；表体尾部上推时表头随尾部一起推出（pushed sticky，不悬空）。
  /// - 钉底横滚条 local top：表体底在视口底之下（看不到末行下的自然滚动条）且表体仍
  ///   可见时钉视口底；否则隐藏，由末行下的自然滚动条接管（内容不超高时就是原样）。
  void _updateSticky() {
    if (!mounted) return;
    final gridCtx = _gridKey.currentContext;
    final gridBox = gridCtx?.findRenderObject() as RenderBox?;
    final headerBox = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    final bodyBox = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    if (gridCtx == null ||
        gridBox == null ||
        !gridBox.attached ||
        headerBox == null ||
        !headerBox.attached ||
        bodyBox == null ||
        !bodyBox.attached) {
      return;
    }
    // 视口 = 最近的祖先 Scrollable（单据编辑页的页面 ListView）；找不到则保持自然布局。
    final scrollable = Scrollable.maybeOf(gridCtx);
    final vpBox = scrollable?.context.findRenderObject() as RenderBox?;
    if (vpBox == null || !vpBox.attached || !vpBox.hasSize) return;
    final gridTop = gridBox.localToGlobal(Offset.zero).dy;
    final headerH = headerBox.size.height;
    if (headerH > 0 && (headerH - _headerHeight).abs() > 0.5) {
      // 表头实测高度变化（字体缩放/主题切换）→ 修正流内占位高度。
      setState(() => _headerHeight = headerH);
    }
    final bodyTop = bodyBox.localToGlobal(Offset.zero).dy;
    final bodyBottom = bodyTop + bodyBox.size.height;
    final vpTop = vpBox.localToGlobal(Offset.zero).dy;
    final vpBottom = vpTop + vpBox.size.height;

    // sticky 表头：自然位 local 0；表头随页面上滑到视口顶才吸附；表体尾部把表头顶出。
    var headerY = vpTop - gridTop;
    if (headerY < 0) headerY = 0;
    final headerMaxY = bodyBottom - gridTop - headerH;
    if (headerY > headerMaxY) headerY = headerMaxY < 0 ? 0 : headerMaxY;
    if (_headerY.value != headerY) _headerY.value = headerY;

    // 钉底横滚条：表体底在视口底之下（末行下的自然滚动条看不到）且表体仍可见 → 钉视口底。
    final double? pinnedY =
        (bodyBottom > vpBottom && bodyTop < vpBottom) ? vpBottom - gridTop : null;
    if (_pinnedBarY.value != pinnedY) _pinnedBarY.value = pinnedY;
  }

  /// 拖拽改第 [index] 列宽：按本次横向增量更新，下限 [_minColWidth] 防拖没。
  void _resizeColumn(int index, double dx) {
    final next = _widths[index] + dx;
    if (next < _minColWidth) return;
    setState(() => _widths[index] = next);
  }

  double get _totalWidth =>
      (widget.showAddRow ? _selectColWidth : 0) +
      _widths.fold(0.0, (s, w) => s + w) +
      (widget.showRowDelete ? _deleteColWidth : 0);

  @override
  void dispose() {
    _pagePos?.removeListener(_scheduleStickyUpdate);
    widget.controller.removeListener(_onControllerChanged);
    _headerY.dispose();
    _pinnedBarY.dispose();
    _headerH.dispose();
    _bodyH.dispose();
    _pinnedH.dispose();
    super.dispose();
  }

  /// 表头全选 checkbox（批量模式表头首列；读写由 controller 驱动）。
  Widget _selectAllHeader(ThemeData theme) {
    final c = widget.controller;
    final all = c.allSelected;
    final some = !all && c.selectedCount > 0;
    return SizedBox(
      width: _selectColWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          border: Border(right: BorderSide(color: theme.colorScheme.outline)),
        ),
        child: Checkbox(
          value: all ? true : (some ? null : false),
          tristate: true,
          onChanged: (_) => c.selectAll(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _totalWidth;
    final divider = BorderSide(
      color: theme.colorScheme.outlineVariant,
      width: 0.5,
    );
    final headerUnit = KeyedSubtree(
      key: _headerKey,
      child: _buildHeaderUnit(theme, total),
    );
    // 首帧/数据/布局变化后，post-frame 重算 sticky 表头与钉底横滚条位置。
    _scheduleStickyUpdate();
    final body = Stack(
      key: _gridKey,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 表头占位：真正的表头在下方 Stack 覆盖层里（始终挂载，横滚 offset 不丢），
            // 流内只留同高占位撑起布局。
            SizedBox(height: _headerHeight),
            // 表体：content-tall（shrinkWrap），横向可滚。内容不超高 → 末行下的自然滚动条
            // 即原样；内容超高 → 自然滚动条在视口外，由钉底横滚条（下方覆盖层）接管。
            KeyedSubtree(
              key: _bodyKey,
              child: Scrollbar(
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
                            showSelect: widget.showAddRow,
                            isSelected: widget.controller.isSelected(rows[i]),
                            onSelect: () =>
                                widget.controller.toggleSelect(rows[i]),
                            showDelete: widget.showRowDelete,
                            deleteColWidth: _deleteColWidth,
                            divider: divider,
                            confirmDelete: widget.confirmDelete,
                            deleteConfirmLabel: widget.deleteConfirmLabel,
                            onDelete: () => widget.controller.removeAt(i),
                          ),
                        );
                      },
                    ),
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
                onAddOne: () =>
                    widget.controller.addRow(widget.createBlankRow()),
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
        ),
        // sticky 表头覆盖层：top 由 [_headerY] 驱动——0=自然位（表头在网格顶）；
        // 页面上滑把表头顶到视口顶后钉住；表体尾部上推时随尾部推出。
        ValueListenableBuilder<double>(
          valueListenable: _headerY,
          builder: (context, y, _) =>
              Positioned(left: 0, right: 0, top: y, child: headerUnit),
        ),
        // 钉底横滚条覆盖层：[_pinnedBarY] 非空（表体底在视口外且表体可见）时钉视口底；
        // 为空时 Offstage 但保持挂载——横滚 offset 不丢，重新钉上时立即对齐。
        ValueListenableBuilder<double?>(
          valueListenable: _pinnedBarY,
          builder: (context, y, _) => Positioned(
            left: 0,
            right: 0,
            top: (y ?? 0) - _pinnedBarHeight,
            child: Offstage(
              offstage: y == null,
              child: SizedBox(
                height: _pinnedBarHeight,
                child: Scrollbar(
                  controller: _pinnedH,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _pinnedH,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: SizedBox(width: total, height: 1),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    // 操作条放在 Stack 之外（外层 Column），随页滚动且永不被 sticky 表头覆盖。
    // 仅可编辑表格（showAddRow）显示；选择弹层（showAddRow=false）不显示。
    if (!widget.showAddRow) return body;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_actionsBar(theme), body],
    );
  }

  /// 明细操作条（全选/复制选中/批量删除/粘贴），常驻显示在表体上方。
  /// cloneRow 非空才显「复制/粘贴」。订阅 controller，选择数/缓冲变化即时刷新。
  Widget _actionsBar(ThemeData theme) {
    final clone = widget.cloneRow;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final n = c.selectedCount;
        return Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Wrap(
            spacing: UtenSpacing.s4,
            runSpacing: UtenSpacing.s4,
            children: [
              _actBtn(
                theme,
                c.allSelected ? '取消全选' : '全选',
                c.selectAll,
              ),
              if (clone != null)
                _actBtn(
                  theme,
                  '复制选中 ($n)',
                  n > 0 ? () => c.copySelected(clone) : null,
                ),
              _actBtn(
                theme,
                '批量删除 ($n)',
                n > 0 ? () => _confirmBatchDelete(context) : null,
                danger: true,
              ),
              if (clone != null && c.hasBuffer) ...[
                _actBtn(theme, '粘贴', () => c.paste(clone)),
                _actBtn(
                  theme,
                  '粘贴多行',
                  () => _pasteMany(context, clone),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _actBtn(
    ThemeData theme,
    String label,
    VoidCallback? onPressed, {
    bool danger = false,
  }) {
    final color = danger ? theme.colorScheme.error : theme.colorScheme.primary;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  Future<void> _confirmBatchDelete(BuildContext context) async {
    final ok = await UtenDialog.show(
      context,
      title: '批量删除',
      content: Text('确认删除选中的 ${widget.controller.selectedCount} 行明细？'),
      confirmLabel: '删除',
      danger: true,
    );
    if (ok == true) widget.controller.batchDelete();
  }

  Future<void> _pasteMany(BuildContext context, T Function(T) clone) async {
    final n = await _showCountDialog(context);
    if (n != null && n > 0) widget.controller.paste(clone, count: n);
  }

  Future<int?> _showCountDialog(BuildContext context) {
    final ctrl = TextEditingController(text: '1');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴多行'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '粘贴份数',
            hintText: '1 - 50',
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
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 表头单元（表头行 + 下分隔线）：常驻 Stack 覆盖层，横向跟随表体同步；
  /// 每列左对齐 + 右竖线 + 可拖拽调宽；竖向位置由 [_headerY] 驱动（sticky）。
  Widget _buildHeaderUnit(ThemeData theme, double total) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: SingleChildScrollView(
            controller: _headerH,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total,
              child: Row(
                children: [
                  if (widget.showAddRow) _selectAllHeader(theme),
                  for (var i = 0; i < widget.columns.length; i++)
                    SizedBox(
                      width: _widths[i],
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          border: Border(
                            right: BorderSide(
                              color: theme.colorScheme.outline,
                            ),
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
                                child: Text.rich(
                                  TextSpan(
                                    text: widget.columns[i].label,
                                    style: (theme.textTheme.labelMedium ??
                                            const TextStyle())
                                        .copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                    children: widget.columns[i].required
                                        ? [
                                            TextSpan(
                                              text: ' *',
                                              style: (theme.textTheme.labelMedium ??
                                                      const TextStyle())
                                                  .copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .error,
                                                    fontWeight:
                                                        FontWeight.w700,
                                                  ),
                                            ),
                                          ]
                                        : null,
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
                            right: BorderSide(
                              color: theme.colorScheme.outline,
                            ),
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
    this.showSelect = false,
    this.selectColWidth = 44,
    this.isSelected = false,
    this.onSelect,
    this.confirmDelete = true,
    this.deleteConfirmLabel = '确认删除该行明细？',
  });
  final int index;
  final T row;
  final List<EditableGridColumn<T>> columns;
  final List<double> widths;
  final bool showDelete;
  final double deleteColWidth;
  final BorderSide divider;
  final VoidCallback onDelete;

  /// 批量模式：行首选中框。
  final bool showSelect;
  final double selectColWidth;
  final bool isSelected;
  final VoidCallback? onSelect;

  /// 删除前确认弹窗。
  final bool confirmDelete;
  final String deleteConfirmLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOdd = index.isOdd;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
            : (isOdd ? theme.colorScheme.surfaceContainerLowest : null),
        border: Border(bottom: divider),
      ),
      child: Row(
        children: [
          if (showSelect)
            SizedBox(
              width: selectColWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border(right: divider)),
                child: Checkbox(
                  value: isSelected,
                  onChanged: onSelect == null ? null : (_) => onSelect!(),
                ),
              ),
            ),
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
                  onPressed: () async {
                    if (confirmDelete) {
                      final ok = await UtenDialog.show(
                        context,
                        title: deleteConfirmLabel,
                        content: const Text('删除后不可撤销，确认删除？'),
                        confirmLabel: '删除',
                        danger: true,
                      );
                      if (ok != true) return;
                    }
                    onDelete();
                  },
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

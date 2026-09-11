// UtenEditableGrid - 编辑页明细可编辑 Excel 表（采购/销售/委外/仓库/钱流 共用）
//
// 设计目标（plans/witty-imagining-reef.md Workstream B1）：
// - 灭"重绘风暴"：行 model 持有 TextEditingController/ValueNotifier（跨重建存活，绝不在
//   build 里 new）；金额单元与表尾合计用 ValueListenableBuilder 订阅通知器，
//   敲一个字只重绘那一格 + 合计，不重绘行/表/页。表级 ChangeNotifier 仅在增删行时触发。
// - sticky 表头（页面上滑把表头顶到视口顶才吸附，随表体尾部推出，不原地固定）+ 横向滚动；
//   表体 content-tall：横滚条走共用 UtenHScrollArea——内容不超高时在最后一行下方、
//   紧贴末行下方（约 1px 空隙）；超高时钉视口底，随拖随用（与散装表同一份实现，改一处全部生效）。
// - Excel 交互：表头全左对齐；每个单元格右竖线分隔；按住列右边界竖线左右拖拽调宽窄
//   （复用 MasterDataTableView 的 grip 范式，下限 48 防拖没）。
// - 列宽随内容自动加宽（2026-08-27）：列定义提供 textOf（+listenableOf）的列，输入/换值
//   内容变宽时列自动加长——只增不减、封顶 480；用户手动拖拽过的列锁定用户宽度，不再
//   自动加宽（列集合变化才解锁）。详见 EditableGridColumn.textOf 文档。
// - "添加行"(加1) + "添加多行"(对话框填 N，1-50)；行尾删除。
// - 表头体系与 MasterDataTableView 共用同一份实现（2026-09-05 收敛，见
//   uten_table_column_kit.dart）：可选表头设置（按钮处锚定的浮层勾选列表：勾选显隐、
//   拖拽排序、恢复默认）；表头纵向拖出隐藏 = 跟手浮层升 root Overlay 最顶层、过阈值
//   变红底红×、原格变淡；必填列(required)锁定不可隐藏。设置入口为深绿实心大按钮
//   （与主数据页同款）。
// - 列可带 headerInfo：表头 ⓘ 信息图标，悬停/长按弹说明（如折扣「1 = 原价；
//   0.9 = 9折」）。
// - 行级右键/长按操作菜单（2026-09-03，可编辑模式）：复用 UtenContextMenu——
//   复制选中/粘贴/批量粘贴/在上方插入空行/删除选中，与 controller 同一套逻辑。
//   编辑模式操作条（2026-09-05 起精简）只保留「表头设置」与宿主注入的批量动作
//   （batchActionsBuilder）；全选走表头复选框、复制/粘贴/删除走行菜单。
// - 全尺寸 Excel(手机横向滚动，与报表一致)；列隐藏只改变呈现，不销毁行控制器或数据。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_context_menu.dart';
import '../feedback/uten_dialog.dart';
import 'uten_grid_header_filter_cell.dart';
import 'uten_h_scroll_area.dart';
import 'uten_table_column_kit.dart';

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
/// [cellBuilder]（单元格控件，从行 model 取控制器/通知器）、[numeric]（金额/数量→数据右对齐+tabular）、
/// [textOf]+[listenableOf]（可选，随内容自动加宽）。
class EditableGridColumn<T extends EditableGridRow> {
  const EditableGridColumn({
    required this.key,
    required this.label,
    required this.width,
    required this.cellBuilder,
    this.numeric = false,
    this.required = false,
    this.headerInfo,
    this.textOf,
    this.listenableOf,
    this.filterValueOf,
    this.chromeWidth = 0,
  });

  final String key;
  final String label;
  final double width;
  final Widget Function(BuildContext context, T row) cellBuilder;
  final bool numeric;

  /// 该列是否必填：表头文案后显红 *；单元为空时由 [RequiredCellFrame] 描红边。
  /// 开启 [UtenEditableGrid.showColumnSettings] 后必填列锁定——表头设置列表
  /// 勾选禁用、表头纵向拖出隐藏不生效（必填项不允许从界面上消失）。
  final bool required;

  /// 表头说明（可选）：表头文案后显 ⓘ 信息图标，悬停/长按弹说明（如折扣列
  /// 「1 = 保持原价；0.9 = 9折」）。纯信息展示，不是按钮。
  final String? headerInfo;

  /// 「随内容自动加宽」取文本：返回该列在 [row] 上当前显示/输入的文本，如备注列
  /// `(r) => r.remark.text`、货品列 `(r) => r.goods?.name ?? ''`、只读主档列
  /// `(r) => colorEntries[r.colorId] ?? ''`。
  ///
  /// 提供后该列参与自动加宽：初始行/整批换行时量前若干行最宽文本撑列（只增不减，
  /// 封顶 480，超出后单元内滚动）；同时提供 [listenableOf] 则敲字/换值实时加宽。
  /// 用户手动拖过的列锁定用户宽度，不再自动加宽。null（默认）= 固定列宽。
  final String Function(T row)? textOf;

  /// 「随内容自动加宽」的变更源：该列单元绑定的 TextEditingController / ValueNotifier
  /// （须与 cellBuilder 里绑定的是同一个）。任一格内容变化 → 量 [textOf] 的新文本 →
  /// 超宽自动加列宽。仅提供 [textOf] 而不提供本字段时，只在行集变化时整体量一次
  /// （适合行model普通字段的只读列）。数值/日期等短内容列建议不接，保持固定宽。
  final Listenable? Function(T row)? listenableOf;

  /// 表头筛选（可选，2026-09-05）：返回该列在 [row] 上的当前取值（如车间名、
  /// 负责人名、状态文案）。提供后表头变为可点的筛选单元格（与 MasterDataTableView
  /// 同款锚定下拉）：点开显示去重值清单（含计数），单选后网格只显示匹配行。
  /// 纯视图级过滤——行数据与勾选（按行身份持有）都不动，清除筛选即全部恢复。
  /// null（默认）= 普通表头。
  final String? Function(T row)? filterValueOf;

  /// 单元内部后缀装饰占宽（2026-09-09）：格内 ⓘ（UtenFieldHintIcon 44）或
  /// 下拉箭头（20）这类排在文本之后的固定装饰宽度。自动加宽量宽时叠加在
  /// [_cellChromeX] 上，否则装饰会吃掉文本宽度——110px 的币种列曾被 44px ⓘ
  /// 挤到看不见默认值。无后缀装饰的列保持 0。
  ///
  /// 2026-09-10 口径：凡单元可能出现「预填黄标/必填红标」状态图标的列（学习
  /// 预填的币种/汇率/税率/结账/供应商等），必须把 [UtenEditableGridCellSpec.hintIconWidth]
  /// （44）计入——状态图标由 UtenInputDecoration 在预填态动态塞进 suffix，
  /// 新单默认就是预填态，只按箭头 20 计会让默认值被裁成省略号。
  final double chromeWidth;
}

/// UtenEditableGrid 单元格统一规格（2026-09-10，一处定义全表生效）：
/// 圆角 = [UtenRadius.control]、内边距与全局 inputDecorationTheme 一致、
/// 单行；各列 cellBuilder **不得**自带 OutlineInputBorder/contentPadding/
/// bodySmall/maxLines:2——此前币种/供应商/仓库/车间格各画各的（6 圆角、
/// (10,8) 内边距、小字、双行）导致同一行格高、圆角、字号三种口径并存。
abstract final class UtenEditableGridCellSpec {
  /// 单元内输入框圆角（与全站控件圆角同源）。
  static const double radius = UtenRadius.control;

  /// 单元内输入框内边距（与 light/dark 主题 inputDecorationTheme 同值）。
  static const EdgeInsets contentPadding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 12,
  );

  /// 格内状态/说明图标（UtenFieldHintIcon）占宽，供 [EditableGridColumn.chromeWidth]
  /// 叠加：`chromeWidth: 20 + UtenEditableGridCellSpec.hintIconWidth`。
  static const double hintIconWidth = 44;

  /// 下拉/选择格的右侧展开箭头占宽。
  static const double dropdownChevronWidth = 20;
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
    final theme = Theme.of(context);
    final InputDecorationThemeData idt;
    if (_empty) {
      final errorColor = theme.colorScheme.error;
      // 把红框交给「内部输入框自己的边框」来画，而不是在外层叠一个 DecoratedBox：
      // 后者会被 TextField/InputDecorator 自带的灰色 OutlineInputBorder 盖住中段，只剩四角
      // 露红。这里覆盖后代 inputDecorationTheme 的各类边框为红色，让 child 自身边框变红。
      OutlineInputBorder redBorder({bool focused = false}) =>
          OutlineInputBorder(
            // 2026-09-09 统一口径：红框圆角与全局主题 UtenRadius.control(10) 一致，
            // 不再自带 6——同一格里红/常态切换圆角跳变。
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: errorColor, width: focused ? 2 : 1.5),
          );
      idt = theme.inputDecorationTheme.copyWith(
        enabledBorder: redBorder(),
        focusedBorder: redBorder(focused: true),
        border: redBorder(),
        errorBorder: redBorder(),
        focusedErrorBorder: redBorder(focused: true),
      );
    } else {
      // 非空：原样透传主题（不改边框）。
      idt = theme.inputDecorationTheme;
    }
    // 关键：无论是否为空，都返回「Theme > child」这一恒定结构。
    // 早先版本在非空时 `return widget.child;`（裸）、空时才 Theme 包裹——必填数字格（数量/
    // 单价）从空输入第一个有效字符时 _empty 由 true 翻 false，本方法根 widget 类型从 Theme
    // 变成 TextField，Flutter 会废弃并重建 TextField 的 Element → 焦点丢失（输入一位光标就
    // 消失，得再点一次才能继续输入）。这里两分支结构一致，_empty 翻转只改 Theme.data
    // （InheritedWidget 更新，不重建子树 Element），TextField Element 与焦点得以保持。
    // 一处改，全模块 grid（销售/采购/委外/生产/钱流/仓库）必填格统一生效。
    return Theme(
      data: theme.copyWith(inputDecorationTheme: idt),
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

  /// 移除所有满足 [test] 的行（删前 dispose）。「从上游引入」前清掉占位空白行用：
  /// 用户点引入时，新建态预填的那条空行（无货品、各字段空）应自动消失，直接显示引入项。
  void removeWhere(bool Function(T) test) {
    removeRows(_rows.where(test).toList());
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
  bool get allSelected => _rows.isNotEmpty && _rows.every(_selected.contains);
  bool get hasBuffer => _copyBuffer.isNotEmpty;

  /// 当前选中的行（快照；已删行自动排除）。批量操作（统一设供应商等）取此列表。
  List<T> get selectedRows =>
      List.unmodifiable(_selected.where(_rows.contains));

  void toggleSelect(T row) {
    if (!_selected.add(row)) _selected.remove(row);
    notifyListeners();
  }

  /// 批量置选/取消一组行（行级门控 + controller 模式的表头全选用）；其余行不动。
  void setSelected(Iterable<T> rows, bool selected) {
    var changed = false;
    for (final row in rows) {
      if (selected) {
        changed = _selected.add(row) || changed;
      } else {
        changed = _selected.remove(row) || changed;
      }
    }
    if (changed) notifyListeners();
  }

  void selectAll() {
    if (_rows.every(_selected.contains)) {
      _selected.clear();
    } else {
      _selected.addAll(_rows);
    }
    notifyListeners();
  }

  /// 行菜单打开前的选中归位：该行已在选中集 → 不动（保留多选，菜单作用于整组）；
  /// 不在 → 选择集替换为仅该行（文件管理器语义，与 MasterDataTableView 右键一致）。
  void selectOnly(T row) {
    if (_selected.contains(row)) return;
    _selected
      ..clear()
      ..add(row);
    notifyListeners();
  }

  /// 清空全部选中。上下文菜单中的动作完成后统一调用，避免操作对象继续残留高亮。
  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
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
/// 横向滚动（共用 UtenHScrollArea：内容矮→横滚条紧贴末行下；内容高→钉视口底）+ 增删行。
class UtenEditableGrid<T extends EditableGridRow> extends StatefulWidget {
  const UtenEditableGrid({
    super.key,
    required this.controller,
    required this.columns,
    this.createBlankRow,
    this.footer,
    this.showRowDelete = true,
    this.showAddRow = true,
    this.addRowLabel = '添加行',
    this.addRowsLabel = '添加多行',
    this.emptyMessage = '暂无明细，点击下方按钮添加',
    this.confirmDelete = true,
    this.deleteConfirmLabel = '确认删除该行明细？',
    this.cloneRow,
    this.batchActionsBuilder,
    this.selectable = false,
    this.selectionEnabled = true,
    this.canSelectRow,
    this.selectedOf,
    this.onRowSelect,
    this.rowColor,
    this.onRemoveRows,
    this.removeRowsActionLabel = '删除选中',
    this.removeRowsDialogTitle = '批量删除',
    this.removeRowsConfirmLabel = '删除',
    this.removeRowsMessageBuilder,
    this.rowMenuExtraBuilder,
    this.showColumnSettings = false,
    this.initialColumnOrder,
    this.initialHiddenColumnKeys,
    this.onColumnSettingsChanged,
    this.showSelectAllToggle = true,
  }) : assert(
         !showAddRow || createBlankRow != null,
         'showAddRow=true 必须提供 createBlankRow（「添加行」按钮需要构造空行）',
       );

  final UtenEditableGridController<T> controller;
  final List<EditableGridColumn<T>> columns;

  /// 构造一个空行（"添加行"/"添加多行"用）。showAddRow=false 的只选/只读场景可省。
  final T Function()? createBlankRow;

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

  /// 操作条附加批量动作（插在「全选」之后、「复制/批量删除」之前）。
  /// 按选中数即时刷新（订阅 controller）；如订货单「统一设供应商 (n)」。
  final List<Widget> Function(
    BuildContext context,
    UtenEditableGridController<T> controller,
  )?
  batchActionsBuilder;

  /// 是否显示行首选选列（与 [showAddRow] 解耦）：任务办理表只要勾选 + 个别可编辑
  /// 单元、不要增删行操作条时置 true。编辑模式（showAddRow）天然隐含选列。
  final bool selectable;

  /// 选择及其派生操作的全局门控。false 时保留复选列和操作条布局，但禁用表头全选、
  /// 行复选、批量动作以及行右键/长按菜单。用于保存/提交期间防止选择集与请求快照漂移。
  /// 不影响表头设置，也不替调用方禁用单元格编辑或底部新增按钮。
  final bool selectionEnabled;

  /// 行级可选门控：返回 false 的行复选框禁用、表头全选跳过（如无待办量的行不可勾）。
  /// 编辑模式不传时全行可选（原语义）。
  final bool Function(T row)? canSelectRow;

  /// 外部受控选中判定：非空时行复选框与表头三态全选都读它（单一真值源在调用方，
  /// 如行 model 的 selected 字段），controller 内部选中集不再参与本模式。
  final bool Function(T row)? selectedOf;

  /// 外部受控切换回调（与 [selectedOf] 配对）：复选框/全选把新值回交调用方。
  final void Function(T row, bool next)? onRowSelect;

  /// 行语义底色（按行数据定，如不合格=浅红）；null = 默认斑马纹。选中行统一用
  /// 高亮色覆盖，避免颜色叠加后文字对比不足（与 MasterDataTableView.rowColor 同款语义）。
  final Color? Function(T row)? rowColor;

  /// 任务办理表的“从本次操作移出”回调。非空时，即使 [showAddRow] 为 false，
  /// 也显示选择操作条并给行挂右键/长按菜单。组件只负责确认与选择语义；调用方决定
  /// 是临时移出、软删除还是其它业务动作，避免把上游来源行误当数据库删除。
  final void Function(List<T> rows)? onRemoveRows;
  final String removeRowsActionLabel;
  final String removeRowsDialogTitle;
  final String removeRowsConfirmLabel;
  final String Function(int count)? removeRowsMessageBuilder;

  /// 行右键/长按菜单的附加条目（作用于**当前选择集**，菜单打开前已完成选中归位）。
  ///
  /// 非空时即使 `showAddRow=false` 且没有 [onRemoveRows]（纯勾选办理表）也会挂菜单
  /// ——下达车间/采购/委外这类页面需要「批量清空可填内容」这样的整组动作
  /// （2026-09-11 用户要求）。条目自身负责权限与禁用态。
  final List<UtenContextMenuEntry> Function(
    BuildContext context,
    List<T> selected,
  )?
  rowMenuExtraBuilder;

  /// 显示「表头设置 x/y」：支持列显隐、拖拽排序、恢复默认；表头纵向拖出也可隐藏。
  /// 默认关闭以保持既有嵌入式/任务表布局不变，业务编辑页按需开启。
  final bool showColumnSettings;

  /// 列设置持久化（与 [showColumnSettings] 配用，由宿主页注入；典型宿主是
  /// UtenPagePrefsNotifier 子类）。key 均为稳定列 key：未知 key 忽略、新增列
  /// 追加到末尾；若持久化状态把所有列都隐藏了则回落为全显示（至少保留一列）。
  /// 宿主回调 -> 更新 prefs -> 重建本组件传入新 initial 值时，这里只重放不回写，
  /// 不会形成通知回环。
  final List<String>? initialColumnOrder;
  final Set<String>? initialHiddenColumnKeys;
  final void Function(List<String> order, Set<String> hidden)?
  onColumnSettingsChanged;

  /// 操作条是否渲染「全选/取消全选」按钮（默认 true）。批量下达类页面（表头
  /// 复选框已覆盖当页选择、跨页由页面自管）传 false 收敛入口。
  final bool showSelectAllToggle;

  /// 是否渲染行首选选列。
  bool get _showSelect => showAddRow || selectable;

  @override
  State<UtenEditableGrid<T>> createState() => _UtenEditableGridState<T>();
}

class _UtenEditableGridState<T extends EditableGridRow>
    extends State<UtenEditableGrid<T>>
    with UtenColumnHeaderDragHost<UtenEditableGrid<T>> {
  // 表头/表体 双向横滚同步（两 ScrollController + _syncing 防回环）；表体横滚条
  // （含钉底条）整体走共用 UtenHScrollArea，其内部自行与注入的 _bodyH 同步。
  late final ScrollController _headerH;
  late final ScrollController _bodyH;
  bool _syncing = false;

  /// 选择列宽（批量模式行首 checkbox）。
  static const double _selectColWidth = 44;

  /// 表尾「添加行/添加多行 + 合计」并作一行的最小可用宽度。
  /// 低于此宽两者分两行——两个按钮约 200、合计条多单位/多币别时轻松超 300，
  /// 硬挤在一行会把金额压成省略号。
  static const double _footerSingleRowMinWidth = 560;

  // —— sticky 表头 测量与位置状态 ——
  /// 网格 Stack / 表头单元 / 表体区 的测量键（post-frame 量全局位置用）。
  final GlobalKey _gridKey = GlobalKey();
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _bodyKey = GlobalKey();

  /// 表头覆盖层在网格内的 local top（0=自然位，表头就在网格顶；
  /// 页面上滑把表头顶到视口顶后=吸附位；表体尾部上推时随尾部推出）。
  final ValueNotifier<double> _headerY = ValueNotifier<double>(0);

  /// 表头实测高度（流内占位用；首帧用兜底值，post-frame 实测修正）。
  double _headerHeight = 40;

  /// 页面滚动监听（最近的祖先 Scrollable 的 position，单据编辑页的页面 ListView）。
  ScrollPosition? _pagePos;

  // 当前列宽（可被用户拖拽覆盖）；列集合变化时按 columns.width 重置。
  List<double> _widths = const [];

  /// 列顺序与显隐默认属于当前页面会话；宿主注入 [UtenEditableGrid.initialColumnOrder]
  /// 等持久化参数后跨会话保留。key 是稳定真值，宽度仍按原 columns 下标保存。
  List<String> _columnOrder = const [];
  final Set<String> _hiddenColumnKeys = <String>{};

  /// 本次会话内用户是否已手动改过列设置：改过之后迟到抵达的服务端偏好不再
  /// 覆盖本地（详见 [_applyInitialColumnSettings]）。
  bool _userTouchedColumns = false;

  /// 列下标→LayerLink：每列表头包一个 CompositedTransformTarget，跟手浮层（共用
  /// [UtenColumnDragHideHost]）锚定到"当前拖拽列"的 target。列集合变化时清空重建。
  final Map<int, LayerLink> _colLinks = {};

  @override
  LayerLink columnDragLink(int i) =>
      _colLinks.putIfAbsent(i, () => LayerLink());

  @override
  double columnDragWidth(int i) =>
      i < _widths.length ? _widths[i] : _minColWidth;

  @override
  String columnDragLabel(int i) =>
      i < widget.columns.length ? widget.columns[i].label : '';

  /// 该列当前可否拖出隐藏：仅开启表头设置时可用；至少保留一列可见；
  /// 必填列锁定（必填项不允许从界面上消失，表头设置同款口径）。
  @override
  bool columnCanDragHide(int i) =>
      widget.showColumnSettings &&
      i < widget.columns.length &&
      _visibleColumnCount > 1 &&
      !widget.columns[i].required;

  @override
  void onColumnDragHide(int i) => _toggleColumn(widget.columns[i].key);

  /// 编辑明细表的表头手势跟随表头设置开关：未开启列设置的页面保持固定布局。
  @override
  bool get columnHeaderHideEnabled => widget.showColumnSettings;

  @override
  bool get columnHeaderReorderEnabled => widget.showColumnSettings;

  @override
  List<({int index, double width})> get reorderVisibleColumns => [
    for (final i in _visibleColumnIndices) (index: i, width: _widths[i]),
  ];

  /// 横拖换位落位：在**可见列序列**内搬移；隐藏列保持原相对锚位（对 _columnOrder
  /// 做可见子序列替换），随后走既有持久化回调（与表头设置弹窗拖拽同一出口）。
  @override
  void onColumnsReordered(int fromOriginalIndex, int slot) {
    final visible = _visibleColumnIndices;
    final fromPos = visible.indexOf(fromOriginalIndex);
    if (fromPos < 0) return;
    final seq = [...visible]..removeAt(fromPos);
    final target = slot.clamp(0, seq.length);
    if (target == fromPos) return;
    seq.insert(target, fromOriginalIndex);
    final newVisibleKeys = <String>{for (final i in seq) widget.columns[i].key};
    final queue = <String>[for (final i in seq) widget.columns[i].key];
    setState(() {
      _columnOrder = [
        for (final key in _columnOrder)
          newVisibleKeys.contains(key) ? queue.removeAt(0) : key,
      ];
    });
    _notifyColumnSettingsChanged();
  }

  /// 列宽拖拽命中区半宽（贴列右边界，半溢出到相邻列）。
  static const double _gripHalf = 4;

  /// 列宽下限（防拖没）。
  static const double _minColWidth = 48;

  /// 删除列宽（行尾 × 按钮）。
  static const double _deleteColWidth = 48;

  // —— 列宽随内容自动加宽（textOf/listenableOf 列）——
  /// 用户已手动拖拽过的列 key：锁定用户宽度，不再随内容自动加宽；列集合变化
  /// （如切 docType）时随列宽一起重置。与 MasterDataTableView._manualResized
  /// 同款语义（那边按下标存、这边列有 key 按 key 存）。
  final Set<String> _manualResized = {};

  /// 自动加宽待重算标记：初始行 / 行集变化时置 true，build 里量完清掉。
  bool _autoGrowDirty = true;

  /// 上次量宽的字号系数与文字样式快照：敲字监听回调里拿不到 BuildContext，
  /// 复用 build 时捕获的（bodyLarge + tabular 数字，覆盖 TextField/Text 两种单元）。
  TextScaler? _lastScaler;
  TextStyle _measureStyle = const TextStyle();

  /// 已挂自动加宽监听的行快照：按对象身份比对，行集变化才拆线重挂
  /// （勾选/全选等 notifyListeners 不动行集，不触发重挂）。
  List<T> _wiredRows = const [];
  List<VoidCallback> _autoGrowUnsubs = const [];

  /// 自动加宽上限：超长文本（如备注）封顶后单元内横向滚动，用户可再手动拖宽。
  static const double _maxColWidth = 480;

  /// 自动加宽取样行数：初始行/整批换行时量前 N 行的最宽值即可（与
  /// MasterDataTableView 自动适配同款取舍；更靠后的行靠"边输入边加宽"兜底）。
  static const int _autoGrowSampleSize = 200;

  /// 单元横向装饰总宽：格 Padding(8×2) + 输入框 contentPadding(14×2，全局
  /// inputDecorationTheme)。只读 Text 单元实为 40（12+8×2），按 44 量略偏宽——
  /// 只增不减语义下偏宽无害。
  static const double _cellChromeX = 44;

  // —— 表头最小可读宽（2026-09-11）——
  // 此前只按单元内容量宽，表头标签从不参与：声明宽偏窄的列（如「缺口 ⓘ」）
  // 一进页面标签就被省略号吃掉，只剩一个 ⓘ 图标，用户根本不知道这列是什么。
  /// 表头左右内边距（与 [_headerLabel] / GridHeaderFilterCell 同值）。
  static const double _headerPadX = UtenSpacing.s12;

  /// 表头筛选下拉箭头（18）+ 与标签的间距。
  static const double _headerArrowWidth = 22;

  /// 表头 ⓘ 说明图标命中区（UtenFieldHintIcon dense = 28）。
  static const double _headerInfoIconWidth = 28;

  /// 表头量宽富余（防贴边省略号）。
  static const double _headerBuffer = 6;

  /// 加宽富余：一次加到位后预留几个字符的余量，避免每敲一个字都触发布局。
  static const double _autoGrowBuffer = 24;

  @override
  void initState() {
    super.initState();
    _headerH = ScrollController();
    _bodyH = ScrollController();
    _headerH.addListener(() => _sync(_headerH));
    _bodyH.addListener(() => _sync(_bodyH));
    _widths = widget.columns
        .map((c) => c.width.clamp(_minColWidth, double.infinity))
        .toList();
    _columnOrder = widget.columns.map((column) => column.key).toList();
    _applyInitialColumnSettings();
    // 挂各行自动加宽监听（初始行已带内容时首帧即量宽撑列）。
    _rewireAutoGrowListeners();
    // 增删行改变表体高度 → sticky 表头位置需重算。
    widget.controller.addListener(_onControllerChanged);
    _scheduleStickyUpdate();
  }

  @override
  void didUpdateWidget(covariant UtenEditableGrid<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列集合变了（数量或 key 序列不同，如切换 docType）→ 按新 columns.width 重置列宽，
    // 清手动锁定（新列集合下标/语义已变），重挂监听并重算自动加宽。
    if (!_sameColumnKeys(oldWidget.columns, widget.columns)) {
      _widths = widget.columns
          .map((c) => c.width.clamp(_minColWidth, double.infinity))
          .toList();
      _manualResized.clear();
      _columnOrder = widget.columns.map((column) => column.key).toList();
      _hiddenColumnKeys.clear();
      _applyInitialColumnSettings();
      // 列集合换了（切 docType/换段）→ 旧列 key 上的表头筛选一并作废，避免
      // 「看不见的筛选」把新列集合下的行全滤掉。
      _columnFilters.clear();
      columnHeaderDragReset(); // 拖拽态/跟手浮层可能指向失效下标，重置。
      _colLinks.clear(); // 旧下标的 LayerLink 作废，按新列集合下标重建。
      _autoGrowDirty = true;
      _rewireAutoGrowListeners(force: true);
    } else if (!_sameInitialColumnSettings(oldWidget)) {
      // 列集合未变但宿主注入的持久化值变了（如登录后服务端偏好迟到）：
      // 用户本次会话已手动改过列设置则尊重本地，否则按新值重放。
      if (!_userTouchedColumns) {
        _columnOrder = widget.columns.map((column) => column.key).toList();
        _hiddenColumnKeys.clear();
        _applyInitialColumnSettings();
      }
    }
    // 行控制器换实例 → 重挂监听（增删行驱动 sticky 位置重算 + 自动加宽绑到新行集）。
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _autoGrowDirty = true;
      _rewireAutoGrowListeners(force: true);
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

  bool _sameInitialColumnSettings(covariant UtenEditableGrid<T> oldWidget) {
    if (identical(oldWidget.initialColumnOrder, widget.initialColumnOrder) &&
        identical(
          oldWidget.initialHiddenColumnKeys,
          widget.initialHiddenColumnKeys,
        )) {
      return true;
    }
    if (!setEquals(
      oldWidget.initialHiddenColumnKeys ?? const <String>{},
      widget.initialHiddenColumnKeys ?? const <String>{},
    )) {
      return false;
    }
    return listEquals(
      oldWidget.initialColumnOrder ?? const <String>[],
      widget.initialColumnOrder ?? const <String>[],
    );
  }

  /// 应用宿主注入的持久化列设置：未知 key 忽略、缺失列按默认序追加；若持久化
  /// 状态把所有列都隐藏了则回落为全显示（与「至少保留一列」兜底同口径）。
  /// 只重放不回写——宿主回调更新 prefs 后传回的新 initial 值走到这里时，
  /// 值与当前一致，不会形成通知回环。
  void _applyInitialColumnSettings() {
    final order = widget.initialColumnOrder;
    final hidden = widget.initialHiddenColumnKeys;
    if (order == null && hidden == null) return;
    final known = widget.columns.map((column) => column.key).toList();
    final knownSet = known.toSet();
    final seen = <String>{};
    final merged = <String>[
      for (final key in order ?? const <String>[])
        if (knownSet.contains(key) && seen.add(key)) key,
      for (final key in known)
        if (!seen.contains(key)) key,
    ];
    final hiddenKeys = <String>{
      for (final key in hidden ?? const <String>[])
        if (knownSet.contains(key)) key,
    };
    if (hiddenKeys.containsAll(merged)) hiddenKeys.clear();
    _columnOrder = merged;
    _hiddenColumnKeys
      ..clear()
      ..addAll(hiddenKeys);
  }

  void _notifyColumnSettingsChanged() {
    _userTouchedColumns = true;
    widget.onColumnSettingsChanged?.call(
      List.unmodifiable(_columnOrder),
      Set.unmodifiable(_hiddenColumnKeys),
    );
  }

  List<int> get _visibleColumnIndices {
    final indicesByKey = <String, int>{
      for (var i = 0; i < widget.columns.length; i++) widget.columns[i].key: i,
    };
    final result = <int>[];
    for (final key in _columnOrder) {
      final index = indicesByKey[key];
      if (!_hiddenColumnKeys.contains(key) && index != null) result.add(index);
    }
    return result;
  }

  int get _visibleColumnCount =>
      widget.columns.length - _hiddenColumnKeys.length;

  void _toggleColumn(String key) {
    var changed = false;
    setState(() {
      if (_hiddenColumnKeys.contains(key)) {
        _hiddenColumnKeys.remove(key);
        changed = true;
      } else if (_visibleColumnCount > 1) {
        _hiddenColumnKeys.add(key);
        changed = true;
      }
    });
    if (changed) _notifyColumnSettingsChanged();
  }

  /// 全选(true)=全部显示；取消全选(false)=仅留首列（必填列始终保留）。
  void _toggleAllColumns(bool showAll) {
    setState(() {
      _hiddenColumnKeys.clear();
      if (!showAll && widget.columns.length > 1) {
        final keep = <String>{widget.columns.first.key};
        for (final column in widget.columns) {
          if (column.required) keep.add(column.key);
        }
        _hiddenColumnKeys.addAll(
          widget.columns.where((c) => !keep.contains(c.key)).map((c) => c.key),
        );
      }
    });
    _notifyColumnSettingsChanged();
  }

  /// 拖拽排序：[newIndex] 为 removeAt 后的最终插入位（onReorderItem 口径）。
  void _reorderColumns(int oldIndex, int newIndex) {
    setState(() {
      final key = _columnOrder.removeAt(oldIndex);
      _columnOrder.insert(newIndex, key);
    });
    _notifyColumnSettingsChanged();
  }

  /// 恢复默认：清隐藏 + 回默认列序。
  void _resetColumnSettings() {
    setState(() {
      _columnOrder = widget.columns.map((column) => column.key).toList();
      _hiddenColumnKeys.clear();
    });
    _notifyColumnSettingsChanged();
  }

  /// 双向横滚同步：表头 / 表体 任一滚动 → 另一个 jumpTo 跟随（[_syncing] 防回环；
  /// 未挂载的控制器跳过，挂上后由下一次同步追平。表体内的钉底横滚条由
  /// UtenHScrollArea 监听 _bodyH 自行跟随）。
  void _sync(ScrollController src) {
    if (_syncing || !src.hasClients) return;
    _syncing = true;
    for (final d in [_headerH, _bodyH]) {
      if (!identical(d, src) && d.hasClients) d.jumpTo(src.offset);
    }
    _syncing = false;
  }

  /// 布局完成后重算 sticky 表头位置（渲染对象须完成 layout 才能量）。
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
    // 行集变化（增删/替换/粘贴）→ 拆线重挂自动加宽监听 + 标记整体重算列宽 +
    // 撤掉已失效的表头筛选值；仅选择变化的通知不动行集，三个操作都跳过。
    if (_rewireAutoGrowListeners()) {
      _autoGrowDirty = true;
      _pruneColumnFilters();
    }
    _scheduleStickyUpdate();
    setState(() {});
  }

  /// 量网格/表头/表体与页面视口的全局位置，算出 sticky 表头覆盖层的位置：
  /// local top 0=自然位（表头就在网格顶，不原地固定）；页面上滑把表头顶到视口顶后
  /// 钉住；表体尾部上推时表头随尾部一起推出（pushed sticky，不悬空）。
  /// （钉底横滚条不在本组件——表体横滚整体走共用 UtenHScrollArea。）
  void _updateSticky() {
    if (!mounted) return;
    final gridCtx = _gridKey.currentContext;
    final gridBox = gridCtx?.findRenderObject() as RenderBox?;
    final headerBox =
        _headerKey.currentContext?.findRenderObject() as RenderBox?;
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

    // sticky 表头：自然位 local 0；表头随页面上滑到视口顶才吸附；表体尾部把表头顶出。
    var headerY = vpTop - gridTop;
    if (headerY < 0) headerY = 0;
    final headerMaxY = bodyBottom - gridTop - headerH;
    if (headerY > headerMaxY) headerY = headerMaxY < 0 ? 0 : headerMaxY;
    if (_headerY.value != headerY) _headerY.value = headerY;
  }

  /// 拖拽改第 [index] 列宽：按本次横向增量更新，下限 [_minColWidth] 防拖没。
  /// 手动拖过的列即锁定（进 [_manualResized]），不再随内容自动加宽——用户拖到哪就
  /// 停在哪（缩小的位置就是默认位置），列集合变化时才随列宽重置一起解锁。
  void _resizeColumn(int index, double dx) {
    final next = _widths[index] + dx;
    if (next < _minColWidth) return;
    _manualResized.add(widget.columns[index].key);
    setState(() => _widths[index] = next);
  }

  /// 拆/挂各行的自动加宽监听：列同时提供 [EditableGridColumn.textOf] 与
  /// [EditableGridColumn.listenableOf] 才订阅（只量不挂的只读列除外）。
  /// 返回行集是否变化。[force]=true 强制重挂（列集合或 controller 实例变化，
  /// 行集不变也要换绑，否则闭包里的列下标已失效）。
  bool _rewireAutoGrowListeners({bool force = false}) {
    final rows = widget.controller.rows;
    if (!force && _sameRowIdentities(_wiredRows, rows)) return false;
    for (final u in _autoGrowUnsubs) {
      u();
    }
    _wiredRows = List.of(rows);
    final unsubs = <VoidCallback>[];
    for (var i = 0; i < widget.columns.length; i++) {
      final textOf = widget.columns[i].textOf;
      final listenableOf = widget.columns[i].listenableOf;
      if (textOf == null || listenableOf == null) continue;
      for (final row in rows) {
        final listenable = listenableOf(row);
        if (listenable == null) continue;
        void onChanged() => _onAutoGrowCellChanged(i, row);
        listenable.addListener(onChanged);
        unsubs.add(() => listenable.removeListener(onChanged));
      }
    }
    _autoGrowUnsubs = unsubs;
    return true;
  }

  bool _sameRowIdentities(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  /// 某格内容变了（敲字/点选货品/换下拉值）：量该格新文本宽，超宽自动加列宽。
  /// 一次只量一格（TextPainter 单行布局，微秒级），不触碰其他行。
  void _onAutoGrowCellChanged(int index, T row) {
    if (!mounted) return;
    if (index >= widget.columns.length || index >= _widths.length) return;
    final col = widget.columns[index];
    if (_manualResized.contains(col.key)) return;
    final scaler = _lastScaler;
    final textOf = col.textOf;
    if (scaler == null || textOf == null) return; // 首帧未量过，由 build 兜底。
    final next = _growOnly(
      _widths[index],
      _measureText(textOf(row), _measureStyle, scaler) +
          _cellChromeX +
          col.chromeWidth +
          _autoGrowBuffer,
    );
    if (next > _widths[index]) {
      setState(() => _widths[index] = next);
    }
  }

  /// 自动加宽量宽入口（build 首行调用）：首帧 / 行集变化 / 字号档变化时，对所有
  /// 提供 textOf 且未被手动锁定的列量前 [_autoGrowSampleSize] 行的最宽文本。
  /// 只增不减（普通行集变化不会把列缩回去）；字号档变化时回列定义基准重算（可缩，
  /// 保证系统改大字号后列重新适配）。量宽直接写 [_widths]，同帧布局即用新值
  /// （与 MasterDataTableView._ensureWidths 同款做法，不经 setState）。
  void _ensureAutoFit(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final scaleChanged =
        _lastScaler != null && _lastScaler!.scale(1) != scaler.scale(1);
    if (_lastScaler == null || scaleChanged) _autoGrowDirty = true;
    _lastScaler = scaler;
    // TextField 单元默认 bodyLarge（16px），只读 Text 单元为 bodyMedium（14px）；
    // 统一按 bodyLarge + tabular 数字量（偏宽不超过一档，只增不减下无害）。
    _measureStyle = (Theme.of(context).textTheme.bodyLarge ?? const TextStyle())
        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    if (!_autoGrowDirty) return;
    _autoGrowDirty = false;
    final rows = widget.controller.rows;
    final sample = rows.length < _autoGrowSampleSize
        ? rows.length
        : _autoGrowSampleSize;
    final headerStyle =
        (Theme.of(context).textTheme.labelMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w700,
        );
    for (var i = 0; i < widget.columns.length && i < _widths.length; i++) {
      final col = widget.columns[i];
      if (_manualResized.contains(col.key)) continue;
      var w = scaleChanged
          ? col.width.clamp(_minColWidth, double.infinity)
          : _widths[i];
      // 表头地板：所有列都参与（不限于提供 textOf 的列）——标签本身必须显示全。
      w = _growOnly(w, _headerNeededWidth(col, headerStyle, scaler));
      final textOf = col.textOf;
      if (textOf != null) {
        for (var r = 0; r < sample; r++) {
          w = _growOnly(
            w,
            _measureText(textOf(rows[r]), _measureStyle, scaler) +
                _cellChromeX +
                col.chromeWidth +
                _autoGrowBuffer,
          );
        }
      }
      _widths[i] = w;
    }
  }

  /// 该列表头完整显示所需宽度：标签（含必填星号）+ 左右内边距 + 下拉箭头 / ⓘ 图标。
  double _headerNeededWidth(
    EditableGridColumn<T> col,
    TextStyle headerStyle,
    TextScaler scaler,
  ) {
    final label = col.required ? '${col.label} *' : col.label;
    return _measureText(label, headerStyle, scaler) +
        _headerPadX * 2 +
        (col.filterValueOf != null ? _headerArrowWidth : 0) +
        (col.headerInfo != null ? _headerInfoIconWidth : 0) +
        _headerBuffer;
  }

  /// 只增不减：needed 不超 current 时不变；超过则封顶 [_maxColWidth]。
  /// current ≥ 上限时保持（列定义初始宽本身超限时尊重初始宽，不自动收窄）。
  double _growOnly(double current, double needed) {
    if (needed <= current || current >= _maxColWidth) return current;
    return needed.clamp(current, _maxColWidth);
  }

  /// 测量单行文本渲染宽度（TextPainter，maxLines:1）。测完 dispose 防泄漏。
  /// [textScaler] 必须传当前生效的字号系数——单元文字渲染会自动吃该缩放，
  /// 量宽不带则按 1.0 量偏窄（与 MasterDataTableView._measureText 同款实现）。
  double _measureText(String text, TextStyle style, TextScaler textScaler) {
    if (text.isEmpty) return 0;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  double get _totalWidth =>
      (widget._showSelect ? _selectColWidth : 0) +
      _visibleColumnIndices.fold(0.0, (sum, index) => sum + _widths[index]) +
      (widget.showRowDelete ? _deleteColWidth : 0);

  @override
  void dispose() {
    _pagePos?.removeListener(_scheduleStickyUpdate);
    widget.controller.removeListener(_onControllerChanged);
    for (final u in _autoGrowUnsubs) {
      u();
    }
    _autoGrowUnsubs = const [];
    _headerY.dispose();
    _headerH.dispose();
    _bodyH.dispose();
    super.dispose();
  }

  /// 表头首格的冻结包裹：无选择列时原样返回（零开销）。
  Widget _withFrozenSelectAll(ThemeData theme, Widget row) {
    if (!widget._showSelect) return row;
    return UtenFrozenLeadingColumn(
      horizontal: _headerH,
      width: _selectColWidth,
      cell: _selectAllHeaderCell(theme),
      row: row,
    );
  }

  /// 表头全选 checkbox 的格子内容（批量模式表头首列；读写由 controller 或外部
  /// 受控回调驱动）。外层由 [UtenFrozenLeadingColumn] 钉在视口左缘。
  Widget _selectAllHeaderCell(ThemeData theme) {
    final targets = _selectableRows();
    final selected = _rowIsSelected;
    final all = targets.isNotEmpty && targets.every(selected);
    final some = !all && targets.any(selected);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(right: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Checkbox(
        value: all ? true : (some ? null : false),
        tristate: true,
        onChanged: !widget.selectionEnabled || targets.isEmpty
            ? null
            : (_) => _toggleSelectAllRows(targets, all),
      ),
    );
  }

  /// 参与全选的行（canSelectRow 门控后；无门控 = 全部行）。表头筛选活跃时只含
  /// 当前可见（未被筛掉）的行——全选作用于眼前所见。
  List<T> _selectableRows() {
    final test = widget.canSelectRow;
    var rows = widget.controller.rows;
    rows = _filterRows(rows);
    return test == null ? rows : rows.where(test).toList();
  }

  // ======================= 表头筛选（filterValueOf，2026-09-05） =======================
  /// key=列 key，value=选中筛选值；null（或不在 map）=「所有」。纯视图级过滤：
  /// 行数据与选中集（按行身份持有）都不动，清除即全部恢复。
  final Map<String, String?> _columnFilters = {};

  bool get _hasColumnFilters => _columnFilters.values.any((v) => v != null);

  /// 行集变化（换段/重载/批量动作后重建行）后，把「已不在任何行上出现」的筛选值
  /// 撤回「所有」。不撤的话表头单元会 sanitize 回列名（看起来没筛选），表体却仍
  /// 按旧值过滤 → 用户面对一张空表却找不到筛选入口（2026-09-11 表头快速筛选补齐）。
  void _pruneColumnFilters() {
    if (!_hasColumnFilters) return;
    final rows = widget.controller.rows;
    final columnsByKey = <String, EditableGridColumn<T>>{
      for (final column in widget.columns) column.key: column,
    };
    _columnFilters.removeWhere((key, value) {
      if (value == null) return true;
      final filterValueOf = columnsByKey[key]?.filterValueOf;
      if (filterValueOf == null) return true;
      return !rows.any((row) => filterValueOf(row) == value);
    });
  }

  /// 应用全部列筛选后的行集（无筛选 = 原样返回）。
  List<T> _filterRows(List<T> rows) {
    if (!_hasColumnFilters || widget.columns.isEmpty) return rows;
    final active = <(EditableGridColumn<T>, String)>[
      for (final column in widget.columns)
        if (column.filterValueOf != null && _columnFilters[column.key] != null)
          (column, _columnFilters[column.key]!),
    ];
    if (active.isEmpty) return rows;
    return rows
        .where(
          (row) =>
              active.every((entry) => entry.$1.filterValueOf!(row) == entry.$2),
        )
        .toList(growable: false);
  }

  /// 某筛选列的去重取值与计数（按值稳定排序；空值不计入桶，走 nullCount）。
  List<({String value, String display, int count})> _filterBuckets(
    EditableGridColumn<T> column,
  ) {
    final counts = <String, int>{};
    for (final row in widget.controller.rows) {
      final value = column.filterValueOf!(row);
      if (value == null || value.trim().isEmpty) continue;
      counts[value] = (counts[value] ?? 0) + 1;
    }
    return [
      ...counts.entries.map(
        (entry) => (value: entry.key, display: entry.key, count: entry.value),
      ),
    ]..sort((a, b) => a.display.compareTo(b.display));
  }

  int _filterNullCount(EditableGridColumn<T> column) {
    var nullCount = 0;
    for (final row in widget.controller.rows) {
      final value = column.filterValueOf!(row);
      if (value == null || value.trim().isEmpty) nullCount++;
    }
    return nullCount;
  }

  /// 行选中判定：外部受控（selectedOf）优先，否则读 controller 内部选中集。
  bool Function(T row) get _rowIsSelected =>
      widget.selectedOf ?? widget.controller.isSelected;

  /// 行复选框切换回调：外部受控模式回交调用方（带翻转后的新值），
  /// 否则走 controller.toggleSelect（不可选行返回 null → 复选框禁用）。
  VoidCallback? _rowOnSelect(T row) {
    if (!widget.selectionEnabled) return null;
    if (widget.canSelectRow != null && widget.canSelectRow!(row) == false) {
      return null;
    }
    final external = widget.onRowSelect;
    if (external != null) {
      return () => external(row, !_rowIsSelected(row));
    }
    return () => widget.controller.toggleSelect(row);
  }

  /// 表头三态全选：目标行已全选 → 全部取消；否则全部选中。外部受控模式逐行回调；
  /// controller 模式且带行级门控时批量置集（一次通知），无门控保持原 selectAll 语义。
  void _toggleSelectAllRows(List<T> targets, bool allSelected) {
    if (!widget.selectionEnabled) return;
    final external = widget.onRowSelect;
    if (external != null) {
      for (final row in targets) {
        external(row, !allSelected);
      }
      return;
    }
    if (widget.canSelectRow == null) {
      widget.controller.selectAll();
      return;
    }
    widget.controller.setSelected(targets, !allSelected);
  }

  @override
  Widget build(BuildContext context) {
    _ensureAutoFit(context); // 随内容自动加宽：首帧/行集/字号档变化时量宽（手动锁定列除外）。
    final theme = Theme.of(context);
    final visibleColumnIndices = _visibleColumnIndices;
    final total = _totalWidth;
    final divider = BorderSide(
      color: theme.colorScheme.outlineVariant,
      width: 0.5,
    );
    final headerUnit = KeyedSubtree(
      key: _headerKey,
      child: _buildHeaderUnit(theme, total, visibleColumnIndices),
    );
    // 首帧/数据/布局变化后，post-frame 重算 sticky 表头位置。
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
            // 表体：content-tall（shrinkWrap），横滚条走共用 UtenHScrollArea——
            // 内容不超高 → 末行下方紧贴的自然滚动条；超高 → 钉视口底。
            KeyedSubtree(
              key: _bodyKey,
              child: UtenHScrollArea(
                controller: _bodyH,
                child: SizedBox(
                  width: total,
                  child: ListenableBuilder(
                    listenable: widget.controller,
                    builder: (context, _) {
                      final all = widget.controller.rows;
                      if (all.isEmpty) {
                        return _EmptyRows(message: widget.emptyMessage);
                      }
                      // 表头筛选为视图级过滤：只影响可见行集，不动数据与选中。
                      final rows = _filterRows(all);
                      if (rows.isEmpty) {
                        return const _EmptyRows(message: '没有符合表头筛选条件的行');
                      }
                      return ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        itemCount: rows.length,
                        itemBuilder: (context, i) => RepaintBoundary(
                          // 隔离行重绘：列宽拖拽/选中/粘性头重排时只绘本行，不蔓延整表与外层页面。
                          child: _rowCellOrMenuRegion(
                            rows[i],
                            i,
                            divider,
                            visibleColumnIndices,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            // 表尾一条线：左「添加行/添加多行」、右合计。此前两者各占一行，
            // 明细表下方白白多出一条高度（用户 2026-09-11 明确要求并作一行）。
            // 窄视口（<[_footerSingleRowMinWidth]）退回上下两行：一行塞不下时
            // 强挤会把合计压成省略号，而合计是不能看不清的数字。
            if (widget.showAddRow || widget.footer != null)
              LayoutBuilder(
                builder: (context, c) {
                  final addBar = widget.showAddRow
                      ? _AddRowBar(
                          onAddOne: () => widget.controller.addRow(
                            widget.createBlankRow!(),
                          ),
                          onAddMany: () async {
                            final n = await _showAddRowsDialog(context);
                            if (n != null && n > 0) {
                              widget.controller.addRows(
                                List.generate(
                                  n,
                                  (_) => widget.createBlankRow!(),
                                ),
                              );
                            }
                          },
                          addRowLabel: widget.addRowLabel,
                          addRowsLabel: widget.addRowsLabel,
                        )
                      : null;
                  final footer = widget.footer == null
                      ? null
                      : DefaultTextStyle.merge(
                          style:
                              theme.textTheme.bodyMedium ?? const TextStyle(),
                          child: widget.footer!,
                        );
                  final sideBySide =
                      addBar != null &&
                      footer != null &&
                      c.maxWidth >= _footerSingleRowMinWidth;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s12,
                      vertical: UtenSpacing.s8,
                    ),
                    child: sideBySide
                        ? Row(
                            children: [
                              addBar,
                              const SizedBox(width: UtenSpacing.s12),
                              // 合计条自身 width:double.infinity + 右对齐 Wrap，
                              // 交给 Expanded 吃掉剩余宽度即自然贴右。
                              Expanded(child: footer),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ?footer,
                              if (footer != null && addBar != null)
                                const SizedBox(height: UtenSpacing.s4),
                              ?addBar,
                            ],
                          ),
                  );
                },
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
      ],
    );
    // 操作条放在 Stack 之外（外层 Column），随页滚动且永不被 sticky 表头覆盖。
    // 编辑模式（showAddRow）只保留「表头设置」+ 宿主批量动作（全选走表头复选框、
    // 复制/粘贴/删除走行菜单）；只选/任务模式（含 onRemoveRows）保留全选与移出按钮。
    // 整体 SelectionContainer.disabled：单元格本就是 TextField（自带长按选词复制，
    // 不受 disabled 影响），而行级长按菜单/列宽拖拽把手与区域文字拖选手势打架，
    // 故编辑网格整体不参与页面级 SelectionArea（准则 §3.4）。
    final actionsBar = _actionsBar(theme);
    if (actionsBar == null) {
      return SelectionContainer.disabled(child: body);
    }
    return SelectionContainer.disabled(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [actionsBar, body],
      ),
    );
  }

  /// 单个行单元：可编辑模式使用内置编辑菜单；任务办理表只有显式提供
  /// [UtenEditableGrid.onRemoveRows] 才挂“从本次操作移出”菜单，绝不把上游来源
  /// 行默认解释成可持久化删除。
  Widget _rowCellOrMenuRegion(
    T row,
    int i,
    BorderSide divider,
    List<int> visibleColumnIndices,
  ) {
    final cell = _DataRow<T>(
      index: i,
      row: row,
      columns: widget.columns,
      columnIndices: visibleColumnIndices,
      widths: _widths,
      showSelect: widget._showSelect,
      isSelected: _rowIsSelected(row),
      onSelect: _rowOnSelect(row),
      rowTint: widget.rowColor?.call(row),
      showDelete: widget.showRowDelete,
      deleteColWidth: _deleteColWidth,
      divider: divider,
      confirmDelete: widget.confirmDelete,
      deleteConfirmLabel: widget.deleteConfirmLabel,
      onDelete: () => widget.controller.removeAt(i),
      // 行首勾选列横滚时钉在视口左缘（与表头全选格同款）。
      frozenSelectionScroll: _bodyH,
    );
    // 纯勾选模式（selectable 且非编辑）：点行身任意非输入区 = 切换选中，与
    // MasterDataTableView「单击行选中」契约统一（2026-09-05，物料分析车间计划表
    // 反馈）。输入/按钮格自己消费点按，不会误触；编辑模式（showAddRow）不启用——
    // 点格输入优先，选中走复选框/行菜单。
    final tapToggle = widget.selectable && !widget.showAddRow
        ? _rowOnSelect(row)
        : null;
    final rowBody = tapToggle == null
        ? cell
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: tapToggle,
            child: cell,
          );
    final rowSelectable = widget.canSelectRow?.call(row) ?? true;
    if (!widget.selectionEnabled ||
        !rowSelectable ||
        (!widget.showAddRow &&
            widget.onRemoveRows == null &&
            widget.rowMenuExtraBuilder == null)) {
      return rowBody;
    }
    return UtenContextMenuRegion(
      // 组件在手势触发时先调 entriesBuilder 再回调 onMenuOpening——选中归位必须
      // 在构建条目前完成，"复制选中 (n)"/"删除选中 (n)" 的计数才是归位后的口径。
      entriesBuilder: () {
        _selectOnlyForMenu(row);
        final extra =
            widget.rowMenuExtraBuilder?.call(context, _selectedRows()) ??
            const <UtenContextMenuEntry>[];
        if (widget.showAddRow) {
          final base = _rowMenuEntries(row, i);
          if (extra.isEmpty) return base;
          return [...base, const UtenMenuDivider(), ...extra];
        }
        final victims = _selectedRows();
        final n = victims.length;
        if (widget.onRemoveRows == null) return extra;
        return [
          UtenMenuItem(
            label: '${widget.removeRowsActionLabel} ($n)',
            icon: Icons.remove_circle_outline_rounded,
            enabled: n > 0,
            destructive: true,
            onTap: () => _confirmBatchDelete(context, victims: victims),
          ),
          if (extra.isNotEmpty) ...[const UtenMenuDivider(), ...extra],
        ];
      },
      // 只在用户真正选择菜单条目且其同步/异步动作结束后清空；点外部取消菜单
      // 保留当前选择，避免误清用户主动勾选的多行。
      onActionCompleted: () => _clearSelection(),
      child: rowBody,
    );
  }

  List<T> _selectedRows() =>
      widget.controller.rows.where(_rowIsSelected).toList(growable: false);

  void _selectOnlyForMenu(T row) {
    if (!widget.selectionEnabled ||
        (widget.canSelectRow?.call(row) ?? true) == false) {
      return;
    }
    if (_rowIsSelected(row)) return;
    final external = widget.onRowSelect;
    if (external == null) {
      widget.controller.selectOnly(row);
      return;
    }
    for (final selected in _selectedRows()) {
      external(selected, false);
    }
    external(row, true);
  }

  void _clearSelection([Iterable<T>? rows]) {
    final external = widget.onRowSelect;
    if (external == null) {
      widget.controller.clearSelection();
      return;
    }
    for (final selected in rows ?? _selectedRows()) {
      external(selected, false);
    }
  }

  /// 行菜单条目：复制选中/粘贴/批量粘贴/在上方插入空行/删除选中。
  /// cloneRow 未提供（页面无行克隆）时不显复制粘贴组；缓冲为空时粘贴置灰不隐藏
  /// （与 UtenContextMenu「看得见功能边界」约定一致）。所有操作与操作条同一套
  /// controller 逻辑 + 确认弹窗，粘贴统一追加表尾。
  List<UtenContextMenuEntry> _rowMenuEntries(T row, int i) {
    final c = widget.controller;
    final clone = widget.cloneRow;
    final victims = _selectedRows();
    final n = victims.length;
    return [
      if (clone != null) ...[
        UtenMenuItem(
          label: '复制选中 ($n)',
          icon: Icons.copy_rounded,
          enabled: n > 0,
          onTap: () => c.copySelected(clone),
        ),
        UtenMenuItem(
          label: '粘贴',
          icon: Icons.content_paste_rounded,
          enabled: c.hasBuffer,
          onTap: () => c.paste(clone),
        ),
        UtenMenuItem(
          label: '批量粘贴',
          icon: Icons.library_add_rounded,
          enabled: c.hasBuffer,
          onTap: () => _pasteMany(context, clone),
        ),
      ],
      UtenMenuItem(
        label: '在上方插入空行',
        icon: Icons.add_circle_outline_rounded,
        onTap: () => c.insertAt(i, widget.createBlankRow!()),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '删除选中 ($n)',
        icon: Icons.delete_outline_rounded,
        enabled: n > 0,
        destructive: true,
        onTap: () => _confirmBatchDelete(context, victims: victims),
      ),
    ];
  }

  /// 明细操作条。编辑模式（showAddRow）：仅「表头设置」+ 宿主批量动作——全选走表头
  /// 复选框，复制/粘贴/批量删除走行级右键/长按菜单（2026-09-05 与货品资料工具条统一，
  /// 去掉与行菜单重复的常驻按钮）。只选/任务模式（showAddRow=false）：保留
  /// 全选/移出（删除选中）常驻按钮（无行菜单的纯勾选表的主操作面）。
  /// 无任何可显内容时返回 null（不渲染空条）。
  Widget? _actionsBar(ThemeData theme) {
    final editMode = widget.showAddRow;
    final clone = widget.cloneRow;
    if (widget.showColumnSettings ||
        widget.batchActionsBuilder != null ||
        (!editMode && (widget._showSelect || widget.onRemoveRows != null))) {
      return ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final selectedRows = _selectedRows();
          final n = selectedRows.length;
          final targets = _selectableRows();
          final all = targets.isNotEmpty && targets.every(_rowIsSelected);
          return Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Wrap(
              spacing: UtenSpacing.s4,
              runSpacing: UtenSpacing.s4,
              children: [
                if (widget.showColumnSettings)
                  UtenColumnChooserButton(
                    entries: [
                      for (final column in widget.columns)
                        UtenColumnChooserEntry(
                          key: column.key,
                          label: column.label,
                          required: column.required,
                        ),
                    ],
                    hiddenKeys: _hiddenColumnKeys,
                    order: _columnOrder,
                    onToggle: _toggleColumn,
                    onToggleAll: _toggleAllColumns,
                    onReorder: _reorderColumns,
                    onReset: _resetColumnSettings,
                  ),
                if (!editMode &&
                    widget._showSelect &&
                    widget.showSelectAllToggle)
                  _actBtn(
                    theme,
                    all ? '取消全选' : '全选',
                    !widget.selectionEnabled || targets.isEmpty
                        ? null
                        : () => _toggleSelectAllRows(targets, all),
                  ),
                // 宿主批量动作（如订货单「统一设供应商」）两种模式都常驻。
                for (final action
                    in widget.batchActionsBuilder?.call(context, c) ??
                        const <Widget>[])
                  _selectionActionGate(action),
                if (!editMode &&
                    (widget.showAddRow || widget.onRemoveRows != null))
                  _actBtn(
                    theme,
                    '${widget.onRemoveRows == null ? '批量删除' : widget.removeRowsActionLabel} ($n)',
                    widget.selectionEnabled && n > 0
                        ? () => _confirmBatchDelete(context)
                        : null,
                    danger: true,
                  ),
                if (!editMode && clone != null && c.hasBuffer) ...[
                  _actBtn(
                    theme,
                    '粘贴',
                    widget.selectionEnabled ? () => c.paste(clone) : null,
                  ),
                  _actBtn(
                    theme,
                    '粘贴多行',
                    widget.selectionEnabled
                        ? () => _pasteMany(context, clone)
                        : null,
                  ),
                ],
              ],
            ),
          );
        },
      );
    }
    return null;
  }

  Widget _selectionActionGate(Widget child) => ExcludeFocus(
    excluding: !widget.selectionEnabled,
    child: IgnorePointer(
      ignoring: !widget.selectionEnabled,
      child: AnimatedOpacity(
        opacity: widget.selectionEnabled ? 1 : 0.45,
        duration: const Duration(milliseconds: 150),
        child: child,
      ),
    ),
  );

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
        textStyle: theme.textTheme.titleSmall,
      ),
      child: Text(label),
    );
  }

  Future<void> _confirmBatchDelete(
    BuildContext context, {
    List<T>? victims,
  }) async {
    final targets = victims ?? _selectedRows();
    if (targets.isEmpty) return;
    final ok = await UtenDialog.show(
      context,
      title: widget.removeRowsDialogTitle,
      content: Text(
        widget.removeRowsMessageBuilder?.call(targets.length) ??
            '确认删除选中的 ${targets.length} 行明细？',
      ),
      confirmLabel: widget.removeRowsConfirmLabel,
      danger: true,
    );
    if (ok != true) return;
    final remove = widget.onRemoveRows;
    if (remove == null) {
      if (victims == null) {
        widget.controller.batchDelete();
      } else {
        widget.controller.removeRows(targets);
        widget.controller.clearSelection();
      }
    } else {
      remove(targets);
      // 外部受控选择的行可能已经从 controller 移出，须按手势/操作条捕获的
      // 快照清选，不能再从当前 rows 反查，否则恢复同一行对象时会残留 selected。
      _clearSelection(targets);
    }
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
  Widget _buildHeaderUnit(
    ThemeData theme,
    double total,
    List<int> visibleColumnIndices,
  ) {
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
              // 换位拖动中在表头行上渲染插入位指示线（前导选择列让位）。
              child: columnHeaderIndicatorOverlay(
                leadingInset: widget._showSelect ? _selectColWidth : 0,
                child: _withFrozenSelectAll(
                  theme,
                  Row(
                    children: [
                      if (widget._showSelect)
                        SizedBox(
                          width: _selectColWidth,
                          child: _selectAllHeaderCell(theme),
                        ),
                      for (final i in visibleColumnIndices)
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
                                // 表头标签区（共用 UtenColumnHeaderDragHost）：
                                // 竖滑拖出隐藏 + 长按拎起横拖排序。手势识别器在视觉
                                // 包裹外层，拖拽更新只重建内层视觉，不打断进行中的手势；
                                // 仅开启表头设置时启用。
                                columnHeaderGestureArea(
                                  i,
                                  columnHeaderCell(i, _headerLabel(theme, i)),
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

  Widget _headerLabel(ThemeData theme, int index) {
    final column = widget.columns[index];
    if (column.filterValueOf != null) {
      return GridHeaderFilterCell(
        label: column.label,
        requiredStar: column.required,
        buckets: [
          for (final bucket in _filterBuckets(column))
            GridHeaderFilterBucket(
              value: bucket.value,
              display: bucket.display,
              count: bucket.count,
            ),
        ],
        nullCount: _filterNullCount(column),
        selected: _columnFilters[column.key],
        onChanged: (value) =>
            setState(() => _columnFilters[column.key] = value),
      );
    }
    final Widget label = Text.rich(
      TextSpan(
        text: column.label,
        style: (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w700,
        ),
        children: column.required
            ? [
                TextSpan(
                  text: ' *',
                  style: (theme.textTheme.labelMedium ?? const TextStyle())
                      .copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ]
            : null,
      ),
      overflow: TextOverflow.ellipsis,
    );
    // 拖动手势提示不挂 Tooltip：触屏长按已让给「拎起排序」（2026-09-05），
    // Tooltip 的长按弹提示会与之打架；锁定/兜底说明在表头设置弹层的行内副标题。
    // [headerInfo] 走共用 UtenColumnHeaderInfo（UtenFieldHintIcon：悬停/点按/键盘，
    // 吞长按），与 MasterDataTableView 列头、输入框内 ⓘ 同一份实现（2026-09-10）。
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: column.headerInfo == null
            ? label
            : UtenColumnHeaderInfo(label: label, message: column.headerInfo!),
      ),
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
    required this.columnIndices,
    required this.widths,
    required this.showDelete,
    required this.deleteColWidth,
    required this.divider,
    required this.onDelete,
    this.showSelect = false,
    this.selectColWidth = 44,
    this.isSelected = false,
    this.onSelect,
    this.rowTint,
    this.confirmDelete = true,
    this.deleteConfirmLabel = '确认删除该行明细？',
    this.frozenSelectionScroll,
  });
  final int index;
  final T row;
  final List<EditableGridColumn<T>> columns;
  final List<int> columnIndices;
  final List<double> widths;
  final bool showDelete;
  final double deleteColWidth;
  final BorderSide divider;
  final VoidCallback onDelete;

  /// 批量模式：行首选中框。
  final bool showSelect;
  final double selectColWidth;
  final bool isSelected;

  /// 选中框切换；null（含行级门控判定不可选）时复选框禁用。
  final VoidCallback? onSelect;

  /// 行语义底色；null = 斑马纹。选中行统一高亮覆盖。
  final Color? rowTint;

  /// 删除前确认弹窗。
  final bool confirmDelete;
  final String deleteConfirmLabel;

  /// 表体横滚控制器：非空时行首选择列钉在视口左缘（横滚不会把它带走）。
  final ScrollController? frozenSelectionScroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOdd = index.isOdd;
    // 单元格统一规格（UtenEditableGridCellSpec）：一行只包一层 Theme，让不自带
    // 装饰的输入格/下拉格/选择格自动等高、同圆角、同内边距。
    final cellTheme = theme.copyWith(
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        isDense: true,
        contentPadding: UtenEditableGridCellSpec.contentPadding,
      ),
    );
    final rowBg = isSelected
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
        : (rowTint ??
              (isOdd ? theme.colorScheme.surfaceContainerLowest : null));
    final selectionCheckbox = Checkbox(
      value: isSelected,
      onChanged: onSelect == null ? null : (_) => onSelect!(),
    );
    // 行内这一份**不自带底色**：跟整行同底（斑马纹/选中高亮由外层 DecoratedBox 给），
    // 且不遮住行底分隔线（DecoratedBox 的边框画在子节点之前）。
    final selectionCell = DecoratedBox(
      decoration: BoxDecoration(border: Border(right: divider)),
      child: selectionCheckbox,
    );
    // 横滚时钉在视口左缘的副本浮在数据格之上：必须自带同色不透明底 + 右线 + 行底线，
    // 否则下面的数据格会透上来、行线也会在这一段断开。
    final frozenSelectionCell = ColoredBox(
      color: rowBg ?? theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(right: divider, bottom: divider),
        ),
        child: selectionCheckbox,
      ),
    );
    final horizontal = frozenSelectionScroll;
    Widget wrapFrozen(Widget rowBody) => showSelect && horizontal != null
        ? UtenFrozenLeadingColumn(
            horizontal: horizontal,
            width: selectColWidth,
            cell: frozenSelectionCell,
            row: rowBody,
          )
        : rowBody;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: rowBg,
        border: Border(bottom: divider),
      ),
      child: Theme(
        data: cellTheme,
        child: wrapFrozen(
          Row(
            children: [
              if (showSelect)
                SizedBox(width: selectColWidth, child: selectionCell),
              for (final i in columnIndices)
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
        ),
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

  // 深色实心 + 白字白图标，紧凑不抢空间——旧版 TextButton 太淡，用户反馈"看不见"。
  static final ButtonStyle _btnStyle = FilledButton.styleFrom(
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s12,
      vertical: UtenSpacing.s4,
    ),
    minimumSize: const Size(0, 36),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );

  @override
  Widget build(BuildContext context) {
    // 纵向留白交给宿主表尾容器统一给（与合计条并排时两者才对得齐）。
    // 不要包 Align/Container+alignment：并排分支里本控件拿到的是**无界宽约束**，
    // 那类组件会试图撑满上限直接布局崩（见 MEMORY「Container alignment 撑满宽度」）。
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s4,
      children: [
        FilledButton.icon(
          onPressed: onAddOne,
          icon: const Icon(Icons.add_circle_outline, size: 18),
          label: Text(addRowLabel),
          style: _btnStyle,
        ),
        FilledButton.icon(
          onPressed: onAddMany,
          icon: const Icon(Icons.playlist_add, size: 18),
          label: Text(addRowsLabel),
          style: _btnStyle,
        ),
      ],
    );
  }
}

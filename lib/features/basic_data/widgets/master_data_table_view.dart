// MasterDataTableView - 基础资料主档通用表格视图（货品/模具/客户/供应商 共用）。
//
// Excel 风格：横排 autofilter 列头（表头跟随表体横滚，无滚动条）+ 逐行数据（列对齐，
// 底部横向滚动条）。表头/表体各自一个横向 ScrollView，双向 listener 同步横滚位置
// （拖底部滚动条表头跟随；列始终对齐）。列头 autofilter 用自定义 Overlay 下拉（锚定
// 列头下方、限高、竖向滚动，不全屏）。翻页（上一页/下一页）后表体竖向回到顶部。
// 搜索框由调用方放在标题行，不在本组件内。

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_table_column_kit.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/master_facet.dart';

/// Actual table selection and foreground for custom cell builders.
/// Single-row focus and checkbox selection share this visual contract.
class MasterDataTableCellScope extends InheritedWidget {
  const MasterDataTableCellScope({
    required this.selected,
    required this.foregroundColor,
    required super.child,
    super.key,
  });

  final bool selected;
  final Color? foregroundColor;

  static MasterDataTableCellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MasterDataTableCellScope>();

  @override
  bool updateShouldNotify(MasterDataTableCellScope oldWidget) =>
      selected != oldWidget.selected ||
      foregroundColor != oldWidget.foregroundColor;
}

/// 一列定义：[key](筛选键，与后端 query 参数对齐)、[label](列头)、
/// [width](固定列宽，列对齐用)、[value](文本值)、[cellBuilder](可选自定义内容)。
class MasterColumnDef<T> {
  const MasterColumnDef({
    required this.key,
    required this.label,
    required this.width,
    required this.value,
    this.type = 'text',
    this.sortable = false,
    this.cellColor,
    this.cellBuilder,
    this.cellBuilderHandlesSemantics = false,
    this.info,
  });

  final String key;
  final String label;
  final double width;
  final String? Function(T item) value;

  /// 表头说明（2026-09-06）：非空时列头标签后渲染 ⓘ——桌面悬停出 Tooltip、
  /// 点击（含手机）弹出说明小窗。用于业务口径晦涩的列（如物料分析的数量列）
  /// 向非专业用户解释「这列数字是什么、怎么算出来的」。
  final String? info;

  /// 可选自定义单元格。外层仍负责列宽、内边距、网格线和选中底色；builder 只负责
  /// 单元格内部内容。[value] 仍是列宽测算、排序键、文本行键和无障碍标签的回退真值。
  /// Builder context exposes [MasterDataTableCellScope] and the effective text/icon style.
  final Widget Function(BuildContext context, T item)? cellBuilder;

  /// Interactive/custom cells can opt out of the table's fallback label when
  /// their child already exposes complete button/expanded/value semantics.
  /// Defaults to false so existing simple custom cells keep the column label.
  final bool cellBuilderHandlesSemantics;

  /// 列类型，对齐后端 ReportColumn.type：text / date / number / money / bool。
  /// 用于决定排序菜单文案（date=从远到近/从近到远，数值=从小到大/从大到小）。
  final String type;

  /// 该列是否允许点表头排序（日期/金额/数量等可排序列置 true）。
  final bool sortable;

  /// 单元格语义底色（如待处理步骤用浅警示色）；null = 跟随所在行底色。
  /// 选中行仍由表格统一使用深绿高亮，避免颜色叠加后文字对比不足。
  final Color? Function(BuildContext context, T item)? cellColor;
}

/// 一个可折叠的「前导分组」：渲染在表头之下、主数据行之上（如货品页的「禁用货品」
/// 「不明货品」集合）。折叠时是一整行（跨满表宽）的浅色标题行；展开后其 [items]
/// 按主表同款列定义、列宽与列显隐逐行渲染——因此「表头设置」与列对齐天然对它生效。
class MasterDataGroup<T> {
  const MasterDataGroup({
    required this.id,
    required this.title,
    required this.items,
    this.subtitle,
    this.tint,
    this.icon,
    this.total,
    this.detailLabel = '下拉查看详情', // TODO(l10n): 补 arb
    this.loading = false,
    this.error,
    this.onExpand,
    this.onRetry,
  });

  /// 分组唯一 id（折叠/展开态键）；同一表格内不应重复。
  final String id;

  /// 标题文案（如「禁用货品（31）」）。
  final String title;

  /// 副标题（标题行第二行小字说明），可空。
  final String? subtitle;

  /// 标题行底色（禁用=浅红、不明=浅琥珀）；null 用工具条同款 surfaceContainerHigh。
  final Color? tint;

  /// 标题行左侧图标。
  final IconData? icon;

  /// 该分组的条目（展开后按主表列逐行渲染）。可能为分页截断的前若干条。
  final List<T> items;

  /// 全集计数（[items] 可能被分页截断）；标题显示与「还有更多」提示用。null=用 items.length。
  final int? total;

  /// 标题行右侧的展开提示文案（默认「下拉查看详情」）。渲染为加粗深红，老人易看清。
  final String detailLabel;

  /// 首次展开或手动刷新时的加载态。既有 [items] 保留展示，避免刷新跳动。
  final bool loading;

  /// 分组数据加载失败的可恢复提示；标题行就地提供重试。
  final String? error;

  /// 从折叠切换为展开时触发。调用方可在这里首次懒加载。
  final VoidCallback? onExpand;

  /// 加载失败后的重试回调；未传时回退到 [onExpand]。
  final VoidCallback? onRetry;
}

/// 主档通用表格视图：横排 autofilter 筛选 + 逐行数据（列对齐）+ 分页。
/// 搜索框由调用方自行放在标题行（标题 | 搜索 | 添加）。
class MasterDataTableView<T> extends StatefulWidget {
  const MasterDataTableView({
    super.key,
    required this.columns,
    required this.items,
    required this.facets,
    required this.nullCounts,
    required this.filters,
    required this.onFilterChanged,
    this.onRowTap,
    this.canOpenRow,
    this.onSelectionChanged,
    this.onSelectionCleared,
    this.isSelected,
    this.rowMenuBuilder,
    this.canShowRowMenu,
    this.batchActionsBuilder,
    this.sortColumn,
    this.sortAscending = true,
    this.onSortChange,
    this.isLoading = false,
    this.loadingMore = false,
    this.onLoadMore,
    this.error,
    this.onRetry,
    this.emptyMessage = '暂无数据', // TODO(l10n): 补 arb
    this.currentPage = 1,
    this.totalPages = 1,
    this.onPageChange,
    this.summaryBar,
    this.toolbarActions,
    this.toolbarLeadingActions,
    this.embedded = false,
    this.primary = false,
    this.virtualized = false,
    this.showFullscreenToggle,
    this.showColumnChooser = true,
    this.enableTextSelection = true,
    this.rowColor,
    this.leadingGroups,
    this.selectable = false,
    this.idOf,
    this.rowKeyOf,
    this.rowWidgetKeyOf,
    this.unselectableLeadingBuilder,
    this.selectedIds = const <String>{},
    this.onSelectedIdsChanged,
    this.selectionSummaryCount,
    this.onClearSelection,
    this.showSelectionSummary = true,
    this.preserveSelectionOnContextMenu = false,
    this.onFullscreenChanged,
  }) : assert(
         !embedded || !virtualized,
         'virtualized=true requires a bounded, non-embedded table',
       );

  /// 全屏态变化通知（进入/退出各回调一次）。宿主页可借此把搜索框等控件
  /// 在全屏时放回表格工具条（正常态放页面头部卡片），两处共享同一控制器。
  final ValueChanged<bool>? onFullscreenChanged;

  final List<MasterColumnDef<T>> columns;
  final List<T> items;
  final Map<String, List<MasterFacetBucket>> facets;
  final Map<String, int> nullCounts;
  final Map<String, String?> filters;
  final void Function(String key, String? value) onFilterChanged;

  /// 行的「打开」操作。列表页（非 embedded）统一为「双击打开」——单击只选中；
  /// embedded（picker/滑窗内明细表）保留单击直达：picker 行的单击语义本来就是
  /// 「选中这条」，不是「打开页面」。触屏上双击同样可打开；挂了 [rowMenuBuilder]
  /// 的行也可从长按/右击菜单的「查看详情」进入。
  /// 为空时该行不创建 [InkWell]，也不会暴露鼠标可点击状态或无障碍 tap 语义；
  /// 个别受限/无详情行可用 [canOpenRow] 按行关闭打开能力。
  final void Function(T item)? onRowTap;

  /// 按行判断是否允许打开。默认全部允许；返回 false 的行仍可在 [selectable]
  /// 模式下切换勾选，但不暴露双击、打开详情语义或鼠标可打开状态。
  final bool Function(T item)? canOpenRow;

  /// 单击选中行变化回调（供调用方拿选中行做后续操作，如 BOM Tab 据此决定
  /// "添加组件"默认父级）；embedded 表在选中后继续调用 [onRowTap]。
  final void Function(T item)? onSelectionChanged;

  /// 行菜单中的可用动作执行完毕后，表格会清除内部单选高亮，并调用本回调让页面
  /// 同步清理依赖选中行的外部动作状态。仅关闭菜单、不执行条目时不会调用。
  final VoidCallback? onSelectionCleared;

  /// 外部受控选中判定：非空时优先用它判定高亮（按业务键比较，不受 item 引用变化影响），
  /// 供每次 build 重建 item 对象的场景（如 BOM 的 _BomRow）——否则默认内部 _selectedItem 走引用相等。
  final bool Function(T item)? isSelected;

  /// 行右键/长按菜单条目构建器：非空时数据行右击（桌面/Web）或长按（触屏）弹出自绘
  /// 小框菜单（[UtenContextMenuRegion]）。弹出前组件自动把该行置为选中态
  /// （多选模式下：该行未勾选则先把选择集替换为仅该行，已勾选则保留多选）。
  /// 条目在手势触发那一刻构建，可按行数据/剪贴板状态决定可用性。
  final List<UtenContextMenuEntry> Function(T item)? rowMenuBuilder;

  /// 按行判断是否存在右键/长按菜单。默认全部存在；返回 false 时该行不会仅因
  /// 页面配置了 [rowMenuBuilder] 就获得空菜单手势或伪可交互状态。
  final bool Function(T item)? canShowRowMenu;

  /// 批量业务动作构建器：selectable 时，表头工具条始终显示「已选 N 项 + 清除」；
  /// 本构建器可选，非空时返回的业务按钮统一悬浮在表格右下角，普通视图和全屏路由都会渲染。
  /// 未选中时动作保留位置但灰显并拦截点击，调用方仍应保留空集业务守卫。
  final List<Widget> Function(BuildContext context, Set<String> selectedIds)?
  batchActionsBuilder;

  /// 多选模式开关：true 时在最前列渲染勾选框 + 表头三态全选，行高亮改由 [selectedIds] 驱动
  /// （此时单选 [isSelected]/[onSelectionChanged]/内部 _selectedItem 全部失效）。
  /// 列表和嵌入式业务明细共用；未启用多选的 picker 保留原单击选取。多选时单击行 = 切换勾选，
  /// 双击行 = [onRowTap] 打开详情。
  final bool selectable;

  /// 行→业务 id 提取器（[selectable]:true 时必填）。用于把行键进 [selectedIds] 集合，避免依赖
  /// item 引用相等（列表每次 build 重建对象；_BomRow / InstantInventoryRow 无 id 都会踩坑）。
  /// 无 id 的行传复合键，如 `(r) => '${r.goodsId}|${r.colorId}'`。
  final String? Function(T)? idOf;

  /// 行→稳定键提取器，只影响 RepaintBoundary 的行 key（数据刷新时行复用），
  /// 不参与勾选。混合队列里「部分行可勾选」时 idOf 对不可勾选行须返回 null
  ///（勾选门控与 idOf 同源），此时用本参数给这些行保留稳定键，避免全部回落
  /// 到下标键（筛选/刷新后 Selectable 复用性变差）。缺省沿用 idOf，行为不变。
  final String? Function(T)? rowKeyOf;

  /// Optional test/automation key for the rendered row wrapper. Business code
  /// should still use [rowKeyOf] for identity; this hook lets migrations keep
  /// stable row locators without encoding widget internals into the data key.
  final Key? Function(T item)? rowWidgetKeyOf;

  /// Optional replacement for the disabled checkbox of rows whose [idOf]
  /// returns null. Hierarchical/workflow tables use this for a 48dp gate icon
  /// with a concrete reason instead of presenting a checkbox that can never act.
  final Widget Function(BuildContext context, T item)?
  unselectableLeadingBuilder;

  /// 多选选中集合（调用方拥有，单一真值源）。组件只读它判定勾选/高亮、只通过
  /// [onSelectedIdsChanged] 把"新集合"回交调用方，从不自行清空——故跨页天然保留。
  final Set<String> selectedIds;

  /// 选中集合变化回调：行勾选与表头三态全选共用这一个（传入新的 Set）。
  final void Function(Set<String> next)? onSelectedIdsChanged;

  /// Optional count of canonical business tasks when one displayed row represents
  /// several tasks. Selection may include items hidden by the current filter.
  final int? selectionSummaryCount;

  /// Clears the complete selection, including tasks hidden by filters.
  /// Ordinary tables retain the default empty-set callback.
  final VoidCallback? onClearSelection;

  /// 表头工具条是否驻留「已选 N 项」选择摘要胶囊（默认驻留）。
  /// 页面把批量动作放在自己的右下角悬浮组、并在组内自摆 UtenSelectionSummaryPill
  /// 时传 false，避免同一选择数在工具条与悬浮组重复出现。
  final bool showSelectionSummary;

  /// Keep explicit business selections when opening or completing a row menu.
  /// Default tables retain their standard context-selection behaviour.
  final bool preserveSelectionOnContextMenu;

  /// 表头上方工具条的追加按钮（预览打印 / 下载表格等），排在工具条右侧贴边
  /// （全站口径：刷新等页面动作放表格右上角）。调用方通常传深绿大号款
  ///（UtenButtonType.primary + large）。
  final List<Widget>? toolbarActions;

  /// 表头上方工具条的前缀按钮：渲染在「表头设置 / 全屏」同一左簇内、紧挨全屏
  /// 按钮之后（吃 Wrap 的 s8 间距），适合视图切换类 chip——避免塞进右侧贴边
  /// 动作区后与全屏按钮相距过远、且多按钮间无间距（2026-09-06 物料分析 BOM
  /// 视图切换按钮移位需求）。
  final List<Widget>? toolbarLeadingActions;

  /// 嵌入模式：用于详情页 ListView 等无界高度场景（单据明细只读表）。
  /// 不渲染翻页条、不用 Expanded 撑满，表体按内容收缩。
  final bool embedded;

  /// 联动折叠模式：true 时表体竖向 ListView 改用 primary（拾取祖先 NestedScrollView
  /// 注入的 PrimaryScrollController），参与「顶部折叠 → 表格内滚」联动；shrinkWrap 关、
  /// physics 改 AlwaysScrollable、_BodyFlex 改 tight。仅用于包在
  /// [UtenCollapsingHeaderScrollView]（或等价 NestedScrollView）body 里的列表页表格；
  /// 不能与 [embedded] 同用（embedded 无 NestedScrollView 祖先）。
  final bool primary;

  /// Bounded data-workbench mode: fill the available body height and keep the
  /// row list lazy (`shrinkWrap:false`). Use for rich/interactive tables with
  /// dozens of rows; short master-data tables keep the default shrink-to-content
  /// behaviour. Cannot be combined with [embedded].
  final bool virtualized;

  /// 是否显示工具条「全屏」按钮。null 时按 [embedded] 推断：嵌入场景（滑窗/picker/弹窗内的
  /// 明细表）默认隐藏全屏按钮，避免整屏路由在受限容器里铺满屏幕（详细排产滑窗 bug 修复）；
  /// 非嵌入主页面默认显示。显式传 true 可在嵌入场景放开。
  final bool? showFullscreenToggle;

  /// 是否显示工具条「表头设置」。窄屏页面可关闭以把有限高度留给数据，
  /// 桌面/全屏默认保留完整列显隐能力。
  final bool showColumnChooser;

  /// 是否为只读表体创建独立 [SelectionArea]。
  ///
  /// 默认开启，保留普通数据表的复制能力。包含横向同步滚动、分页或密集行手势的
  /// 重交互页面可显式关闭；此时整表用 [SelectionContainer.disabled] 隔离，避免
  /// Flutter Web 在路由转场/滚动期间反复维护 SelectionRegistrar 导致主线程卡顿。
  /// [selectable] 为 true 的业务多选表始终关闭文字框选，本开关不改变行勾选语义。
  final bool enableTextSelection;

  /// 行底色（按行数据定，如货品按状态：使用=浅蓝/禁用=浅红）；返回 null = 默认透明。
  /// 单击选中时组件自动把该色加深加亮（提高不透明度），无底色行维持原 primary 高亮。
  final Color? Function(T item)? rowColor;

  /// 前导可折叠分组（表头下、主数据行上）：禁用货品/不明货品等集合行。
  /// 折叠时是浅色标题行（跨满表宽）；展开后其 items 按主表同款列/列宽/列显隐逐行渲染，
  /// 故「表头设置」与列对齐天然对它生效。N=0 的分组不渲染。
  final List<MasterDataGroup<T>>? leadingGroups;

  /// 当前排序的列 key（与 MasterColumnDef.key 对齐）；null = 不排序（用后端默认顺序）。
  final String? sortColumn;

  /// 当前排序方向：true=升序，false=降序。仅当 [sortColumn] 非空时有效。
  final bool sortAscending;

  /// 列头排序回调：(列 key, 升序) 应用排序；(null, _) 取消排序回到默认。
  /// 报表分页场景下，回调应触发带 sort/order 参数重新请求后端。
  final void Function(String? column, bool ascending)? onSortChange;

  final bool isLoading;
  final bool loadingMore;

  /// 滚动触发式自动加载：表体竖向滚动临近底部（距底 [_loadMoreEdge] 内）时回调，
  /// 与 [loadingMore]（末尾转圈行 + 本组件防重入）配合实现「滑到底自动加载下一页」。
  /// 组件不感知是否还有更多页——增量加载式页面不传 currentPage/totalPages（避免
  /// 渲染翻页条），由调用方在回调里自行判断 [_loadMore] 类守卫后 no-op。
  final VoidCallback? onLoadMore;
  final String? error;
  final VoidCallback? onRetry;
  final String emptyMessage;

  final int currentPage;
  final int totalPages;
  final void Function(int page)? onPageChange;

  /// 表格下方的合计条（通常是 `UtenTotalsSummaryBar`）。
  ///
  /// 全站统一挂在**表体与翻页条之间**：表体内部滚动，合计条在滚动区之外，
  /// 因此滚到哪一行它都在；全屏表格与嵌入式明细表同样跟随，位置/间距/字号一处定义处处一致。
  ///
  /// **服务端分页的表格必须传服务端合计**——对当前页求和会得出一个看着像总计、
  /// 其实只覆盖一页的数；拿不到服务端合计时要么不传，要么把标签写成「本页合计」。
  final Widget? summaryBar;

  @override
  State<MasterDataTableView<T>> createState() => _MasterDataTableViewState<T>();
}

class _MasterDataTableViewState<T> extends State<MasterDataTableView<T>>
    with UtenColumnHeaderDragHost<MasterDataTableView<T>> {
  // 表头/表体横滚同步（早期 Flutter 的 LinkedScrollControllerGroup 在 3.44 已移除，
  // 改用两个普通 ScrollController + 互听 + _syncing 防回环，行为等价）。
  late final ScrollController _headerH;
  late final ScrollController _bodyH;
  // 表体竖向滚动：翻页时 jumpTo(0) 回顶（从第一条开始）。
  late final ScrollController _bodyV;
  // primary 模式横滚条覆盖层：与 _bodyH 双向同步（_overlaySyncing 防回环）。
  // 该模式下表体竖向填满联动区（折叠手势全域有效），自然横滚条会沉到区底，
  // 故用覆盖层按「内容高度」定位——内容少贴末行下（约 1px 空隙），超高钉表体区底。
  late final ScrollController _overlayH = ScrollController();
  bool _overlaySyncing = false;
  // 分页跳转输入框：填数字回车跳页；外部翻页（上一页/下一页/跳页）时同步回当前页。
  late final TextEditingController _pageCtrl;
  bool _syncing = false;

  // —— primary 模式横滚条覆盖层测量 ——
  /// 表体区 Stack / 末行 的测量键。
  final GlobalKey _bodyAreaKey = GlobalKey();
  final GlobalKey _lastRowKey = GlobalKey();

  /// 横滚条底边在表体区内的 local top；null=未测得（隐藏覆盖层）。
  final ValueNotifier<double?> _hBarY = ValueNotifier<double?>(null);

  /// 横滚条覆盖层高度（thumb 在其底部绘制）。
  static const double _hBarHeight = 11;

  /// 末行底到横滚条 box 底边的距离（含滑块厚 10）：滑块上缘距末行约 1px。
  static const double _hBarGap = 11;

  /// 悬浮批量按钮的滚动让位（按钮组约 72 + 底距 16）：内容超高时表体底 padding
  /// 扩到这个值，滚动到底末行能露出按钮上方；内容装得下时回到 [_hBarGap]。
  static const double _batchPad = 88;

  /// 表体 ListView 当前底 padding（初值小间距；仅悬浮批量表会动态切换，见
  /// [_updateBodyPad]）。
  double _bodyBottomPad = _hBarGap;

  /// 当前列宽：默认按列内容自动适配最宽值（[MasterColumnDef.width] 不再用于布局，
  /// 保留字段供未来手动覆盖/最小宽度扩展）。用户拖拽后覆盖；自动适配需 BuildContext 的
  /// 文字样式，故在 build 首帧测算（见 [_ensureWidths]）。
  List<double> _widths = const [];

  /// 用户已手动拖拽过的列下标：数据刷新时这些列保留用户宽度，其余按新内容重新适配。
  final Set<int> _manualResized = {};

  /// 列宽待重算标记：列集合或数据变化时置 true，[_ensureWidths] 算完清掉。
  bool _widthsDirty = true;

  /// 上次量宽时生效的字号系数（textScaler.scale(1)）。用户在系统设置改字号档后，
  /// 渲染文字按新字号铺，但列宽缓存不会自动失效——[_ensureWidths] 据此比较触发重算，
  /// 保证字号变大列也跟着变宽（与 floating_capsule_nav_bar 同款 textScaler 处理）。
  double? _lastScale;

  /// 当前选中（单击高亮）的行：滚动不刷新数据故高亮常驻，翻页/重查换对象后自然失效。
  T? _selectedItem;

  /// 手动双击检测（列表页「单击选中、双击打开」）：上次点击的行键与时刻。
  /// 用 package:clock 的 [clock]（widget 测试环境为 fake clock，随 pump 推进）
  /// 比对时间窗；不用 DoubleTapGestureRecognizer（其竞技场 hold 会延迟单击
  /// 并诱发 FM2 崩溃）。
  String? _lastTapRowKey;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 双击时间窗：比系统 kDoubleTapTimeout(300ms) 略宽，老人双击慢一点也不漏判。
  static const Duration _kDoubleClickWindow = Duration(milliseconds: 350);

  /// 当前隐藏的列 key 集合：表头上方工具条「列」浮层勾选维护；
  /// 列集合变化（如报表切 docType）时清空（默认全部显示）。
  final Set<String> _hiddenKeys = {};

  /// 当前列显示顺序（含隐藏列）。默认 = widget.columns 原序；表头横拖换位/
  /// 表头设置弹窗拖拽排序修改（会话内有效，与 _hiddenKeys 同生命周期——主数据页
  /// 无账号级列偏好持久化）。列集合变化时重置。
  List<String> _columnOrder = const [];

  /// 全屏状态：true 时正常树让位成 SizedBox.shrink（ScrollController 只挂全屏路由一棵树），
  /// 表格经 showGeneralDialog 全屏路由渲染——走 Navigator 路由栈，故全屏里再开
  /// 「预览打印 / 下载表格」对话框会正常叠在全屏之上（手动 OverlayEntry 会压住路由弹窗）。
  /// [_fsTick] 驱动全屏内容重建（数据/列宽/显隐变化时 bump）。
  bool _fullscreen = false;
  final ValueNotifier<int> _fsTick = ValueNotifier<int>(0);

  /// 当前展开的前导分组 id 集合（点击分组标题行切换）。默认全折叠。
  final Set<String> _expandedGroups = {};

  /// 列下标→LayerLink：每列表头包一个 CompositedTransformTarget，跟手浮层（共用
  /// [UtenColumnDragHideHost]）经 CompositedTransformFollower 锚定到"当前拖拽列"的
  /// target，随其屏幕位置浮动（含横滚跟随）。列集合变化时清空，按新下标重建。
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

  /// 该列当前可否拖出隐藏：至少保留一列可见（末列永不 arm，松开 no-op、视觉回弹）。
  @override
  bool columnCanDragHide(int i) =>
      i < widget.columns.length && _visibleCount > 1;

  /// 松手且 armed：复用既有显隐切换守卫（末列不隐）。
  @override
  void onColumnDragHide(int i) => _toggleColumn(widget.columns[i].key);

  @override
  List<({int index, double width})> get reorderVisibleColumns => [
    for (final i in _visibleIndices)
      (index: i, width: i < _widths.length ? _widths[i] : _minColWidth),
  ];

  /// 横拖换位/弹窗排序落位：可见序列内搬移，隐藏列保持原锚位；会话内生效
  /// （与 _hiddenKeys 同生命周期），全屏内容经 _fsTick 同步重建。
  @override
  void onColumnsReordered(int fromOriginalIndex, int slot) {
    _reorderColumnInto(fromOriginalIndex, slot);
  }

  void _reorderColumnInto(int fromOriginalIndex, int slot) {
    final visible = _visibleIndices;
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
    _fsTick.value++; // 全屏路由内的表格同步重建。
  }

  /// 表头设置弹窗拖拽排序：在完整列序（含隐藏列）内搬移 key。
  /// onReorderItem 口径：[newIndex] 为 removeAt 后的最终插入位。
  void _reorderColumnByKeys(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _columnOrder.length) return;
    setState(() {
      final key = _columnOrder.removeAt(oldIndex);
      _columnOrder.insert(newIndex.clamp(0, _columnOrder.length), key);
    });
    _fsTick.value++;
  }

  // —— 列宽自动适配 / 手动拖拽 常量 ——
  /// 拖拽命中区半宽：以列右边界为中心、半溢出到相邻列，便于精准抓住边界。
  static const double _gripHalf = 4;

  /// 列宽下限（自动适配与拖拽收窄共同下限，防止列被拖没）。
  static const double _minColWidth = 48;

  /// 列宽自动适配上限：超长文本（如备注）默认按此截断+省略号，用户可再拖宽。
  static const double _maxColWidth = 480;

  /// 自动适配取样行数：量前 N 行最宽值即可（全量量算大表偏重，最宽值通常在前段出现）。
  static const int _autoFitSampleSize = 100;
  static const double _cellPadX = UtenSpacing.s12; // 单元格左右内边距（表头/表体一致）
  static const double _headerIconAllowance = 24; // 表头筛选下拉箭头 + 富余
  static const double _sortIconAllowance = 20; // 可排序列表头排序图标 + 间距

  /// 列头 ⓘ 说明图标命中区（UtenColumnHintIcon → UtenFieldHintIcon dense = 28）。
  /// 不计入就会挤掉标签：声明宽偏窄又带说明的列（下达采购的「缺口」）一进页面
  /// 只剩一个 ⓘ，标签被省略号吃光（2026-09-11 用户反馈）。
  static const double _headerInfoIconAllowance = 28;
  static const double _autoFitBuffer = 6; // 防贴边 ellipsis 富余

  /// 多选前导勾选列宽（合成单元格，不计入 widget.columns / 列宽自动适配 / 列显隐）。
  static const double _selectionColWidth = 48;

  @override
  void initState() {
    super.initState();
    assert(
      !widget.selectable || widget.idOf != null,
      'MasterDataTableView: selectable:true 需提供 idOf(行→业务 id 提取器)。',
    );
    assert(
      !widget.primary || !widget.embedded,
      'MasterDataTableView: primary 不能与 embedded 同用(embedded 场景无 NestedScrollView 祖先)。',
    );
    _headerH = ScrollController();
    _columnOrder = widget.columns.map((c) => c.key).toList();
    _bodyH = ScrollController();
    _bodyV = ScrollController();
    _pageCtrl = TextEditingController(text: '${widget.currentPage}');
    _headerH.addListener(() => _sync(_headerH, _bodyH));
    _bodyH.addListener(() => _sync(_bodyH, _headerH));
    _bodyH.addListener(() => _syncH(_bodyH, _overlayH));
    _overlayH.addListener(() => _syncH(_overlayH, _bodyH));
  }

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing || !dst.hasClients) return;
    _syncing = true;
    dst.jumpTo(src.offset);
    _syncing = false;
  }

  /// primary 模式横滚条覆盖层 ↔ 表体横滚 双向同步（[_overlaySyncing] 防回环；
  /// 覆盖层未挂载（非 primary/未测得）时 no-op）。
  void _syncH(ScrollController src, ScrollController dst) {
    if (_overlaySyncing || !dst.hasClients || !src.hasClients) return;
    _overlaySyncing = true;
    dst.jumpTo(src.offset);
    _overlaySyncing = false;
  }

  /// 布局完成后重算表体测量（渲染对象须完成 layout 才能量）：
  /// primary 模式横滚条覆盖层位置 + 表体底 padding（悬浮批量让位，见 [_updateBodyPad]）。
  bool _hBarUpdateScheduled = false;

  void _scheduleHBarUpdate() {
    if (!mounted || _hBarUpdateScheduled) return;
    _hBarUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hBarUpdateScheduled = false;
      if (!mounted) return;
      if (widget.primary) _updateHBar();
      _updateBodyPad();
    });
  }

  /// 表体底 padding 动态让位（仅 [_hasFloatingBatchActions] 时参与）：内容装得下 →
  /// 小间距 [_hBarGap]（横滚条贴末行）；内容超高 → 88（滚动到底时末行能露出悬浮
  /// 批量按钮上方）。判定与滚动位置无关（maxScrollExtent 恒定），且两态阈值差
  /// （0 ↔ 77）天然构成迟滞带，行数在临界附近不抖动。
  void _updateBodyPad() {
    if (!_hasFloatingBatchActions) return;
    final rowCtx = _lastRowKey.currentContext;
    final pos = rowCtx == null ? null : Scrollable.maybeOf(rowCtx)?.position;
    final double next;
    if (pos == null || !pos.hasContentDimensions) {
      next = _batchPad; // 末行未挂载（内容超高被虚拟化）→ 让位。
    } else {
      // 滚动无关：内容(不含 pad)超出视口 ⇔ maxScrollExtent > 当前pad - 最小gap。
      next = pos.maxScrollExtent > _bodyBottomPad - _hBarGap
          ? _batchPad
          : _hBarGap;
    }
    if (next != _bodyBottomPad) setState(() => _bodyBottomPad = next);
  }

  /// primary 模式横滚条定位：末行可量（内容少，行都在树里）→ 底边贴末行 + 底
  /// padding（滑块上缘距末行约 1px）；末行未挂载（内容超高被虚拟化）→ 钉表体区底。
  /// 顶部卡片折叠/展开改变区高、翻页/筛选改变内容高，都会经 LayoutBuilder 重建
  /// 触发重测。（不能用 maxScrollExtent+viewportDimension：primary 表体被强制
  /// 填满联动区，量出来恒等于区高。）
  void _updateHBar() {
    final areaCtx = _bodyAreaKey.currentContext;
    final areaBox = areaCtx?.findRenderObject() as RenderBox?;
    if (areaCtx == null || areaBox == null || !areaBox.attached) {
      if (_hBarY.value != null) _hBarY.value = null;
      return;
    }
    final areaTop = areaBox.localToGlobal(Offset.zero).dy;
    final areaBottom = areaTop + areaBox.size.height;
    final lastRowBox =
        _lastRowKey.currentContext?.findRenderObject() as RenderBox?;
    double barBottom;
    if (lastRowBox != null && lastRowBox.attached) {
      // 贴末行时恒用小间距（滑块上缘距末行约 1px）：悬浮批量按钮只与钉底态/滚动
      // 余量相关（由表体 ListView 底 padding [_batchPad] 承担），内容少时按钮在
      // 表体区右下角、不与贴末行的横滚条冲突。
      const pad = _hBarGap;
      final contentBottom =
          lastRowBox.localToGlobal(Offset.zero).dy +
          lastRowBox.size.height +
          pad;
      barBottom = contentBottom < areaBottom
          ? contentBottom - areaTop
          : areaBox.size.height;
    } else {
      barBottom = areaBox.size.height;
    }
    if (_hBarY.value != barBottom) _hBarY.value = barBottom;
  }

  @override
  void didUpdateWidget(covariant MasterDataTableView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列集合变了（数量或 key 序列不同，如报表切 docType）→ 清手动标记、全量重算列宽。
    if (!_sameColumnKeys(oldWidget.columns, widget.columns)) {
      _manualResized.clear();
      _widthsDirty = true;
      _hiddenKeys.clear(); // 列显隐选择跟随列集合重置（默认全部显示）。
      _columnOrder = widget.columns.map((c) => c.key).toList(); // 列序同随重置。
      columnHeaderDragReset(); // 拖拽态/跟手浮层可能指向失效下标，重置（FM6）。
      _colLinks.clear(); // 旧下标的 LayerLink 作废，按新列集合下标重建。
    } else if (oldWidget.items != widget.items) {
      // 数据变了（翻页/筛选/排序/加载更多）→ 标记重算；已手动调整的列在 _ensureWidths 保留。
      _widthsDirty = true;
    }
    // 翻页（currentPage 变化）→ 表体竖向回顶，从第一条开始。
    // primary 模式下竖向 position 由祖先 NestedScrollView 持有（_bodyV 无 client），
    // 须走 PrimaryScrollController；且 didUpdateWidget 处于 build 期，inner position
    // 首次翻页可能尚未挂载 → 推迟到帧结束后再 jump。
    if (oldWidget.currentPage != widget.currentPage) {
      if (widget.primary) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final ScrollController? c = PrimaryScrollController.maybeOf(context);
          if (c != null && c.hasClients) {
            c.jumpTo(0);
          }
        });
      } else if (_bodyV.hasClients) {
        _bodyV.jumpTo(0);
      }
    }
    // 外部翻页后，跳页输入框同步回当前页（用户未提交的输入被放弃，符合直觉）。
    if (oldWidget.currentPage != widget.currentPage) {
      _pageCtrl.text = '${widget.currentPage}';
    }
    // 全屏中：数据/列变化 bump tick，驱动全屏路由内的表格重建。
    // didUpdateWidget 处于 build 阶段，直接写 ValueNotifier 会让全屏路由里的
    // ValueListenableBuilder 在 build 中 setState（断言崩溃）；推迟到本帧结束后，
    // 且仅全屏时才需要通知（非全屏没有监听者）。
    if (_fullscreen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fsTick.value++;
      });
    }
  }

  /// 全屏切换：进入时弹全屏路由（正常树让位）；全屏里再点「退出全屏」pop 该路由。
  /// 注意：正常树重新接管表格的时机必须绑在全屏路由彻底 dispose（含退出动画结束）
  /// 之后，不能挂在 await 返回点——否则退出动画播放期间正常树一旦挂回，同一批
  /// ScrollController 会同时挂在全屏路由和正常树两棵树上，Scrollbar 每帧断言
  /// "attached to more than one ScrollPosition"（2026-07-29 现场报错）。
  Future<void> _toggleFullscreen() async {
    // 切全屏会换渲染树，进行中的拖拽手势可能不再回调 onEnd，浮层 target 也在旧树，
    // 统一重置卸下（FM6）。
    columnHeaderDragReset();
    if (_fullscreen) {
      // 在全屏路由内点击：pop 全屏对话框（路由 dispose 后统一复位标志）。
      Navigator.of(context, rootNavigator: true).pop();
      return;
    }
    setState(() => _fullscreen = true);
    widget.onFullscreenChanged?.call(true);
    await showGeneralDialog<void>(
      context: context,
      barrierLabel: '全屏表格', // TODO(l10n): 补 arb
      barrierColor: Colors.transparent, // 内容整屏不透明，无需遮罩色
      pageBuilder: (ctx, _, _) => _FullscreenDisposer(
        // 路由完全移除后再让正常树接管同一批 ScrollController（见上方注释）。
        onDisposed: () {
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _fullscreen = false);
              widget.onFullscreenChanged?.call(false);
            }
          });
        },
        child: ValueListenableBuilder<int>(
          valueListenable: _fsTick,
          builder: (ctx2, _, _) {
            final theme = Theme.of(ctx2);
            return Material(
              color: theme.colorScheme.surface,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  child: Column(
                    children: [
                      Expanded(child: _buildTableStage(ctx2)),
                      if (widget.summaryBar != null) _buildSummaryBar(ctx2),
                      if (!widget.embedded && widget.totalPages > 1)
                        _buildPager(ctx2),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 两列集合的 key 序列是否一致（用于判定是否需要重置/重算列宽）。
  bool _sameColumnKeys(List<MasterColumnDef<T>> a, List<MasterColumnDef<T>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key) return false;
    }
    return true;
  }

  /// 按当前列与已加载数据自动测算各列宽度：取表头标签与单元格值的最大文本宽，加内边距/图标富余。
  /// 用户已手动拖拽的列（[_manualResized]）保留原宽度不重算。仅在 [_widthsDirty] 时执行。
  void _ensureWidths(BuildContext context) {
    // 字号档（textScaler）变化也要重算：渲染时文字按放大字号铺，但量宽用的 TextPainter
    // 必须显式带上同一 textScaler 才量得准（否则按 1.0 量偏窄，大字号下要拖才显示全）。
    final textScaler = MediaQuery.textScalerOf(context);
    final scale = textScaler.scale(1);
    if (_lastScale != null && _lastScale != scale) {
      _widthsDirty = true;
    }
    if (!_widthsDirty) return;
    _widthsDirty = false;
    _lastScale = scale;
    final theme = Theme.of(context);
    final headerStyle = (theme.textTheme.labelMedium ?? const TextStyle())
        .copyWith(fontWeight: FontWeight.w700);
    final bodyStyle = theme.textTheme.bodySmall ?? const TextStyle();
    final next = List<double>.filled(
      widget.columns.length,
      _minColWidth,
      growable: true,
    );
    // 取样池：主数据 + 前导分组条目（分组行与主行共用同一套列宽，故一并参与测算，
    // 保证展开/折叠分组时列宽不跳动；分组条目通常是禁用/不明货品，量小不影响性能）。
    final pool = <T>[
      ...widget.items,
      for (final g in (widget.leadingGroups ?? <MasterDataGroup<T>>[]))
        ...g.items,
    ];
    final sampleCount = pool.length < _autoFitSampleSize
        ? pool.length
        : _autoFitSampleSize;
    for (var i = 0; i < widget.columns.length; i++) {
      if (_manualResized.contains(i) && i < _widths.length) {
        next[i] = _widths[i];
        continue;
      }
      final def = widget.columns[i];
      double w = _measureText(def.label, headerStyle, textScaler);
      for (var r = 0; r < sampleCount; r++) {
        final tw = _measureText(
          def.value(pool[r]) ?? '',
          bodyStyle,
          textScaler,
        );
        if (tw > w) w = tw;
      }
      final measured =
          (w +
                  _cellPadX * 2 +
                  _headerIconAllowance +
                  (def.sortable ? _sortIconAllowance : 0) +
                  (def.info != null ? _headerInfoIconAllowance : 0) +
                  _autoFitBuffer)
              .clamp(_minColWidth, _maxColWidth);
      final declared = def.width.clamp(_minColWidth, _maxColWidth);
      // Rich cells may contain buttons/progress/two-line guidance whose width
      // cannot be inferred from [value]. Treat the declared width as a minimum;
      // plain text columns can still auto-grow beyond it.
      next[i] = measured < declared ? declared : measured;
    }
    _widths = next;
  }

  /// 测量单行文本渲染宽度（TextPainter，maxLines:1）。测完 dispose 防泄漏。
  ///
  /// [textScaler] 必须传当前生效的字号系数（来自 MediaQuery.textScalerOf）——单元格里
  /// 的 Text 在渲染时会自动吃这个缩放，量宽若不带它就会按未放大字号量、列偏窄。
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

  @override
  void dispose() {
    // 跟手浮层/拖拽态由 UtenColumnDragHideHost.dispose（super 链）统一卸除。
    _fsTick.dispose();
    _headerH.dispose();
    _bodyH.dispose();
    _bodyV.dispose();
    _overlayH.dispose();
    _hBarY.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  double get _totalWidth {
    var s = widget.selectable ? _selectionColWidth : 0.0;
    for (final i in _visibleIndices) {
      if (i < _widths.length) s += _widths[i];
    }
    return s;
  }

  /// 当前可见列在原列集合中的下标：按 [_columnOrder] 顺序、隐藏列跳过
  /// （列宽仍按原下标存 [_widths]；[initState]/列集合变化时同步重建 _columnOrder）。
  List<int> get _visibleIndices {
    final byKey = <String, int>{
      for (var i = 0; i < widget.columns.length; i++) widget.columns[i].key: i,
    };
    return [
      for (final key in _columnOrder)
        if (byKey.containsKey(key) && !_hiddenKeys.contains(key)) byKey[key]!,
    ];
  }

  /// 可见列数（至少 1：[_toggleColumn] 拦住最后一列的隐藏）。
  int get _visibleCount => widget.columns.length - _hiddenKeys.length;

  /// 切换单列显隐：最后一列不允许隐藏，避免表格没列。
  void _toggleColumn(String key) {
    setState(() {
      if (_hiddenKeys.contains(key)) {
        _hiddenKeys.remove(key);
      } else if (_visibleCount > 1) {
        _hiddenKeys.add(key);
      }
    });
    _fsTick.value++;
  }

  /// 全选(true)=全部显示；取消全选(false)=仅留首列（表格至少保留一列）。
  void _toggleAllColumns(bool selectAll) {
    setState(() {
      _hiddenKeys.clear();
      if (!selectAll && widget.columns.length > 1) {
        _hiddenKeys.addAll(widget.columns.skip(1).map((c) => c.key));
      }
    });
    _fsTick.value++;
  }

  // —— 表头列手势（共用 UtenColumnHeaderDragHost）——
  // 竖滑拖出隐藏（单指契约、过阈值 arm、末列永不 arm）+ 长按拎起横拖排序：
  // 全部由 mixin 提供；本类只补列链接/列宽/列名/可隐判定与落位回调。

  /// 单列表头：横拖换位 + 竖拖移除的手势区（识别器在外层，拖拽中不重建）；
  /// 内层 columnHeaderCell 负责原格变淡与两类跟手浮层的锚点。
  /// 作为外层 Stack 的**非定位**子节点（由内层 _FilterCell 的 minHeight:44 撑高）；
  /// resize 手柄是其 Stack 兄弟且在最上层，右 8px 命中区优先吃横向拖拽，与长按
  /// 排序不冲突（按住不动过 slop 才拎起，横滑未按住归表头横向滚动）。
  Widget _buildDraggableHeaderCell(ThemeData theme, int i, Widget filterCell) {
    return columnHeaderGestureArea(i, columnHeaderCell(i, filterCell));
  }

  // —— 多选（selectable 模式）——

  /// 多选模式下表头/表体行的交叉轴对齐：stretch 让所有单元格同高、网格竖线贯通，
  /// 文字垂直居中；非多选沿用默认 center（行为不变）。
  /// ⚠️ stretch 在无界高度下会让子级拿到 tight h=Infinity 直接布局崩溃
  /// （表头在横向滚动视口内、表体行在竖向 ListView 内，二者高度均无界），
  /// 因此 selectable 的两处 Row 必须套 [IntrinsicHeight] 先按内容收紧高度
  /// （2026-08-11 采购/委外/仓库任务台表头+表体整片空白的根因）。
  CrossAxisAlignment get _selectableCross => widget.selectable
      ? CrossAxisAlignment.stretch
      : CrossAxisAlignment.center;

  /// selectable 的 stretch 行在无界高度下的合法化包裹（见 [_selectableCross]）。
  /// 非 selectable 行用 center、不需要，保持原样零开销。
  Widget _boundStretchRow(Widget row) =>
      widget.selectable ? IntrinsicHeight(child: row) : row;

  /// 当前页可勾选的行 id 集合（主数据行 + 已展开的前导分组 items；过滤空 id）。
  /// 内联计算、勿缓存到实例字段——全屏 post-frame 间隙会读到旧值。
  Set<String> _pageSelectableIds() {
    final ids = <String>{};
    void add(T it) {
      final id = widget.idOf?.call(it);
      if (id != null && id.isNotEmpty) ids.add(id);
    }

    for (final it in widget.items) {
      add(it);
    }
    final leading = widget.leadingGroups;
    if (leading != null) {
      for (final g in leading) {
        if (_expandedGroups.contains(g.id)) {
          for (final it in g.items) {
            add(it);
          }
        }
      }
    }
    return ids;
  }

  /// 表头三态值：false=本页全未选 / true=本页全选 / null=部分选。
  bool? get _headerCheckValue {
    final pageIds = _pageSelectableIds();
    if (pageIds.isEmpty) return false;
    final hit = pageIds.where(widget.selectedIds.contains).length;
    if (hit == 0) return false;
    if (hit == pageIds.length) return true;
    return null;
  }

  /// 表头三态切换：Checkbox.onChanged 回传的是点击后的新值，不是旧值。
  /// true=全选本页；false/null=取消本页。
  /// 拷贝调用方集合后回交，从不就地改 widget.selectedIds。
  void _onToggleAllPage(bool? newValue) {
    final pageIds = _pageSelectableIds();
    if (pageIds.isEmpty) return;
    final next = Set<String>.of(widget.selectedIds);
    if (newValue == true) {
      next.addAll(pageIds);
    } else {
      next.removeAll(pageIds);
    }
    widget.onSelectedIdsChanged?.call(next);
    _fsTick.value++; // 全屏路由随 selectedIds 重建（三态/勾选刷新）。
  }

  /// 单行勾选切换。
  void _toggleRow(T item, bool checked) {
    final id = widget.idOf?.call(item);
    if (id == null || id.isEmpty) return;
    final next = Set<String>.of(widget.selectedIds);
    if (checked) {
      next.add(id);
    } else {
      next.remove(id);
    }
    widget.onSelectedIdsChanged?.call(next);
    _fsTick.value++;
  }

  /// selectable 模式下数据单元格文本：整行 stretch 时垂直居中；非 selectable 不走此方法。
  Widget _dataCellText(String value, TextStyle style) {
    final text = Text(
      value,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return widget.selectable
        ? Align(alignment: Alignment.centerLeft, child: text)
        : text;
  }

  Widget _dataCell(
    MasterColumnDef<T> column,
    T item,
    TextStyle textStyle,
    bool selected,
  ) {
    final builder = column.cellBuilder;
    if (builder == null) {
      return _dataCellText(column.value(item) ?? '', textStyle);
    }
    final value = column.value(item)?.trim();
    final custom = MasterDataTableCellScope(
      selected: selected,
      foregroundColor: textStyle.color,
      child: DefaultTextStyle.merge(
        style: textStyle,
        child: IconTheme.merge(
          data: IconThemeData(color: textStyle.color),
          child: Builder(builder: (cellContext) => builder(cellContext, item)),
        ),
      ),
    );
    final aligned = widget.selectable
        ? Align(alignment: Alignment.centerLeft, child: custom)
        : custom;
    if (column.cellBuilderHandlesSemantics) return aligned;
    return Semantics(
      label: value == null || value.isEmpty
          ? column.label
          : '${column.label}: $value',
      child: aligned,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 全屏中：表格在全屏路由里渲染，正常树让位（ScrollController 只挂一棵树）。
    if (_fullscreen) {
      return const SizedBox.shrink();
    }
    // 嵌入模式（详情页明细表）：无界高度场景按内容收缩、无翻页条。
    if (widget.embedded) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildTable(context),
          if (widget.summaryBar != null) _buildSummaryBar(context),
          if (_hasFloatingBatchActions)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: _buildFloatingBatchActions(context),
              ),
            ),
        ],
      );
    }
    return Column(
      children: [
        Expanded(child: _buildTableStage(context)),
        // 合计条在表体（内部滚动）之外、翻页条之上：滚到哪一行它都在。
        if (widget.summaryBar != null) _buildSummaryBar(context),
        if (widget.totalPages > 1) _buildPager(context),
      ],
    );
  }

  /// 合计条容器：与表体同宽、左右对齐表格内容边距。
  /// 只在这一处定义间距，所有接入页的合计条位置与留白因此完全一致。
  Widget _buildSummaryBar(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
    child: widget.summaryBar,
  );

  bool get _hasFloatingBatchActions =>
      widget.selectable && widget.batchActionsBuilder != null;

  /// 自动加载触发距底阈值（约 4~5 行高）：滚到末尾前预取下一页，体感「到底即有」。
  static const double _loadMoreEdge = 200;

  /// 竖向滚动临近底部时触发 [MasterDataTableView.onLoadMore]。
  /// loadingMore 为 true 期间不重复触发；更多页判断在调用方（见参数文档）。
  void _maybeTriggerLoadMore(ScrollMetrics metrics) {
    if (widget.onLoadMore == null || widget.loadingMore) return;
    if (metrics.extentAfter < _loadMoreEdge) widget.onLoadMore!();
  }

  /// 表格批量动作与采购任务工作台一致：选择摘要仍在表头上方，真正业务动作
  /// 悬浮在右下角。动作层属于表格自身，因此普通视图和全屏路由使用同一实现。
  Widget _buildTableStage(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical) _scheduleHBarUpdate();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.vertical) {
            _scheduleHBarUpdate();
            _maybeTriggerLoadMore(notification.metrics);
          }
          return false;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildTable(context),
            if (_hasFloatingBatchActions)
              PositionedDirectional(
                end: UtenSpacing.s16,
                bottom: UtenSpacing.s16,
                child: _buildFloatingBatchActions(context),
              ),
          ],
        ),
      ),
    );
  }

  /// 空态/错误/加载占位壳。
  /// primary（联动折叠）模式下包一层拾取 PrimaryScrollController 的竖向 ListView：
  /// 空表/错误区域仍可上滑收起外层 header（页面任意位置触发滚动），
  /// 矮视口下占位内容可滚不溢出；非 primary 保持原 Center 语义不变。
  Widget _stateShell(Widget child) {
    if (!widget.primary) {
      return Center(child: child);
    }
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        primary: true,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: child),
          ),
        ],
      ),
    );
  }

  /// 当前有值的表头筛选列（含「筛空值」哨兵）。
  List<String> get _activeFilterKeys => [
    for (final entry in widget.filters.entries)
      if (entry.value != null && entry.value!.isNotEmpty) entry.key,
  ];

  /// 全屏切换按钮：工具条与空态共用一份（全屏里 0 行时也必须能退出，否则
  /// 表头筛选把表过滤成空后会被困在全屏路由——2026-09-10 物料分析反馈）。
  /// 高度对齐工具条统一口径 48；按钮态靠 `_fsTick` 重建时读 `_fullscreen`。
  Widget _fullscreenToggleButton() => UtenButton(
    key: const ValueKey('master-table-fullscreen-toggle'),
    size: UtenButtonSize.large,
    height: UtenTableToolbar.controlHeight,
    icon: _fullscreen
        ? Icons.fullscreen_exit_rounded
        : Icons.fullscreen_rounded,
    onPressed: _toggleFullscreen,
    child: Text(_fullscreen ? '退出全屏' : '全屏'),
  );

  /// 成功空态仍保留调用方业务工具条(例如 BOM 的“添加组件”)。加载中/错误态不走
  /// 本壳，避免基础数据尚未确认时开放依赖现状的写动作。
  Widget _emptyStateWithToolbarActions(Widget child) {
    final activeFilterKeys = _activeFilterKeys;
    final actions = <Widget>[
      // 空表不给「进全屏」：一张没有行的表放大到整屏毫无意义，用户反而会以为
      // 数据被按钮挡住了（2026-09-11 销售订单财务确认「待确认」空态反馈）。
      // 已在全屏中时保留按钮——那是唯一的退出口。
      if (_fullscreen) _fullscreenToggleButton(),
      // 有激活表头筛选却 0 行：列头筛选控件随表头一起不渲染，用户没有入口
      // 把「看不见的筛选」撤掉——这里给一键清除（逐列回调 onFilterChanged(key,null)）。
      if (activeFilterKeys.isNotEmpty)
        UtenButton(
          key: const ValueKey('master-table-clear-filters'),
          height: UtenTableToolbar.controlHeight,
          icon: Icons.filter_alt_off_rounded,
          onPressed: () {
            for (final key in activeFilterKeys) {
              widget.onFilterChanged(key, null);
            }
          },
          child: const Text('清除筛选'), // TODO(l10n): 补 arb
        ),
      if (widget.selectable && !_hasFloatingBatchActions)
        _buildBatchBar(Theme.of(context)),
      // 空态也保留左簇前缀按钮（视图切换 chips 等）：筛选出 0 行时用户才有得
      // 切回其他视图——否则整个工具条随表格一起消失，页面“不知道点哪里”
      // （2026-09-09 物料分析「待确认路线=0」反馈的根因）。
      ...?widget.toolbarLeadingActions,
      ...?widget.toolbarActions,
    ];
    if (actions.isEmpty) return _stateShell(child);
    final toolbar = Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: actions,
      ),
    );
    if (widget.embedded) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [toolbar, _stateShell(child)],
      );
    }
    // A two-pane page can temporarily leave only one row-height for its empty
    // table while banners or filters are visible.  A fixed Column needs the
    // 44dp action plus its 8dp gap and overflows before the empty state can
    // shrink.  Slivers keep the action reachable and let the empty state scroll
    // naturally in that bounded viewport; primary mode still participates in
    // the ancestor NestedScrollView.
    return CustomScrollView(
      controller: widget.primary ? null : _bodyV,
      primary: widget.primary,
      physics: widget.primary
          ? const AlwaysScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(child: toolbar),
        SliverFillRemaining(hasScrollBody: false, child: Center(child: child)),
      ],
    );
  }

  Widget _buildTable(BuildContext context) {
    final theme = Theme.of(context);
    // 嵌入场景（滑窗/picker/弹窗内明细表）默认不显示全屏按钮：整屏路由在受限容器里会铺满
    // 屏幕（详细排产滑窗 bug）。显式 showFullscreenToggle 可覆盖。
    final showFullscreen = widget.showFullscreenToggle ?? !widget.embedded;
    if (widget.isLoading && widget.items.isEmpty) {
      return _stateShell(const CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (widget.error != null) {
      return _stateShell(
        UtenEmpty.error(
          message: widget.error,
          actionLabel: '重试', // TODO(l10n): 补 arb
          onAction: widget.onRetry,
        ),
      );
    }
    final groups = widget.leadingGroups ?? <MasterDataGroup<T>>[];
    final hasGroupRows = groups.any(
      (g) =>
          g.items.isNotEmpty ||
          (g.total ?? 0) > 0 ||
          g.loading ||
          g.error != null ||
          g.onExpand != null,
    );
    // 主数据为空且无任何前导分组 → 空态占位（有分组时仍渲染表头 + 分组行）。
    if (widget.items.isEmpty && !hasGroupRows) {
      final activeFilters = _activeFilterKeys.length;
      return _emptyStateWithToolbarActions(
        UtenEmpty(
          icon: Icons.table_rows_outlined,
          message: widget.emptyMessage,
          // 空态说明补一行筛选生效数，配合上方「清除筛选」按钮。
          description: activeFilters > 0
              ? '当前有 $activeFilters 个表头筛选生效' // TODO(l10n): 补 arb
              : null,
        ),
      );
    }
    _ensureWidths(context);
    final total = _totalWidth;
    // 行计划：前导分组（表头下第一区）+ 主数据行。分组折叠=仅一条跨满宽标题行；
    // 展开=其 items 按主表同款列逐行渲染（与主行共用 _widths / _visibleIndices / 横滚）。
    final plan = <({bool header, MasterDataGroup<T>? group, T? item})>[];
    for (final g in groups) {
      if (g.items.isEmpty &&
          (g.total ?? 0) == 0 &&
          !g.loading &&
          g.error == null &&
          g.onExpand == null) {
        continue; // 明确 N=0 且不可加载的分组不渲染
      }
      plan.add((header: true, group: g, item: null));
      if (_expandedGroups.contains(g.id)) {
        for (final it in g.items) {
          plan.add((header: false, group: g, item: it));
        }
      }
    }
    for (final it in widget.items) {
      plan.add((header: false, group: null, item: it));
    }
    // stretch：列总宽 < 视口宽时（颜色/单位等列少主档）表头与表体撑满视口宽、
    // 内容靠左，而非整体水平居中（Column 默认 crossAxisAlignment.center 会把窄于
    // 视口的表格居中、左右留白）。仅作用于交叉轴（横向），不影响主轴 Flexible(loose)
    // 的「行少收缩、横滚条贴末行」行为。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 表头上方工具条：左侧「表头设置」列显隐选择 + 追加按钮（预览打印/下载
        // 表格等）左对齐；右侧为调用方动作区（刷新等——全站口径：刷新按钮放
        // 表格右上角）。宽度足够时动作区固定贴右；窄屏回退整条 Wrap 流式换行
        //（动作不收缩，Row 会在窄约束溢出，故按可用宽度分流）。
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final toolbarChildren = [
                if (widget.showColumnChooser)
                  UtenColumnChooserButton(
                    entries: [
                      for (final c in widget.columns)
                        UtenColumnChooserEntry(key: c.key, label: c.label),
                    ],
                    hiddenKeys: _hiddenKeys,
                    onToggle: _toggleColumn,
                    onToggleAll: _toggleAllColumns,
                    order: _columnOrder,
                    onReorder: (oldIndex, newIndex) =>
                        _reorderColumnByKeys(oldIndex, newIndex),
                  ),
                // 全屏切换：表格放大到整屏显示（行列多时能看更多内容），
                // 再点退出（与空态共用 _fullscreenToggleButton）。
                if (showFullscreen) _fullscreenToggleButton(),
                // 前缀按钮：视图切换类 chip 紧挨全屏按钮（左簇内，Wrap s8 间距）。
                ...?widget.toolbarLeadingActions,
                // 选择摘要：有悬浮批量动作时随动作进右下悬浮组（见
                // [_buildFloatingBatchActions]）；无悬浮动作的表格仍驻表头上方；
                // 页面自管选择摘要（showSelectionSummary=false）时不驻留。
                if (widget.selectable &&
                    widget.showSelectionSummary &&
                    !_hasFloatingBatchActions)
                  _buildBatchBar(theme),
              ];
              final actions = widget.toolbarActions;
              if (actions == null || constraints.maxWidth < 720) {
                return Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [...toolbarChildren, ...?actions],
                );
              }
              return Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: toolbarChildren,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  // 右侧贴边动作区也走 Wrap（s8 间距）：多个动作不再零间距粘连，
                  // 宽度不足时换行而非溢出。
                  Wrap(
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: actions,
                  ),
                ],
              );
            },
          ),
        ),
        // 表头：横向跟随表体同步（无可见滚动条），竖向固定（sticky）。
        // 表头整体 SelectionContainer.disabled：表头有「拖拽换位/移除列」「拖拽调宽」
        // 手势，与文字拖选打架（准则 §3.4：表头不进选择区）；disabled 同时挡住外层
        // 页面级 SelectionArea（UtenContentContainer）渗入，保证手势稳定。
        SelectionContainer.disabled(
          child: Material(
            color: theme.colorScheme.surfaceContainerHigh,
            child: SingleChildScrollView(
              controller: _headerH,
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: total, child: _buildHeaderRow(theme)),
            ),
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          color: theme.colorScheme.outlineVariant,
        ),
        // 表体：竖向按内容收缩（行少→横滚条贴最后一行），顶到 LayoutBuilder 上限则竖向滚动（行多→横滚条钉视口底）。
        // 用 Flexible(loose) 而非 Expanded，让 ListView(shrinkWrap) 在行少时真正收缩；
        // ConstrainedBox(maxHeight) 把高度封顶在可用空间，行多时转为可滚。
        // embedded（详情页 ListView 等无界高度场景）不能用 Flexible：flex 在无界约束下
        // 会直接抛 "non-zero flex but incoming height constraints are unbounded"。
        // primary（联动折叠）例外：表体竖向填满联动区（折叠手势全域有效），流内横滚条
        // 会沉到区底 → 横滚条改走覆盖层（下方 Stack），按内容高度定位。
        _BodyFlex(
          embedded: widget.embedded,
          primary: widget.primary,
          virtualized: widget.virtualized,
          child: _maybeSelectionArea(
            Stack(
              key: _bodyAreaKey,
              children: [
                LayoutBuilder(
                  builder: (ctx, c) {
                    // 区高随卡片折叠/展开变化（constraints 变化）→ 重测横滚条位置。
                    if (widget.primary || _hasFloatingBatchActions) {
                      _scheduleHBarUpdate();
                    }
                    final list = ListView.builder(
                      controller: widget.primary ? null : _bodyV,
                      // primary 模式：交还给祖先 NestedScrollView 注入的 PrimaryScrollController
                      // 参与联动。shrinkWrap 必须关（否则短表 maxScrollExtent=0，header 收完后
                      // 滚动卡死）；physics 必须 AlwaysScrollable（行少时 body 也要能滚→header 才收）。
                      primary: widget.primary,
                      shrinkWrap: widget.primary || widget.virtualized
                          ? false
                          : true,
                      physics: widget.primary
                          ? const AlwaysScrollableScrollPhysics()
                          : const ClampingScrollPhysics(),
                      // 底部留可滚余量：内容超高时滚动到底，末行能露出钉底横滚条
                      // （问题 #10）与悬浮批量按钮（[_batchPad]）上方；内容装得下时
                      // 为小间距（[_bodyBottomPad]，见 [_updateBodyPad] 动态切换）。
                      padding: EdgeInsets.only(bottom: _bodyBottomPad),
                      itemCount: plan.length + (widget.loadingMore ? 1 : 0),
                      itemBuilder: (ctx, i) {
                        if (widget.loadingMore && i == plan.length) {
                          return const Padding(
                            padding: EdgeInsets.all(UtenSpacing.s12),
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        }
                        final row = plan[i];
                        if (row.header) {
                          return _buildGroupHeader(theme, row.group!);
                        }
                        // 数据行：item 必非空（仅 header 行 item=null）；显式 null
                        // 判定把 T? 提升为 T，避免对类型参数用 `!` 的告警。
                        final item = row.item;
                        if (item == null) {
                          return const SizedBox.shrink();
                        }
                        // RepaintBoundary 隔离行重绘（选中/列宽/刷新时只绘本行，不蔓延整表）。
                        // 稳定 key：rowKeyOf 优先，缺省回落 idOf（数据刷新时 Selectable
                        // 复用而非重建，降低 SelectionArea 的 CME 抖动，FM2）；否则用下标。
                        final idKey =
                            widget.rowKeyOf?.call(item) ??
                            widget.idOf?.call(item);
                        final rowWidget = RepaintBoundary(
                          key:
                              widget.rowWidgetKeyOf?.call(item) ??
                              ((idKey != null && idKey.isNotEmpty)
                                  ? ValueKey('row:$idKey')
                                  : ValueKey('idx:$i')),
                          child: _buildDataRow(theme, item),
                        );
                        // 末行挂测量键：primary 模式横滚条按末行定位（贴末行下）。
                        // 内容超高时末行被虚拟化不挂载 → 横滚条钉表体区底。
                        if (i == plan.length - 1) {
                          return KeyedSubtree(
                            key: _lastRowKey,
                            child: rowWidget,
                          );
                        }
                        return rowWidget;
                      },
                    );
                    final hArea = SingleChildScrollView(
                      controller: _bodyH,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: total,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: c.maxHeight),
                          child: list,
                        ),
                      ),
                    );
                    // 横向滚动条（左右）：非 primary 用流内 Scrollbar（表体随内容收缩，
                    // 行少贴末行下、行多钉视口底）；primary 表体填满联动区（折叠手势），
                    // 流内条会沉到区底 → 改用下方 Stack 覆盖层按内容高度定位。
                    final hWrapped = widget.primary
                        ? hArea
                        : Scrollbar(
                            controller: _bodyH,
                            thumbVisibility: true,
                            child: hArea,
                          );
                    return Scrollbar(
                      // 竖向滚动条（上下）：绑表体 ListView 的 _bodyV。置于横向滚动之外层，
                      // 使 thumb 固定在视口右边缘、不随横向滚动被带走。竖向 ListView 嵌在
                      // 横向 SingleChildScrollView 内层，其滚动通知冒泡到本 Scrollbar 时
                      // depth=1（穿过了横向那层 Scrollable），Scrollbar 默认 notificationPredicate
                      // (depth==0) 会滤掉 → thumb 不更新；放宽到 depth<=1 才能捕获竖向滚动。
                      // primary 模式下 _bodyV 无 client，省略 controller：Scrollbar 经
                      // notificationPredicate(depth<=1) 仍能捕获 primary ListView 的竖向滚动。
                      controller: widget.primary ? null : _bodyV,
                      thumbVisibility: true,
                      notificationPredicate: (ScrollNotification n) =>
                          n.depth <= 1,
                      child: hWrapped,
                    );
                  },
                ),
                // primary 模式横滚条覆盖层：按内容高度定位（[_hBarY] 为底边 local top）。
                // 内容少 → 贴末行下方（约 1px 空隙）；超高 → 钉表体区底。与 _bodyH 双向同步，
                // 表头经既有 _sync 跟随。非 primary 不渲染（自然滚动条本就贴内容）。
                if (widget.primary)
                  ValueListenableBuilder<double?>(
                    valueListenable: _hBarY,
                    builder: (context, y, _) => Positioned(
                      left: 0,
                      right: 0,
                      top: (y ?? 0) - _hBarHeight,
                      child: Offstage(
                        offstage: y == null,
                        child: SizedBox(
                          height: _hBarHeight,
                          child: Scrollbar(
                            controller: _overlayH,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: _overlayH,
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
            ),
          ),
        ),
      ],
    );
  }

  /// selectable 模式（任务中心批量勾选）下整表 SelectionContainer.disabled：批量勾选
  /// 场景不需要文本复制，且勾选/拖选同处一表会增加 SelectionRegistrar 的 CME 风险
  /// （FM2）。disabled 同时把表体与外层页面级 SelectionArea（UtenContentContainer
  /// 默认包裹）隔开——勾选行为不受页面选择区影响。
  /// 注：2026-08-11 查明 selectable 表整片空白的真正根因是 stretch 行在无界高度下
  /// 布局崩溃（见 [_selectableCross]），并非 SelectionArea；此处隔离仅按上述理由保留。
  /// 非 selectable 表默认保留自身文本复制；重交互调用方可用
  /// [MasterDataTableView.enableTextSelection] 显式退出。
  Widget _maybeSelectionArea(Widget child) =>
      widget.selectable || !widget.enableTextSelection
      ? SelectionContainer.disabled(child: child)
      : SelectionArea(child: child);

  /// 选择摘要：已选 N 项 + 清除（升位公共组件 UtenSelectionSummaryPill）。
  /// 业务动作在右下悬浮区，不再塞进表头工具条。
  Widget _buildBatchBar(ThemeData theme) {
    final ids = widget.selectedIds;
    final count = widget.selectionSummaryCount ?? ids.length;
    final hasSelection = count > 0;
    return UtenSelectionSummaryPill(
      count: count,
      clearKey: const Key('master-table-clear-selection'),
      onClear: hasSelection
          ? () {
              if (widget.onClearSelection != null) {
                widget.onClearSelection!();
              } else {
                widget.onSelectedIdsChanged?.call(<String>{});
              }
              _fsTick.value++;
            }
          : null,
    );
  }

  Widget _buildFloatingBatchActions(BuildContext context) {
    final theme = Theme.of(context);
    final ids = widget.selectedIds;
    final actions =
        widget.batchActionsBuilder?.call(context, ids) ?? const <Widget>[];
    if (actions.isEmpty) return const SizedBox.shrink();

    // 已选摘要与业务动作同框（悬浮组首位），选择数与按钮零距离——
    // 全站统一口径：有悬浮批量动作的表格，已选胶囊不再驻表头工具条。
    final children = [if (widget.selectable) _buildBatchBar(theme), ...actions];
    // 2026-09-11 去掉 0 选中时的 Opacity(0.4)：叠在本就发灰的禁用按钮上会整组
    // 淡到「看不出这里能点」（物料分析、下达采购/委外/自制的用户反馈）。
    // 未选态的可辨识度改由控件自身承担——UtenButton 禁用态是实底+描边+可读灰字，
    // UtenSelectionSummaryPill 未选态是实底+描边，两者都清楚可见且明显不可用。
    return UtenFloatingActionGroup(children: children);
  }

  /// 前导分组标题行：跨满表宽（_totalWidth），与表头/数据行同处一个横向 ScrollView，
  /// 故横滚同步、列边界对齐。底色取 [MasterDataGroup.tint]（禁用=浅红等）；点击切换展开。
  /// 单行布局：图标 + 标题（加粗）+ 副标题（灰、可省略号）+ 「下拉查看详情」加粗深红 + 旋转箭头。
  /// 「下拉查看详情」与箭头用深红强提示色，老人也能看清（禁用/不明分组一致）。
  Widget _buildGroupHeader(ThemeData theme, MasterDataGroup<T> group) {
    final expanded = _expandedGroups.contains(group.id);
    final tint = group.tint ?? theme.colorScheme.surfaceContainerHigh;
    final error = group.error?.trim();
    final hasError = error != null && error.isNotEmpty;
    final moreLeft =
        !group.loading &&
        !hasError &&
        (group.total ?? group.items.length) > group.items.length;
    final detailStyle = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.bold,
      color: UtenColors.error,
    );
    final expansionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150);
    return Semantics(
      button: true,
      expanded: expanded,
      label: '${group.title}，${expanded ? '已展开' : '已折叠'}',
      child: InkWell(
        onTap: () {
          final willExpand = !expanded;
          setState(() {
            if (expanded) {
              _expandedGroups.remove(group.id);
            } else {
              _expandedGroups.add(group.id);
            }
          });
          // 全屏路由经 _fsTick 驱动重建；bump 使全屏里展开/折叠同步（与列显隐同款）。
          _fsTick.value++;
          if (willExpand) group.onExpand?.call();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.outline, width: 0.5),
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  if (group.icon != null) ...[
                    Icon(
                      group.icon,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                  ],
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            group.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (group.subtitle != null) ...[
                          const SizedBox(width: UtenSpacing.s8),
                          Flexible(
                            child: Text(
                              group.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                        if (moreLeft && expanded)
                          Padding(
                            padding: const EdgeInsets.only(
                              left: UtenSpacing.s8,
                            ),
                            child: Text(
                              '仅前 ${group.items.length}/${group.total}', // TODO(l10n): 补 arb
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  if (expanded && group.loading) ...[
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text('正在加载', style: theme.textTheme.labelLarge),
                  ] else if (expanded && hasError)
                    Tooltip(
                      message: error,
                      child: TextButton.icon(
                        onPressed: group.onRetry ?? group.onExpand,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('加载失败，重试'),
                      ),
                    )
                  else
                    Text(group.detailLabel, style: detailStyle),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: expansionDuration,
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 22,
                      color: UtenColors.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderRow(ThemeData theme) {
    // 多选表头三态全选格（合成单元格）：false=本页全未选 / true=全选 / 空=部分。
    // 横滚时钉在视口左缘（[UtenFrozenLeadingColumn]），行内留等宽占位保持列对齐。
    final headerSelectionCell = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(right: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Center(
        child: Checkbox(
          tristate: true,
          value: _headerCheckValue,
          onChanged: _pageSelectableIds().isEmpty ? null : _onToggleAllPage,
        ),
      ),
    );
    return _boundStretchRow(
      // 换位拖动中在表头行上渲染插入位指示线（前导选择列让位）。
      columnHeaderIndicatorOverlay(
        leadingInset: widget.selectable ? _selectionColWidth : 0,
        child: _withFrozenSelection(
          controller: _headerH,
          cell: headerSelectionCell,
          row: Row(
            crossAxisAlignment: _selectableCross,
            children: [
              if (widget.selectable)
                SizedBox(width: _selectionColWidth, child: headerSelectionCell),
              for (final i in _visibleIndices)
                Container(
                  width: _widths[i],
                  // 表头竖线分隔（与 UtenEditableGrid 表头一致：outline/width1）。
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: theme.colorScheme.outline),
                    ),
                  ),
                  child: Stack(
                    children: [
                      _buildDraggableHeaderCell(
                        theme,
                        i,
                        _FilterCell(
                          label: widget.columns[i].label,
                          sortKey: widget.columns[i].key,
                          type: widget.columns[i].type,
                          sortable: widget.columns[i].sortable,
                          sortActive:
                              widget.sortColumn == widget.columns[i].key,
                          sortAscending: widget.sortAscending,
                          onSort: widget.onSortChange,
                          info: widget.columns[i].info,
                          buckets:
                              widget.facets[widget.columns[i].key] ?? const [],
                          nullCount:
                              widget.nullCounts[widget.columns[i].key] ?? 0,
                          selected: widget.filters[widget.columns[i].key],
                          onChanged: (v) =>
                              widget.onFilterChanged(widget.columns[i].key, v),
                        ),
                      ),
                      // 列宽拖拽手柄：贴列右边界、半溢出到相邻列的 8px 命中区。
                      // opaque 截获该区点击（避免误开筛选下拉）；横向拖拽改本列宽，
                      // 桌面端悬停显示 resize 光标作为可调提示。
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
            ],
          ),
        ),
      ),
    );
  }

  /// 行首多选格的冻结包裹：非多选表原样返回（零开销）。
  Widget _withFrozenSelection({
    required ScrollController controller,
    required Widget cell,
    required Widget row,
  }) {
    if (!widget.selectable) return row;
    return UtenFrozenLeadingColumn(
      horizontal: controller,
      width: _selectionColWidth,
      cell: cell,
      row: row,
    );
  }

  /// 拖拽改第 [index] 列宽：按本次横向增量更新，下限 [_minColWidth] 防拖没；
  /// 标记该列已手动调整，后续数据刷新不再自动重算其宽度。
  void _resizeColumn(int index, double dx) {
    final next = _widths[index] + dx;
    if (next < _minColWidth) return;
    setState(() {
      _widths[index] = next;
      _manualResized.add(index);
    });
    _fsTick.value++;
  }

  /// 单个数据格：列宽 + 语义底色（cellColor）+ 列间竖线 + 内边距 + 内容。
  /// 底色与文字始终双向保证对比度：深底（如缺口列的 error 实底）切白字，
  /// 浅底（暗色主题下 error/primary/tertiary 等浅色作为底色时）切深字——
  /// 只处理深底会在暗色主题里留下「浅底白字」的不可读组合。
  Widget _buildDataCell(
    ThemeData theme,
    int columnIndex,
    T item,
    bool selected,
    TextStyle textStyle,
  ) {
    final column = widget.columns[columnIndex];
    final cellColor = selected ? null : column.cellColor?.call(context, item);
    final Color? onCellColor = cellColor == null
        ? null
        : ThemeData.estimateBrightnessForColor(cellColor) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    final cellStyle = onCellColor != null
        ? textStyle.copyWith(color: onCellColor)
        : textStyle;
    final lineColor = selected ? Colors.white : theme.colorScheme.outline;
    return Container(
      width: _widths[columnIndex],
      // 列间竖线：逐格勾勒单元格右边界；选中行用白色竖线。
      decoration: BoxDecoration(
        color: cellColor,
        border: Border(right: BorderSide(color: lineColor, width: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        child: _dataCell(column, item, cellStyle, selected),
      ),
    );
  }

  Widget _buildDataRow(ThemeData theme, T item) {
    // selectable 多选：选中由 selectedIds（业务键）驱动，单选 _selectedItem 失效。
    // 否则沿用单选：外部 isSelected 谓词优先，回落内部 _selectedItem 引用相等。
    final String? multiId = widget.selectable ? widget.idOf?.call(item) : null;
    final bool selected;
    if (widget.selectable) {
      selected =
          multiId != null &&
          multiId.isNotEmpty &&
          widget.selectedIds.contains(multiId);
    } else if (widget.isSelected != null) {
      selected = widget.isSelected!(item);
    } else {
      selected = identical(item, _selectedItem);
    }
    // 行底色：调用方可按行数据着色（货品按状态）；选中统一高亮为深绿底 + 白字 + 白线。
    final base = widget.rowColor?.call(item);
    final Color rowBg = selected
        ? UtenColors.deepGreen
        : (base ?? Colors.transparent);
    // 选中行的网格线/字体统一改白，保证在深绿底上清晰可读。
    final lineColor = selected ? Colors.white : theme.colorScheme.outline;
    final textStyle = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: selected ? Colors.white : null,
    );
    // 多选前导勾选格（合成单元格，不进列宽机制）。
    // **行内这一份不能自带底色**：它要跟整行同底（斑马纹/选中深绿/行语义色都由外层
    // ColoredBox 统一给），而且 DecoratedBox 的边框画在子节点之前——自带不透明底会把
    // 行底那条分隔线在这 48px 里盖掉（2026-09-11 用户截图：首列底色不一样、行线断了）。
    final selectionCheckbox = Center(
      child:
          (multiId == null || multiId.isEmpty) &&
              widget.unselectableLeadingBuilder != null
          ? widget.unselectableLeadingBuilder!(context, item)
          : Checkbox(
              value: selected,
              // 无业务 id 的行禁用勾选（不计入全选）。
              onChanged: (multiId == null || multiId.isEmpty)
                  ? null
                  : (v) => _toggleRow(item, v ?? false),
            ),
    );
    final selectionCell = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: lineColor, width: 0.5)),
      ),
      child: selectionCheckbox,
    );
    // 横滚时钉在视口左缘的那一份副本（[UtenFrozenLeadingColumn]）：它浮在数据格之上，
    // **必须**自带与本行一致的不透明底 + 右线 + 行底线，否则下面的数据格会透上来、
    // 行线也会在这一段断开。
    final frozenSelectionCell = ColoredBox(
      color: rowBg == Colors.transparent ? theme.colorScheme.surface : rowBg,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: lineColor, width: 0.5),
            bottom: BorderSide(color: lineColor, width: 0.5),
          ),
        ),
        child: selectionCheckbox,
      ),
    );
    final row = DecoratedBox(
      // 行间横线：逐行分隔；选中行用白色横线与深绿底搭配。
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: lineColor, width: 0.5)),
      ),
      child: ColoredBox(
        color: rowBg,
        child: _boundStretchRow(
          _withFrozenSelection(
            controller: _bodyH,
            cell: frozenSelectionCell,
            row: Row(
              crossAxisAlignment: _selectableCross,
              children: [
                if (widget.selectable)
                  SizedBox(width: _selectionColWidth, child: selectionCell),
                for (final i in _visibleIndices)
                  _buildDataCell(theme, i, item, selected, textStyle),
              ],
            ),
          ),
        ),
      ),
    );
    final configuredOnRowTap = widget.onRowTap;
    final rowCanOpen =
        configuredOnRowTap != null && (widget.canOpenRow?.call(item) ?? true);
    final onRowTap = rowCanOpen ? configuredOnRowTap : null;
    final rowCanSelect = widget.selectable && multiId?.isNotEmpty == true;
    final configuredRowMenuBuilder = widget.rowMenuBuilder;
    final rowMenuBuilder =
        configuredRowMenuBuilder != null &&
            (widget.canShowRowMenu?.call(item) ?? true)
        ? configuredRowMenuBuilder
        : null;
    // 纯展示行(无打开、无行菜单、无单选回调、非多选)不挂手势，避免伪可交互。
    // 只有 onSelectionChanged 的行仍必须可单击选中，例如 BOM 把展开动作放进树单元格后，
    // 整行不再负责打开，但编辑/删除仍依赖行选择。
    if (onRowTap == null &&
        rowMenuBuilder == null &&
        widget.onSelectionChanged == null &&
        !rowCanSelect) {
      return row;
    }

    /// 选中该行（不改变多选勾选集之外的语义）：
    /// - 多选模式：切换该行的勾选（单击 = 选中/取消选中，与点勾选框等价）；
    /// - 单选模式：内部高亮 + 通知调用方 onSelectionChanged。
    void selectRow() {
      if (widget.selectable) {
        final id = widget.idOf?.call(item);
        if (id == null || id.isEmpty) return;
        _toggleRow(item, !selected);
        return;
      }
      // 单击高亮该行：滚动时常驻（数据不刷新），翻页/重查换对象后自然失效。
      setState(() => _selectedItem = item);
      _fsTick.value++;
      widget.onSelectionChanged?.call(item);
    }

    /// 右击/长按弹菜单前把该行置为选中：
    /// 多选模式下该行未勾选 → 选择集替换为仅该行（标准文件管理器行为）；
    /// 已勾选 → 保留多选（菜单操作作用于整个选择集的语义由调用方决定）。
    void selectRowForMenu() {
      if (widget.selectable) {
        if (widget.preserveSelectionOnContextMenu) return;
        final id = widget.idOf?.call(item);
        if (id == null || id.isEmpty) return;
        if (!widget.selectedIds.contains(id)) {
          widget.onSelectedIdsChanged?.call(<String>{id});
          _fsTick.value++;
        }
        return;
      }
      setState(() => _selectedItem = item);
      _fsTick.value++;
      widget.onSelectionChanged?.call(item);
    }

    /// 菜单动作(含其异步确认/业务回调)完成后清理上下文选中。仅取消菜单时保留
    /// 原选择，避免用户已有多选被一次误触清空。
    void clearSelectionAfterMenuAction() {
      if (!mounted) return;
      if (widget.selectable) {
        if (widget.preserveSelectionOnContextMenu) return;
        widget.onSelectedIdsChanged?.call(const <String>{});
        _fsTick.value++;
        return;
      }
      setState(() => _selectedItem = null);
      _fsTick.value++;
      widget.onSelectionCleared?.call();
    }

    /// 打开前保证多选行仍保持勾选。手动双击窗会让第一次点击立即执行
    /// “切换选择”；若用户原本已选中该行，第一次点击会先取消，第二击识别为
    /// 双击时必须补回选择，避免打开详情后右下/批量主操作意外变灰。
    void openRow() {
      if (widget.selectable) {
        final id = widget.idOf?.call(item);
        if (id != null && id.isNotEmpty && !widget.selectedIds.contains(id)) {
          _toggleRow(item, true);
        }
      }
      onRowTap?.call(item);
    }

    // 列表页（非 embedded）统一交互：单击选中、双击打开。
    // 双击判定不用 DoubleTapGestureRecognizer，改用手动时间窗比对：
    // DoubleTapGestureRecognizer 会在首次点击后 hold 手势竞技场（~300ms），
    // 既让单击高亮延迟，又会拖住 SelectionArea 文本拖选手势的竞技场解析，
    // 大表拖选+自动滚动时触发 selection 子树访问已销毁行（FM2 defunct 崩溃）。
    // 手动判定下单击立即生效、双击窗口内同行再点即打开，无任何竞技场副作用。
    // 例外：embedded（picker/滑窗内明细表）保留单击直达——picker 行的单击
    // 语义本来就是「选中这条」，不是「打开页面」。
    Widget interactive;
    if (widget.embedded && !widget.selectable) {
      interactive = InkWell(
        onTap: () {
          selectRow();
          onRowTap?.call(item);
        },
        child: row,
      );
    } else {
      // 双击判定的行键：优先业务 id（idOf）；无 idOf 时回落到「全列可见文本」——
      // 不能用 identityHashCode：单击选中触发重建后 item 对象引用已换
      // （BOM 的 _BomRow 每次 build 重建），内容键对同一逻辑行保持稳定。
      final rowKey =
          widget.rowKeyOf?.call(item) ??
          widget.idOf?.call(item) ??
          'cells:${widget.columns.map((c) => c.value(item) ?? '').join(' ')}';
      interactive = InkWell(
        onTap: () {
          final now = clock.now();
          final isDoubleClick =
              _lastTapRowKey == rowKey &&
              now.difference(_lastTapAt) <= _kDoubleClickWindow;
          _lastTapRowKey = isDoubleClick ? null : rowKey; // 打开后复位，防三连击重复开
          _lastTapAt = now;
          if (isDoubleClick && onRowTap != null) {
            openRow(); // 双击：保持选择并打开对应弹窗/页面
            return;
          }
          selectRow(); // 单击：只选中（多选模式=切换勾选）
        },
        child: row,
      );
    }
    if ((!widget.embedded || widget.selectable) && onRowTap != null) {
      interactive = Semantics(
        customSemanticsActions: {
          const CustomSemanticsAction(label: '打开详情'): openRow,
        },
        child: interactive,
      );
    }
    if (rowCanSelect ||
        (!widget.selectable && widget.onSelectionChanged != null)) {
      interactive = Semantics(selected: selected, child: interactive);
    }
    if (rowMenuBuilder != null) {
      return UtenContextMenuRegion(
        entriesBuilder: () => rowMenuBuilder(item),
        onMenuOpening: selectRowForMenu,
        onActionCompleted: clearSelectionAfterMenuAction,
        child: interactive,
      );
    }
    return interactive;
  }

  Widget _buildPager(BuildContext context) {
    final theme = Theme.of(context);
    final canPrev = widget.currentPage > 1;
    final canNext = widget.currentPage < widget.totalPages;
    // 「上一页/下一页」带文案时的固有宽度随字号一起放大：窄屏（375px）叠大字号（1.5×）
    // 就超出可用宽。按可用宽 × 当前字号判断，放不下就收成纯图标按钮——
    // 翻页条**恒为一行**（改折行会把表体挤到纵向溢出，得不偿失）。
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 250 * textScale + 54;
          void goto(int page) => widget.onPageChange?.call(page);
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (compact)
                IconButton(
                  onPressed: (canPrev && widget.onPageChange != null)
                      ? () => goto(widget.currentPage - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                  tooltip: '上一页', // TODO(l10n): 补 arb
                )
              else
                TextButton.icon(
                  onPressed: (canPrev && widget.onPageChange != null)
                      ? () => goto(widget.currentPage - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                  label: const Text('上一页'), // TODO(l10n): 补 arb
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 54,
                      child: TextFormField(
                        errorBuilder: utenTextFieldErrorBuilder,
                        controller: _pageCtrl,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                        decoration: UtenInputDecoration(
                          InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                        // 填数字回车跳页：非法→回当前页；越界→钳制到 [1,totalPages] 并回填。
                        onFieldSubmitted: (v) {
                          final p = int.tryParse(v.trim());
                          final target = p == null
                              ? widget.currentPage
                              : p.clamp(1, widget.totalPages);
                          if (target != widget.currentPage) {
                            goto(target);
                          } else {
                            _pageCtrl.text = '$target';
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      '/ ${widget.totalPages}', // TODO(l10n): 补 arb
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (compact)
                IconButton(
                  onPressed: (canNext && widget.onPageChange != null)
                      ? () => goto(widget.currentPage + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                  tooltip: '下一页', // TODO(l10n): 补 arb
                )
              else
                TextButton.icon(
                  onPressed: (canNext && widget.onPageChange != null)
                      ? () => goto(widget.currentPage + 1)
                      : null,
                  icon: const Text('下一页'), // TODO(l10n): 补 arb
                  label: const Icon(Icons.chevron_right_rounded, size: 20),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 单个列头的 autofilter 下拉：紧凑「标签 ▼」，选中显示值并高亮。
/// 点击在列头下方原位展开一个限高、可竖向滚动的菜单（不全屏）；点外部关闭。

class _FilterCell extends StatefulWidget {
  const _FilterCell({
    required this.label,
    required this.buckets,
    required this.nullCount,
    required this.selected,
    required this.onChanged,
    this.sortKey,
    this.type = 'text',
    this.sortable = false,
    this.sortActive = false,
    this.sortAscending = true,
    this.onSort,
    this.info,
  });

  final String label;
  final List<MasterFacetBucket> buckets;
  final int nullCount;
  final String? selected;
  final ValueChanged<String?> onChanged;

  /// 列头说明（MasterColumnDef.info 透传）：非空渲染 ⓘ，悬停 Tooltip、
  /// 点击（含手机）弹说明小窗。
  final String? info;

  /// 排序相关（与 MasterColumnDef 对齐）：sortKey=列 key，type 决定菜单文案，
  /// sortable 控制是否可排序，sortActive/sortAscending 反映当前排序态，onSort 应用排序。
  final String? sortKey;
  final String type;
  final bool sortable;
  final bool sortActive;
  final bool sortAscending;
  final void Function(String? column, bool ascending)? onSort;

  @override
  State<_FilterCell> createState() => _FilterCellState();
}

class _FilterCellState extends State<_FilterCell> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  /// 菜单内搜索框（选项多时启用，输入实时过滤 bucket 列表）。
  TextEditingController? _searchCtl;

  /// 切换分类后旧选中值可能不在新 facet：sanitize 退回"所有"。
  String? get _sanitized {
    final validValues = <String>{for (final b in widget.buckets) b.value};
    return (widget.selected == null ||
            widget.selected == kMasterFilterNullValue ||
            validValues.contains(widget.selected))
        ? widget.selected
        : null;
  }

  void _open() {
    if (_overlay != null) return;
    _searchCtl = TextEditingController();
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
    _searchCtl?.dispose();
    _searchCtl = null;
  }

  void _select(String? value) {
    widget.onChanged(value);
    _close();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _sanitized;
    final hasFacets = widget.buckets.isNotEmpty || widget.nullCount > 0;
    // 无 facets 且不可排序的列（如部分单据列表的纯标签列头）→ 纯标签，不渲染下拉/排序。
    // 这样文档页可直接复用 MasterDataTableView，与基础资料布局完全一致。
    final interactive = hasFacets || s != null || widget.sortable;
    if (!interactive) {
      return Container(
        // minHeight（非固定 height）：字号放大后表头标签能撑高，不被裁切。
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
        alignment: Alignment.centerLeft,
        child: Text(
          widget.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final filtered = s != null;
    final highlighted = filtered || widget.sortActive;
    // 选中值用对应桶的展示名（颜色/单位 legacy id → 名称）；找不到回落原值。
    String display;
    if (s == null) {
      display = widget.label;
    } else if (s == kMasterFilterNullValue) {
      display = '${widget.label}：空';
    } else {
      String? sel;
      for (final b in widget.buckets) {
        if (b.value == s) {
          sel = b.display;
          break;
        }
      }
      display = sel ?? s;
    }

    return CompositedTransformTarget(
      link: _link,
      child: InkWell(
        onTap: _open,
        child: Container(
          // minHeight（非固定 height）：字号放大后表头标签能撑高，不被裁切。
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
          color: highlighted ? theme.colorScheme.primaryContainer : null,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: highlighted ? FontWeight.w700 : FontWeight.w600,
                    color: highlighted
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // 列头说明 ⓘ：悬停出 Tooltip，点击（含手机）弹说明小窗——
              // 自吞点击，不触发排序/筛选菜单。
              if (widget.info != null) ...[
                const SizedBox(width: UtenSpacing.s4),
                UtenColumnHintIcon(message: widget.info!),
              ],
              // 排序指示：当前排序列显 ▲/▼（主色）；可排序但非当前显淡 sort 图标提示可点。
              if (widget.sortable)
                Icon(
                  widget.sortActive
                      ? (widget.sortAscending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded)
                      : Icons.sort_rounded,
                  size: 16,
                  color: widget.sortActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              if (widget.sortable && hasFacets)
                const SizedBox(width: UtenSpacing.s4),
              // 筛选下拉箭头（仅有 facets 的列才显示）。
              if (hasFacets)
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: 18,
                  color: highlighted
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 菜单：锚定列头下方（CompositedTransformFollower）、限高 360、ListView 竖向滚动。
  /// TapRegion 捕获菜单外的点击 → 关闭。
  /// 排序菜单文案：日期=从远到近/从近到远；数值(金额/数量)=从小到大/从大到小。
  String get _sortAscLabel => widget.type == 'date' ? '从远到近' : '从小到大';
  String get _sortDescLabel => widget.type == 'date' ? '从近到远' : '从大到小';

  void _sortSelect(String? column, bool ascending) {
    widget.onSort?.call(column, ascending);
    _close();
  }

  Widget _buildOverlay(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final sanitized = _sanitized;
    final hasFacets = widget.buckets.isNotEmpty || widget.nullCount > 0;
    // 选项较多时菜单顶部出搜索框（客户等长列表快速定位）。
    final searchable = widget.buckets.length >= 6;
    return Stack(
      children: [
        // 点菜单外空白关闭（兜底；TapRegion 是主机制）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          offset: const Offset(0, 2),
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Container(
                constraints: const BoxConstraints(
                  maxHeight: 360,
                  maxWidth: 300,
                ),
                child: StatefulBuilder(
                  builder: (ctx, setOverlayState) {
                    final q = _searchCtl?.text.trim().toLowerCase() ?? '';
                    final buckets = q.isEmpty
                        ? widget.buckets
                        : widget.buckets
                              .where((b) => b.display.toLowerCase().contains(q))
                              .toList();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (searchable && hasFacets)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              UtenSpacing.s8,
                              UtenSpacing.s8,
                              UtenSpacing.s8,
                              UtenSpacing.s4,
                            ),
                            child: TextField(
                              controller: _searchCtl,
                              autofocus: true,
                              style: theme.textTheme.bodyMedium,
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '输入关键字搜索',
                                prefixIcon: const Icon(
                                  Icons.search_rounded,
                                  size: 18,
                                ),
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                suffixIcon: q.isEmpty
                                    ? null
                                    : IconButton(
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 16,
                                        ),
                                        onPressed: () {
                                          _searchCtl!.clear();
                                          setOverlayState(() {});
                                        },
                                      ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: UtenSpacing.s8,
                                  vertical: UtenSpacing.s8,
                                ),
                              ),
                              onChanged: (_) => setOverlayState(() {}),
                            ),
                          ),
                        Flexible(
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            children: <Widget>[
                              if (widget.sortable) ...[
                                _menuItem(
                                  ctx,
                                  label: _sortAscLabel,
                                  isSelected:
                                      widget.sortActive && widget.sortAscending,
                                  onTap: () =>
                                      _sortSelect(widget.sortKey, true),
                                  theme: theme,
                                ),
                                _menuItem(
                                  ctx,
                                  label: _sortDescLabel,
                                  isSelected:
                                      widget.sortActive &&
                                      !widget.sortAscending,
                                  onTap: () =>
                                      _sortSelect(widget.sortKey, false),
                                  theme: theme,
                                ),
                                _menuItem(
                                  ctx,
                                  label: '取消排序', // TODO(l10n): 补 arb
                                  isSelected: !widget.sortActive,
                                  onTap: () => _sortSelect(null, true),
                                  theme: theme,
                                ),
                                if (hasFacets)
                                  const Divider(height: 1, thickness: 1),
                              ],
                              if (hasFacets) ...[
                                _menuItem(
                                  ctx,
                                  label: '所有', // TODO(l10n): 补 arb
                                  isSelected: sanitized == null,
                                  onTap: () => _select(null),
                                  theme: theme,
                                ),
                                if (widget.nullCount > 0)
                                  _menuItem(
                                    ctx,
                                    label:
                                        '空值 (${widget.nullCount})', // TODO(l10n): 补 arb
                                    isSelected:
                                        sanitized == kMasterFilterNullValue,
                                    onTap: () =>
                                        _select(kMasterFilterNullValue),
                                    theme: theme,
                                  ),
                                const Divider(height: 1, thickness: 1),
                                for (final b in buckets)
                                  _menuItem(
                                    ctx,
                                    label: b.count > 0
                                        ? '${b.display} (${b.count})'
                                        : b.display,
                                    isSelected: sanitized == b.value,
                                    onTap: () => _select(b.value),
                                    theme: theme,
                                  ),
                                if (buckets.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: UtenSpacing.s12,
                                      vertical: UtenSpacing.s12,
                                    ),
                                    child: Text(
                                      '无匹配项',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuItem(
    BuildContext ctx, {
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        color: isSelected ? theme.colorScheme.primaryContainer : null,
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: isSelected
                  ? Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    )
                  : null,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                  color: isSelected ? theme.colorScheme.primary : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全屏路由外壳：仅用于在路由彻底 dispose（含退出动画结束）时回调，
/// 让正常树安全地重新接管同一批 ScrollController（避免退出动画期间
/// 全屏路由与正常树双挂同一控制器，触发 Scrollbar 断言）。
class _FullscreenDisposer extends StatefulWidget {
  const _FullscreenDisposer({required this.onDisposed, required this.child});

  final VoidCallback onDisposed;
  final Widget child;

  @override
  State<_FullscreenDisposer> createState() => _FullscreenDisposerState();
}

class _FullscreenDisposerState extends State<_FullscreenDisposer> {
  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 表体高度策略：embedded（详情页 ListView 等无界高度场景）直接按内容收缩——
/// 不能用 Flexible（flex 在无界约束下会抛 "non-zero flex but incoming height
/// constraints are unbounded"）；列表页有界场景用 Flexible(loose)，行少收缩、
/// 行多顶到视口上限转竖向滚动。
class _BodyFlex extends StatelessWidget {
  const _BodyFlex({
    required this.embedded,
    required this.primary,
    required this.virtualized,
    required this.child,
  });

  final bool embedded;
  final bool primary;
  final bool virtualized;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      return child;
    }
    // primary（联动折叠）用 tight：表格填满 NestedScrollView body 释放出的空间；
    // 普通列表页用 loose：行少时连同 shrinkWrap 收缩表高。
    return Flexible(
      fit: primary || virtualized ? FlexFit.tight : FlexFit.loose,
      child: child,
    );
  }
}

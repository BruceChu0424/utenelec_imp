import '../../../shared/platform_tables/platform_table_binding.dart';
import '../../../shared/platform_tables/platform_table_controller.dart';
import '../../../shared/platform_tables/platform_table_picker.dart';
import '../../../shared/platform_tables/platform_table_widgets.dart';
import '../../../shared/platform_tables/table_column_projection.dart';
// MasterDataTableView - 基础资料主档通用表格视图（货品/模具/客户/供应商 共用）。
//
// Excel 风格：横排 autofilter 列头（表头跟随表体横滚，无滚动条）+ 逐行数据（列对齐，
// 底部横向滚动条）。表头/表体各自一个横向 ScrollView，双向 listener 同步横滚位置
// （拖底部滚动条表头跟随；列始终对齐）。列头 autofilter 用自定义 Overlay 下拉（锚定
// 列头下方、限高、竖向滚动，不全屏）。翻页（上一页/下一页）后表体竖向回到顶部。
// 搜索框由调用方放在标题行，不在本组件内。

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/master_data_table_rows_controller.dart';
import '../../../components/layout/uten_prepend_scroll_anchor.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_table_cell_hints.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_scrollbar.dart';
import '../../../components/layout/uten_sticky_header.dart';
import '../../../components/layout/uten_table_column_kit.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import 'master_data_card_list.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../models/master_facet.dart';
import '../../../components/data_display/uten_color_name.dart';
import '../../../shared/ai/page_context/ai_page_context.dart';

export '../../../components/data_display/master_data_table_rows_controller.dart';

part 'master_data_table_view_ai.dart';

class MasterDataTableHeaderAddition extends InheritedWidget {
  const MasterDataTableHeaderAddition({
    super.key,
    required this.header,
    required super.child,
  });
  final Widget header;
  @override
  bool updateShouldNotify(MasterDataTableHeaderAddition oldWidget) =>
      header != oldWidget.header;
}

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
    this.filterFromRows = false,
    this.cellColor,
    this.cellColorListenableOf,
    this.cardRole,
    this.cardRendersBuilder = false,
    this.cellBuilder,
    this.cellBuilderHandlesSemantics = false,
    this.fillsCellHeight = false,
    this.info,
    this.defaultVisible = true,
    this.exportDefinition,
    this.exactValueOf,
    this.exactListenableOf,
    this.legendOf,
    this.aiSensitive = false,
  });

  final String key;
  final String label;
  final bool defaultVisible;

  /// 状态图例「值 -> 含义」(ADR-150, 可选)：AI 助手读页面时, 本列每种底色/状态
  /// 值附上这句含义(如车间任务「紫 = 部分物料可领, 去领料」)。只在发问时读取。
  final String? Function(T item)? legendOf;

  /// 敏感数值列(成本/工资/信用额度等, ADR-150)：AI 读页面时只发列名不发值。
  /// 列名命中平台敏感词表的列即使不标也不会发送。
  final bool aiSensitive;
  final Map<String, dynamic>? exportDefinition;

  /// Unformatted decimal source for display calculations; never inferred from a money/quantity label.
  final String? Function(T row)? exactValueOf;
  final Listenable? Function(T row)? exactListenableOf;
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

  /// 本列的自定义单元格自己吃满整行高度（不再被 selectable 模式那层
  /// `Align(centerLeft)` 竖向收缩）。
  ///
  /// 只给「要画跨行图形」的列用——典型就是层级树列（[UtenTreeTableCell]）：
  /// 同一行里只要有别的列换了两行，树格就会被居中、上下各留一截空白，层级
  /// 竖线接不到相邻行，看着像虚线（2026-09-15 用户口径「表示层级的竖线不对」）。
  /// 默认 false，既有列一字不变。
  final bool fillsCellHeight;

  /// 列类型，对齐后端 ReportColumn.type：text / date / number / money / bool /
  /// count / weight。用于决定排序菜单文案 (date=从远到近/从近到远, 数值=从小到大/
  /// 从大到小) 与就地排序口径 (number/money/count 按数值; weight 按换算成千克后的值,
  /// 显示文本可带单位与「≈」, 「未称」排末尾)。
  final String type;

  /// 该列是否允许点表头排序（日期/金额/数量等可排序列置 true）。
  /// 页面传了 onSortChange 时排序走服务端；没传时组件就地排序（全量加载表）。
  final bool sortable;

  /// 本地取值筛选（2026-09-25 用户口径「单号列像我的车间任务那样可排序、
  /// 可只看某个单号」）：组件用当前行的 [value] 就地构建筛选桶并过滤显示行，
  /// 不要求宿主接 facets/onFilterChanged。给**全量加载**（非服务端分页）的
  /// 表用；服务端分页表格筛了也只是当页，应走服务端 facets 而不是这个开关。
  /// 宿主已为该 key 提供服务端 facets 时以服务端为准（本开关不再生效）。
  final bool filterFromRows;

  /// 单元格语义底色（如待处理步骤用浅警示色）；null = 跟随所在行底色。
  /// 选中行仍由表格统一使用深绿高亮，避免颜色叠加后文字对比不足。
  final Color? Function(BuildContext context, T item)? cellColor;

  /// [cellColor] 依赖的行内可监听源（如称重核对列的重量/数量控制器）：
  /// 非空时整格包一层 ListenableBuilder，源变化即重算底色——否则只有
  /// cellBuilder 内部自重建，整格 Container 的底色不会跟着刷新。
  final Listenable? Function(T item)? cellColorListenableOf;

  /// 卡片形态下直接复用本列 [cellBuilder] 渲染（默认 false 用「标签 值」）。
  /// 给信息量大的富格用（如客户应收的两行余额说明）；控制器类格（输入框）
  /// 不要开。
  final bool cardRendersBuilder;

  /// 卡片形态（[MasterDataTableView.compactCards]）下本列的角色；null=自动
  /// （第一可见列当标题，其余列进 `标签 值` 明细）。显式 hidden 的列只在
  /// 表格里出现——副行/明细已承载同信息的列（如标题列本身）用它防重复。
  final MasterColumnCardRole? cardRole;
}

/// compact 卡片形态下列的呈现角色（2026-09-29「大小屏共用一张表」）。
enum MasterColumnCardRole {
  /// 卡片标题（默认第一可见列自动担任；同名不同货的表请把名称列标成 title）。
  title,

  /// 标题下的小字副行（多列用 · 连接，如 单号/编号）。
  subtitle,

  /// 不进卡片（表格里照常显示）。
  hidden,
}

/// 按数值排序的列类型 (与后端 ReportColumn.type 同名; weight 另按千克换算)。
const Set<String> _numericColumnTypes = {'number', 'money', 'count', 'weight'};

/// 重量列显示文本 (如「≈3.52 t」「850 g」) -> 千克; 不是重量 (如「未称」) 返回 null。
double? _weightSortValue(String text) {
  final plain = text.replaceAll('≈', '').trim();
  return parseWithSuffix(plain, WeightUnit.kg)?.kg;
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
  /// 数据格的纵向内边距。要画跨行图形的单元格（层级树列）按它设
  /// `UtenTreeTableCell.guideBleed`，不要在调用点抄一个魔数——抄漏了行与行
  /// 之间就会空出 2×8px，整列连线看着像虚线。
  static const double cellVerticalPadding = UtenSpacing.s8;

  const MasterDataTableView({
    super.key,
    required this.columns,
    required this.items,
    this.unpagedItems = const [],
    this.rowsController,
    this.rowVisible,
    required this.facets,
    required this.nullCounts,
    required this.filters,
    this.externalFilterKeys = const <String>{},
    required this.onFilterChanged,
    this.onRowTap,
    this.canOpenRow,
    this.onSelectionChanged,
    this.onSelectionCleared,
    this.isSelected,
    this.rowMenuBuilder,
    this.backgroundMenuBuilder,
    this.canShowRowMenu,
    this.batchActionsBuilder,
    this.bottomContentPadding = 0,
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
    this.scrollToEndRequest = 0,
    this.totalPages = 1,
    this.onPageChange,
    this.paginationScope,
    this.paginationRevision,
    this.maxRetainedPages = 5,
    this.maxRetainedRows = 1000,
    this.summaryBar,
    this.summaryBarInline = false,
    this.toolbarActions,
    this.toolbarLeadingActions,
    this.embedded = false,
    this.primary = false,
    this.virtualized = false,
    this.showFullscreenToggle,
    this.showColumnChooser = true,
    this.enableTextSelection = true,
    this.rowColor,
    this.rowForegroundColor,
    this.rowDecorationBuilder,
    this.leadingGroups,
    this.selectable = false,
    this.idOf,
    this.rowKeyOf,
    this.rowWidgetKeyOf,
    this.unselectableLeadingBuilder,
    this.leadingOverlayBuilder,
    this.selectionStateOf,
    this.selectedIds = const <String>{},
    this.onSelectedIdsChanged,
    this.onRowSelectionChanged,
    this.selectionSummaryCount,
    this.onClearSelection,
    this.showSelectionSummary = true,
    this.preserveSelectionOnContextMenu = false,
    this.stickyHeaderPinned,
    this.onFullscreenChanged,
    this.compactCards = false,
    this.cardBelowWidth,
    this.tableKey,
    this.platformBinding,
    this.columnEditingEnabled = false,
    this.platformCellDecorator,
    this.scrollingHeader,
    this.errorKey,
    this.listItemBuilder,
    this.listSeparatorBuilder,
    this.listPadding = EdgeInsets.zero,
    this.singleTapRows = false,
  }) : assert(maxRetainedPages >= 2),
       assert(maxRetainedRows > 0),
       assert(
         !embedded || !virtualized,
         'virtualized=true requires a bounded, non-embedded table',
       ),
       assert(
         stickyHeaderPinned == null || embedded,
         'MasterDataTableView: stickyHeaderPinned 仅用于 embedded（详情页等'
         '滚动流内的明细表）——非 embedded 表格表头结构上恒在其滚动盒顶部，无需吸顶。',
       );

  /// 全屏态变化通知（进入/退出各回调一次）。宿主页可借此把搜索框等控件
  /// 在全屏时放回表格工具条（正常态放页面头部卡片），两处共享同一控制器。
  final ValueChanged<bool>? onFullscreenChanged;

  /// Picker lists share the table's paging, request fencing and scroll anchors,
  /// while keeping their existing tiles and confirmation interactions.
  final Widget Function(BuildContext, T)? listItemBuilder;
  final IndexedWidgetBuilder? listSeparatorBuilder;
  final EdgeInsetsGeometry listPadding;

  /// Bounded picker tables keep their single-tap select/open interaction without
  /// opting into an unbounded embedded layout.
  final bool singleTapRows;

  /// 「大小屏共用一张表」（2026-09-29 用户口径）：true 时屏宽进入 compact
  /// 断点（<600）表体自动换成卡片列表——同一份 [columns] 驱动（见
  /// [MasterColumnDef.cardRole]），页面不再各自维护窄屏卡片。默认 false：
  /// 未迁移的页面维持原表格横滚表现，逐页开启。
  /// embedded（滑窗/picker 内明细表）与全屏路由恒用表格。
  final bool compactCards;

  /// 目标页加载后递增此令牌，请求在布局完成后滚到末行。0 不触发；同一令牌
  /// 的普通重建不重复滚动。和翻页同时变化时优先定位末尾，其余翻页仍回顶。
  final int scrollToEndRequest;

  /// Automatic scrolling retains a contiguous window. A visible boundary page
  /// and one incoming response may temporarily add at most two pages; selected
  /// business rows are held separately and never discarded with a cache page.
  final int maxRetainedPages;
  final int maxRetainedRows;

  /// 卡片形态的宽度阈值：**表格可用宽度**低于该值切卡片（与各页旧
  /// LayoutBuilder 口径一致，分栏/容器内宽 ≠ 屏宽）。默认 compact 断点（600）；
  /// 原以 840（expanded）为界的页面传 [UtenBreakpoints.expandedStart]。
  final double? cardBelowWidth;

  final String? tableKey;
  final PlatformTableBinding<T>? platformBinding;

  /// Enable in document entry forms or master-data maintenance lists, gated by
  /// their edit permission. Detail and approval pages remain read-only.
  final bool columnEditingEnabled;
  final Widget Function(
    BuildContext context,
    T row,
    String columnKey,
    String? value,
    Widget child,
  )?
  platformCellDecorator;
  final Widget? scrollingHeader;
  final Key? errorKey;
  final List<MasterColumnDef<T>> columns;
  final List<T> items;
  final Map<String, List<MasterFacetBucket>> facets;
  final Map<String, int> nullCounts;
  final Map<String, String?> filters;

  /// 由宿主页自己承担入口的筛选列 key（不计入空态「筛选生效数」描述）。
  ///
  /// 两类：① 被页面钉死、表里根本改不动的（分段子页的 fixedOrderType）；
  /// ② 表外分段条上一直看得见、用户随时能切回去的（待检处置的类型分段）。
  /// （空态「清除筛选」按钮已按 2026-09-28 用户口径全站退役，见
  /// [_emptyStateWithToolbarActions]。）
  final Set<String> externalFilterKeys;
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

  /// 列表空白区域的菜单（例如粘贴），空列表与全屏视图也保留入口。
  /// 不依赖选中行；行与表头自己的菜单优先。加载或错误时不开放。
  final List<UtenContextMenuEntry> Function()? backgroundMenuBuilder;

  /// 按行判断是否存在右键/长按菜单。默认全部存在；返回 false 时该行不会仅因
  /// 页面配置了 [rowMenuBuilder] 就获得空菜单手势或伪可交互状态。
  final bool Function(T item)? canShowRowMenu;

  /// 批量业务动作构建器：selectable 时，表头工具条始终显示「已选 N 项 + 清除」；
  /// 本构建器可选，非空时返回的业务按钮统一悬浮在表格右下角，普通视图和全屏路由都会渲染。
  /// 未选中时动作保留位置但灰显并拦截点击，调用方仍应保留空集业务守卫。
  final List<Widget> Function(BuildContext context, Set<String> selectedIds)?
  batchActionsBuilder;

  /// 页面自己提供悬浮按钮时，为表体保留的末尾滚动空间。
  final double bottomContentPadding;

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

  /// Optional small badge drawn over the bottom-right corner of a **selectable**
  /// row's checkbox (e.g. a lock glyph with a tooltip). Lets a row stay
  /// selectable for one batch action while visibly gated for another —
  /// workshop tasks can be batch-routed yet locked for start while material is
  /// short (2026-09-20). Return null for no badge.
  final Widget? Function(BuildContext context, T item)? leadingOverlayBuilder;

  /// Optional controlled row state for hierarchical selection. Null represents
  /// partial selection; clicking it selects the complete row scope.
  final bool? Function(T item)? selectionStateOf;

  /// 多选选中集合（调用方拥有，单一真值源）。组件只读它判定勾选/高亮、只通过
  /// [onSelectedIdsChanged] 把"新集合"回交调用方，从不自行清空——故跨页天然保留。
  final Set<String> selectedIds;

  /// 选中集合变化回调：行勾选与表头三态全选共用这一个（传入新的 Set）。
  final void Function(Set<String> next)? onSelectedIdsChanged;

  /// Explicit row gestures can select a subtree while header selection remains
  /// scoped to displayed page rows. Omit for ordinary flat tables.
  final void Function(T item, bool selected)? onRowSelectionChanged;

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

  /// embedded 明细表的「表头吸顶」信号（2026-09-22 全站滚动口径）：
  ///
  /// 详情页等**普通滚动页**里的 embedded 表，上滑时表头行随页滚走、列头与数据
  /// 脱节。传本 notifier 后组件改用吸顶结构：表头行顶到视口上沿后钉住，数据行
  /// 从其下方滚过，表尾推到时表头随表尾离开（pushed sticky）——与
  /// [UtenEditableGrid.stickyHeaderPinned] 同一套 [UtenStickyHeaderTracker]
  /// 实现（同帧跟手，不滞后一帧）。true = 已置顶，宿主拿去门控页面滚动条
  /// （UtenGridPageScrollbar）。无祖先滚动的有界容器（弹窗/picker）量不到
  /// 视口时自动回落自然布局，传了也无副作用。
  final ValueNotifier<bool>? stickyHeaderPinned;

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
  /// 重交互页面可显式关闭；此时各行内容用 [SelectionContainer.disabled] 隔离，避免
  /// Flutter Web 在路由转场/滚动期间反复维护 SelectionRegistrar 导致主线程卡顿。
  /// 表体选择区实例保持稳定，禁用屏障位于 ListView 自动保活节点之下。
  /// [selectable] 为 true 的业务多选表始终关闭文字框选，本开关不改变行勾选语义。
  final bool enableTextSelection;

  /// 行底色（按行数据定，如货品按状态：使用=浅蓝/禁用=浅红）；返回 null = 默认透明。
  /// 单击选中时组件自动把该色加深加亮（提高不透明度），无底色行维持原 primary 高亮。
  final Color? Function(T item)? rowColor;

  /// Optional semantic foreground and whole-row decoration for read-only diffs.
  /// The decorator must preserve the supplied row's layout and interactions.
  final Color? Function(T item)? rowForegroundColor;
  final Widget Function(BuildContext context, T item, Widget row)?
  rowDecorationBuilder;

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
  final FutureOr<void> Function(int page)? onPageChange;

  /// Stable query identity (category, search, status, dates, etc.), excluding
  /// page number. A change discards the previous sequence of appended pages.
  /// Header filters and sort are also checked by the table itself.
  final Object? paginationScope;

  /// Latest accepted response identity for hosts that refresh without setting a
  /// loading flag. A new response outside an append discards older page rows.
  final Object? paginationRevision;

  /// Rows outside server pagination, such as local form drafts. They occur once
  /// before the loaded pages and are replaced immediately when edited/deleted.
  final List<T> unpagedItems;
  final MasterDataTableRowsController<T>? rowsController;

  /// A host predicate applied to every retained page (for example, tasks now
  /// fully covered by a local draft), rather than only the latest response.
  final bool Function(T)? rowVisible;

  /// 表格下方的合计条（通常是 `UtenTotalsSummaryBar`）。
  ///
  /// 全站统一挂在**表体与翻页条之间**：表体内部滚动，合计条在滚动区之外，
  /// 因此滚到哪一行它都在；全屏表格与嵌入式明细表同样跟随，位置/间距/字号一处定义处处一致。
  ///
  /// **服务端分页的表格必须传服务端合计**——对当前页求和会得出一个看着像总计、
  /// 其实只覆盖一页的数；拿不到服务端合计时要么不传，要么把标签写成「本页合计」。
  final Widget? summaryBar;

  /// 合计条改为**随表体滚动**：渲染进表体竖向滚动内容的末尾（最后一行数据之下），
  /// 行少时紧跟末行，行多时要滚到底才见——合计条属于表格那一块，不再钉在区块底部。
  /// 横向同样随表格内容（表格横向滚动时合计条跟着走）。用于详情页等
  /// 「合计行是表格脚注」语义的场景；默认 false 保持钉在表体之外的全站口径。
  final bool summaryBarInline;

  @override
  State<MasterDataTableView<T>> createState() => _MasterDataTableViewState<T>();
}

class _MasterDataTableViewState<T> extends State<MasterDataTableView<T>>
    with UtenColumnHeaderDragHost<MasterDataTableView<T>> {
  Widget? get _scrollingHeader {
    final extra = context
        .dependOnInheritedWidgetOfExactType<MasterDataTableHeaderAddition>()
        ?.header;
    if (extra == null) return widget.scrollingHeader;
    if (widget.scrollingHeader == null) return extra;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [widget.scrollingHeader!, extra],
    );
  }

  final _pages = SplayTreeMap<int, List<T>>();
  final _selectedRows = <String, T>{};
  late List<T> _items;
  int? _appendPage;
  int _acceptedPage = 1;
  int? _visiblePage;
  final _rowPages = <Object, int>{};
  bool _visiblePageScheduled = false;
  bool _settlingPageLayout = false;
  int _pageLayoutGeneration = 0;
  RenderBox? _externalPageViewport;
  String? _appendError;
  int _appendGeneration = 0;
  bool _appendScheduled = false;
  int? _exhaustedPage;
  int? _exhaustedPreviousPage;
  bool _prepending = false;
  final _prependAnchor = UtenPrependScrollAnchor();
  final _prependMeasureKey = GlobalKey();
  final _removeMeasureKey = GlobalKey();
  List<T> _removeMeasureItems = const [];
  List<T>? _prependMeasureItems;
  List<T>? _prependPageItems;
  bool _prependMeasureScheduled = false;
  double _prependBottomSpace = 0;
  final _mountedPaginationRows = <Object, ({RenderBox box, bool paged})>{};
  Map<String, String?> _filterSnapshot = const {};
  bool _queryChanged = false;

  bool get _busy =>
      widget.isLoading || widget.loadingMore || _appendPage != null;
  bool get _loadingMore =>
      !_prepending && (widget.loadingMore || _appendPage != null);
  int get _currentPage => _visiblePage ?? _acceptedPage;
  int get _firstPage => _pages.isEmpty ? _acceptedPage : _pages.firstKey()!;
  int get _lastPage => _pages.isEmpty ? _acceptedPage : _pages.lastKey()!;
  bool get _automaticPagination =>
      widget.onPageChange != null && widget.onLoadMore == null;

  SplayTreeMap<int, List<T>> _withPage(int page, List<T> incoming) {
    final identity = widget.rowKeyOf ?? widget.idOf;
    final updates = <String, T>{};
    if (identity != null) {
      for (final row in incoming) {
        final id = identity(row);
        if (id != null && id.isNotEmpty) updates[id] = row;
      }
    }
    return SplayTreeMap<int, List<T>>()..addAll({
      for (final entry in _pages.entries)
        entry.key: [
          for (final row in entry.value) updates[identity?.call(row)] ?? row,
        ],
      page: incoming,
    });
  }

  void _acceptPage(int page, List<T> rows) {
    _retainSelectedRows();
    final next = _trimWindow(_withPage(page, rows));
    _pages
      ..clear()
      ..addAll(next);
  }

  Set<Object> _visibleRowIds() => {
    for (final entry in _mountedPaginationRows.entries)
      if (entry.value.box.attached &&
          entry.value.box.hasSize &&
          _rowIntersectsViewport(entry.value.box))
        entry.key,
  };

  bool _rowIntersectsViewport(RenderBox box) {
    final object = RenderAbstractViewport.maybeOf(box);
    if (object is! RenderBox) return false;
    final viewport = object as RenderBox;
    if (!viewport.hasSize) return false;
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    return top + box.size.height > 0.5 && top < viewport.size.height;
  }

  bool _pageVisible(List<T> rows, Set<Object> visible) =>
      rows.any((row) => visible.contains(('data', _paginationRowId(row))));

  int get _pageWindowLimit {
    final nonemptySizes = _pages.values
        .map((rows) => rows.length)
        .where((count) => count > 0);
    final pageSize = nonemptySizes.isEmpty
        ? math.max(1, widget.items.length)
        : nonemptySizes.reduce(math.min);
    // Both ordinary limits apply. Whole pages stay atomic: an oversized single
    // response is retained once, never multiplied by the default page count.
    final ordinary = math.max(
      1,
      math.min(widget.maxRetainedPages, widget.maxRetainedRows ~/ pageSize),
    );
    // Small pages may need more than the configured page count to fill a real
    // viewport. This exception is tied to visible data rows plus one incoming
    // page, rather than to the row budget divided by a tiny server page size.
    final visible = _visibleRowIds()
        .where((id) => id is (String, Object) && id.$1 == 'data')
        .length;
    final viewport =
        (visible / pageSize).ceil() +
        (pageSize > widget.maxRetainedRows ? 0 : 1);
    return math.max(ordinary, viewport);
  }

  SplayTreeMap<int, List<T>> _trimWindow(SplayTreeMap<int, List<T>> source) {
    final result = SplayTreeMap<int, List<T>>.of(source);
    final visible = _visibleRowIds();
    while (result.length > _pageWindowLimit) {
      final edge = _prepending ? result.lastKey()! : result.firstKey()!;
      if (_pageVisible(result[edge]!, visible)) break;
      result.remove(edge);
    }
    return result;
  }

  void _retainSelectedRows() {
    _selectedRows.removeWhere((id, _) => !widget.selectedIds.contains(id));
    final identity = widget.idOf;
    if (identity == null) {
      _selectedRows.clear();
      return;
    }
    for (final row in _pages.values.expand((rows) => rows)) {
      final id = identity(row);
      if (id != null && widget.selectedIds.contains(id)) {
        _selectedRows[id] = row;
      }
    }
  }

  List<T> _collectRows(Map<int, List<T>> pages) {
    final rows = _automaticPagination
        ? pages.values.expand((rows) => rows)
        : widget.items;
    // Only an actual row identity is suitable for de-duplication. Equal cell
    // text does not imply the same business record.
    final identity = widget.rowKeyOf ?? widget.idOf;
    final merged = <T>[];
    final indexes = <String, int>{};
    for (final row in [...widget.unpagedItems, ...rows]) {
      final id = identity?.call(row);
      final index = id == null || id.isEmpty ? null : indexes[id];
      if (index == null) {
        if (id != null && id.isNotEmpty) indexes[id] = merged.length;
        merged.add(row);
      } else {
        merged[index] = row;
      }
    }
    return widget.rowVisible == null
        ? merged
        : merged.where(widget.rowVisible!).toList();
  }

  void _syncRows() {
    _items = _collectRows(_pages);
    if (_visiblePage != null && !_pages.containsKey(_visiblePage)) {
      _visiblePage = null;
    }
    _rowPages.clear();
    for (final entry in _pages.entries) {
      for (final row in entry.value) {
        // The first occurrence is the visible position after de-duplication;
        // newer snapshots may update the value but do not move that position.
        _rowPages.putIfAbsent(('data', _paginationRowId(row)), () => entry.key);
      }
    }
    _retainSelectedRows();
    final liveIds = _items.map((row) => widget.idOf?.call(row)).toSet();
    widget.rowsController?.update([
      ..._items,
      for (final entry in _selectedRows.entries)
        if (!liveIds.contains(entry.key)) entry.value,
    ]);
    _bindPagination();
  }

  void _bindPagination() => widget.rowsController?.bindPagination(
    this,
    _loadNextFromController,
    _busy,
    loadPrevious: _loadPreviousFromController,
    updateVisiblePage: (viewport) {
      _externalPageViewport = viewport;
      _scheduleVisiblePage();
    },
  );

  /// Fetch position and reading position are separate. Wait for insertion /
  /// eviction compensation before resolving the actual visible business page.
  void _acceptPageIndicator(int page, {bool reset = false}) {
    _acceptedPage = page;
    if (reset) _visiblePage = null;
    _settlingPageLayout = true;
    final generation = ++_pageLayoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _pageLayoutGeneration) {
          _settlingPageLayout = false;
          _scheduleVisiblePage();
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  void _scheduleVisiblePage() {
    if (_visiblePageScheduled ||
        !_automaticPagination ||
        _busy ||
        _settlingPageLayout ||
        _pages.isEmpty) {
      return;
    }
    _visiblePageScheduled = true;
    final generation = _pageLayoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visiblePageScheduled = false;
      if (!mounted ||
          generation != _pageLayoutGeneration ||
          _busy ||
          _settlingPageLayout) {
        return;
      }
      int? page;
      double? firstTop;
      for (final entry in _mountedPaginationRows.entries) {
        if (!entry.value.paged) continue;
        final rowPage = _rowPages[entry.key];
        final box = entry.value.box;
        if (rowPage == null || !box.attached || !box.hasSize) continue;
        final viewportObject = widget.embedded && !_fullscreen
            ? _externalPageViewport
            : RenderAbstractViewport.maybeOf(box);
        if (viewportObject is! RenderBox) continue;
        final viewport = viewportObject;
        if (!viewport.attached || !viewport.hasSize) continue;
        final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
        final bottom = box
            .localToGlobal(Offset(0, box.size.height), ancestor: viewport)
            .dy;
        // Kept-alive offscreen cells can remain attached with a singular paint
        // transform. They have no visible position and must not win the anchor.
        if (!top.isFinite ||
            !bottom.isFinite ||
            bottom <= 0.5 ||
            top >= viewport.size.height) {
          continue;
        }
        if (firstTop == null || top < firstTop) {
          firstTop = top;
          page = rowPage;
        }
      }
      if (page == null || (page == _currentPage && _visiblePage != null)) {
        return;
      }
      setState(() => _visiblePage = page);
      if (!_pageFocus.hasFocus) _pageCtrl.text = '$page';
      if (_fullscreen) _fsTick.value++;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _resetPages() {
    if (_queryChanged) {
      _selectedRows.clear();
    } else {
      _retainSelectedRows();
    }
    _appendGeneration++;
    _appendPage = null;
    _appendError = null;
    _exhaustedPage = null;
    _exhaustedPreviousPage = null;
    _prepending = false;
    _prependMeasureItems = null;
    _prependPageItems = null;
    _removeMeasureItems = const [];
    _prependBottomSpace = 0;
    _prependAnchor.reset();
    _acceptPageIndicator(widget.currentPage, reset: true);
    _pages
      ..clear()
      ..[widget.currentPage] = widget.items;
    _syncRows();
  }

  /// Returns true only for an accepted continuation, so the scroll position is
  /// retained while explicit navigation still starts at the top of its page.
  bool _updatePages(MasterDataTableView<T> oldWidget) {
    final scopeChanged =
        oldWidget.paginationScope != widget.paginationScope ||
        !mapEquals(_filterSnapshot, widget.filters) ||
        oldWidget.sortColumn != widget.sortColumn ||
        oldWidget.sortAscending != widget.sortAscending ||
        !_sameColumnKeys(oldWidget.columns, widget.columns);
    _filterSnapshot = Map.of(widget.filters);
    _queryChanged = scopeChanged;
    if (!_automaticPagination || scopeChanged) {
      _resetPages();
      return false;
    }
    if (_appendPage != null) {
      if (widget.error != null && !widget.loadingMore && !widget.isLoading) {
        _appendError = widget.error;
        _appendPage = null;
        _prependMeasureItems = null;
        _prependPageItems = null;
      } else if (!widget.loadingMore &&
          !widget.isLoading &&
          widget.currentPage == _appendPage) {
        if ((_prepending || _pages.length >= _pageWindowLimit) &&
            !widget.embedded &&
            widget.items.isNotEmpty &&
            _displayItems.isNotEmpty) {
          if (_prependMeasureItems == null) {
            _prependMeasureItems = const [];
          }
          _prependPageItems = widget.items;
          _bindPagination();
          // Measure only the newly inserted rows, at their actual column/card
          // width. Keep the old visible rows mounted until that layout exists.
          return true;
        }
        if (widget.items.isEmpty) {
          if (_prepending) {
            _exhaustedPreviousPage = widget.currentPage;
          } else {
            _exhaustedPage = widget.currentPage;
          }
        }
        _acceptPage(widget.currentPage, widget.items);
        _acceptPageIndicator(widget.currentPage);
        _appendPage = null;
        _appendError = null;
        _syncRows();
        return true;
      }
      _syncRows();
      return true;
    }
    final reloadStarted =
        (!oldWidget.loadingMore && widget.loadingMore) ||
        (!oldWidget.isLoading && widget.isLoading);
    if (reloadStarted ||
        oldWidget.currentPage != widget.currentPage ||
        oldWidget.paginationRevision != widget.paginationRevision) {
      _resetPages();
    } else if (_appendError == null) {
      _pages[widget.currentPage] = widget.items;
      _syncRows();
    } else {
      _syncRows();
    }
    return false;
  }

  bool _hasAdjacentPage(bool prepend) => prepend
      ? _firstPage > 1 && _exhaustedPreviousPage != _firstPage
      : _lastPage < widget.totalPages && _exhaustedPage != _lastPage;

  void _scheduleAppend({bool prepend = false}) {
    if (!_automaticPagination ||
        _busy ||
        _appendScheduled ||
        !_hasAdjacentPage(prepend) ||
        _appendError != null ||
        widget.error != null) {
      return;
    }
    _appendScheduled = true;
    final generation = _appendGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appendScheduled = false;
      if (!mounted || generation != _appendGeneration || _busy) return;
      _extendPages(prepend: prepend);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _appendNextPage() => _extendPages(prepend: false);

  Future<void> _extendPages({required bool prepend}) async {
    if (!_automaticPagination ||
        _busy ||
        !_hasAdjacentPage(prepend) ||
        (widget.error != null && _appendError == null)) {
      return;
    }
    if (_pages.length > _pageWindowLimit) {
      final edge = prepend ? _pages.lastKey()! : _pages.firstKey()!;
      if (_pageVisible(_pages[edge]!, _visibleRowIds())) return;
    }
    final target = prepend ? _firstPage - 1 : _lastPage + 1;
    final generation = ++_appendGeneration;
    setState(() {
      _appendPage = target;
      _appendError = null;
      _prepending = prepend;
    });
    _bindPagination();
    if (_fullscreen) _fsTick.value++;
    try {
      await widget.onPageChange!(target);
    } catch (_) {
      if (!mounted || generation != _appendGeneration) return;
      setState(() {
        _appendPage = null;
        _appendError = '${prepend ? '上一页' : '下一页'}加载失败，请重试';
      });
      _bindPagination();
      if (_fullscreen) _fsTick.value++;
      return;
    }
    // The callback may finish before the parent rebuilds, or be a synchronous
    // provider setter. Accept rows only from a completed widget update.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _appendGeneration ||
          _appendPage == null ||
          widget.loadingMore ||
          widget.isLoading) {
        return;
      }
      if (widget.currentPage != target || widget.error != null) {
        setState(() {
          _appendPage = null;
          _appendError = widget.error ?? '${prepend ? '上一页' : '下一页'}加载失败，请重试';
        });
        _bindPagination();
        if (_fullscreen) _fsTick.value++;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _loadNextFromController() async {
    if (_appendError != null || widget.error != null) return;
    await _appendNextPage();
  }

  Future<void> _loadPreviousFromController() async {
    if (_appendError != null || widget.error != null) return;
    await _extendPages(prepend: true);
  }

  void _gotoPage(int page) {
    if (_busy || widget.onPageChange == null) return;
    _appendGeneration++;
    _appendError = null;
    _prependMeasureItems = null;
    _prependPageItems = null;
    _prependAnchor.reset();
    widget.onPageChange!(page);
  }

  Object _paginationRowId(T row) =>
      widget.rowKeyOf?.call(row) ?? widget.idOf?.call(row) ?? row as Object;

  Widget _trackPaginationRow(Object id, bool paged, Widget child) =>
      !_automaticPagination
      ? child
      : _PaginationRowMarker(
          key: ValueKey(('pagination-row', id)),
          register: (box) {
            _mountedPaginationRows[id] = (box: box, paged: paged);
            _scheduleVisiblePage();
          },
          unregister: (box) {
            if (identical(_mountedPaginationRows[id]?.box, box)) {
              _mountedPaginationRows.remove(id);
            }
          },
          child: child,
        );

  ({Object id, double top, RenderBox viewport})? _visiblePaginationAnchor() {
    ({Object id, double top, RenderBox viewport})? anchor;
    for (final entry in _mountedPaginationRows.entries) {
      final box = entry.value.box;
      if (!box.attached || !box.hasSize) continue;
      final viewportObject = RenderAbstractViewport.maybeOf(box);
      if (viewportObject is! RenderBox) continue;
      final viewport = viewportObject as RenderBox;
      if (!viewport.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (!top.isFinite ||
          top + box.size.height <= 0.5 ||
          top >= viewport.size.height) {
        continue;
      }
      if (anchor == null || top < anchor.top) {
        anchor = (id: entry.key, top: top, viewport: viewport);
      }
    }
    return anchor;
  }

  List<T> _rowsInsertedBefore(Object? anchorId) {
    if (_appendPage == null || _prependPageItems == null) return const [];
    final proposed = _applyRowView(
      _collectRows(_withPage(_appendPage!, _prependPageItems!)),
    );
    final anchorIndex = proposed.indexWhere(
      (row) => ('data', _paginationRowId(row)) == anchorId,
    );
    // A group header stays before the main rows. Local sorting may also put
    // some new rows below the visible anchor; those must not move the viewport.
    if (anchorIndex < 0) return const [];
    final known = _items.map(_paginationRowId).toSet();
    return proposed
        .take(anchorIndex)
        .where((row) => !known.contains(_paginationRowId(row)))
        .toList();
  }

  List<T> _rowsRemovedBefore(Object? anchorId) {
    if (_appendPage == null || _prependPageItems == null || anchorId == null) {
      return const [];
    }
    final retained = _collectRows(
      _trimWindow(_withPage(_appendPage!, _prependPageItems!)),
    ).map(_paginationRowId).toSet();
    final current = _applyRowView(_items);
    final anchorIndex = current.indexWhere(
      (row) => ('data', _paginationRowId(row)) == anchorId,
    );
    if (anchorIndex < 0) return const [];
    return current
        .take(anchorIndex)
        .where((row) => !retained.contains(_paginationRowId(row)))
        .toList();
  }

  void _schedulePrependMeasurement() {
    if (_prependMeasureItems == null || _prependMeasureScheduled) return;
    _prependMeasureScheduled = true;
    final generation = _appendGeneration;
    final measuredWidths = List<double>.of(_widths);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prependMeasureScheduled = false;
      if (!mounted ||
          generation != _appendGeneration ||
          _prependMeasureItems == null ||
          _appendPage == null) {
        return;
      }
      if (_displayItems.isEmpty) {
        // A local filter can hide the old anchor while the measuring frame is
        // pending. There is then no position to preserve and no measuring tree.
        _prependAnchor.reset();
        _commitPrepend();
        return;
      }
      if (!listEquals(measuredWidths, _widths)) {
        // Auto-width growth can run earlier in this same post-frame phase.
        // Wait for layout at those final widths before using the measured height.
        _schedulePrependMeasurement();
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      final box = _prependMeasureKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final controller = _verticalScrollController;
      final position = controller != null && controller.positions.length == 1
          ? controller.position
          : null;
      final anchor = _visiblePaginationAnchor();
      final needed = _rowsInsertedBefore(anchor?.id);
      final removed = _rowsRemovedBefore(anchor?.id);
      if (!listEquals(needed, _prependMeasureItems) ||
          !listEquals(removed, _removeMeasureItems)) {
        setState(() {
          _prependMeasureItems = needed;
          _removeMeasureItems = removed;
        });
        return;
      }
      final removedBox = _removeMeasureKey.currentContext?.findRenderObject();
      if (removed.isNotEmpty &&
          (removedBox is! RenderBox || !removedBox.hasSize)) {
        return;
      }
      final insertedExtent = box.size.height;
      final removedExtent = removedBox is RenderBox && removedBox.hasSize
          ? removedBox.size.height
          : 0.0;
      _prependAnchor.prepareChange(insertedExtent - removedExtent);
      // Replacing equal-height pages at opposite edges can leave the total
      // scroll extent unchanged. Still run the pending measured correction in
      // the next layout instead of silently skipping it with unchanged metrics.
      if (_prependAnchor.pending && position != null) position.correctBy(0);
      setState(() {
        if (position != null &&
            position.maxScrollExtent <= 0.5 &&
            insertedExtent > 0) {
          // A list shorter than its viewport needs real trailing room to keep
          // the old row in place after prepending. Otherwise its offset clamps
          // to zero despite the measured correction.
          final anchorBox = anchor == null
              ? null
              : _mountedPaginationRows[anchor.id]?.box;
          final viewportObject = anchorBox == null
              ? null
              : RenderAbstractViewport.maybeOf(anchorBox);
          if (viewportObject is RenderBox) {
            final viewport = viewportObject as RenderBox;
            final viewportBottom = viewport.size.height;
            var contentBottom = 0.0;
            for (final entry in _mountedPaginationRows.values) {
              if (entry.box.attached &&
                  entry.box.hasSize &&
                  identical(
                    RenderAbstractViewport.maybeOf(entry.box),
                    viewport,
                  )) {
                contentBottom = math.max(
                  contentBottom,
                  entry.box.localToGlobal(Offset.zero, ancestor: viewport).dy +
                      entry.box.size.height,
                );
              }
            }
            _prependBottomSpace += math.max(0, viewportBottom - contentBottom);
          }
        }
      });
      _commitPrepend();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _appendGeneration) return;
        // A short list can keep maxScrollExtent == 0, so the physics callback
        // need not run. Never leave a correction to affect a later interaction.
        _prependAnchor.reset();
        final retained = anchor == null
            ? null
            : _mountedPaginationRows[anchor.id]?.box;
        if (position == null ||
            retained == null ||
            !retained.attached ||
            !retained.hasSize ||
            !position.hasContentDimensions ||
            controller?.positions.contains(position) != true ||
            !identical(
              RenderAbstractViewport.maybeOf(retained),
              anchor!.viewport,
            )) {
          return;
        }
        final residual =
            retained.localToGlobal(Offset.zero, ancestor: anchor.viewport).dy -
            anchor.top;
        if (residual.abs() > 0.5) {
          position.jumpTo(
            (position.pixels + residual).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
      });
    });
  }

  void _commitPrepend() {
    setState(() {
      _acceptPageIndicator(_appendPage!);
      _acceptPage(_acceptedPage, _prependPageItems!);
      _appendPage = null;
      _appendError = null;
      _prependMeasureItems = null;
      _prependPageItems = null;
      _removeMeasureItems = const [];
      _syncRows();
    });
    if (!_pageFocus.hasFocus) _pageCtrl.text = '$_currentPage';
    _configurePlatform();
    if (_fullscreen) _fsTick.value++;
  }

  Widget _measurePrepend(Widget child, Widget Function(T) buildRow) {
    if (_prependMeasureItems != null) {
      _prependMeasureItems = _rowsInsertedBefore(
        _visiblePaginationAnchor()?.id,
      );
      _removeMeasureItems = _rowsRemovedBefore(_visiblePaginationAnchor()?.id);
    }
    final measuring = _prependMeasureItems;
    if (measuring != null) _schedulePrependMeasurement();
    return Stack(
      children: [
        child,
        if (measuring != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Offstage(
              child: Column(
                key: _prependMeasureKey,
                mainAxisSize: MainAxisSize.min,
                children: [for (final row in measuring) buildRow(row)],
              ),
            ),
          ),
        if (_removeMeasureItems.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Offstage(
              child: Column(
                key: _removeMeasureKey,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final row in _removeMeasureItems) buildRow(row),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget? get _prependFeedback => !_prepending
      ? null
      : _appendError != null
      ? Material(child: _appendFailure())
      : _appendPage != null
      ? const LinearProgressIndicator(minHeight: 2)
      : null;

  Widget _appendFailure() => Padding(
    padding: const EdgeInsets.all(UtenSpacing.s8),
    child: Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(_appendError ?? '下一页加载失败'),
        TextButton(
          onPressed: () => _extendPages(prepend: _prepending),
          child: const Text('重试'),
        ),
      ],
    ),
  );

  final _platform = PlatformTableController<T>();
  List<MasterColumnDef<T>>? _platformColumnCache;
  List<MasterColumnDef<T>>? _platformBaseCache;
  TableColumnProjectionController? _projection;
  bool _platformRefreshScheduled = false;
  bool _projectionScheduled = false;
  Object? _projectionOwner;
  final _aiSlot = AiPageSlot();

  /// [setState] for the AI part file (extension members cannot call it).
  void _aiRebuild(VoidCallback change) => setState(change);

  List<MasterColumnDef<T>> get _columns {
    if (_platformColumnCache != null &&
        identical(_platformBaseCache, widget.columns)) {
      return _platformColumnCache!;
    }
    _platformBaseCache = widget.columns;
    return _platformColumnCache = [
      ...widget.columns,
      for (final column in _platform.definitions)
        MasterColumnDef<T>(
          key: column.key,
          label: column.name,
          width: column.numeric ? 140 : 180,
          type: column.numeric ? 'number' : 'text',
          info: column.calculated ? '计算展示，不改变原单据金额或库存数量' : '业务记录的补充信息',
          exportDefinition: _platform.projectionDefinition(column),
          value: (row) => _platform.value(row, column),
          cellBuilderHandlesSemantics: true,
          cellBuilder: (context, row) {
            final child = PlatformColumnValue(
              controller: _platform,
              row: row,
              column: column,
            );
            return widget.platformCellDecorator?.call(
                  context,
                  row,
                  column.key,
                  _platform.value(row, column),
                  child,
                ) ??
                child;
          },
        ),
    ];
  }

  void _configurePlatform() {
    if (widget.listItemBuilder != null) return;
    _projection = TableColumnProjectionScope.read(context);
    _platform.configure(
      context,
      descriptor: PlatformTableDescriptor<T>(
        kind: 'master',
        revision: (_items, widget.leadingGroups),
        tableKey: widget.tableKey,
        columnKeys: widget.columns.map((c) => c.key).toList(),
        rows: [
          ..._items,
          for (final group in widget.leadingGroups ?? <MasterDataGroup<T>>[])
            ...group.items,
        ],
      ),
      explicitBinding: widget.platformBinding,
      columnEditingEnabled: widget.columnEditingEnabled,
      exactFactKeys: widget.columns
          .where((column) => column.exactValueOf != null)
          .map((column) => column.key)
          .toSet(),
      factListenablesOf: (row) => [
        for (final column in widget.columns)
          if (column.exactValueOf != null && column.exactListenableOf != null)
            ?column.exactListenableOf!(row),
      ],
      factsOf: (row) => {
        for (final column in widget.columns)
          if (column.exactValueOf != null)
            column.key: column.exactValueOf!(row),
      },
    );
    _platformColumnCache = null;
    _applyPlatformLayout();
  }

  void _applyPlatformLayout() {
    final columns = _columns;
    final keys = columns.map((c) => c.key).toSet();
    final saved = _platform.localLayout(
      _columns.map((c) => c.key).toList(),
      defaultHidden: _columns
          .where((c) => !c.defaultVisible)
          .map((c) => c.key)
          .toSet(),
    );
    _applyQueryPreferences(
      saved.filters,
      saved.sortColumn,
      saved.sortAscending,
      saved.hasQueryPreferences,
    );
    if (saved.order.isNotEmpty) {
      _columnOrder = [
        ...saved.order.where(keys.contains),
        ...columns.map((c) => c.key).where((key) => !saved.order.contains(key)),
      ];
      _hiddenKeys
        ..clear()
        ..addAll(saved.hidden.where(keys.contains))
        ..addAll(
          columns
              .where((c) => !c.defaultVisible && !saved.order.contains(c.key))
              .map((c) => c.key),
        );
      _pinnedKeys
        ..clear()
        ..addAll(
          saved.pinned.where(
            (key) => keys.contains(key) && !_hiddenKeys.contains(key),
          ),
        );
    } else {
      _columnOrder = [
        ..._columnOrder.where(keys.contains),
        ...columns
            .map((c) => c.key)
            .where((key) => !_columnOrder.contains(key)),
      ];
    }
    for (final column in columns) {
      if (_platform.binding?.revealPopulatedColumnKeys.contains(
                _platform.canonicalKey(column.key),
              ) ==
              true &&
          _items.any((row) {
            final value = column.value(row)?.trim();
            return value != null && value.isNotEmpty && value != '—';
          })) {
        _hiddenKeys.remove(column.key);
      }
    }
    if (_hiddenKeys.length >= columns.length) _hiddenKeys.clear();
    _columnOrder = utenNormalizePinnedPrefix(
      order: _columnOrder,
      hiddenKeys: _hiddenKeys,
      pinnedKeys: _pinnedKeys,
    );
    if (_widths.length != columns.length) {
      _widths = [
        for (var i = 0; i < columns.length; i++)
          i < _widths.length ? _widths[i] : columns[i].width,
      ];
    }
    for (var i = 0; i < columns.length; i++) {
      final width = saved.widths[columns[i].key];
      if (width != null) {
        _widths[i] = width;
        _manualResized.add(i);
      }
    }
  }

  void _platformChanged() {
    if (_platformRefreshScheduled || !mounted) return;
    _platformRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _platformRefreshScheduled = false;
      if (!mounted) return;
      setState(() {
        _platformColumnCache = null;
        _applyPlatformLayout();
        _widthsDirty = true;
      });
      if (_fullscreen) _fsTick.value++;
      _publishProjection();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _persistPlatformLayout() {
    _platform.saveLayout(
      knownKeys: _columns.map((c) => c.key).toList(),
      order: List.of(_columnOrder),
      hidden: Set.of(_hiddenKeys),
      pinned: Set.of(_pinnedKeys),
      widths: {
        for (final i in _manualResized)
          if (i < _widths.length && i < _columns.length)
            _columns[i].key: _widths[i],
      },
    );
    _publishProjection();
  }

  void _resetPlatformLayout() {
    _platform.resetLayout();
    setState(() {
      _platformColumnCache = null;
      _columnOrder = [];
      _hiddenKeys.clear();
      _pinnedKeys.clear();
      _manualResized.clear();
      _applyPlatformLayout();
      _widthsDirty = true;
    });
    _persistPlatformLayout();
    if (_fullscreen) _fsTick.value++;
  }

  Future<void> _addPlatformColumn() async {
    final key = await showPlatformColumnPicker(
      context,
      controller: _platform,
      hiddenColumns: [
        for (final column in _columns)
          if (_hiddenKeys.contains(column.key))
            PlatformSystemColumn(
              key: column.key,
              label: column.label,
              numeric: _numericColumnTypes.contains(column.type),
            ),
      ],
      allColumns: [
        for (final column in _columns)
          PlatformSystemColumn(
            key: column.key,
            label: column.label,
            numeric: _numericColumnTypes.contains(column.type),
          ),
      ],
    );
    if (!mounted || key == null) return;
    setState(() {
      _platformColumnCache = null;
      _applyPlatformLayout();
      _hiddenKeys.remove(key);
      _widthsDirty = true;
    });
    _persistPlatformLayout();
    if (_fullscreen) _fsTick.value++;
  }

  Widget _platformAddButton() => IconButton(
    key: const Key('platform-table-add-column'),
    tooltip: _platform.columnEditingEnabled ? '添加列' : '显示列',
    onPressed: _addPlatformColumn,
    icon: Icon(
      _platform.columnEditingEnabled
          ? Icons.add_rounded
          : Icons.view_column_outlined,
    ),
  );
  void _publishProjection() {
    if (_projectionScheduled || _projection == null) return;
    _projectionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _projectionScheduled = false;
      if (!mounted) return;
      _projection?.publish(
        this,
        TableColumnProjection(
          tableKey: _platform.tableKey,
          scope: _platform.binding?.scope,
          sourceKeys: {
            for (final column in _columns)
              _platform.canonicalKey(column.key): column.key,
          },
          columns: [
            for (final i in _visibleIndices)
              TableProjectedColumn(
                key: _platform.canonicalKey(_columns[i].key),
                sourceKey: _columns[i].key,
                label: _columns[i].label,
                width: i < _widths.length ? _widths[i] : _columns[i].width,
                type: _columns[i].type,
                definition: _columns[i].exportDefinition,
              ),
          ],
        ),
        contextOwner: _projectionOwner ?? ModalRoute.of(context),
      );
    });
  }

  // 表头/表体横滚同步（早期 Flutter 的 LinkedScrollControllerGroup 在 3.44 已移除，
  // 改用两个普通 ScrollController + 互听 + _syncing 防回环，行为等价）。
  late final ScrollController _headerH;
  late final ScrollController _bodyH;
  // 表体竖向滚动：翻页时 jumpTo(0) 回顶（从第一条开始）。
  late final ScrollController _bodyV;
  bool get _usesPrimaryScroll => widget.primary && !_fullscreen;
  ScrollController? get _verticalScrollController =>
      _usesPrimaryScroll ? PrimaryScrollController.maybeOf(context) : _bodyV;
  int? _pendingScrollToEnd;
  int _scrollToEndAttempts = 0;
  bool _scrollToEndScheduled = false;

  void _scheduleScrollToEnd() {
    if (_pendingScrollToEnd == null ||
        _scrollToEndScheduled ||
        widget.isLoading ||
        widget.error != null ||
        widget.items.isEmpty) {
      return;
    }
    _scrollToEndScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToEndScheduled = false;
      if (!mounted ||
          _pendingScrollToEnd == null ||
          widget.isLoading ||
          widget.error != null ||
          widget.items.isEmpty) {
        return;
      }
      final controller = _verticalScrollController;
      if (controller == null || controller.positions.length != 1) return;
      final position = controller.position;
      if (!position.hasContentDimensions) return;
      final target = position.maxScrollExtent;
      if (!target.isFinite || (target - position.pixels).abs() < 0.5) {
        _pendingScrollToEnd = null;
        return;
      }
      controller.jumpTo(target);
      // Lazy rows can revise maxScrollExtent after this jump. Recheck the next
      // layout, but bound retries so later rebuilds cannot trap the user at end.
      if (++_scrollToEndAttempts < 8) {
        _scheduleScrollToEnd();
        WidgetsBinding.instance.scheduleFrame();
      } else {
        _pendingScrollToEnd = null;
      }
    });
  }

  // 联动表格与带悬浮留白表格共用横滚条覆盖层，与 _bodyH 双向同步。
  // 横滚条按实际末行定位，额外滚动留白不改变横滚条与末行的间距。
  late final ScrollController _overlayH = ScrollController();
  bool _overlaySyncing = false;
  // 分页跳转输入框：填数字回车跳页；外部翻页（上一页/下一页/跳页）时同步回当前页。
  late final TextEditingController _pageCtrl;
  final FocusNode _pageFocus = FocusNode();
  bool _syncing = false;

  // —— 本地取值筛选 / 本地排序（filterFromRows 列；2026-09-25）——
  // filterFromRows 列的筛选值由组件自持（宿主 filters/onFilterChanged 不参与），
  // 显示行就地过滤；宿主未接 onSortChange 时 sortable 列就地排序（取值感知
  // number/money/date，空值恒排末尾）。服务端分页页两者都由宿主回调接管。
  final Map<String, String?> _rowFilters = <String, String?>{};
  String? _localSortColumn;
  bool _localSortAscending = true;
  String _queryPreferenceSignature = '';
  int _queryRestoreRevision = 0;
  bool get _serverPaged =>
      widget.onPageChange != null ||
      widget.onLoadMore != null ||
      widget.totalPages > 1;
  bool _ownsHeaderFilter(MasterColumnDef<T> column) =>
      !widget.externalFilterKeys.contains(column.key) &&
      ((!_serverPaged && column.filterFromRows) ||
          widget.facets.containsKey(column.key));
  String _querySignature(
    Map<String, String?> filters,
    String? sort,
    bool ascending,
    bool present,
  ) => jsonEncode([
    _platform.tableKey,
    _platform.queryLifecycle,
    filters,
    sort,
    ascending,
    present,
    _columns.where(_ownsHeaderFilter).map((column) => column.key).toList()
      ..sort(),
  ]);
  void _applyQueryPreferences(
    Map<String, String?> filters,
    String? sort,
    bool ascending,
    bool present,
  ) {
    final signature = _querySignature(filters, sort, ascending, present);
    if (signature == _queryPreferenceSignature) return;
    final previouslyPresent = _queryPreferenceSignature.isNotEmpty;
    _queryPreferenceSignature = signature;
    final revision = ++_queryRestoreRevision;
    final lifecycle = _platform.queryLifecycle;
    if (!present && !previouslyPresent) return;
    final local = <String, String?>{};
    final server = <String, String?>{};
    for (final column in _columns) {
      if (!_ownsHeaderFilter(column)) continue;
      final value = present ? filters[column.key] : null;
      if (!_serverPaged &&
          column.filterFromRows &&
          !widget.facets.containsKey(column.key)) {
        if (value != null) local[column.key] = value;
      } else if (widget.filters[column.key] != value) {
        server[column.key] = value;
      }
    }
    _rowFilters
      ..clear()
      ..addAll(local);
    final validSort = _columns.any(
      (column) => column.key == sort && column.sortable,
    );
    final desiredSort = present && validSort ? sort : null;
    if (widget.onSortChange == null) {
      _localSortColumn = desiredSort;
      _localSortAscending = desiredSort == null ? true : ascending;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          revision != _queryRestoreRevision ||
          lifecycle != _platform.queryLifecycle) {
        return;
      }
      for (final entry in server.entries) {
        widget.onFilterChanged(entry.key, entry.value);
      }
      if (widget.onSortChange != null &&
          (widget.sortColumn != desiredSort ||
              widget.sortAscending != ascending)) {
        widget.onSortChange!(
          desiredSort,
          desiredSort == null ? true : ascending,
        );
      }
    });
  }

  void _persistQuery({
    String? filterKey,
    String? filterValue,
    String? sort,
    bool? ascending,
    bool sortChanged = false,
  }) {
    final filters = <String, String?>{};
    for (final column in _columns) {
      if (!_ownsHeaderFilter(column)) continue;
      final value = column.key == filterKey
          ? filterValue
          : (!_serverPaged &&
                    column.filterFromRows &&
                    !widget.facets.containsKey(column.key)
                ? _rowFilters[column.key]
                : widget.filters[column.key]);
      if (value != null) filters[column.key] = value;
    }
    final chosenSort = sortChanged
        ? sort
        : widget.onSortChange == null
        ? _localSortColumn
        : widget.sortColumn;
    final chosenAscending =
        ascending ??
        (widget.onSortChange == null
            ? _localSortAscending
            : widget.sortAscending);
    _platform.saveQuery(
      filters: filters,
      sortColumn: chosenSort,
      sortAscending: chosenAscending,
    );
    _queryPreferenceSignature = _querySignature(
      filters,
      chosenSort,
      chosenAscending,
      true,
    );
    _queryRestoreRevision++;
  }

  // —— 横滚条覆盖层测量 ——
  /// 表体区 Stack / 末行 的测量键。
  final GlobalKey _bodyAreaKey = GlobalKey();
  final GlobalKey _lastRowKey = GlobalKey();
  // 自然滚动条/覆盖层切换时保留同一个横向视口，不因包装层变化重建 ScrollPosition。
  final GlobalKey _bodyHorizontalKey = GlobalKey();

  /// 横滚条底边在表体区内的 local top；null=未测得（隐藏覆盖层）。
  final ValueNotifier<double?> _hBarY = ValueNotifier<double?>(null);

  /// 横滚条覆盖层高度（thumb 在其底部绘制）。
  static const double _hBarHeight = 11;

  /// 末行底到横滚条 box 底边的距离（含滑块厚 10）：滑块上缘距末行约 1px。
  static const double _hBarGap = 11;

  /// 悬浮批量按钮的额外滚动让位，末行可继续滚出操作区。
  static const double _batchPad = UtenFloatingActionGroup.scrollClearance;

  /// 表体 ListView 当前底 padding，随悬浮动作或外部留白配置同步。
  double _bodyBottomPad = _hBarGap;

  /// compact 悬浮胶囊遮挡高度（非外壳内恒 0），didChangeDependencies 里同步。
  double _capsuleOcclusion = 0;

  // —— embedded 表头吸顶（stickyHeaderPinned，2026-09-22）——
  /// 吸顶核心（仅传了 stickyHeaderPinned 的 embedded 表创建）。表体测量复用
  /// [_bodyAreaKey]；Stack/表头单元各有独立键。
  UtenStickyHeaderTracker? _sticky;
  final GlobalKey _stickyStackKey = GlobalKey();
  final GlobalKey _stickyHeaderKey = GlobalKey();

  /// 吸顶单元的流内占位高度（首帧 45 兜底 = 表头 minHeight 44 + 1px 分隔线；
  /// post-frame 实测修正——见 _updateStickyHeader）。
  double _pinnedUnitHeight = 45;

  /// 祖先滚动（详情页页面 ListView）position：滚动 tick 同帧驱动吸顶。
  ScrollPosition? _stickyPagePos;

  /// 表格是否已被滚到置顶过（或滚轮门按需请求过垫高）。见 [_stickyTrailingSpace]：
  /// 短表垫高的启用门槛——首屏保持自然高度，置顶过/被请求后垫足且不缩回。
  bool _stickyEngaged = false;

  /// 滚轮门按需补差累计的撑高量（置顶点仍够不着时按实测量追加；0=只按公式）。
  double _stickyReachExtra = 0;

  /// 实测缺口累计的垫高量（见 [_stickyTrailingSpace]；0=还不需要垫）。
  double _stickyStretch = 0;

  /// 短表/空表置顶所需的额外滚动余量（仅 sticky 表生效），垫在表体**下方**。
  /// 表头要顶到视口顶，页面滚动余量得够——短表内容不够就把缺口补在这里。
  /// 历史版本按「视口高−表头−24」公式把表体撑满（Excel 式空白表格区），结果
  /// 表后内容被整屏空白隔开（与 UtenEditableGrid「添加行/汇总不跟表上移」同根）。
  /// 2026-09-25 起改按实测缺口：置顶点够得着（页面下方本就有内容）就一点不垫，
  /// 够不着才垫足差值——空白最小化，表后内容紧跟末行。
  double get _stickyTrailingSpace =>
      _stickyEngaged ? _stickyStretch + _stickyReachExtra : 0;

  /// 实测置顶缺口：置顶点（[UtenStickyHeaderTracker.pinOffset]）减页面当前滚动
  /// 余量（maxScrollExtent）。>0 = 怎么滚表头都到不了视口顶（2026-09-25 用户口径
  /// 「财务那里一直滚不到置顶，总是差点」的根因），需要垫高这么多才够。
  /// 页面总高不足视口时 maxScrollExtent 被钳成 0，本值会低估一截——靠
  /// [_onStickyEngage] 的「缺口>0 就累加」逐跳收敛：第一跳垫完总高即超视口，
  /// 余量回到未钳制区间，下一跳算出的缺口就是精确值。
  /// 锚点未建/量不到时返回 0（按不需要垫处理，滚轮门会再触发）。
  double _measureReachDeficit() {
    final sticky = _sticky;
    if (sticky == null) return 0;
    final pin = sticky.pinOffset;
    final pos = sticky.pagePosition;
    if (pin == null || pos == null || !pos.hasContentDimensions) return 0;
    final deficit = pin - pos.maxScrollExtent;
    return deficit > 0 ? deficit : 0;
  }

  /// 滚轮门请求垫高。extra>0 = 门 post-frame 复测后的精确补差（新于本帧读数，
  /// 优先采信，避免与自算缺口双计）；extra=0 = 自算实测缺口，缺口>0 就累加
  /// （见 [_measureReachDeficit] 的钳制收敛说明）。垫足后缺口归 0 自然停。
  void _onStickyEngage(double extra) {
    if (!mounted) return;
    final deficit = extra > 0 ? 0.0 : _measureReachDeficit();
    if (!_stickyEngaged || extra > 0 || deficit > 0) {
      setState(() {
        _stickyEngaged = true;
        if (extra > 0) {
          _stickyReachExtra += extra;
        } else {
          _stickyStretch += deficit;
        }
      });
    }
  }

  /// 表体右缘竖向内容滚动条（自绘，2026-09-22）。
  Widget _buildVerticalScrollbar() {
    final controller = _verticalScrollController;
    final innerPhase = UtenInnerScrollActiveScope.maybeOf(context);
    if (innerPhase == null) {
      return UtenContentScrollbar(
        controller: controller ?? _bodyV,
        bottomInset: _bodyBottomPad,
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: innerPhase,
      builder: (context, innerActive, child) => UtenContentScrollbar(
        controller: controller ?? _bodyV,
        visible: innerActive,
        bottomInset: _bodyBottomPad,
      ),
    );
  }

  void _onStickyPageScroll() {
    _sticky?.handleScrollTick();
    _scheduleStickyMeasure();
  }

  /// post-frame 量位（build/数据/滚动后刷新锚点与占位高度）。
  bool _stickyMeasureScheduled = false;

  void _scheduleStickyMeasure() {
    if (_sticky == null || !mounted || _stickyMeasureScheduled) return;
    _stickyMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stickyMeasureScheduled = false;
      if (!mounted) return;
      final sticky = _sticky;
      if (sticky == null) return;
      sticky.measure();
      final h = sticky.headerHeight;
      if (h > 0 && (h - _pinnedUnitHeight).abs() > 0.5) {
        setState(() => _pinnedUnitHeight = h);
      }
      // 首次置顶 → 启用短表垫高（与 UtenEditableGrid._updateSticky 同款）。能自然
      // 置顶说明余量够，实测缺口为 0、一点不垫；余量不足的短表经滚轮门
      // （UtenStickyWheelGate.onEngage → [_onStickyEngage]）按缺口垫足。
      if (sticky.isPinned && !_stickyEngaged) {
        setState(() => _stickyEngaged = true);
      }
    });
  }

  /// 当前列宽：默认按列内容自动适配最宽值（[MasterColumnDef.width] 不再用于布局，
  /// 保留字段供未来手动覆盖/最小宽度扩展）。用户拖拽后覆盖；自动适配需 BuildContext 的
  /// 文字样式，故在 build 首帧测算（见 [_ensureWidths]）。
  List<double> _widths = const [];

  /// 用户已手动拖拽过的列下标：数据刷新时这些列保留用户宽度，其余按新内容重新适配。
  final Set<int> _manualResized = {};

  /// 列宽全量重算标记：首帧、列集合或字号档变化时置 true，[_ensureWidths] 算完清掉。
  bool _widthsDirty = true;

  /// 每列已量过的文本宽度(按列 key；单元格值按字符串去重)。列集合或字号档变化时清空。
  /// 数据刷新(翻页/筛选/静默重拉)只量新出现的值，列宽只增不减(ADR-108)：
  /// 同一份数据换个 List 实例不再整表重量，静默刷新时列宽也不跳。
  final Map<String, _ColumnTextMeasure> _textMeasures = {};

  /// 数据变了(列集合不变)：待本帧之后补量新值、需要时加宽。
  bool _widthGrowthPending = false;
  bool _widthGrowthScheduled = false;

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

  /// 当前列显示顺序（含隐藏列）。默认 = _columns 原序；表头横拖换位/
  /// 表头设置弹窗拖拽排序/表头右键菜单移动修改（会话内有效，与 _hiddenKeys 同
  /// 生命周期——主数据页无账号级列偏好持久化）。列集合变化时重置。
  List<String> _columnOrder = const [];

  /// 固定在左侧的列 key（横滚时钉在多选框列右侧、不随表体滚走，2026-09-25）。
  /// 可见序列中恒为前缀（utenNormalizePinnedPrefix 维护）；与 _hiddenKeys 同
  /// 生命周期，列集合变化时重置、隐藏固定列时自动解除固定。
  final Set<String> _pinnedKeys = {};

  /// 各固定列「固定前」在完整列序中的下标：取消固定时据此放回原位
  /// （2026-09-25 用户口径「取消固定也要回到对应的地方」）。
  final Map<String, int> _pinOriginIndex = {};

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
  String columnDragLabel(int i) => i < _columns.length ? _columns[i].label : '';

  /// 该列当前可否拖出隐藏：至少保留一列可见（末列永不 arm，松开 no-op、视觉回弹）。
  @override
  bool columnCanDragHide(int i) => i < _columns.length && _visibleCount > 1;

  /// 松手且 armed：复用既有显隐切换守卫（末列不隐）。
  @override
  void onColumnDragHide(int i) => _toggleColumn(_columns[i].key);

  @override
  List<({int index, double width})> get reorderVisibleColumns => [
    for (final i in _visibleIndices)
      (index: i, width: i < _widths.length ? _widths[i] : _minColWidth),
  ];

  /// 横拖换位/弹窗排序/右键菜单移动落位：可见序列内搬移，隐藏列保持原锚位；
  /// 固定块前缀不变量兜底（拖过固定块边界的落位被规范化收回到块边界之后）。
  /// 会话内生效（与 _hiddenKeys 同生命周期），全屏内容经 _fsTick 同步重建。
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
    final newVisibleKeys = <String>{for (final i in seq) _columns[i].key};
    final queue = <String>[for (final i in seq) _columns[i].key];
    setState(() {
      _columnOrder = utenNormalizePinnedPrefix(
        order: [
          for (final key in _columnOrder)
            newVisibleKeys.contains(key) ? queue.removeAt(0) : key,
        ],
        hiddenKeys: _hiddenKeys,
        pinnedKeys: _pinnedKeys,
      );
    });
    _fsTick.value++; // 全屏路由内的表格同步重建。
    _persistPlatformLayout();
  }

  /// 表头设置弹窗拖拽排序：在完整列序（含隐藏列）内搬移 key。
  /// onReorderItem 口径：[newIndex] 为 removeAt 后的最终插入位。
  /// 越过固定块边界的搬移由规范化收回（固定列恒为可见前缀）。
  void _reorderColumnByKeys(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _columnOrder.length) return;
    setState(() {
      final key = _columnOrder.removeAt(oldIndex);
      _columnOrder.insert(newIndex.clamp(0, _columnOrder.length), key);
      _columnOrder = utenNormalizePinnedPrefix(
        order: _columnOrder,
        hiddenKeys: _hiddenKeys,
        pinnedKeys: _pinnedKeys,
      );
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  // —— 表头右键菜单（固定/移动/隐藏，2026-09-25）——

  /// 固定在左侧的可见列下标（前缀不变量下即可见序列开头的连续固定列）。
  List<int> get _pinnedVisibleIndices {
    final result = <int>[];
    for (final i in _visibleIndices) {
      if (!_pinnedKeys.contains(_columns[i].key)) break;
      result.add(i);
    }
    return result;
  }

  /// 固定区总宽（含行首多选框列）。
  double _pinnedLeadingWidth(List<int> pinnedIndices) =>
      (widget.selectable ? _selectionColWidth : 0) +
      pinnedIndices.fold(
        0.0,
        (sum, i) => sum + (i < _widths.length ? _widths[i] : 0),
      );

  /// 固定/取消固定一列：固定 = 记录当前下标后搬到固定块末尾；取消固定 =
  /// 放回固定前的位置（2026-09-25 用户口径「取消固定也要回到对应的地方」）。
  void _toggleColumnPin(String key) {
    setState(() {
      final origin = _pinOriginIndex[key];
      final wasPinned = _pinnedKeys.contains(key);
      if (!wasPinned) {
        _pinOriginIndex[key] = _columnOrder.indexOf(key);
      } else {
        _pinOriginIndex.remove(key);
      }
      final r = utenToggleColumnPin(
        order: _columnOrder,
        hiddenKeys: _hiddenKeys,
        pinnedKeys: _pinnedKeys,
        key: key,
        originIndex: origin,
        defaultOrder: _columns.map((c) => c.key).toList(),
      );
      _columnOrder = r.order;
      _pinnedKeys
        ..clear()
        ..addAll(r.pinned);
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  /// 表头右键菜单的移动动作（向左/右一格、放到最前/最后）。
  void _moveColumnTo(String key, UtenColumnHeaderMove move) {
    setState(() {
      _columnOrder = utenMoveVisibleColumn(
        order: _columnOrder,
        hiddenKeys: _hiddenKeys,
        pinnedKeys: _pinnedKeys,
        key: key,
        move: move,
      );
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  /// 表头右键菜单条目（能力判定走 kit 纯函数；隐藏复用既有「至少留一列」守卫）。
  List<UtenContextMenuEntry> _headerMenuEntries(int i) {
    final key = _columns[i].key;
    final cap = utenColumnHeaderMenuCapabilities(
      order: _columnOrder,
      hiddenKeys: _hiddenKeys,
      pinnedKeys: _pinnedKeys,
      key: key,
      canHide: columnCanDragHide(i),
    );
    return utenColumnHeaderMenuEntries(
      UtenColumnHeaderMenuSpec(
        pinned: cap.pinned,
        canPin: cap.canPin,
        canHide: cap.canHide,
        canMoveLeft: cap.canMoveLeft,
        canMoveRight: cap.canMoveRight,
        canMoveToFront: cap.canMoveToFront,
        canMoveToBack: cap.canMoveToBack,
        onTogglePin: cap.canPin ? () => _toggleColumnPin(key) : null,
        onHide: cap.canHide ? () => _toggleColumn(key) : null,
        onMoveLeft: cap.canMoveLeft
            ? () => _moveColumnTo(key, UtenColumnHeaderMove.left)
            : null,
        onMoveRight: cap.canMoveRight
            ? () => _moveColumnTo(key, UtenColumnHeaderMove.right)
            : null,
        onMoveToFront: cap.canMoveToFront
            ? () => _moveColumnTo(key, UtenColumnHeaderMove.front)
            : null,
        onMoveToBack: cap.canMoveToBack
            ? () => _moveColumnTo(key, UtenColumnHeaderMove.back)
            : null,
      ),
    );
  }

  // —— 列宽自动适配 / 手动拖拽 常量 ——
  /// 拖拽命中区半宽：以列右边界为中心、半溢出到相邻列，便于精准抓住边界。
  static const double _gripHalf = 4;

  /// 列宽下限（自动适配与拖拽收窄共同下限，防止列被拖没）。
  static const double _minColWidth = 48;

  /// 列宽自动适配上限：超长文本（如备注）默认按此截断+省略号，用户可再拖宽。
  static const double _maxColWidth = 480;

  /// 自动适配取样行数：量前 N 行最宽值即可(全量量算大表偏重，最宽值通常在前段出现；
  /// 此后每次数据刷新再各取前 N 行里没量过的值补量，列只会加宽)。
  static const int _autoFitSampleSize = 30;
  static const double _cellPadX = UtenSpacing.s12; // 单元格左右内边距（表头/表体一致）
  static const double _headerIconAllowance = 24; // 表头筛选下拉箭头 + 富余
  static const double _sortIconAllowance = 20; // 可排序列表头排序图标 + 间距

  /// 列头 ⓘ 说明图标命中区（UtenColumnHintIcon → UtenFieldHintIcon dense = 28）。
  /// 不计入就会挤掉标签：声明宽偏窄又带说明的列（下达采购的「缺口」）一进页面
  /// 只剩一个 ⓘ，标签被省略号吃光（2026-09-11 用户反馈）。
  static const double _headerInfoIconAllowance = 28;

  /// 固定列标签前的图钉占宽（18 图标 + 4 间距，2026-09-25）。
  static const double _pinIconAllowance = 22;
  static const double _autoFitBuffer = 6; // 防贴边 ellipsis 富余

  /// 多选前导勾选列宽（合成单元格，不计入 _columns / 列宽自动适配 / 列显隐）。
  static const double _selectionColWidth = 48;

  @override
  void initState() {
    super.initState();
    _filterSnapshot = Map.of(widget.filters);
    _resetPages();
    _platform.addListener(_platformChanged);
    assert(
      !widget.selectable || widget.idOf != null,
      'MasterDataTableView: selectable:true 需提供 idOf(行→业务 id 提取器)。',
    );
    assert(
      !widget.primary || !widget.embedded,
      'MasterDataTableView: primary 不能与 embedded 同用(embedded 场景无 NestedScrollView 祖先)。',
    );
    _headerH = ScrollController();
    _columnOrder = _columns.map((c) => c.key).toList();
    _hiddenKeys.addAll(
      _columns.where((c) => !c.defaultVisible).map((c) => c.key),
    );
    _bodyH = ScrollController();
    _bodyV = ScrollController();
    if (widget.scrollToEndRequest != 0) {
      _pendingScrollToEnd = widget.scrollToEndRequest;
    }
    _pageCtrl = TextEditingController(text: '${widget.currentPage}');
    _pageFocus.addListener(() {
      if (!_pageFocus.hasFocus && mounted) _pageCtrl.text = '$_currentPage';
    });
    if (widget.stickyHeaderPinned != null) {
      _sticky = UtenStickyHeaderTracker(
        stackKey: _stickyStackKey,
        headerKey: _stickyHeaderKey,
        bodyKey: _bodyAreaKey,
        pinnedSink: widget.stickyHeaderPinned,
      );
    }
    _headerH.addListener(() => _sync(_headerH, _bodyH));
    _bodyH.addListener(() => _sync(_bodyH, _headerH));
    _bodyH.addListener(() => _syncH(_bodyH, _overlayH));
    _overlayH.addListener(() => _syncH(_overlayH, _bodyH));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configurePlatform();
    if (widget.listItemBuilder == null) {
      _aiSlot.attach(context, _aiTableSource);
    }
    // compact 悬浮胶囊避让：遮挡高度变化（进/出外壳、转屏改手势条）时重算
    // 表体底部留白。弹窗/picker 里查不到 scope 取 0，留白不受影响。
    final capsuleOcclusion = UtenCapsuleNavScope.occlusionOf(context);
    if (capsuleOcclusion != _capsuleOcclusion) {
      _capsuleOcclusion = capsuleOcclusion;
      _updateBodyPad();
    }
    // 吸顶表：绑定祖先滚动 position（详情页页面 ListView）——滚动 tick 同帧
    // 定表头位置，post-frame 复核量位（与 UtenEditableGrid 同款两段式）。
    if (_sticky == null) return;
    final pos = Scrollable.maybeOf(context)?.position;
    if (!identical(pos, _stickyPagePos)) {
      _stickyPagePos?.removeListener(_onStickyPageScroll);
      _stickyPagePos = pos;
      _stickyPagePos?.addListener(_onStickyPageScroll);
    }
    _scheduleStickyMeasure();
  }

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing || !dst.hasClients) return;
    _syncing = true;
    dst.jumpTo(src.offset);
    _syncing = false;
  }

  /// 横滚条覆盖层与表体双向同步，未挂载时不做处理。
  void _syncH(ScrollController src, ScrollController dst) {
    if (_overlaySyncing || !dst.hasClients || !src.hasClients) return;
    _overlaySyncing = true;
    dst.jumpTo(src.offset);
    _overlaySyncing = false;
  }

  /// 布局完成后重算表体测量（渲染对象须完成 layout 才能量）：
  /// 更新横滚条覆盖层位置与表体底部留白。
  bool _hBarUpdateScheduled = false;

  void _scheduleHBarUpdate() {
    if (!mounted || _hBarUpdateScheduled) return;
    _hBarUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hBarUpdateScheduled = false;
      if (!mounted) return;
      if (_usesOverlayHBar) {
        _updateHBar();
        _syncH(_bodyH, _overlayH);
      } else if (_hBarY.value != null) {
        _hBarY.value = null;
      }
      _updateBodyPad();
    });
  }

  /// 滚动留白独立于横滚条：悬浮动作取共享留白，页面可再提供更大的让位空间。
  void _updateBodyPad() {
    // 即使内容刚好装得下，也要允许把最后一行滚到操作区上方。
    // compact 悬浮胶囊的遮挡高度叠加在其后：页面给的 floor 也须抬过胶囊，
    // 否则悬浮批量动作（已按胶囊避让抬升）反而盖住末行。
    final next =
        (_hasFloatingBatchActions ? _batchPad : _hBarGap).clamp(
          widget.bottomContentPadding,
          double.infinity,
        ) +
        _capsuleOcclusion;
    if (next != _bodyBottomPad) setState(() => _bodyBottomPad = next);
  }

  /// 末行可量时贴实际末行，始终只保留滑块自身的间距；末行未挂载时钉视口底。
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
    // 末行位置相对表体区量(localToGlobal 带 ancestor)：不带 ancestor 得到的是窗口
    // 坐标，根部整体缩放(UtenDisplayZoomBox)时与区高的画布尺寸相差 zoom 倍。
    const areaTop = 0.0;
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
          lastRowBox.localToGlobal(Offset.zero, ancestor: areaBox).dy +
          lastRowBox.size.height +
          pad;
      barBottom = contentBottom < areaBottom
          ? contentBottom - areaTop
          : areaBox.size.height;
    } else {
      barBottom = areaBox.size.height;
    }
    final minimumBottom = areaBox.size.height < _hBarHeight
        ? areaBox.size.height
        : _hBarHeight;
    barBottom = barBottom.clamp(minimumBottom, areaBox.size.height);
    if (_hBarY.value != barBottom) _hBarY.value = barBottom;
  }

  @override
  void didUpdateWidget(covariant MasterDataTableView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rowsController, widget.rowsController)) {
      oldWidget.rowsController?.detachPagination(this);
    }
    final appended = _updatePages(oldWidget);
    _configurePlatform();
    // 包括 200 -> 0 / 移除悬浮动作：新布局不再启用覆盖层时也必须撤掉旧留白。
    if (oldWidget.bottomContentPadding != widget.bottomContentPadding ||
        oldWidget.primary != widget.primary ||
        oldWidget.selectable != widget.selectable ||
        (oldWidget.batchActionsBuilder == null) !=
            (widget.batchActionsBuilder == null)) {
      _scheduleHBarUpdate();
    }
    // 列集合变了（数量或 key 序列不同，如报表切 docType）→ 清手动标记、全量重算列宽。
    if (!_sameColumnKeys(oldWidget.columns, widget.columns)) {
      _manualResized.clear();
      _widthsDirty = true;
      _textMeasures.clear(); // 换了一套列：旧列的量宽结果不沿用。
      _hiddenKeys
        ..clear()
        ..addAll(_columns.where((c) => !c.defaultVisible).map((c) => c.key));
      _columnOrder = _columns.map((c) => c.key).toList(); // 列序同随重置。
      _pinnedKeys.clear(); // 固定列同随列集合重置。
      _pinOriginIndex.clear();
      columnHeaderDragReset(); // 拖拽态/跟手浮层可能指向失效下标，重置（FM6）。
      _colLinks.clear(); // 旧下标的 LayerLink 作废，按新列集合下标重建。
    } else if (oldWidget.items != widget.items ||
        oldWidget.leadingGroups != widget.leadingGroups) {
      // 数据变了(翻页/筛选/排序/加载更多/静默重拉)→ 帧后只补量新出现的值，
      // 超出当前宽度才加宽；已手动调整的列不动。
      _widthGrowthPending = true;
    }
    // 吸顶表：数据/列变化改表高 → post-frame 重测锚点；notifier 换实例重绑。
    if (!identical(oldWidget.stickyHeaderPinned, widget.stickyHeaderPinned)) {
      _sticky?.pinnedSink = widget.stickyHeaderPinned;
    }
    if (_sticky != null) _scheduleStickyMeasure();
    // 翻页（currentPage 变化）→ 表体竖向回顶，从第一条开始。
    // primary 模式下竖向 position 由祖先 NestedScrollView 持有（_bodyV 无 client），
    // 须走 PrimaryScrollController；且 didUpdateWidget 处于 build 期，inner position
    // 首次翻页可能尚未挂载 → 推迟到帧结束后再 jump。
    final requestedEnd =
        widget.scrollToEndRequest != 0 &&
        oldWidget.scrollToEndRequest != widget.scrollToEndRequest;
    if (requestedEnd) {
      _pendingScrollToEnd = widget.scrollToEndRequest;
      _scrollToEndAttempts = 0;
    } else if ((!appended && oldWidget.currentPage != widget.currentPage) ||
        oldWidget.paginationScope != widget.paginationScope ||
        widget.scrollToEndRequest == 0) {
      _pendingScrollToEnd = null;
    }
    if (!appended &&
        !requestedEnd &&
        (oldWidget.currentPage != widget.currentPage || _queryChanged)) {
      final page = widget.currentPage;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            widget.currentPage != page ||
            _pendingScrollToEnd != null) {
          return;
        }
        final controller = _verticalScrollController;
        if (controller != null && controller.hasClients) controller.jumpTo(0);
        // 2026-10-02 用户口径「点分类/筛选后分类栏不得消失」：表体随翻页/换筛选
        // 回顶时，联动页（UtenCollapsingHeaderScrollView 的 NestedScrollView）的
        // 外层一起回顶。否则内容替换的滚动校正会被 NestedScrollView 转嫁成外层
        // 塌陷，宿主分类栏/工具条整条滚出视口，看起来就是「分类栏消失」。
        if (!_usesPrimaryScroll) return;
        final nested = context
            .findAncestorWidgetOfExactType<NestedScrollView>()
            ?.controller;
        if (nested != null && nested.hasClients && nested.position.pixels > 0) {
          nested.jumpTo(0);
        }
      });
    }
    // 外部翻页后，跳页输入框同步回当前页（用户未提交的输入被放弃，符合直觉）。
    if (!_pageFocus.hasFocus && _pageCtrl.text != '$_currentPage') {
      if (_fullscreen) {
        // The pager lives in a different route during fullscreen. Updating its
        // controller in this route's build would mark that TextFormField dirty.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pageCtrl.text = '$_currentPage';
        });
      } else {
        _pageCtrl.text = '$_currentPage';
      }
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
    _applyPlatformLayout();
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
                      if (widget.summaryBar != null && !widget.summaryBarInline)
                        _buildSummaryBar(ctx2),
                      if (widget.totalPages > 1) _buildPager(ctx2),
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
  /// 用户已手动拖拽的列([_manualResized])保留原宽度不重算。全量只在 [_widthsDirty] 时执行
  /// (首帧/换列/换字号档)；数据刷新走帧后增量补量([_scheduleWidthGrowth])，不占当前帧。
  void _ensureWidths(BuildContext context) {
    // 字号档（textScaler）变化也要重算：渲染时文字按放大字号铺，但量宽用的 TextPainter
    // 必须显式带上同一 textScaler 才量得准（否则按 1.0 量偏窄，大字号下要拖才显示全）。
    final textScaler = MediaQuery.textScalerOf(context);
    final scale = textScaler.scale(1);
    if (_lastScale != null && _lastScale != scale) {
      _widthsDirty = true;
      _textMeasures.clear();
    }
    if (!_widthsDirty) {
      if (_widthGrowthPending) _scheduleWidthGrowth();
      return;
    }
    _widthsDirty = false;
    _widthGrowthPending = false;
    _lastScale = scale;
    final pool = _widthSamplePool();
    final next = List<double>.filled(
      _columns.length,
      _minColWidth,
      growable: true,
    );
    for (var i = 0; i < _columns.length; i++) {
      if (_manualResized.contains(i) && i < _widths.length) {
        next[i] = _widths[i];
        continue;
      }
      final def = _columns[i];
      next[i] = _fitColumnWidth(
        def,
        _measureColumn(context, def, pool, textScaler),
      );
    }
    _widths = next;
  }

  /// 取样池：主数据 + 前导分组条目(分组行与主行共用同一套列宽，故一并参与测算，
  /// 保证展开/折叠分组时列宽不跳动；分组条目通常是禁用/不明货品，量小不影响性能)。
  List<T> _widthSamplePool() => <T>[
    ..._items,
    ...?_prependMeasureItems,
    for (final g in (widget.leadingGroups ?? <MasterDataGroup<T>>[]))
      ...g.items,
  ];

  /// 量一列：表头只量一次；取样行里没量过的值才量(按字符串去重)。
  _ColumnTextMeasure _measureColumn(
    BuildContext context,
    MasterColumnDef<T> def,
    List<T> pool,
    TextScaler textScaler,
  ) {
    final theme = Theme.of(context);
    final measure = _textMeasures.putIfAbsent(def.key, _ColumnTextMeasure.new);
    if (!measure.headerMeasured) {
      measure.header = _measureText(
        def.label,
        UtenTableHeader.textStyle(theme),
        textScaler,
      );
      measure.headerMeasured = true;
    }
    final bodyStyle = theme.textTheme.bodySmall ?? const TextStyle();
    final sampleCount = pool.length < _autoFitSampleSize
        ? pool.length
        : _autoFitSampleSize;
    // 去重集合只防重复量同一串；过大时清掉(最大宽度已记下，不影响结果)。
    if (measure.seen.length > 4000) measure.seen.clear();
    for (var r = 0; r < sampleCount; r++) {
      final text = def.value(pool[r]) ?? '';
      if (text.isEmpty || !measure.seen.add(text)) continue;
      final width = _measureText(text, bodyStyle, textScaler);
      if (width > measure.body) measure.body = width;
    }
    return measure;
  }

  /// 量宽结果 → 列宽(加内边距/图标富余，夹在上下限之间；声明宽度作下限)。
  double _fitColumnWidth(MasterColumnDef<T> def, _ColumnTextMeasure measure) {
    final text = measure.header > measure.body ? measure.header : measure.body;
    final measured =
        (text +
                _cellPadX * 2 +
                _headerIconAllowance +
                (def.sortable ? _sortIconAllowance : 0) +
                (def.info != null ? _headerInfoIconAllowance : 0) +
                // 固定列标签前的图钉（18 图标 + 4 间距）也占标签行宽度。
                (_pinnedKeys.contains(def.key) ? _pinIconAllowance : 0) +
                _autoFitBuffer)
            .clamp(_minColWidth, _maxColWidth);
    final declared = def.width.clamp(_minColWidth, _maxColWidth);
    // Rich cells may contain buttons/progress/two-line guidance whose width
    // cannot be inferred from [value]. Treat the declared width as a minimum;
    // plain text columns can still auto-grow beyond it.
    return measured < declared ? declared : measured;
  }

  /// 数据刷新后的增量量宽：挪到本帧之后执行，只量新出现的值；有列需要加宽才重建一次。
  void _scheduleWidthGrowth() {
    if (_widthGrowthScheduled) return;
    _widthGrowthScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _widthGrowthScheduled = false;
      if (!mounted || !_widthGrowthPending) return;
      _widthGrowthPending = false;
      final textScaler = MediaQuery.textScalerOf(context);
      if (_lastScale != textScaler.scale(1) ||
          _widths.length != _columns.length) {
        setState(() => _widthsDirty = true);
        return;
      }
      final pool = _widthSamplePool();
      var grown = false;
      final next = List<double>.of(_widths);
      for (var i = 0; i < _columns.length; i++) {
        if (_manualResized.contains(i)) continue;
        final def = _columns[i];
        final fitted = _fitColumnWidth(
          def,
          _measureColumn(context, def, pool, textScaler),
        );
        if (fitted > next[i] + 0.5) {
          next[i] = fitted;
          grown = true;
        }
      }
      if (grown) setState(() => _widths = next);
    });
  }

  /// 测量单行文本渲染宽度（TextPainter，maxLines:1）。测完 dispose 防泄漏。
  ///
  /// [textScaler] 必须传当前生效的字号系数（来自 MediaQuery.textScalerOf）——单元格里
  /// 的 Text 在渲染时会自动吃这个缩放，量宽若不带它就会按未放大字号量、列偏窄。
  double _measureText(String text, TextStyle style, TextScaler textScaler) {
    if (text.isEmpty) return 0;
    debugMasterTableMeasureTextCount++;
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
    widget.rowsController?.detachPagination(this);
    _projection?.remove(this);
    _aiSlot.detach();
    _platform.dispose();
    // 跟手浮层/拖拽态由 UtenColumnDragHideHost.dispose（super 链）统一卸除。
    _fsTick.dispose();
    _headerH.dispose();
    _bodyH.dispose();
    _bodyV.dispose();
    _overlayH.dispose();
    _hBarY.dispose();
    _pageCtrl.dispose();
    _pageFocus.dispose();
    _stickyPagePos?.removeListener(_onStickyPageScroll);
    _sticky?.dispose();
    super.dispose();
  }

  double get _totalWidth {
    var s = widget.selectable ? _selectionColWidth : 0.0;
    for (final i in _visibleIndices) {
      if (i < _widths.length) s += _widths[i];
    }
    return s + (widget.showColumnChooser ? 48 : 0);
  }

  /// 当前可见列在原列集合中的下标：按 [_columnOrder] 顺序、隐藏列跳过
  /// （列宽仍按原下标存 [_widths]；[initState]/列集合变化时同步重建 _columnOrder）。
  List<int> get _visibleIndices {
    final byKey = <String, int>{
      for (var i = 0; i < _columns.length; i++) _columns[i].key: i,
    };
    return [
      for (final key in _columnOrder)
        if (byKey.containsKey(key) && !_hiddenKeys.contains(key)) byKey[key]!,
    ];
  }

  /// 可见列数（至少 1：[_toggleColumn] 拦住最后一列的隐藏）。
  int get _visibleCount => _columns.length - _hiddenKeys.length;

  /// 切换单列显隐：最后一列不允许隐藏，避免表格没列；隐藏固定列时同时解除固定
  ///（固定列必须在可见序列里，「看不见的固定列」没有意义）。
  void _toggleColumn(String key) {
    setState(() {
      if (_hiddenKeys.contains(key)) {
        _hiddenKeys.remove(key);
      } else if (_visibleCount > 1) {
        _hiddenKeys.add(key);
        _pinnedKeys.remove(key);
        _pinOriginIndex.remove(key);
      }
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  /// 全选(true)=全部显示；取消全选(false)=仅留首列（表格至少保留一列）。
  /// 被隐藏的固定列一并解除固定。
  void _toggleAllColumns(bool selectAll) {
    setState(() {
      _hiddenKeys.clear();
      if (!selectAll && _columns.length > 1) {
        _hiddenKeys.addAll(_columns.skip(1).map((c) => c.key));
      }
      _pinnedKeys.removeWhere(_hiddenKeys.contains);
      _pinOriginIndex.removeWhere((k, _) => _hiddenKeys.contains(k));
    });
    _fsTick.value++;
    _persistPlatformLayout();
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
  // —— 本地取值筛选 / 本地排序的取值与显示行 ——

  Map<String, MasterColumnDef<T>> get _columnByKey => {
    for (final def in _columns) def.key: def,
  };

  /// 筛选桶取值：trim 后空串或「—」占位算空（落「其他」桶）。
  String? _facetRawValue(MasterColumnDef<T> def, T item) {
    final raw = def.value(item)?.trim();
    if (raw == null || raw.isEmpty || raw == '—') return null;
    return raw;
  }

  /// filterFromRows 列的桶：宿主提供了服务端 facets 时返回 null（以服务端为准）。
  ({List<MasterFacetBucket> buckets, int nullCount})? _rowFacetsFor(
    MasterColumnDef<T> def,
  ) {
    if (!def.filterFromRows || _serverPaged) return null;
    if ((widget.facets[def.key] ?? const []).isNotEmpty) return null;
    final counts = <String, int>{};
    var nullCount = 0;
    for (final it in _items) {
      final v = _facetRawValue(def, it);
      if (v == null) {
        nullCount++;
      } else {
        counts[v] = (counts[v] ?? 0) + 1;
      }
    }
    final values = counts.keys.toList()..sort();
    return (
      buckets: [
        for (final v in values) MasterFacetBucket(value: v, count: counts[v]!),
      ],
      nullCount: nullCount,
    );
  }

  /// 实际渲染/可勾选的行 = 宿主行 − 本地筛选命不中的行，再按本地排序整理。
  List<T> get _displayItems => _applyRowView(_items);

  List<T> _applyRowView(List<T> source) {
    var rows = source;
    if (_rowFilters.isNotEmpty) {
      final defs = _columnByKey;
      rows = rows.where((it) {
        for (final entry in _rowFilters.entries) {
          final selected = entry.value;
          if (selected == null || selected.isEmpty) continue;
          final def = defs[entry.key];
          if (def == null || !def.filterFromRows) continue;
          final raw = _facetRawValue(def, it);
          if (selected == kMasterFilterNullValue) {
            if (raw != null) return false;
          } else if (raw != selected) {
            return false;
          }
        }
        return true;
      }).toList();
    }
    final sortKey = _localSortColumn;
    if (sortKey != null && widget.onSortChange == null) {
      final def = _columnByKey[sortKey];
      if (def != null && def.sortable) {
        final numeric = _numericColumnTypes.contains(def.type);
        final weight = def.type == 'weight';
        final asc = _localSortAscending;
        int compare(T a, T b) {
          final left = def.value(a)?.trim() ?? '';
          final right = def.value(b)?.trim() ?? '';
          // 空值/「—」恒排末尾，不随升降序翻到最前；重量列的「未称」同样视为空。
          bool blank(String text) =>
              text.isEmpty ||
              text == '—' ||
              (weight && _weightSortValue(text) == null);
          final leftBlank = blank(left);
          final rightBlank = blank(right);
          if (leftBlank && rightBlank) return 0;
          if (leftBlank) return 1;
          if (rightBlank) return -1;
          int base;
          if (weight) {
            base = _weightSortValue(left)!.compareTo(_weightSortValue(right)!);
          } else if (numeric) {
            final x = double.tryParse(left.replaceAll(',', ''));
            final y = double.tryParse(right.replaceAll(',', ''));
            base = x == null || y == null
                ? left.compareTo(right)
                : x.compareTo(y);
          } else {
            base = left.compareTo(right);
          }
          return asc ? base : -base;
        }

        rows = rows.toList()..sort(compare);
      }
    }
    return rows;
  }

  /// 内联计算、勿缓存到实例字段——全屏 post-frame 间隙会读到旧值。
  Set<String> _pageSelectableIds() {
    final ids = <String>{};
    void add(T it) {
      final id = widget.idOf?.call(it);
      if (id != null && id.isNotEmpty) ids.add(id);
    }

    for (final it in _displayItems) {
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
    if (widget.onRowSelectionChanged case final onRowSelection?) {
      onRowSelection(item, checked);
      _fsTick.value++;
      return;
    }
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
          child: UtenStatusCellScope(
            enabled: utenIsStatusColumn(column.key, column.label),
            child: UtenTableCellHints(
              child: Builder(
                builder: (cellContext) => builder(cellContext, item),
              ),
            ),
          ),
        ),
      ),
    );
    final aligned = widget.selectable && !column.fillsCellHeight
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
    _publishProjection();
    // 吸顶表：每帧 post-frame 复核量位（数据/布局变化后刷新锚点）。
    if (_sticky != null) _scheduleStickyMeasure();
    // 全屏中：表格在全屏路由里渲染，正常树让位（ScrollController 只挂一棵树）。
    if (_fullscreen) {
      return const SizedBox.shrink();
    }
    // 嵌入模式（详情页明细表）：无界高度场景按内容收缩。
    // 吸顶表（stickyHeaderPinned）外包滚轮截停门：一格越置顶点即止 + 停顿窗吞
    // 同一滚势的后续格 + 短表够不着顶时按需撑高（见 UtenStickyWheelGate）。
    if (widget.embedded) {
      final embeddedColumn = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildTable(context),
          if (widget.summaryBar != null && !widget.summaryBarInline)
            _buildSummaryBar(context),
          if (widget.totalPages > 1) _buildPager(context),
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
      final sticky = _sticky;
      if (sticky == null) return embeddedColumn;
      return UtenStickyWheelGate(
        tracker: sticky,
        onEngage: _onStickyEngage,
        child: embeddedColumn,
      );
    }
    return Column(
      children: [
        Expanded(child: _buildTableStage(context)),
        // 合计条在表体（内部滚动）之外、翻页条之上：滚到哪一行它都在。
        // summaryBarInline 时改为表内脚注（见 _buildTable 的 ListView 末项），
        // 不在这里钉住。
        if (widget.summaryBar != null && !widget.summaryBarInline)
          _buildSummaryBar(context),
        if (widget.totalPages > 1) _buildPager(context),
      ],
    );
  }

  /// 表体舞台：横滚区 + 竖向 ListView(+ 表内合计条)。
  ///
  /// 由 [_buildTable] 里表体区的 LayoutBuilder 调用，但**只在宽度变化或宿主重建时**
  /// 调用一次；高度只变时 LayoutBuilder 原样交回上一次的实例(见那里的注释)。
  /// 因此这里不能读任何高度值：ListView 的高度全靠约束传下来。
  Widget _buildBodyStage(
    BuildContext context,
    ThemeData theme,
    List<({bool header, MasterDataGroup<T>? group, T? item})> plan,
    double total,
    double viewportWidth,
  ) {
    // 合计条随表体滚动（summaryBarInline）：作为竖向滚动内容的
    // 最后一项（数据行与「加载更多」指示器之后），行少时紧跟末行。
    final summaryInline = widget.summaryBarInline && widget.summaryBar != null;
    final hasFooter = _loadingMore || (!_prepending && _appendError != null);
    final summaryIndex = plan.length + (hasFooter ? 1 : 0);
    Object planId(int index) {
      final row = plan[index];
      return row.header
          ? ('group', row.group!.id)
          : ('data', _paginationRowId(row.item as T));
    }

    final indexes = _automaticPagination
        ? {
            for (var i = 0; i < plan.length; i++)
              ValueKey(('pagination-row', planId(i))): i,
          }
        : null;
    final list = ListView.builder(
      controller: _usesPrimaryScroll ? null : _bodyV,
      // primary 模式：交还给祖先 NestedScrollView 注入的 PrimaryScrollController
      // 参与联动。shrinkWrap 必须关（否则短表 maxScrollExtent=0，header 收完后
      // 滚动卡死）；physics 必须 AlwaysScrollable（行少时 body 也要能滚→header 才收）。
      primary: _usesPrimaryScroll,
      shrinkWrap:
          widget.primary ||
              widget.virtualized ||
              (_automaticPagination && !widget.embedded)
          ? false
          : true,
      physics: _prependAnchor.wrap(
        widget.primary
            ? const AlwaysScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
      ),
      findChildIndexCallback: indexes == null ? null : (key) => indexes[key],
      // 留白只参与竖向滚动范围，覆盖层横滚条始终以真实末行为锚点。
      padding: EdgeInsets.only(bottom: _bodyBottomPad + _prependBottomSpace),
      itemCount: summaryIndex + (summaryInline ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (summaryInline && i == summaryIndex) {
          return _rowSelectionArea(
            _ViewportPinnedRow(
              controller: _bodyH,
              contentWidth: total,
              fallbackViewportWidth: viewportWidth,
              child: Padding(
                padding: const EdgeInsets.only(
                  top: UtenSpacing.s8,
                  left: UtenSpacing.s4,
                  right: UtenSpacing.s4,
                ),
                child: widget.summaryBar!,
              ),
            ),
          );
        }
        if (!_prepending && _appendError != null && i == plan.length) {
          return _ViewportPinnedRow(
            controller: _bodyH,
            contentWidth: total,
            fallbackViewportWidth: viewportWidth,
            child: _appendFailure(),
          );
        }
        if (_loadingMore && i == plan.length) {
          return const Padding(
            padding: EdgeInsets.all(UtenSpacing.s12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final row = plan[i];
        if (row.header) {
          return _trackPaginationRow(
            planId(i),
            false,
            _rowSelectionArea(_buildGroupHeader(theme, row.group!)),
          );
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
        final idKey = widget.rowKeyOf?.call(item) ?? widget.idOf?.call(item);
        final rowWidget = RepaintBoundary(
          key:
              widget.rowWidgetKeyOf?.call(item) ??
              ((idKey != null && idKey.isNotEmpty)
                  ? ValueKey('row:$idKey')
                  : ValueKey('idx:$i')),
          child: _rowSelectionArea(_buildDataRow(theme, item)),
        );
        // 末行挂测量键：覆盖层横滚条按末行定位（贴末行下）。
        // 内容超高时末行被虚拟化不挂载 → 横滚条钉表体区底。
        final wrapped = i == plan.length - 1
            ? KeyedSubtree(key: _lastRowKey, child: rowWidget)
            : rowWidget;
        return _trackPaginationRow(
          planId(i),
          row.group == null &&
              !widget.unpagedItems.any(
                (local) => _paginationRowId(local) == _paginationRowId(item),
              ),
          wrapped,
        );
      },
    );
    final hArea = SingleChildScrollView(
      key: _bodyHorizontalKey,
      controller: _bodyH,
      scrollDirection: Axis.horizontal,
      // 高度只经约束传给 ListView 视口(SingleChildScrollView 横滚只放开
      // 宽度, 高度约束原样透传), 子树里不出现任何高度值——这是下面
      // 「高度只变时复用同一实例」成立的前提。
      child: SizedBox(
        width: total,
        child: _measurePrepend(list, (row) => _buildDataRow(theme, row)),
      ),
    );
    // 普通无悬浮留白表使用流内横滚条；联动/悬浮表使用独立覆盖层，
    // 避免 ListView 底部留白把横滚条推离末行。
    final hWrapped = _usesOverlayHBar
        ? hArea
        : Scrollbar(controller: _bodyH, thumbVisibility: true, child: hArea);
    // 竖向滚动条（上下）已改为表体 Stack 上的覆盖层
    // （见 body Stack children），此处只产出表体本体。
    //
    // 2026-09-22 根治「竖条长度乱跳/越滚越长」：旧 Scrollbar 无
    // controller 时框架对任何通过谓词的通知都重画 thumb（SDK
    // _shouldUpdatePainter：controller 为 null 恒 true，不做轴向过滤），
    // 表体横向 SV（depth 0）的横轴通知会把竖向 thumb 按横向 metrics 重画。
    // 改用自绘 UtenContentScrollbar（controller 驱动，轴向恒对）。
    //
    // 2026-09-14 滚动条口径（全站统一）：在 UtenCollapsingHeaderScrollView
    // 内的表格，外层收头部阶段（表格未置顶）不显示竖向滚动条，进入表体
    // 内滚后再显示。独立表格查不到 scope，维持常显。
    return hWrapped;
  }

  /// 合计条容器：与表体同宽、左右对齐表格内容边距。
  /// 只在这一处定义间距，所有接入页的合计条位置与留白因此完全一致。
  Widget _buildSummaryBar(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
    child: widget.summaryBar,
  );

  bool get _hasFloatingBatchActions =>
      widget.selectable && widget.batchActionsBuilder != null;

  bool get _usesOverlayHBar =>
      widget.primary ||
      _hasFloatingBatchActions ||
      widget.bottomContentPadding > 0;

  /// 自动加载触发距底阈值（约 4~5 行高）：滚到末尾前预取下一页，体感「到底即有」。
  static const double _loadMoreEdge = 200;

  /// 竖向滚动临近底部时触发 [MasterDataTableView.onLoadMore]。
  /// loadingMore 为 true 期间不重复触发；更多页判断在调用方（见参数文档）。
  void _maybeTriggerLoadMore(ScrollMetrics metrics) {
    if (widget.onLoadMore == null || widget.loadingMore) return;
    if (metrics.extentAfter < _loadMoreEdge) widget.onLoadMore!();
  }

  void _onPaginationWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.scrollDelta.dy == 0 ||
        event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
      return;
    }
    final axisModifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    if (HardwareKeyboard.instance.logicalKeysPressed.any(
      axisModifiers.contains,
    )) {
      return;
    }
    final controller = _verticalScrollController;
    if (controller == null || !controller.hasClients) return;
    _scheduleVisiblePage();
    // At a clamped edge Flutter may emit no ScrollNotification at all. Observe
    // the wheel without claiming it from the normal scroll/zoom machinery.
    final prepend = event.scrollDelta.dy < 0;
    if (controller.positions.any(
      (p) => (prepend ? p.extentBefore : p.extentAfter) <= 0.5,
    )) {
      _scheduleAppend(prepend: prepend);
    }
  }

  /// 表格批量动作与采购任务工作台一致：选择摘要仍在表头上方，真正业务动作
  /// 悬浮在右下角。动作层属于表格自身，因此普通视图和全屏路由使用同一实现。
  Widget _buildTableStage(BuildContext context) {
    return Listener(
      onPointerSignal: _onPaginationWheel,
      behavior: HitTestBehavior.translucent,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.vertical) {
            _scheduleHBarUpdate();
            _scheduleVisiblePage();
          }
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.axis == Axis.vertical) {
              _scheduleHBarUpdate();
              _maybeTriggerLoadMore(notification.metrics);
              if (notification is ScrollUpdateNotification ||
                  notification is OverscrollNotification ||
                  notification is ScrollEndNotification) {
                _scheduleVisiblePage();
              }
              final forward =
                  notification is ScrollUpdateNotification &&
                      notification.dragDetails != null &&
                      (notification.scrollDelta ?? 0) > 0 ||
                  notification is OverscrollNotification &&
                      notification.overscroll > 0;
              if (forward && notification.metrics.extentAfter <= 0.5) {
                _scheduleAppend();
              }
              final backward =
                  notification is ScrollUpdateNotification &&
                      notification.dragDetails != null &&
                      (notification.scrollDelta ?? 0) < 0 ||
                  notification is OverscrollNotification &&
                      notification.overscroll < 0;
              if (backward && notification.metrics.extentBefore <= 0.5) {
                _scheduleAppend(prepend: true);
              }
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
      ),
    );
  }

  /// 空态/错误/加载占位壳。
  /// primary（联动折叠）模式下包一层拾取 PrimaryScrollController 的竖向 ListView：
  /// 空表/错误区域仍可上滑收起外层 header（页面任意位置触发滚动），
  /// 矮视口下占位内容可滚不溢出；非 primary 保持原 Center 语义不变。
  Widget _stateShell(Widget child) {
    if (_scrollingHeader != null) {
      return ListView(
        controller: _usesPrimaryScroll ? null : _bodyV,
        primary: _usesPrimaryScroll,
        shrinkWrap: !widget.primary,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _scrollingHeader!,
          Padding(padding: const EdgeInsets.all(UtenSpacing.s16), child: child),
        ],
      );
    }
    if (!_usesPrimaryScroll) {
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

  /// 当前有值的表头筛选列（含「筛空值」哨兵；含 filterFromRows 列的本地筛选）。
  List<String> get _activeFilterKeys => [
    for (final entry in widget.filters.entries)
      if (entry.value != null && entry.value!.isNotEmpty) entry.key,
    for (final entry in _rowFilters.entries)
      if (entry.value != null && entry.value!.isNotEmpty) entry.key,
  ];

  /// 空态「当前有 N 个表头筛选生效」描述真正计入的列 = 有值 − 宿主自管的列。
  ///
  /// 2026-09-28 用户口径：空态「清除筛选」按钮全站退役（分类分段条就在表上方，
  /// 按钮是重复入口）；此 getter 只剩筛选生效数描述一个用途。
  List<String> get _clearableFilterKeys => [
    for (final key in _activeFilterKeys)
      if (!widget.externalFilterKeys.contains(key)) key,
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

  /// 成功空态仍保留调用方业务工具条(例如 BOM 的“添加组件”)；表头不渲染时
  /// 不提供“添加列”。加载中/错误态不走本壳，避免基础数据尚未确认时开放写动作。
  Widget _emptyStateWithToolbarActions(Widget child) {
    final actions = <Widget>[
      if (_platform.error != null)
        PlatformTableStatus(error: _platform.error, retry: _platform.reload),
      // 空表不给「进全屏」：一张没有行的表放大到整屏毫无意义，用户反而会以为
      // 数据被按钮挡住了（2026-09-11 销售订单财务确认「待确认」空态反馈）。
      // 已在全屏中时保留按钮——那是唯一的退出口。
      if (_fullscreen) _fullscreenToggleButton(),
      // 空态「清除筛选」按钮已退役（2026-09-28 用户口径：分类分段条等筛选入口
      // 常驻表外，按钮是重复入口；空态仅保留「当前有 N 个表头筛选生效」描述）。
      if (widget.selectable &&
          widget.showSelectionSummary &&
          !_hasFloatingBatchActions)
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
    if (_scrollingHeader != null) {
      return _stateShell(
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [toolbar, child],
        ),
      );
    }
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
      controller: _usesPrimaryScroll ? null : _bodyV,
      primary: _usesPrimaryScroll,
      physics: widget.primary
          ? const AlwaysScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(child: toolbar),
        SliverFillRemaining(hasScrollBody: false, child: Center(child: child)),
      ],
    );
  }

  /// compact 卡片形态表体：行交互与表格同语义（勾选=多选、点卡=打开、
  /// 长按/右击=行菜单且弹前选中、动作完成清理选中），见 _Card。
  Widget _buildCompactCards(BuildContext context) {
    final visibleColumns = [for (final i in _visibleIndices) _columns[i]];
    return MasterDataCardList<T>(
      columns: visibleColumns,
      header: _scrollingHeader,
      items: _displayItems,
      primary: _usesPrimaryScroll,
      loadingMore: _loadingMore,
      footer: _prepending || _appendError == null ? null : _appendFailure(),
      overlay: _prependFeedback,
      physics: _prependAnchor.wrap(
        widget.primary
            ? const AlwaysScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
      ),
      itemKey: (row) =>
          ValueKey(('pagination-row', ('data', _paginationRowId(row)))),
      rowDecorator: (row, child) => _trackPaginationRow(
        ('data', _paginationRowId(row)),
        !widget.unpagedItems.any(
          (local) => _paginationRowId(local) == _paginationRowId(row),
        ),
        child,
      ),
      layoutWrapper: (child, buildRow) => _measurePrepend(
        child,
        (row) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
          child: buildRow(row),
        ),
      ),
      controller: _usesPrimaryScroll ? null : _bodyV,
      bottomPadding:
          math.max(UtenSpacing.s8, widget.bottomContentPadding) +
          _prependBottomSpace,
      isSelected: (item) {
        if (widget.selectable) {
          final id = widget.idOf?.call(item);
          return id != null && id.isNotEmpty && widget.selectedIds.contains(id);
        }
        return widget.isSelected?.call(item) ?? identical(item, _selectedItem);
      },
      canSelect: (item) {
        final id = widget.idOf?.call(item);
        return id != null && id.isNotEmpty;
      },
      onCheckboxChanged: widget.selectable ? _toggleRow : null,
      onOpen: (item) {
        if (!(widget.canOpenRow?.call(item) ?? true)) return;
        widget.onRowTap?.call(item);
      },
      rowMenuBuilder: widget.rowMenuBuilder == null
          ? null
          : (item) => (widget.canShowRowMenu?.call(item) ?? true)
                ? widget.rowMenuBuilder!(item)
                : const <UtenContextMenuEntry>[],
      onMenuOpening: (item) {
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
      },
      onActionCompleted: () async {
        // 菜单动作完成后清理上下文选中（与表格行 clearSelectionAfterMenuAction
        // 同语义；仅取消菜单时保留原选择）。
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
      },
    );
  }

  Widget _buildTable(BuildContext context) {
    _scheduleScrollToEnd();
    final table = TableColumnProjectionTarget(
      tableKey: _platform.tableKey,
      owner: this,
      child: _buildProjectedTable(context),
    );
    if (widget.backgroundMenuBuilder == null) return table;
    return UtenContextMenuRegion(
      behavior: HitTestBehavior.opaque,
      entriesBuilder: () => widget.isLoading || widget.error != null
          ? const <UtenContextMenuEntry>[]
          : widget.backgroundMenuBuilder!(),
      child: table,
    );
  }

  Widget _buildPickerList(BuildContext context, List<T> rows) {
    final padding = widget.listPadding.resolve(Directionality.of(context));
    Widget row(T item, int index, {required bool separator}) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.listItemBuilder!(context, item),
        if (separator && widget.listSeparatorBuilder != null)
          widget.listSeparatorBuilder!(context, index),
      ],
    );
    final indexes = {
      for (var i = 0; i < rows.length; i++)
        ValueKey(('pagination-row', ('data', _paginationRowId(rows[i])))): i,
    };
    final proposed = _appendPage != null && _prependPageItems != null
        ? _applyRowView(
            _collectRows(_withPage(_appendPage!, _prependPageItems!)),
          )
        : rows;
    final separatorIndexes = {
      for (var i = 0; i < proposed.length; i++)
        _paginationRowId(proposed[i]): i,
    };
    final hasFooter = _loadingMore || (!_prepending && _appendError != null);
    final list = ListView.builder(
      controller: _bodyV,
      primary: false,
      physics: _prependAnchor.wrap(const ClampingScrollPhysics()),
      padding: padding.copyWith(bottom: padding.bottom + _prependBottomSpace),
      itemCount: rows.length + (hasFooter ? 1 : 0),
      findChildIndexCallback: (key) => indexes[key],
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return _appendError != null
              ? _appendFailure()
              : const Padding(
                  padding: EdgeInsets.all(UtenSpacing.s12),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
        }
        final item = rows[index];
        return _trackPaginationRow(
          ('data', _paginationRowId(item)),
          true,
          row(item, index, separator: index < rows.length - 1),
        );
      },
    );
    return Stack(
      children: [
        _measurePrepend(
          list,
          (item) => Padding(
            padding: EdgeInsets.only(left: padding.left, right: padding.right),
            child: row(
              item,
              separatorIndexes[_paginationRowId(item)] ?? 0,
              separator: true,
            ),
          ),
        ),
        if (_prependFeedback case final feedback?)
          Positioned(left: 0, right: 0, top: 0, child: feedback),
      ],
    );
  }

  Widget _buildProjectedTable(BuildContext context) {
    _projectionOwner = ModalRoute.of(context);
    _publishProjection();
    final theme = Theme.of(context);
    // 嵌入场景（滑窗/picker/弹窗内明细表）默认不显示全屏按钮：整屏路由在受限容器里会铺满
    // 屏幕（详细排产滑窗 bug）。显式 showFullscreenToggle 可覆盖。
    final showFullscreen = widget.showFullscreenToggle ?? !widget.embedded;
    if (widget.isLoading && _items.isEmpty) {
      return _stateShell(const CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (widget.error != null &&
        _appendError == null &&
        widget.unpagedItems.isEmpty) {
      return _stateShell(
        UtenEmpty.error(
          key: widget.errorKey,
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
    // 本地取值筛选把行全部滤空时同样走空态（描述行会报筛选生效数，可一键清除）。
    final displayItems = _displayItems;
    if (displayItems.isEmpty && !hasGroupRows) {
      final activeFilters = _clearableFilterKeys.length;
      return _emptyStateWithToolbarActions(
        UtenEmpty(
          icon: Icons.table_rows_outlined,
          message: widget.emptyMessage,
          // 空态说明补一行筛选生效数，提示表格为何为空（清除入口在表外分段条/
          // 重新出现行后的列头筛选控件）。
          description: activeFilters > 0
              ? '当前有 $activeFilters 个表头筛选生效' // TODO(l10n): 补 arb
              : null,
        ),
      );
    }
    if (widget.listItemBuilder != null) {
      return _buildPickerList(context, displayItems);
    }
    // 卡片只呈现主列表，不能让仍可展开/重试的分组落成没有表体的工具条。
    final useCompactCards = widget.compactCards && !hasGroupRows;
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
    for (final it in displayItems) {
      plan.add((header: false, group: null, item: it));
    }
    // stretch：列总宽 < 视口宽时（颜色/单位等列少主档）表头与表体撑满视口宽、
    // 内容靠左，而非整体水平居中（Column 默认 crossAxisAlignment.center 会把窄于
    // 视口的表格居中、左右留白）。仅作用于交叉轴（横向），不影响主轴 Flexible(loose)
    // 的「行少收缩、横滚条贴末行」行为。
    //
    // 表头上方工具条：左侧「表头设置」列显隐选择 + 追加按钮（预览打印/下载
    // 表格等）左对齐；右侧为调用方动作区（刷新等——全站口径：刷新按钮放
    // 表格右上角）。宽度足够时动作区固定贴右；窄屏回退整条 Wrap 流式换行
    //（动作不收缩，Row 会在窄约束溢出，故按可用宽度分流）。
    // 2026-09-25 用户口径：工具条与上方分区栏、下方表格的垂直间距对称
    //（此前只有 bottom 4、top 0，看着贴住上沿）。
    final Widget toolbar = Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final toolbarChildren = [
            if (widget.showColumnChooser &&
                useCompactCards &&
                constraints.maxWidth <
                    (widget.cardBelowWidth ?? UtenBreakpoints.mediumStart))
              _platformAddButton(),
            if (_platform.error != null)
              PlatformTableStatus(
                error: _platform.error,
                retry: _platform.reload,
              ),
            if (widget.showColumnChooser)
              UtenColumnChooserButton(
                entries: [
                  for (final c in _columns)
                    UtenColumnChooserEntry(key: c.key, label: c.label),
                ],
                hiddenKeys: _hiddenKeys,
                onToggle: _toggleColumn,
                onToggleAll: _toggleAllColumns,
                order: _columnOrder,
                onReorder: (oldIndex, newIndex) =>
                    _reorderColumnByKeys(oldIndex, newIndex),
                onReset: _resetPlatformLayout,
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
    );
    Widget buildStandardTable() {
      // 表头：横向跟随表体同步（无可见滚动条），竖向固定（sticky）。
      // 表头整体 SelectionContainer.disabled：表头有「拖拽换位/移除列」「拖拽调宽」
      // 手势，与文字拖选打架（准则 §3.4：表头不进选择区）；disabled 同时挡住外层
      // 页面级 SelectionArea（UtenContentContainer）渗入，保证手势稳定。
      // 吸顶表（stickyHeaderPinned）：表头行+分隔线进覆盖层（顶到视口上沿后钉住、
      // 表尾推到时随表尾离开），流内留同高占位——组装见下方 children 的 Stack 分支。
      final Widget headerRow = SelectionContainer.disabled(
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: SingleChildScrollView(
            controller: _headerH,
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: total, child: _buildHeaderRow(theme)),
          ),
        ),
      );
      final Widget headerDivider = Divider(
        height: 1,
        thickness: 1,
        color: theme.colorScheme.outlineVariant,
      );
      // 表体：竖向按内容收缩（行少→横滚条贴最后一行），顶到 LayoutBuilder 上限则竖向滚动（行多→横滚条钉视口底）。
      // 用 Flexible(loose) 而非 Expanded，让 ListView(shrinkWrap) 在行少时真正收缩；
      // ConstrainedBox(maxHeight) 把高度封顶在可用空间，行多时转为可滚。
      // embedded（详情页 ListView 等无界高度场景）不能用 Flexible：flex 在无界约束下
      // 会直接抛 "non-zero flex but incoming height constraints are unbounded"。
      // primary（联动折叠）例外：表体竖向填满联动区（折叠手势全域有效），流内横滚条
      // 会沉到区底 → 横滚条改走覆盖层（下方 Stack），按内容高度定位。
      // 表体舞台缓存(见下方 LayoutBuilder 内注释)：本次 build 的局部变量，键 = 区宽。
      Widget? bodyStage;
      double? bodyStageWidth;
      final Widget tableBody = _BodyFlex(
        embedded: widget.embedded,
        primary: _usesPrimaryScroll,
        virtualized: widget.virtualized,
        child: _maybeSelectionArea(
          Stack(
            key: _bodyAreaKey,
            children: [
              LayoutBuilder(
                builder: (context, c) {
                  // 区高随卡片折叠/展开变化（constraints 变化）→ 重测横滚条位置。
                  if (_usesOverlayHBar) {
                    _scheduleHBarUpdate();
                  }
                  // 只按宽度重建（2026-09-22 根治「表格一步步往置顶移动时一卡一卡」）：
                  // 联动折叠(NestedScrollView)收/放头部时本区**每格滚轮都在变高**，
                  // LayoutBuilder 每次都再跑一遍 builder——原来整棵表体子树跟着重建，
                  // 一格滚轮 25-31 个可见单元格从头建一遍再布局(探针数据)，而表内滚动
                  // 高度不变、只动偏移，所以「表内滚还好、往上移就卡」。表体子树里不含
                  // 任何高度值(高度只经约束传给 ListView 视口)，高度只变时原样交回
                  // 同一 widget 实例：框架看到同一实例直接跳过重建，只做一次布局，
                  // 且 ListView 里已布局过的行按原约束缓存、不再动。宽度变了(拖窗 /
                  // 折叠侧栏 / 换列)或宿主重建(bodyStage 是本次 build 的局部变量，
                  // 每次 build 天然作废)才真正重建。
                  if (bodyStage != null && bodyStageWidth == c.maxWidth) {
                    return bodyStage!;
                  }
                  bodyStageWidth = c.maxWidth;
                  return bodyStage = _buildBodyStage(
                    context,
                    theme,
                    plan,
                    total,
                    c.maxWidth,
                  );
                },
              ),
              // 竖向内容滚动条（自绘）：thumb 活动带与长度剔除底部让位空白
              // （悬浮批量动作 clearance / bottomContentPadding），滚到底时 thumb
              // 下缘贴内容底而非视口底；可拖、hover 高亮。联动表经
              // UtenInnerScrollActiveScope 门控（外滚收头部阶段隐藏）。
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: 14,
                child: _buildVerticalScrollbar(),
              ),
              if (_prependFeedback case final feedback?)
                Positioned(left: 0, right: 14, top: 0, child: feedback),
              // 横滚条覆盖层：按内容高度定位（[_hBarY] 为底边 local top）。
              // 内容少 → 贴末行下方（约 1px 空隙）；超高 → 钉表体区底。与 _bodyH 双向同步，
              // 表头经既有 _sync 跟随，底部额外留白不参与定位。
              if (_usesOverlayHBar)
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
      );
      // —— 表头/表体组装 ——
      // 吸顶表（stickyHeaderPinned，详情页滚动流内的 embedded 明细表）：表头行+分隔线
      // 顶到视口上沿后钉住（覆盖层），数据行从其下方滚过；表尾推到时随表尾离开
      // （pushed sticky）。流内留同高占位（[_pinnedUnitHeight]，post-frame 实测修正），
      // 整表总高与非吸顶形态一致。普通表原样流内渲染，零结构变化。
      final sticky = _sticky;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toolbar,
          if (sticky == null) ...[
            headerRow,
            headerDivider,
            tableBody,
          ] else
            Stack(
              key: _stickyStackKey,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: _pinnedUnitHeight),
                    tableBody,
                    // 短表置顶垫高（[_stickyTrailingSpace]）：垫在表体**下方**——
                    // 表头吸顶后表后内容紧跟末行上移，空白最小化且只落页面尾部
                    // （在滚轮门覆盖区内，对着表格下方空白滚向置顶依旧截停）。
                    if (_stickyTrailingSpace > 0)
                      SizedBox(height: _stickyTrailingSpace),
                  ],
                ),
                ValueListenableBuilder<double>(
                  valueListenable: sticky.headerY,
                  builder: (context, y, child) =>
                      Positioned(left: 0, right: 0, top: y, child: child!),
                  child: KeyedSubtree(
                    key: _stickyHeaderKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [headerRow, headerDivider],
                    ),
                  ),
                ),
              ],
            ),
        ],
      );
    }

    // compact 卡片形态（2026-09-29「大小屏共用一张表」）：按**表格可用宽度**
    // 判定（与各页旧 LayoutBuilder 口径一致，而非屏幕宽度——分栏/容器内宽 ≠
    // 屏宽），低于阈值表体换卡片列表；工具条/空态/错误/加载/翻页/合计条壳
    // 不变，列定义同一份（cardRole 分派）。
    if (useCompactCards) {
      final threshold = widget.cardBelowWidth ?? UtenBreakpoints.mediumStart;
      return LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < threshold
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  toolbar,
                  if (constraints.hasBoundedHeight)
                    Expanded(
                      child: _maybeSelectionArea(_buildCompactCards(context)),
                    )
                  else
                    _maybeSelectionArea(_buildCompactCards(context)),
                ],
              )
            : buildStandardTable(),
      );
    }
    return buildStandardTable();
  }

  /// 表体选择区保持稳定，切分类时不撤掉 ListView 的 SelectionRegistrar。
  /// SDK 的行保活节点在祖先 registrar 变 null 后仍可能收到旧文本的 remove，
  /// 此时内部强制解引用会崩溃。禁用文字选择必须放在行保活节点下面。
  Widget _maybeSelectionArea(Widget child) => SelectionArea(
    // 2026-09-15 用户口径：表格自带右键行菜单时，只显示自家菜单。右键点到
    // 可选文字上 SelectionArea 会弹框架默认「全选/复制」工具条与行菜单撞车
    //（文字拖选/键盘复制不受影响，只静音右键工具条）。
    contextMenuBuilder: widget.rowMenuBuilder == null
        ? null
        : (_, _) => const SizedBox.shrink(),
    child: child,
  );

  /// 多选和显式退出文字选择时，只隔离行内容，不改变 ListView 自动创建的
  /// SelectionKeepAlive 的祖先 registrar；普通浏览仍可拖选和复制文本。
  Widget _rowSelectionArea(Widget child) =>
      widget.selectable || !widget.enableTextSelection
      ? SelectionContainer.disabled(child: child)
      : child;

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
    // 动作列表可能运行态为空（如物料分析 FQC 补料视图没有可下单按钮）：
    // 表格自管已选胶囊（showSelectionSummary=true）时悬浮组保留胶囊单独成组，
    // 不随空动作一起消失——否则胶囊被 builder 非空压制在表头之外又无处渲染，
    // 选择数整页不见（2026-10-04 用户口径：已选恒右下悬浮）。页面自摆胶囊
    //（showSelectionSummary=false）时整组隐藏，避免同一选择数出现两枚。
    if (actions.isEmpty && !widget.showSelectionSummary) {
      return const SizedBox.shrink();
    }

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
    final row = _buildHeaderRowBody(theme);
    return !widget.showColumnChooser
        ? row
        : UtenFrozenTrailingColumn(
            horizontal: _headerH,
            width: 48,
            // 左线隔开滚过的列头（与行内形态靠末列右线分隔等价），右线收表格
            // 右缘（2026-10-04 用户口径「最后操作列右边没竖杠」）。
            cell: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                border: Border(
                  left: BorderSide(color: theme.colorScheme.outline),
                  right: BorderSide(color: theme.colorScheme.outline),
                ),
              ),
              child: _platformAddButton(),
            ),
            row: row,
          );
  }

  Widget _buildHeaderRowBody(ThemeData theme) {
    // 多选表头三态全选格（合成单元格）：false=本页全未选 / true=全选 / 空=部分。
    // 横滚时钉在视口左缘（[UtenFrozenLeadingColumn]），行内留等宽占位保持列对齐。
    final headerSelectionCell = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(right: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Center(
        child: Checkbox(
          key: const Key('master-data-table-select-all'),
          tristate: true,
          value: _headerCheckValue,
          onChanged: _pageSelectableIds().isEmpty ? null : _onToggleAllPage,
        ),
      ),
    );
    final pinnedIndices = _pinnedVisibleIndices;
    // 横滚时钉在视口左缘的冻结区副本：多选框 + 已固定列的表头格。
    // 副本格不挂换位/移除拖拽（避免同一 LayerLink 双挂载），但保留筛选点按、
    // 右键菜单与列宽手柄——滚动态下固定列的全部日常操作都还在线。
    // **必须自带不透明底**：正常表头的底色来自外层 Material（surfaceContainerHigh），
    // 副本浮在滚动的列表头之上，不带底色会把底下列头透出来（2026-09-25 用户反馈）。
    final frozenHeaderRegion = ColoredBox(
      color: theme.colorScheme.surfaceContainerHigh,
      child: _boundStretchRow(
        Row(
          crossAxisAlignment: _selectableCross,
          children: [
            if (widget.selectable)
              SizedBox(width: _selectionColWidth, child: headerSelectionCell),
            for (final i in pinnedIndices)
              _headerColumnCell(theme, i, frozen: true),
          ],
        ),
      ),
    );
    return _boundStretchRow(
      // 换位拖动中在表头行上渲染插入位指示线（前导选择列让位）。
      columnHeaderIndicatorOverlay(
        leadingInset: widget.selectable ? _selectionColWidth : 0,
        child: _withFrozenLeadingRegion(
          controller: _headerH,
          width: _pinnedLeadingWidth(pinnedIndices),
          cell: frozenHeaderRegion,
          row: Row(
            crossAxisAlignment: _selectableCross,
            children: [
              if (widget.selectable)
                SizedBox(width: _selectionColWidth, child: headerSelectionCell),
              for (final i in _visibleIndices)
                _headerColumnCell(theme, i, frozen: false),
              if (widget.showColumnChooser)
                SizedBox(
                  width: 48,
                  height: 48,
                  // 尾部 48px 列设置格补右线：末列右线之后这一格原先不描边，
                  // 表头右缘没封口（与数据行行级右线同位收口）。
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        right: BorderSide(color: theme.colorScheme.outline),
                      ),
                    ),
                    child: _platformAddButton(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 行首冻结区（多选框列 + 已固定列）的通用包裹：宽度为 0（既无多选也无固定列）
  /// 时原样返回，非多选无固定列的表零开销、行为与从前一致。
  Widget _withFrozenLeadingRegion({
    required ScrollController controller,
    required double width,
    required Widget cell,
    required Widget row,
  }) {
    if (width <= 0) return row;
    return UtenFrozenLeadingColumn(
      horizontal: controller,
      width: width,
      cell: cell,
      row: row,
    );
  }

  /// 单个表头列格：列宽 + 竖线 + 内容 + 列宽手柄。
  ///
  /// [frozen]=true 时构建的是「钉在视口左缘的冻结副本」格：内容不带换位/移除
  /// 拖拽手势（kit 的 LayerLink 每 State 只挂一个 target，双挂载会让跟手浮层
  /// 锚定错乱），但保留筛选点按、右键菜单（固定/移动/隐藏）与列宽手柄。
  /// 已固定的列表头标签前显图钉（18px、与标签行垂直居中，2026-09-25 用户口径
  /// 「icon 大一点、上下居中」——旧版 12px 右上角小角标太小）。
  Widget _headerColumnCell(ThemeData theme, int i, {required bool frozen}) {
    final pinned = _pinnedKeys.contains(_columns[i].key);
    // filterFromRows 列：桶由当前行就地构建、值与回调走组件内部状态；
    // 否则维持宿主 facets/filters/onFilterChanged 的服务端链路。
    final rowFacets = _rowFacetsFor(_columns[i]);
    // 宿主接了 onSortChange → 排序走服务端（sortActive 以宿主状态为准）；
    // 没接（全量加载表）→ sortable 列就地排序，取消排序传 null 列。
    final serverSort = widget.onSortChange != null;
    final sortKey = _columns[i].key;
    final localSortActive = !serverSort && _localSortColumn == sortKey;
    final filterCell = _FilterCell(
      label: _columns[i].label,
      sortKey: sortKey,
      type: _columns[i].type,
      sortable: _columns[i].sortable,
      sortActive: serverSort ? widget.sortColumn == sortKey : localSortActive,
      sortAscending: serverSort
          ? widget.sortAscending
          : (localSortActive ? _localSortAscending : true),
      onSort: serverSort
          ? (column, ascending) {
              _persistQuery(
                sort: column,
                ascending: ascending,
                sortChanged: true,
              );
              widget.onSortChange!(column, ascending);
            }
          : (column, ascending) => setState(() {
              _localSortColumn = column;
              _localSortAscending = column == null ? true : ascending;
              _persistQuery(
                sort: column,
                ascending: ascending,
                sortChanged: true,
              );
            }),
      info: _serverPaged && !serverSort && _columns[i].sortable
          ? [
              if (_columns[i].info != null) _columns[i].info!,
              '排序仅影响当前已加载的数据；继续加载或更改查询会改变此范围。',
            ].join('\n')
          : _columns[i].info,
      leading: pinned
          ? Icon(
              Icons.push_pin_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            )
          : null,
      buckets: rowFacets?.buckets ?? widget.facets[_columns[i].key] ?? const [],
      nullCount:
          rowFacets?.nullCount ?? widget.nullCounts[_columns[i].key] ?? 0,
      selected: rowFacets != null
          ? _rowFilters[_columns[i].key]
          : widget.filters[_columns[i].key],
      onChanged: rowFacets != null
          ? (v) => setState(() {
              _rowFilters[_columns[i].key] = v;
              _persistQuery();
            })
          : (v) {
              _persistQuery(filterKey: _columns[i].key, filterValue: v);
              widget.onFilterChanged(_columns[i].key, v);
            },
    );
    // 右键菜单挂在内容外层：桌面右击弹「固定/移动/隐藏」菜单（表头专用 region：
    // 不挂长按——触屏长按/按下即拖已让给列换位/移除手势；并压制系统右键
    // 「全选/复制」工具条，此前右击表头弹的就是那个）。
    final Widget content = UtenColumnHeaderMenuRegion(
      entriesBuilder: () => _headerMenuEntries(i),
      child: frozen
          ? filterCell
          : _buildDraggableHeaderCell(theme, i, filterCell),
    );
    return Container(
      width: _widths[i],
      // 表头竖线分隔（与 UtenEditableGrid 表头一致：outline/width1）。
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Stack(
        children: [
          content,
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
              onHorizontalDragUpdate: (d) => _resizeColumn(i, d.delta.dx),
              child: const MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
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
    _persistPlatformLayout();
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
    final column = _columns[columnIndex];
    // 选中行整行青绿实底（utenTableSelectedRowColor，与编辑网格同款，2026-09-13
    // 全站统一口径、2026-09-22 加深），文字保持常态深色——语义底色（cellColor）在
    // 选中行上让位给统一选中色，保证选中行读作一个整体。
    Widget buildCell() {
      final cellColor = selected
          ? null
          : column.cellColor?.call(context, item) ??
                (utenIsStatusColumn(column.key, column.label)
                    ? udenStatusBadgeCellColor(
                        context,
                        utenStatusLabelType(column.value(item)),
                      )
                    : null);
      final Color? onCellColor = cellColor == null
          ? null
          : utenSemanticCellForeground(context, cellColor);
      final cellStyle = onCellColor != null
          ? textStyle.copyWith(color: onCellColor)
          : textStyle;
      return Container(
        width: _widths[columnIndex],
        // 列间竖线：逐格勾勒单元格右边界。
        // 语义底色格补上/下边框（2026-09-27 用户口径「整格背景变色后上下单元格
        // 边框看不清」）：实底会淹没行的横向分隔，描一圈同款细线让行列网格在
        // 任何底色下都保持可读；无底色格维持原有竖线，不加重整表线感。
        decoration: BoxDecoration(
          color: cellColor,
          border: cellColor == null
              ? Border(
                  right: BorderSide(
                    color: theme.colorScheme.outline,
                    width: 0.5,
                  ),
                )
              : Border(
                  top: BorderSide(color: theme.colorScheme.outline, width: 0.5),
                  bottom: BorderSide(
                    color: theme.colorScheme.outline,
                    width: 0.5,
                  ),
                  right: BorderSide(
                    color: theme.colorScheme.outline,
                    width: 0.5,
                  ),
                ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: MasterDataTableView.cellVerticalPadding,
          ),
          child: _dataCell(column, item, cellStyle, selected),
        ),
      );
    }

    // cellColor 依赖行内可监听源时（如称重核对列的重量/数量控制器），整格
    // （底色 + 对比度文字 + 内容）随源重算——只有 cellBuilder 自重建的话，
    // 整格 Container 的底色不会跟着刷新。选中态没有语义底色，不需要监听。
    final listenable = selected
        ? null
        : column.cellColorListenableOf?.call(item);
    return listenable == null
        ? buildCell()
        : ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => buildCell(),
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
    // 行底色：调用方可按行数据着色（货品按状态）；选中统一青绿实底
    // （utenTableSelectedRowColor，与编辑网格同款；2026-09-13 全站统一口径，
    // 2026-09-22 用户口径「看不清是否选中」加深）——文字与网格线保持常态色，
    // 行内输入框也无需再为选中态做任何变色适配。
    final base = widget.rowColor?.call(item);
    final Color rowBg = selected
        ? utenTableSelectedRowColor(theme)
        : (base ?? Colors.transparent);
    final lineColor = theme.colorScheme.outline;
    final textStyle = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: widget.rowForegroundColor?.call(item),
    );
    // 多选前导勾选格（合成单元格，不进列宽机制）。
    // **行内这一份不能自带底色**：它要跟整行同底（选中淡绿/行语义色都由外层
    // ColoredBox 统一给），而且 DecoratedBox 的边框画在子节点之前——自带不透明底会把
    // 行底那条分隔线在这 48px 里盖掉（2026-09-11 用户截图：首列底色不一样、行线断了）。
    final bool rowSelectable = multiId != null && multiId.isNotEmpty;
    final Widget? leadingOverlay = rowSelectable
        ? widget.leadingOverlayBuilder?.call(context, item)
        : null;
    final rowSelectionState = widget.selectionStateOf == null
        ? selected
        : widget.selectionStateOf!(item);
    final Widget checkbox = Theme(
      // 勾选框按视觉尺寸(约18)参与布局而非默认 40 触控位(2026-10-06 行高统一
      // 口径)：这一格没有 v8 留白兜底，40 会把所有多选表的数据行都抬到 40+，
      // 高于只读表的 37 基准；点击切换有整行单击兜底，不缺触控面。
      data: Theme.of(
        context,
      ).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      child: Checkbox(
        tristate: widget.selectionStateOf != null,
        value: rowSelectionState,
        // 无业务 id 的行禁用勾选(不计入全选)。
        onChanged: !rowSelectable
            ? null
            : (_) => _toggleRow(item, rowSelectionState != true),
      ),
    );
    final selectionCheckbox = Center(
      child: !rowSelectable && widget.unselectableLeadingBuilder != null
          ? widget.unselectableLeadingBuilder!(context, item)
          : leadingOverlay == null
          ? checkbox
          // 可勾选但另有门槛的行：勾选框右下角压一个小徽记(如锁)，勾选仍可用。
          : SizedBox(
              width: _selectionColWidth,
              height: _selectionColWidth,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Center(child: checkbox),
                  Positioned(right: 2, bottom: 4, child: leadingOverlay),
                ],
              ),
            ),
    );
    final selectionCell = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: lineColor, width: 0.5)),
      ),
      child: selectionCheckbox,
    );
    // 横滚时钉在视口左缘的那一份副本（[UtenFrozenLeadingColumn]）：它浮在数据格之上，
    // **必须**自带与本行一致的不透明底 + 行底线，否则下面的数据格会透上来、行线
    // 也会在这一段断开。选中淡绿与行语义色都可能是半透明色，先压到 surface
    // 上取实底（与 UtenEditableGrid 冻结列同款处理）。已固定的数据格一并进副本：
    // 格内语义底色（cellColor）允许半透明——透出来的是这里的实底行色而非滚过的
    // 普通列，颜色口径与未滚动时一致。
    final pinnedIndices = _pinnedVisibleIndices;
    final Widget? frozenRowRegion =
        (pinnedIndices.isEmpty && !widget.selectable)
        ? null
        : ColoredBox(
            color: rowBg == Colors.transparent
                ? theme.colorScheme.surface
                : Color.alphaBlend(rowBg, theme.colorScheme.surface),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: lineColor, width: 0.5),
                ),
              ),
              child: _boundStretchRow(
                Row(
                  crossAxisAlignment: _selectableCross,
                  children: [
                    if (widget.selectable)
                      SizedBox(width: _selectionColWidth, child: selectionCell),
                    for (final i in pinnedIndices)
                      _buildDataCell(theme, i, item, selected, textStyle),
                  ],
                ),
              ),
            ),
          );
    final undecoratedRow = DecoratedBox(
      // 行间横线：逐行分隔；选中行也用常态横线（底色由下面的 ColoredBox 统一给）。
      // 右缘竖线：showColumnChooser 时末列右线之后还有 48px 列设置空档（行内
      // SizedBox 无内容无高度、描不了边），行级补一条把表格右缘收口；无 chooser
      // 的表末格右线已在原位，行级再画会同位叠加变粗，故条件关掉。
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: lineColor, width: 0.5),
          right: widget.showColumnChooser
              ? BorderSide(color: lineColor, width: 0.5)
              : BorderSide.none,
        ),
      ),
      child: ColoredBox(
        color: rowBg,
        child: _boundStretchRow(
          _withFrozenLeadingRegion(
            controller: _bodyH,
            width: _pinnedLeadingWidth(pinnedIndices),
            cell: frozenRowRegion ?? const SizedBox.shrink(),
            row: Row(
              crossAxisAlignment: _selectableCross,
              children: [
                if (widget.selectable)
                  SizedBox(width: _selectionColWidth, child: selectionCell),
                for (final i in _visibleIndices)
                  _buildDataCell(theme, i, item, selected, textStyle),
                if (widget.showColumnChooser) const SizedBox(width: 48),
              ],
            ),
          ),
        ),
      ),
    );
    final row =
        widget.rowDecorationBuilder?.call(context, item, undecoratedRow) ??
        undecoratedRow;
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
        _toggleRow(item, rowSelectionState != true);
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
    // 语义本来就是「选中这条」，不是「打开页面」。**多选 picker 同样走这条**
    //（2026-09-11 报工来源选择器改多选时踩到）：落到下面的单击选中/双击打开
    // 分支后，单击只会 selectRow()，而 idOf 返回 null 的不可选行连 selectRow
    // 都提前返回——用户点了不可报工的行毫无反应，也拿不到「为什么不能选」的提示。
    // 这里 selectRow() 负责勾选、onRowTap 负责提示，调用方的 onRowTap 里
    // **不要再自己切换选中**，否则一次点击切两下等于没切。
    Widget interactive;
    if (widget.embedded || widget.singleTapRows) {
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
          'cells:${_columns.map((c) => c.value(item) ?? '').join(' ')}';
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
    final canPrev = !_busy && _currentPage > 1;
    final canNext = !_busy && _currentPage < widget.totalPages;
    // 「上一页/下一页」带文案时的固有宽度随字号一起放大：窄屏（375px）叠大字号（1.5×）
    // 就超出可用宽。按可用宽 × 当前字号判断，放不下就收成纯图标按钮——
    // 翻页条**恒为一行**（改折行会把表体挤到纵向溢出，得不偿失）。
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 250 * textScale + 54;
          void goto(int page) => _gotoPage(page);
          // Split pickers can leave less than 190px for the right-hand list.
          // Keep navigation usable there without forcing a fixed-width page
          // input plus total into the same row.
          if (constraints.maxWidth < 190 * textScale) {
            final buttonWidth = math.min(48.0, constraints.maxWidth / 3);
            return Row(
              children: [
                IconButton(
                  constraints: BoxConstraints.tightFor(
                    width: buttonWidth,
                    height: 48,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: canPrev && widget.onPageChange != null
                      ? () => goto(_currentPage - 1)
                      : null,
                  tooltip: '上一页',
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                ),
                Expanded(
                  child: Tooltip(
                    message: '$_currentPage / ${widget.totalPages}',
                    child: Text(
                      '$_currentPage / ${widget.totalPages}',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
                IconButton(
                  constraints: BoxConstraints.tightFor(
                    width: buttonWidth,
                    height: 48,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: canNext && widget.onPageChange != null
                      ? () => goto(_currentPage + 1)
                      : null,
                  tooltip: '下一页',
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                ),
              ],
            );
          }
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (compact)
                IconButton(
                  onPressed: (canPrev && widget.onPageChange != null)
                      ? () => goto(_currentPage - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                  tooltip: '上一页', // TODO(l10n): 补 arb
                )
              else
                TextButton.icon(
                  onPressed: (canPrev && widget.onPageChange != null)
                      ? () => goto(_currentPage - 1)
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
                        focusNode: _pageFocus,
                        enabled: !_busy,
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
                              ? _currentPage
                              : p.clamp(1, widget.totalPages);
                          if (target != _currentPage) {
                            goto(target);
                          } else {
                            _pageCtrl.text = '$target';
                          }
                          _pageFocus.unfocus();
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
                      ? () => goto(_currentPage + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                  tooltip: '下一页', // TODO(l10n): 补 arb
                )
              else
                TextButton.icon(
                  onPressed: (canNext && widget.onPageChange != null)
                      ? () => goto(_currentPage + 1)
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

/// Tracks only mounted rows; no per-record GlobalKey or full-list layout.
class _PaginationRowMarker extends SingleChildRenderObjectWidget {
  const _PaginationRowMarker({
    super.key,
    required this.register,
    required this.unregister,
    required super.child,
  });
  final void Function(RenderBox) register;
  final void Function(RenderBox) unregister;

  @override
  RenderObject createRenderObject(BuildContext context) {
    final box = RenderProxyBox();
    register(box);
    return box;
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    register(renderObject as RenderBox);
  }

  @override
  void didUnmountRenderObject(covariant RenderProxyBox renderObject) {
    unregister(renderObject);
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
    this.leading,
  });

  final String label;
  final List<MasterFacetBucket> buckets;
  final int nullCount;
  final String? selected;
  final ValueChanged<String?> onChanged;

  /// 列头说明（MasterColumnDef.info 透传）：非空渲染 ⓘ，悬停 Tooltip、
  /// 点击（含手机）弹说明小窗。
  final String? info;

  /// 标签前缀（2026-09-25）：固定列传图钉图标，与标签同行垂直居中。
  final Widget? leading;

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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.leading != null) ...[
              widget.leading!,
              const SizedBox(width: UtenSpacing.s4),
            ],
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UtenTableHeader.textStyle(theme),
              ),
            ),
            // 列头说明 ⓘ 与可筛选/可排序列同款（2026-09-27 用户口径「提示
            // icon 统一放表头」）：非交互列此前静默丢弃 MasterColumnDef.info，
            // 领料汇总「应领数量」等列的列头说明一直没渲染。列宽量法已计入
            // _headerInfoIconAllowance，这里只补渲染，不占额外量宽。
            if (widget.info != null) ...[
              const SizedBox(width: UtenSpacing.s4),
              UtenColumnHintIcon(message: widget.info!),
            ],
          ],
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
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: UtenSpacing.s4),
              ],
              Expanded(
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UtenTableHeader.textStyle(
                    theme,
                    highlighted: highlighted,
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
                              // 2026-09-25 用户口径：「取消排序」放最上面（重置类
                              // 选项先见），升降序跟后；值筛选段「所有」仍居首。
                              if (widget.sortable) ...[
                                _menuItem(
                                  ctx,
                                  label: '取消排序', // TODO(l10n): 补 arb
                                  isSelected: !widget.sortActive,
                                  onTap: () => _sortSelect(null, true),
                                  theme: theme,
                                ),
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
                                // 「其他」兜底桶固定放最后（2026-09-16 用户口径）：
                                // 该列为空/未归类的行都落这里（如货品未分类、
                                // 单据未指定仓库）；选它即只看这些"匹配不到
                                // 任何已列出选项"的行。
                                if (widget.nullCount > 0)
                                  _menuItem(
                                    ctx,
                                    label:
                                        '其他 (${widget.nullCount})', // TODO(l10n): 补 arb
                                    isSelected:
                                        sanitized == kMasterFilterNullValue,
                                    onTap: () =>
                                        _select(kMasterFilterNullValue),
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

/// 表体横滚内容里的「贴可视框右缘」行——目前只服务表内合计条
/// ([MasterDataTableView.summaryBarInline])。
///
/// 2026-09-15 用户口径：合计条竖向要跟着最后一行走(表格脚注语义)，横向却必须
/// 一直看得见——表宽超出卡片时，靠右对齐的合计会落在表格最右端，用户得把表格拖到
/// 底才看得到「合计数量/合计金额」。这里把整条按当前横滚位置左移，使其右边缘始终
/// 落在表体**可视框**右缘：怎么左右滑，合计都在卡片右边、紧跟末行下方。
///
/// 实现取 [Transform.translate](只改绘制、不改布局)：本行在布局上仍是整张表宽，
/// 因此不影响列宽/横滚范围/末行测量(横滚条覆盖层仍按真实末行定位)。
class _ViewportPinnedRow extends StatelessWidget {
  const _ViewportPinnedRow({
    required this.controller,
    required this.contentWidth,
    required this.fallbackViewportWidth,
    required this.child,
  });

  /// 表体横向 ScrollView 的控制器([MasterDataTableView] 的 _bodyH)。
  final ScrollController controller;

  /// 表格总宽(列宽合计)——本行右边缘在滚动内容里的位置。
  final double contentWidth;

  /// 首帧(controller 尚未 attach)用的可视框宽度，取表体 LayoutBuilder 约束。
  final double fallbackViewportWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      // child 不随滚动重建，只重算平移量。
      child: child,
      builder: (context, inner) {
        // 多 position(全屏路由双挂同一 controller)时 `.position` 会断言失败，
        // 与 [UtenFrozenLeadingColumn] 同款守卫：回落首帧取值。
        final position =
            controller.hasClients && controller.positions.length == 1
            ? controller.position
            : null;
        final viewport = position != null && position.hasViewportDimension
            ? position.viewportDimension
            : fallbackViewportWidth;
        final offset = position != null && position.hasPixels
            ? position.pixels
            : 0.0;
        // 目标右边缘 = 可视框右缘；表宽没撑满可视框时保持贴表格右端(shift 不取正)。
        final shift = offset + viewport - contentWidth;
        return Transform.translate(
          offset: Offset(shift < 0 ? shift : 0, 0),
          child: inner,
        );
      },
    );
  }
}

/// 测试用：[MasterDataTableView] 累计文本测量次数(验证数据刷新不再整表重量)。
@visibleForTesting
int debugMasterTableMeasureTextCount = 0;

/// 一列的量宽缓存：表头宽、单元格最大宽、已量过的值(按字符串去重)。
class _ColumnTextMeasure {
  bool headerMeasured = false;
  double header = 0;
  double body = 0;
  final Set<String> seen = <String>{};
}

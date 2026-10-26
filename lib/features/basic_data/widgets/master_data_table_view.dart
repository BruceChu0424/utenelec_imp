import '../../../shared/paging/paged_read_window_binding.dart';
import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import '../../../components/layout/uten_scroll_gutter.dart';
import '../../../components/layout/uten_page_scrollbar_host.dart';
import '../../../components/layout/uten_page_layout.dart';
import '../../../components/layout/uten_scroll_prefetch_policy.dart';
import '../../../shared/paging/paged_read_intent.dart';
import '../../../core/responsive/display_zoom.dart';
import '../../../components/layout/uten_vertical_scrollbar.dart';
import '../../../components/data_display/uten_table_surface.dart';
import '../../../components/data_display/uten_table_text_selection.dart';
import '../../../components/data_display/uten_selection_lifecycle.dart';
import '../../../components/data_display/uten_table_row_drag.dart';
import '../../../shared/platform_tables/platform_table_binding.dart';
import '../../../shared/platform_tables/platform_table_controller.dart';
import '../../../shared/platform_tables/platform_table_picker.dart';
import '../../../shared/platform_tables/platform_column_header_actions.dart';
import '../../../shared/platform_tables/platform_table_widgets.dart';
import '../../../shared/platform_tables/table_column_projection.dart';
import '../../../core/router/page_search_lifecycle.dart';
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
import '../../../shared/search/keyword_search.dart';
import '../../../shared/search/column_keyword_policy.dart';

import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
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
import '../../../components/feedback/uten_overlay_lifecycle.dart';
import '../../../components/feedback/uten_motion.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_table_cell_auto_width.dart';
import '../../../components/inputs/uten_table_cell_hints.dart';
import '../../../components/inputs/uten_table_cell_spec.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_visible_paint_rect.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_scrollbar.dart';
import '../../../components/layout/uten_sticky_header.dart';
import '../../../components/layout/uten_table_column_kit.dart';
import '../../../components/layout/uten_table_horizontal_scroll_controller.dart';
import '../../../components/layout/uten_panel_opening_scope.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/responsive/scale.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../components/layout/uten_ancestor_row_window.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../models/master_facet.dart';
import 'basic_data_l10n.dart';
import '../../../components/data_display/uten_color_name.dart';
import '../../../shared/ai/page_context/ai_page_context.dart';

export '../../../components/data_display/master_data_table_rows_controller.dart';

part 'master_data_table_view_ai.dart';

/// A presentation-only synchronous read scope. Implementations invoke [read]
/// immediately and unwind in finally; commands/events/awaits are never scoped.
typedef MasterTableSelectionReadScope = R Function<R>(R Function() read);

class _MasterWindowSlot {
  _MasterWindowSlot(this.id);
  final Object id;
}

class _DeferredRowKey extends ValueKey<Key> {
  const _DeferredRowKey(super.value);
}

R _profileMasterTableWork<R>(String label, R Function() work) {
  final observer = debugUiWorkSliceObserver;
  if (observer == null) return work();
  final clock = Stopwatch()..start();
  try {
    return work();
  } finally {
    observer(label, clock.elapsed);
  }
}

class _MasterRowLayoutProbe extends SingleChildRenderObjectWidget {
  const _MasterRowLayoutProbe({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _MasterRowLayout();
}

class _MasterRowLayout extends RenderProxyBox {
  @override
  void performLayout() => _profileMasterTableWork('master.row-layout', () {
    super.performLayout();
  });
}

/// Installed only when the profiling observer is present. Separate intrinsic
/// measurement from the following constrained layout without changing either.
class _MasterStretchLayoutProbe extends SingleChildRenderObjectWidget {
  const _MasterStretchLayoutProbe({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MasterStretchLayout();
}

class _MasterStretchLayout extends RenderProxyBox {
  @override
  double computeMaxIntrinsicHeight(double width) => _profileMasterTableWork(
    'master.intrinsic-height',
    () => super.computeMaxIntrinsicHeight(width),
  );

  @override
  void performLayout() => _profileMasterTableWork('master.stretch-layout', () {
    super.performLayout();
  });
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

/// A page-owned range/tree picker using the table's ordinary filter header.
/// The page retains its server query, permission checks and picker lifecycle.
class MasterHeaderFilterAction {
  const MasterHeaderFilterAction({
    required this.onTap,
    this.value,
    this.enabled = true,
  });

  final VoidCallback onTap;
  final String? value;
  final bool enabled;
}

/// 一列定义：[key](筛选键，与后端 query 参数对齐)、[label](列头)、
/// [width](富内容默认下限)、[value](文本值)、[cellBuilder](可选自定义内容)。
class MasterColumnDef<T> {
  const MasterColumnDef({
    required this.key,
    required this.label,
    required this.width,
    required this.value,
    this.measureValueOf,
    this.measureWidthOf,
    this.measureWidthScope,
    this.minimumWidthOf,
    this.cellHorizontalPaddingOf,
    this.type = 'text',
    this.sortable = false,
    this.filterFromRows = false,
    this.columnSearchEnabled,
    this.facetSearchEnabled = false,
    this.headerFilterAction,
    this.headerTrailingBuilder,
    this.cellColor,
    this.cellColorListenableOf,
    this.cellBuilder,
    this.cellBuilderHandlesSemantics = false,
    this.fillsCellHeight = false,
    this.emphasized = false,
    this.info,
    this.defaultVisible = true,
    this.exportDefinition,
    this.exactValueOf,
    this.exactListenableOf,
    this.legendOf,
    this.aiSensitive = false,
    this.exportable = true,
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

  /// 是否随「下载表格」导出（默认 true）。纯展示列——树形身份格、审计勾选格这类
  /// 后端导出列集里没有对应列的——标 false：投影照常发布（打印预览继续用），
  /// 只在导出请求组装 columnProjection 时剔除（2026-10-20「导出组件」报
  /// 「列不存在或不在可导出范围：treeIdentity」的根因收口）。
  final bool exportable;
  final Map<String, dynamic>? exportDefinition;

  /// Unformatted decimal source for display calculations; never inferred from a money/quantity label.
  final String? Function(T row)? exactValueOf;
  final Listenable? Function(T row)? exactListenableOf;

  /// Rich cells retain this fallback minimum unless [minimumWidthOf] describes
  /// their actual control geometry. Plain text columns fit their loaded values.
  /// User-resized widths always take precedence.
  final double width;

  /// Optional presentation minimum for interactive cells. The ordinary
  /// 48-column minimum remains unchanged; this callback never changes data.
  final double Function(BuildContext context)? minimumWidthOf;

  /// Body-cell padding for compact interactive columns; defaults to 12 per
  /// side. Header labels retain their existing padding and tooltip behavior.
  final double Function(BuildContext context)? cellHorizontalPaddingOf;
  final String? Function(T item) value;

  /// Presentation-only text for automatic width sampling of rich controls.
  /// Uses the existing per-frame measurement budget; value/exactValueOf remain
  /// authoritative for filtering, sorting, semantics and export.
  final String? Function(T item)? measureValueOf;

  /// Optional rich-cell geometry, evaluated within the same bounded width
  /// batch as plain text. [measureValueOf] is its stable presentation cache key;
  /// business values, filtering, exact quantities and export never call this.
  final double Function(BuildContext context, T item, TextScaler textScaler)?
  measureWidthOf;

  /// Stable identity for [measureWidthOf], independent of a rebuilt closure.
  /// Change this value when its geometry/strategy changes for the same rows.
  /// Without a scope, the callback identity remains the invalidation key.
  final Object? measureWidthScope;

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

  /// 重点核对列（2026-10-10 财务口径）：整列红色加粗，与 UtenRevisionTable 的
  /// highlightColumnKeys 同色同字重，语义是「请逐行核对这些数字」（审核中心
  /// 金额/汇率链等）。列自身带语义底色（cellColor）时底色对比色优先，不叠加。
  final bool emphasized;

  /// 该列是否允许点表头排序（日期/金额/数量等可排序列置 true）。
  /// 页面传了 onSortChange 时排序走服务端；没传时组件就地排序（全量加载表）。
  final bool sortable;

  /// 本地取值筛选（2026-09-25 用户口径「单号列像我的车间任务那样可排序、
  /// 可只看某个单号」）：组件用当前行的 [value] 就地构建筛选桶并过滤显示行，
  /// 不要求宿主接 facets/onFilterChanged。给**全量加载**（非服务端分页）的
  /// 表用；服务端分页表格筛了也只是当页，应走服务端 facets 而不是这个开关。
  /// 宿主已为该 key 提供服务端 facets 时以服务端为准（本开关不再生效）。
  final bool filterFromRows;

  /// Override only where business meaning differs from the ordinary text-column
  /// convention. Dates, measures, enums and action columns retain their existing
  /// range, choice and sort controls instead of a keyword field.
  final bool? columnSearchEnabled;

  /// Search the complete supplied candidate list without adding a row keyword
  /// query. Opt in for enum facets whose server API accepts one exact value.
  final bool facetSearchEnabled;
  final MasterHeaderFilterAction? headerFilterAction;
  final WidgetBuilder? headerTrailingBuilder;

  bool get supportsKeywordSearch => supportsColumnKeywordSearch(
    key: key,
    label: label,
    type: type,
    override: columnSearchEnabled,
  );

  /// 单元格语义底色（如待处理步骤用浅警示色）；null = 跟随所在行底色。
  /// 选中行仍由表格统一使用深绿高亮，避免颜色叠加后文字对比不足。
  final Color? Function(BuildContext context, T item)? cellColor;

  /// [cellColor] 依赖的行内可监听源（如称重核对列的重量/数量控制器）：
  /// 非空时整格包一层 ListenableBuilder，源变化即重算底色——否则只有
  /// cellBuilder 内部自重建，整格 Container 的底色不会跟着刷新。
  final Listenable? Function(T item)? cellColorListenableOf;
}

/// 按数值排序的列类型 (与后端 ReportColumn.type 同名; weight 另按千克换算)。
const Set<String> _numericColumnTypes = {'number', 'money', 'count', 'weight'};

/// 重量列显示文本 (如「≈3.52 t」「850 g」) -> 千克; 不是重量 (如「未称」) 返回 null。
double? _weightSortValue(String text) {
  final plain = text.replaceAll('≈', '').trim();
  return parseWithSuffix(plain, WeightUnit.kg)?.kg;
}

/// 数值列排序解析：容错「数字 + 单位后缀」的显示口径 (2026-10-10 起数量列
/// 普遍把单位内联到数字后面，如「12 米」「3.5 PCS」)。直接 tryParse 失败时
/// 取前导数字部分解析，仍解析不出才返回 null 交回字符串比较。
double? _numericSortValue(String text) {
  final cleaned = text.replaceAll(',', '').trim();
  final direct = double.tryParse(cleaned);
  if (direct != null) return direct;
  final match = RegExp(r'^-?\d+(?:\.\d+)?').firstMatch(cleaned);
  return match == null ? null : double.tryParse(match.group(0)!);
}

/// 一个可折叠的「前导分组」：渲染在表头之下、主数据行之上（如货品页的「禁用货品」
/// 「不明货品」集合）。折叠时是一整行浅色标题行（钉在视口左缘，横滚不带走文案）；
/// 展开后其 [items] 按主表同款列定义、列宽与列显隐逐行渲染——因此「表头设置」
/// 与列对齐天然对它生效。
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
    this.initiallyExpanded = false,
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

  /// 标题行的展开提示文案（默认「下拉查看详情」），紧跟副标题渲染（加粗深红，老人易看清）。
  final String detailLabel;

  /// 首次出现即展开（默认折叠）。给「类似人员」这类结果提示型分组用——
  /// 它们生来就该被看见，不需要用户再点一下（2026-10-09）。
  final bool initiallyExpanded;

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
/// An editor-only row with no business identity, projection or selection value.
class MasterTableAppendRow {
  const MasterTableAppendRow({
    required this.key,
    required this.cellBuilder,
    this.detailsBuilder,
  });
  final Key key;
  final Widget Function(BuildContext context, String columnKey) cellBuilder;
  final Widget? Function(BuildContext context, List<String> visibleColumnKeys)?
  detailsBuilder;
}

class MasterDataTableView<T> extends StatefulWidget {
  /// 数据格的纵向内边距。要画跨行图形的单元格（层级树列）按它设
  /// `UtenTreeTableCell.guideBleed`，不要在调用点抄一个魔数——抄漏了行与行
  /// 之间就会空出 2×8px，整列连线看着像虚线。
  static const double cellVerticalPadding = UtenSpacing.s8;

  const MasterDataTableView({
    super.key,
    required this.columns,
    this.requiredLeadingColumnKeys = const [],
    this.temporaryLeadingColumnKeys = const [],
    required this.items,
    this.unpagedItems = const [],
    this.rowsController,
    this.rowVisible,
    required this.facets,
    this.loadFacetPage,
    this.facetPageLoaders = const {},
    this.facetSearchScope,
    required this.nullCounts,
    required this.filters,
    this.externalFilterKeys = const <String>{},
    required this.onFilterChanged,
    this.serverColumnSearch = false,
    this.preserveQueryOnReturn = false,
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
    this.isRefreshing = false,
    this.refreshError,
    this.refreshedPages = const {},
    this.onRetainedPagesChanged,
    this.onLoadMore,
    this.error,
    this.onRetry,
    this.emptyMessage = '暂无数据', // TODO(l10n): 补 arb
    this.currentPage = 1,
    this.scrollToEndRequest = 0,
    this.revealItemId,
    this.revealRequest = 0,
    this.totalPages = 1,
    this.showPaginationControls = true,
    this.onPageChange,
    this.paginationScope,
    this.paginationRevision,
    this.maxRetainedPages = 5,
    this.maxRetainedRows = 1000,
    this.summaryBar,
    this.summaryBarInline = true,
    this.toolbarActions,
    this.toolbarLeadingActions,
    this.bodyPresentationBuilder,
    this.embedded = false,
    this.primary = false,
    this.virtualized = false,
    this.expensiveRowMounts,
    this.showFullscreenToggle,
    this.showColumnChooser = true,
    this.enableTextSelection = true,
    this.rowDrag,
    this.rowColor,
    this.rowForegroundColor,
    this.rowDecorationBuilder,
    this.dataCellVerticalPadding = cellVerticalPadding,
    this.leadingGroups,
    this.selectable = false,
    this.showSelectionColumn = true,
    this.singleSelection = false,
    this.idOf,
    this.selectionReadScope,
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
    this.tableKey,
    this.platformBinding,
    this.columnEditingEnabled = false,
    this.platformCellDecorator,
    this.errorKey,
    this.listItemBuilder,
    this.listSeparatorBuilder,
    this.listPadding = EdgeInsets.zero,
    this.singleTapRows = false,
    this.appendRows = const [],
    this.appendRowsSource,
    this.onRowDoubleTap,
  }) : assert(maxRetainedPages >= 2),
       assert(maxRetainedRows > 0),
       assert(dataCellVerticalPadding >= 0),
       assert(
         !embedded || !virtualized,
         'virtualized=true requires a bounded, non-embedded table',
       ),
       assert(
         stickyHeaderPinned == null || embedded,
         'MasterDataTableView: stickyHeaderPinned 仅用于 embedded（详情页等'
         '滚动流内的明细表）——非 embedded 表格表头结构上恒在其滚动盒顶部，无需吸顶。',
       ),
       assert(
         !singleSelection || selectable,
         'MasterDataTableView: singleSelection 仅在 selectable:true 下有意义。',
       );

  /// 全屏态变化通知（进入/退出各回调一次）。宿主页可借此把搜索框等控件
  /// 在全屏时放回表格工具条（正常态放页面头部卡片），两处共享同一控制器。
  final ValueChanged<bool>? onFullscreenChanged;

  /// Vertical space around body-cell content. Dense hosts may opt in without
  /// reducing control hit targets or imposing a fixed row height. Tree guides
  /// must use the same value as their [UtenTreeTableCell.guideBleed].
  final double dataCellVerticalPadding;

  /// Picker lists share the table's paging, request fencing and scroll anchors,
  /// while keeping their existing tiles and confirmation interactions.
  final Widget Function(BuildContext, T)? listItemBuilder;
  final IndexedWidgetBuilder? listSeparatorBuilder;
  final EdgeInsetsGeometry listPadding;

  /// Bounded picker tables keep their single-tap select/open interaction without
  /// opting into an unbounded embedded layout.
  final bool singleTapRows;
  final List<MasterTableAppendRow> appendRows;
  final ValueListenable<List<MasterTableAppendRow>>? appendRowsSource;
  final void Function(T item)? onRowDoubleTap;

  /// 目标页加载后递增此令牌，请求在布局完成后滚到末行。0 不触发；同一令牌
  /// 的普通重建不重复滚动。和翻页同时变化时优先定位末尾，其余翻页仍回顶。
  final int scrollToEndRequest;
  final String? revealItemId;
  final int revealRequest;

  /// Automatic scrolling retains a contiguous window. A visible boundary page
  /// and one incoming response may temporarily add at most two pages; selected
  /// business rows are held separately and never discarded with a cache page.
  final int maxRetainedPages;
  final int maxRetainedRows;

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
  final Key? errorKey;
  final List<MasterColumnDef<T>> columns;

  /// Business identity/status columns that must remain visible in this order,
  /// immediately after the optional selection column. Opt-in only: saved layout
  /// choices for other columns remain intact. Required columns are pinned and
  /// cannot be hidden, moved or unpinned, including in the fullscreen view.
  final List<String> requiredLeadingColumnKeys;

  /// Temporary required fields shown first while editing. This is a display
  /// projection: their visibility, order and pins never enter saved layouts.
  /// Removing the keys restores their original layout without replacing the
  /// table state; layout changes to other columns still persist normally.
  final List<String> temporaryLeadingColumnKeys;
  final List<T> items;
  final Map<String, List<MasterFacetBucket>> facets;

  /// Optional full-scope candidate lookup for capped server facet previews.
  /// This searches candidate values; choosing one keeps exact filtering.
  final MasterFacetPageLoader? loadFacetPage;
  final Map<String, MasterFacetColumnLoader> facetPageLoaders;
  final Object? facetSearchScope;
  final Map<String, int> nullCounts;
  final Map<String, String?> filters;

  /// 由宿主页自己承担入口的筛选列 key（不计入空态「筛选生效数」描述）。
  ///
  /// 两类：① 被页面钉死、表里根本改不动的（分段子页的 fixedOrderType）；
  /// ② 表外分段条上一直看得见、用户随时能切回去的（待检处置的类型分段）。
  /// （空态「清除筛选」按钮已按 2026-09-28 用户口径全站退役；空态说明里的
  /// 筛选生效数描述见 _buildProjectedTable 的行区提示。）
  final Set<String> externalFilterKeys;
  final void Function(String key, String? value) onFilterChanged;

  /// Server lists forward `search.<column key>` through their normal query and
  /// export path. Complete in-memory tables search the displayed column values.
  final bool serverColumnSearch;

  /// A revision browser keeps its current filters while opening a child page.
  /// Ordinary workspaces still clear their header query on return by default;
  /// identity and server-boundary invalidation remain independent of this flag.
  final bool preserveQueryOnReturn;

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

  /// 多选时最前列是否渲染勾选框列（默认渲染）。审核页「防看岔行」纯阅读勾选
  /// （无批量动作）传 false：行单击仍切选中、青绿高亮与「已选 N」胶囊照旧，
  /// 只是最前列不再画行勾选框与表头全选格（2026-10-10 用户口径「最前面的
  /// 多选不要显示」）。仅在 [selectable]:true 下有意义。
  final bool showSelectionColumn;

  /// 选中互斥（单选）：点击行选中该行并自动取消其他行（再点一次取消），
  /// 选中集合恒为空或单元素。默认 false=多选累积。审核页「防看岔行」纯阅读
  /// 勾选传 true（2026-10-10 用户口径「默认不要多选，选另一个之前的取消」）；
  /// 带批量动作的表保持多选。仅在 [selectable]:true 下有意义。
  final bool singleSelection;

  /// 行→业务 id 提取器（[selectable]:true 时必填）。用于把行键进 [selectedIds] 集合，避免依赖
  /// item 引用相等（列表每次 build 重建对象；_BomRow / InstantInventoryRow 无 id 都会踩坑）。
  /// 无 id 的行传复合键，如 `(r) => '${r.goodsId}|${r.colorId}'`。
  final String? Function(T)? idOf;

  /// Amortizes live eligibility context reads within one synchronous identity
  /// collection. Individual row callbacks remain live outside this scope.
  final MasterTableSelectionReadScope? selectionReadScope;

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
  ///
  /// 前缀按钮经 GlobalKey 稳定挂载（见 _stableLeadingActions）：loading/错误/
  /// 空态与数据态的工具条是不同分支，稳定槽保证其中的搜索框等控件跨状态切换
  /// 不重建、焦点与输入法组合不丢；loading/错误态也保留前缀按钮（业务写动作
  /// 仍只在数据态/空态出现）。
  final List<Widget>? toolbarLeadingActions;

  /// Optional presentation around the existing body. Keep [child] mounted when
  /// showing local progress; the toolbar and the single selection area retain
  /// their identity. Does not change rows, selection, filtering or measurement.
  final Widget Function(BuildContext context, Widget child)?
  bodyPresentationBuilder;

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

  /// Input-heavy rows retain conservative one-row admission. Known lightweight
  /// read-only presentations can opt into bounded batches and more overscan.
  /// By default, custom cells are conservative and plain text uses batches.
  final bool? expensiveRowMounts;

  /// 是否显示工具条「全屏」按钮。null 时按 [embedded] 推断：嵌入场景（滑窗/picker/弹窗内的
  /// 明细表）默认隐藏全屏按钮，避免整屏路由在受限容器里铺满屏幕（详细排产滑窗 bug 修复）；
  /// 非嵌入主页面默认显示。显式传 true 可在嵌入场景放开。
  final bool? showFullscreenToggle;

  /// 是否显示工具条「表头设置」。窄屏页面可关闭以把有限高度留给数据，
  /// 桌面/全屏默认保留完整列显隐能力。
  final bool showColumnChooser;

  /// 是否允许表体文字框选与复制，与行勾选 [selectable] 相互独立。
  ///
  /// 默认开启，包括多选表和含输入格的表；输入控件保留自己的原生文字选择。
  /// 特殊内容可显式关闭，此时各行内容用 [SelectionContainer.disabled] 隔离。
  /// 表体选择区实例保持稳定，禁用屏障位于 ListView 自动保活节点之下。
  /// 拖选文字不触发行勾选；单击、复选框和行菜单保留原有业务选择语义。
  final bool enableTextSelection;

  /// 行拖拽（长按启动）：单行换位、多选整批移动、树表跨层级移入。
  ///
  /// 默认 null = 不支持拖拽（普通清单页、自带服务端排序口径的表都不挂）。
  /// 只有需要人工排层/排顺序的表（如货品「组装信息」BOM）显式接入。
  /// 交互细节见 [UtenTableRowDrag] 的契约文档。
  final UtenTableRowDrag<T>? rowDrag;

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

  /// Revalidates the visible query while its accepted rows remain mounted.
  /// Separate from loadingMore: it must not start a new pagination window.
  final bool isRefreshing;

  /// A failed background read keeps the last accepted rows visible and offers
  /// [onRetry] without replacing the table with a full-page error.
  final String? refreshError;

  /// A successfully revalidated window, published as one complete map.
  final Map<int, List<T>> refreshedPages;
  final ValueChanged<List<int>>? onRetainedPagesChanged;

  /// 表体真实视口临近已加载边界时，按共享预取距离提前回调；滚轮、滑块、
  /// 轨道、箭头及触摸滚动均使用同一入口，不必等到最底才加载下一页。
  /// 与 [loadingMore]（末尾转圈行 + 本组件防重入）配合；纯布局不发起请求。
  /// 组件不感知是否还有更多页——增量加载式页面不传 currentPage/totalPages（避免
  /// 渲染翻页条），由调用方在回调里自行判断 [_loadMore] 类守卫后 no-op。
  final VoidCallback? onLoadMore;
  final String? error;
  final VoidCallback? onRetry;
  final String emptyMessage;

  final int currentPage;
  final int totalPages;

  /// Pickers may place the controls alongside their bottom confirmation bar.
  final bool showPaginationControls;
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
  /// 默认作为表格末行下方的脚注，嵌入式、全屏和独立表格采用同一位置。
  ///
  /// **服务端分页的表格必须传服务端合计**——对当前页求和会得出一个看着像总计、
  /// 其实只覆盖一页的数；拿不到服务端合计时要么不传，要么把标签写成「本页合计」。
  final Widget? summaryBar;

  /// 合计条改为**随表体滚动**：渲染进表体竖向滚动内容的末尾（最后一行数据之下），
  /// 行少时紧跟末行，行多时要滚到底才见——合计条属于表格那一块，不再钉在区块底部。
  /// 横向同样随表格内容（表格横向滚动时合计条跟着走）。用于详情页等
  /// 「合计行是表格脚注」语义的场景。只有明确需要固定总览的宿主才传 false。
  final bool summaryBarInline;

  @override
  State<MasterDataTableView<T>> createState() => _MasterDataTableViewState<T>();
}

class _MasterDataTableViewState<T> extends State<MasterDataTableView<T>>
    with UtenColumnHeaderDragHost<MasterDataTableView<T>> {
  final _pageLayoutToken = Object();
  List<MasterTableAppendRow> get _appendRows =>
      widget.appendRowsSource?.value ?? widget.appendRows;
  void _appendRowsChanged() {
    if (!mounted) return;
    setState(() {});
    _fsTick.value++;
  }

  final _pages = SplayTreeMap<int, List<T>>();
  final _readWindowOwner = Object();
  PagedReadWindowBinding<T>? _readWindowBinding;
  PagedReadWindowBinding<T>? _acceptedReadWindowBinding;
  Map<int, List<T>>? _replacementWindowPages;

  void _bindReadWindow() {
    final incoming = readWindowBindingOf<T>(widget.items);
    final previous = _readWindowBinding;
    final next =
        incoming ??
        (previous?.isCurrent == true && (previous!.pending || previous.failed)
            ? previous
            : null);
    if (previous != null && !previous.sameSession(next)) {
      previous.detachPresentation(_readWindowOwner);
    }
    _readWindowBinding = next;
    next?.attachPresentation(
      _readWindowOwner,
      retainedPages: () => _pages.keys.toList(growable: false),
      visiblePage: () => mounted ? _currentPage : null,
      isCurrent: () =>
          mounted && _automaticPagination && _prefetchViewportActive,
    );
  }

  SplayTreeMap<int, List<T>> _proposedMeasuredPages() =>
      _replacementWindowPages == null
      ? _withPage(_appendPage!, _prependPageItems!)
      : SplayTreeMap<int, List<T>>.of(_replacementWindowPages!);

  ({Object id, double top, RenderBox viewport})? _measurementAnchor() {
    if (_replacementWindowPages == null) return _visiblePaginationAnchor();
    final proposed = _collectRows(_proposedMeasuredPages());
    final surviving = {
      for (final row in proposed) ('data', _paginationRowId(row)),
    };
    ({Object id, double top, RenderBox viewport})? anchor;
    for (final entry in _mountedPaginationRows.entries) {
      if (!surviving.contains(entry.key)) continue;
      final box = entry.value.box;
      if (!box.attached || !box.hasSize) continue;
      final object = RenderAbstractViewport.maybeOf(box);
      if (object is! RenderBox) continue;
      final viewport = object as RenderBox;
      if (!viewport.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (!top.isFinite ||
          top + box.size.height <= .5 ||
          top >= viewport.size.height) {
        continue;
      }
      if (anchor == null || top < anchor.top) {
        anchor = (id: entry.key, top: top, viewport: viewport);
      }
    }
    return anchor;
  }

  bool _beginReadWindowReplacement(Map<int, List<T>> pages) {
    _appendGeneration++;
    _appendError = null;
    _prependAnchor.reset();
    _replacementWindowPages = {
      for (final entry in pages.entries)
        entry.key: _reuseUnchangedMapRows(entry.key, entry.value),
    };
    _selectedRows.clear();
    _exhaustedPage = null;
    _exhaustedPreviousPage = null;
    _appendPage = widget.currentPage;
    _prependPageItems = widget.items;
    _prepending = true;
    _prependMeasureItems = const [];
    _removeMeasureItems = const [];
    if (widget.embedded || _displayItems.isEmpty || _expensiveRowMounts) {
      // Input-heavy rows keep their live editors; never mount a second copy
      // of their controllers merely to measure refreshed display geometry.
      _pages
        ..clear()
        ..addAll(_replacementWindowPages!);
      _replacementWindowPages = null;
      _appendPage = null;
      _prependPageItems = null;
      _prependMeasureItems = null;
      _prepending = false;
      _acceptedPage = widget.currentPage;
      _syncRows();
    } else {
      _bindPagination();
    }
    return true;
  }

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
      widget.isLoading ||
      widget.loadingMore ||
      widget.isRefreshing ||
      _appendPage != null;
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
    return widget.onRetainedPagesChanged == null
        ? math.max(ordinary, viewport)
        : math.min(5, ordinary);
  }

  SplayTreeMap<int, List<T>> _trimWindow(SplayTreeMap<int, List<T>> source) {
    final result = SplayTreeMap<int, List<T>>.of(source);
    final visible = _visibleRowIds();
    while (result.length > _pageWindowLimit) {
      final edge = _prepending ? result.lastKey()! : result.firstKey()!;
      if (widget.onRetainedPagesChanged == null &&
          _pageVisible(result[edge]!, visible)) {
        break;
      }
      result.remove(edge);
    }
    return result;
  }

  void _retainSelectedRows() {
    _selectedRows.removeWhere((id, _) => !widget.selectedIds.contains(id));
    // idOf can be a live business eligibility predicate. No selected identity
    // needs retention when the selection is empty.
    if (widget.selectedIds.isEmpty) return;
    final identity = widget.idOf;
    if (identity == null) {
      _selectedRows.clear();
      return;
    }
    _withSelectionReadScope<void>(() {
      for (final row in _pages.values.expand((rows) => rows)) {
        final id = identity(row);
        if (id != null && widget.selectedIds.contains(id)) {
          _selectedRows[id] = row;
        }
      }
    });
  }

  R _withSelectionReadScope<R>(R Function() read) {
    final scope = widget.selectionReadScope;
    return scope == null ? read() : scope<R>(read);
  }

  List<T> _collectRows(Map<int, List<T>> pages) => _profileMasterTableWork(
    'master.collect-rows',
    () => _collectRowsImpl(pages),
  );

  List<T> _collectRowsImpl(Map<int, List<T>> pages) {
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

  void _syncRows() =>
      _profileMasterTableWork('master.sync-rows', _syncRowsImpl);

  void _syncRowsImpl() {
    _items = _collectRows(_pages);
    // This already runs at data/projection changes, never at a scroll tick.
    // Compare values rather than the newly collected List identity so selection
    // rebuilds do not discard a virtualized row's measured height.
    if (!listEquals(_floatingBatchRowsSnapshot, _items)) {
      _floatingBatchRowsSnapshot = _items;
      _floatingBatchDataRevision++;
    }
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
    final controller = widget.rowsController;
    if (controller != null) {
      if (_selectedRows.isEmpty) {
        controller.update(_items);
      } else {
        final liveIds = _withSelectionReadScope(
          () => _items.map((row) => widget.idOf?.call(row)).toSet(),
        );
        controller.update([
          ..._items,
          for (final entry in _selectedRows.entries)
            if (!liveIds.contains(entry.key)) entry.value,
        ]);
      }
    }
    _bindPagination();
    _bindReadWindow();
    _reportRetainedPages();
  }

  List<int>? _reportedRetainedPages;
  bool _retainedPagesReportScheduled = false;

  void _reportRetainedPages() {
    if (widget.onRetainedPagesChanged == null ||
        _retainedPagesReportScheduled) {
      return;
    }
    _retainedPagesReportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retainedPagesReportScheduled = false;
      if (!mounted) return;
      final pages = _pages.keys.toList(growable: false);
      if (listEquals(pages, _reportedRetainedPages)) return;
      _reportedRetainedPages = pages;
      widget.onRetainedPagesChanged?.call(pages);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _bindPagination() => widget.rowsController?.bindPagination(
    this,
    _loadNextFromController,
    _busy,
    currentPage: _currentPage,
    totalPages: widget.totalPages,
    goToPage: _gotoPage,
    onScrollIntent: _releaseExplicitReadingPage,
    settlePresentation: _waitForRowLayout,
    loadPrevious: _loadPreviousFromController,
    updateVisiblePage: (viewport) {
      _externalPageViewport = viewport;
      _scheduleVisiblePage();
    },
  );

  Future<void> _waitForRowLayout() async {
    final generation = _appendGeneration;
    var stableFrames = 0;
    for (var pass = 0; pass < 120; pass++) {
      if (!mounted ||
          generation != _appendGeneration ||
          !_prefetchViewportActive) {
        return;
      }
      await Future.wait([
        _localRowWindow.settled,
        for (final row in _deferredRowMounts.values) row.settled,
        for (final row in _measurementRowMounts.values) row.settled,
      ]);
      if (!mounted || generation != _appendGeneration) return;
      final widths = List<double>.of(_widths);
      final heights = Object.hashAll(
        _deferredRowHeights.entries.map(
          (entry) => Object.hash(entry.key, entry.value),
        ),
      );
      WidgetsBinding.instance.ensureVisualUpdate();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _appendGeneration) return;
      final stable =
          !_widthGrowthPending &&
          !_localRowWindow.isMounting &&
          !_deferredRowMounts.values.any((row) => row.isMounting) &&
          !_measurementRowMounts.values.any((row) => row.isMounting) &&
          listEquals(widths, _widths) &&
          heights ==
              Object.hashAll(
                _deferredRowHeights.entries.map(
                  (entry) => Object.hash(entry.key, entry.value),
                ),
              );
      stableFrames = stable ? stableFrames + 1 : 0;
      if (stableFrames >= 2) return;
    }
  }

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
        _explicitReadingPage != null ||
        !_automaticPagination ||
        (_busy && _appendPage == null && _readWindowBinding?.pending != true) ||
        _settlingPageLayout ||
        _pages.isEmpty) {
      return;
    }
    _visiblePageScheduled = true;
    final generation = _pageLayoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visiblePageScheduled = false;
      if (!mounted ||
          _explicitReadingPage != null ||
          generation != _pageLayoutGeneration ||
          (_busy &&
              _appendPage == null &&
              _readWindowBinding?.pending != true) ||
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
      _bindPagination();
      if (!_pageFocus.hasFocus) _pageCtrl.text = '$page';
      if (_fullscreen) _fsTick.value++;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _resetPages() {
    _replacementWindowPages = null;
    _explicitReadingPage = null;
    _reportedRetainedPages = null;
    if (_queryChanged || (widget.error != null && widget.items.isEmpty)) {
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
  List<T> _reuseUnchangedMapRows(int page, List<T> incoming) {
    final previous = _pages[page];
    if (previous == null) return incoming;
    const equality = DeepCollectionEquality();
    return [
      for (var index = 0; index < incoming.length; index++)
        if (index < previous.length &&
            incoming[index] is Map<Object?, Object?> &&
            previous[index] is Map<Object?, Object?> &&
            equality.equals(incoming[index], previous[index]))
          previous[index]
        else
          incoming[index],
    ];
  }

  bool _updatePages(MasterDataTableView<T> oldWidget) {
    final scopeChanged =
        oldWidget.paginationScope != widget.paginationScope ||
        !mapEquals(_filterSnapshot, widget.filters) ||
        oldWidget.sortColumn != widget.sortColumn ||
        oldWidget.sortAscending != widget.sortAscending ||
        !_sameColumnKeys(oldWidget.columns, widget.columns);
    _filterSnapshot = Map.of(widget.filters);
    final previousBinding = _readWindowBinding;
    final incomingBinding = readWindowBindingOf<T>(widget.items);
    if (previousBinding != null &&
        widget.items.isEmpty &&
        (!previousBinding.isCurrent || previousBinding.empty)) {
      _queryChanged = true;
      _acceptedReadWindowBinding = null;
      _resetPages();
      return false;
    }
    final sameWindow =
        incomingBinding?.isCurrent == true &&
        previousBinding?.isCurrent == true &&
        incomingBinding!.sameSession(previousBinding);
    final continuingWindow =
        previousBinding?.isCurrent == true &&
        (sameWindow || incomingBinding == null);
    if (_automaticPagination &&
        _pages.isNotEmpty &&
        continuingWindow &&
        (previousBinding!.pending || previousBinding.failed)) {
      _queryChanged = false;
      _syncRows();
      return true;
    }
    final boundReplacement =
        incomingBinding?.isCurrent == true &&
            !identical(incomingBinding, _acceptedReadWindowBinding)
        ? incomingBinding!.replacementPages
        : null;
    if (_automaticPagination &&
        sameWindow &&
        boundReplacement?.isNotEmpty == true) {
      _queryChanged = false;
      _acceptedReadWindowBinding = incomingBinding;
      _bindReadWindow();
      return _beginReadWindowReplacement(boundReplacement!);
    }
    _queryChanged = scopeChanged;
    if (!_automaticPagination || scopeChanged) {
      _replacementWindowPages = null;
      _acceptedReadWindowBinding = null;
      _resetPages();
      return false;
    }
    if (!identical(oldWidget.refreshedPages, widget.refreshedPages) &&
        widget.refreshedPages.isNotEmpty &&
        oldWidget.paginationRevision == widget.paginationRevision) {
      return _beginReadWindowReplacement(widget.refreshedPages);
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
      if (!identical(oldWidget.items, widget.items)) {
        _pages[widget.currentPage] = widget.items;
      }
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
    if (_appendRows.isNotEmpty ||
        !_automaticPagination ||
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
    if (_appendRows.isNotEmpty ||
        !_automaticPagination ||
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
      if (prepend && target == (_explicitReadingPage ?? 0) - 1) {
        await PagedReadIntent.bufferSeed(
          () => PagedReadIntent.navigation(
            _currentPage,
            () => widget.onPageChange!(target),
          ),
        );
      } else {
        await PagedReadIntent.navigation(
          _currentPage,
          () => widget.onPageChange!(target),
        );
      }
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

  Object? _explicitBufferToken;
  int? _explicitReadingPage;

  void _releaseExplicitReadingPage() {
    if (_explicitReadingPage == null) return;
    _explicitReadingPage = null;
    _scheduleVisiblePage();
  }

  Object? _explicitBufferScope;
  int? _explicitBufferPage;
  bool _explicitBufferCallbackDone = false;
  bool _explicitBufferDataAccepted = false;
  Object? _explicitBufferScheduledToken;

  void _cancelExplicitBuffer() {
    _explicitBufferToken = null;
    _explicitBufferPage = null;
    _explicitBufferCallbackDone = false;
    _explicitBufferDataAccepted = false;
  }

  void _scheduleExplicitBuffer() {
    final token = _explicitBufferToken;
    if (token == null ||
        identical(_explicitBufferScheduledToken, token) ||
        !_explicitBufferCallbackDone ||
        !_explicitBufferDataAccepted ||
        !_prefetchViewportActive ||
        _busy ||
        widget.error != null ||
        _appendError != null ||
        !_automaticPagination ||
        widget.currentPage != _explicitBufferPage ||
        widget.paginationScope != _explicitBufferScope) {
      return;
    }
    _explicitBufferScheduledToken = token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(_explicitBufferScheduledToken, token)) {
        _explicitBufferScheduledToken = null;
      }
      if (!mounted ||
          !identical(token, _explicitBufferToken) ||
          !_prefetchViewportActive ||
          _busy ||
          _hasPendingPageAnchor ||
          widget.error != null ||
          _appendError != null ||
          widget.currentPage != _explicitBufferPage ||
          widget.paginationScope != _explicitBufferScope) {
        return;
      }
      // Only a successful, explicit pager action gets one leading buffer.
      // Initial routes and layout/automatic continuations never arm this token.
      _explicitReadingPage = _explicitBufferPage;
      _visiblePage = _explicitBufferPage;
      if (!_pageFocus.hasFocus) _pageCtrl.text = '$_explicitBufferPage';
      _cancelExplicitBuffer();
      if (_hasAdjacentPage(true) && _items.isNotEmpty) {
        unawaited(
          PagedReadIntent.bufferSeed(() => _extendPages(prepend: true)),
        );
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _schedulePageStart() {
    final page = widget.currentPage;
    final scope = widget.paginationScope;
    final generation = _pageLayoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.currentPage != page ||
          widget.paginationScope != scope ||
          generation != _pageLayoutGeneration ||
          _pendingScrollToEnd != null) {
        return;
      }
      final controller = _verticalScrollController;
      if (controller != null && controller.hasClients) {
        _prefetchCorrectionDepth++;
        try {
          controller.jumpTo(0);
        } finally {
          _prefetchCorrectionDepth--;
        }
        if (_deferredFallbackActive) {
          _deferredLeadingEdge = true;
          _deferredTrailingEdge = false;
          _deferredEdgeGeneration = _appendGeneration;
          _deferredEdgePasses = 0;
          _scheduleDeferredLeadingEdge();
        }
      }
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

  Object? _pageNavigationToken;

  void _gotoPage(int page) {
    if (_busy || widget.onPageChange == null) return;
    final readingPage = _currentPage;
    final layoutGeneration = _pageLayoutGeneration;
    final scope = widget.paginationScope;
    final navigation = Object();
    _pageNavigationToken = navigation;
    var readAccepted = false;
    _explicitReadingPage = null;
    _appendGeneration++;
    _appendError = null;
    _prependMeasureItems = null;
    _prependPageItems = null;
    _prependAnchor.reset();
    _cancelExplicitBuffer();
    final token = _automaticPagination && page > 1 ? navigation : null;
    _explicitBufferToken = token;
    _explicitBufferPage = token == null ? null : page;
    _explicitBufferScope = scope;

    bool current() =>
        mounted &&
        identical(_pageNavigationToken, navigation) &&
        widget.paginationScope == scope;
    void finish() {
      if (!current() ||
          widget.error != null ||
          widget.isLoading ||
          widget.loadingMore) {
        return;
      }
      if (readAccepted &&
          widget.currentPage == page &&
          layoutGeneration == _pageLayoutGeneration) {
        // The parent can publish the exact cached DTO it already held. A real
        // read receipt, not identity changes or a cancelled confirmation,
        // authorizes replacing the visible window and positioning its start.
        setState(_resetPages);
        _schedulePageStart();
        if (_fullscreen) _fsTick.value++;
      }
      if (token != null && identical(token, _explicitBufferToken)) {
        if (readAccepted && widget.currentPage == page) {
          _explicitBufferDataAccepted = true;
        }
        _scheduleExplicitBuffer();
      }
    }

    unawaited(
      Future<void>.sync(
        () => PagedReadIntent.navigation(
          readingPage,
          () => widget.onPageChange!(page),
          replaceWindow: true,
          onAccepted: (accepted) {
            if (!current() || accepted != page) return;
            readAccepted = true;
            if (token != null && identical(token, _explicitBufferToken)) {
              _explicitBufferDataAccepted = true;
            }
          },
        ),
      ).then<void>(
        (_) {
          if (!current()) return;
          if (token != null && identical(token, _explicitBufferToken)) {
            _explicitBufferCallbackDone = true;
          }
          finish();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!current()) return;
            finish();
            if (!widget.isLoading && !widget.loadingMore) {
              if (!readAccepted &&
                  !_explicitBufferDataAccepted &&
                  layoutGeneration == _pageLayoutGeneration) {
                _cancelExplicitBuffer();
              }
              _pageNavigationToken = null;
            }
          });
          WidgetsBinding.instance.ensureVisualUpdate();
        },
        onError: (Object error, StackTrace stack) {
          if (current()) {
            _pageNavigationToken = null;
            _cancelExplicitBuffer();
          }
          Error.throwWithStackTrace(error, stack);
        },
      ),
    );
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
    final proposed = _applyRowView(_collectRows(_proposedMeasuredPages()));
    final anchorIndex = proposed.indexWhere(
      (row) => ('data', _paginationRowId(row)) == anchorId,
    );
    // A group header stays before the main rows. Local sorting may also put
    // some new rows below the visible anchor; those must not move the viewport.
    if (anchorIndex < 0) return const [];
    final known = {for (final row in _items) _paginationRowId(row): row};
    return proposed
        .take(anchorIndex)
        .where(
          (row) =>
              !known.containsKey(_paginationRowId(row)) ||
              (_replacementWindowPages != null &&
                  !identical(known[_paginationRowId(row)], row)),
        )
        .toList();
  }

  List<T> _rowsRemovedBefore(Object? anchorId) {
    if (_appendPage == null || _prependPageItems == null || anchorId == null) {
      return const [];
    }
    final retained = _collectRows(
      _replacementWindowPages == null
          ? _trimWindow(_proposedMeasuredPages())
          : _proposedMeasuredPages(),
    ).map(_paginationRowId).toSet();
    final current = _applyRowView(_items);
    final anchorIndex = current.indexWhere(
      (row) => ('data', _paginationRowId(row)) == anchorId,
    );
    if (anchorIndex < 0) return const [];
    final proposed = {
      for (final row in _collectRows(_proposedMeasuredPages()))
        _paginationRowId(row): row,
    };
    return current
        .take(anchorIndex)
        .where(
          (row) =>
              !retained.contains(_paginationRowId(row)) ||
              (_replacementWindowPages != null &&
                  !identical(proposed[_paginationRowId(row)], row)),
        )
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
      final anchor = _measurementAnchor();
      final replacingWindow = _replacementWindowPages != null;
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
      final measurementKeys = [
        for (final row in needed) (false, _paginationRowId(row)),
        for (final row in removed) (true, _paginationRowId(row)),
      ];
      if (measurementKeys.any(
        (key) => _measurementRowMounts[key]?.hasMountedContent != true,
      )) {
        if (_prefetchViewportActive) {
          _schedulePrependMeasurement();
          WidgetsBinding.instance.ensureVisualUpdate();
        }
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
        if (replacingWindow) {
          unawaited(
            _settleReadWindowAnchor(
              anchor,
              position,
              generation,
              position.pixels,
            ),
          );
        }
      });
    });
  }

  Future<void> _settleReadWindowAnchor(
    ({Object id, double top, RenderBox viewport}) anchor,
    ScrollPosition position,
    int generation,
    double expectedPixels,
  ) async {
    // A newly visible row may replace its estimated height after the atomic
    // map has been laid out. Wait for the existing row budget to settle before
    // applying its final geometry correction. A new scroll cancels this work.
    await _waitForRowLayout();
    if (!mounted ||
        generation != _appendGeneration ||
        _verticalScrollController?.positions.contains(position) != true ||
        position.isScrollingNotifier.value ||
        !position.hasContentDimensions ||
        (position.pixels - expectedPixels).abs() > .5) {
      return;
    }
    final box = _mountedPaginationRows[anchor.id]?.box;
    if (box == null ||
        !box.attached ||
        !box.hasSize ||
        !identical(RenderAbstractViewport.maybeOf(box), anchor.viewport)) {
      return;
    }
    final residual =
        box.localToGlobal(Offset.zero, ancestor: anchor.viewport).dy -
        anchor.top;
    if (residual.abs() > .5) {
      position.jumpTo(
        (position.pixels + residual).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    }
  }

  void _commitPrepend() {
    setState(() {
      _acceptPageIndicator(_appendPage!);
      if (_replacementWindowPages != null) {
        _pages
          ..clear()
          ..addAll(_replacementWindowPages!);
        _replacementWindowPages = null;
      } else {
        _acceptPage(_acceptedPage, _prependPageItems!);
      }
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
      _prependMeasureItems = _rowsInsertedBefore(_measurementAnchor()?.id);
      _removeMeasureItems = _rowsRemovedBefore(_measurementAnchor()?.id);
    }
    final measuring = _prependMeasureItems;
    if (measuring != null) _schedulePrependMeasurement();
    final liveMeasurementKeys = {
      for (final row in measuring ?? <T>[]) (false, _paginationRowId(row)),
      for (final row in _removeMeasureItems) (true, _paginationRowId(row)),
    };
    _measurementRowMounts.removeWhere(
      (key, _) => !liveMeasurementKeys.contains(key),
    );
    Widget measureRow(T row, bool removing) {
      final id = _paginationRowId(row);
      final key = (removing, id);
      final dataKey = ('data', id);
      return UtenDeferredRowMount(
        key: ValueKey(('measurement', key)),
        controller: _measurementRowMounts.putIfAbsent(
          key,
          UtenDeferredRowMountController.new,
        ),
        estimatedExtent:
            _deferredRowHeights[dataKey] ??
            UtenEditableGridCellSpec.heightOf(context) + UtenSpacing.s16,
        onExtentMeasured: (height) {
          _deferredRowHeights[dataKey] = height;
          _schedulePrependMeasurement();
        },
        builder: (_) => buildRow(row),
      );
    }

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
                children: [for (final row in measuring) measureRow(row, false)],
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
                  for (final row in _removeMeasureItems) measureRow(row, true),
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

  /// 重查反馈：已有旧行时再次查询（回车搜索/切筛选/翻页），行区顶部钉 2px 细
  /// 进度条。此前这类重查只有表尾 loadingMore 小转圈，视口在顶部时完全不可见，
  /// 用户以为「点击没生效/页面卡住」——2026-10-18 全站统一补齐的口径。
  /// 滚动已贴底时表尾指示行在屏内，不再叠加顶部条（滚动追加期间不多耗帧）。
  Widget? get _requeryFeedback {
    if (widget.isRefreshing || widget.refreshError != null) return null;
    if (_prepending || !_busy || _items.isEmpty) return null;
    if (_bodyV.hasClients && _bodyV.position.extentAfter < 400) return null;
    return const LinearProgressIndicator(minHeight: 2);
  }

  bool _refreshStatusHasShown = false;

  /// One height transition below the fixed header moves the whole body. Its
  /// animation owns no rows and never rebuilds/copies the dataset on each tick.
  Widget _buildRefreshStatusRow() {
    final refreshing = widget.isRefreshing;
    final visible = refreshing || widget.refreshError != null;
    final duration = visible || _refreshStatusHasShown
        ? utenMotionDurationOf(context, UtenAnim.normal)
        : Duration.zero;
    if (visible) _refreshStatusHasShown = true;
    final theme = Theme.of(context);
    Widget status = const SizedBox(width: double.infinity, height: 0);
    if (visible) {
      status = Material(
        key: ValueKey(
          refreshing
              ? 'master-table-refresh-status'
              : 'master-table-refresh-error',
        ),
        color: theme.colorScheme.surfaceContainerHigh,
        child: Semantics(
          liveRegion: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: UtenControlMetrics.compactHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s6,
              ),
              child: Row(
                spacing: UtenSpacing.s8,
                children: [
                  if (refreshing)
                    SizedBox.square(
                      dimension: UtenSpacing.s16,
                      child: CircularProgressIndicator(
                        key: const ValueKey('master-table-refresh-progress'),
                        strokeWidth: 2,
                        value: duration == Duration.zero ? 0.5 : null,
                      ),
                    )
                  else
                    Icon(
                      Icons.sync_problem_outlined,
                      size: UtenSpacing.s20,
                      color: theme.colorScheme.error,
                    ),
                  Expanded(
                    child: Tooltip(
                      message: refreshing
                          ? '正在核对最新数据，仍可打开下面的记录'
                          : widget.refreshError!,
                      child: Text(
                        refreshing ? '正在更新数据' : '更新失败，显示上次数据',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                  if (!refreshing && widget.onRetry != null)
                    TextButton(
                      onPressed: widget.onRetry,
                      child: const Text('重试'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return _MasterTableRefreshTransition(
      key: const ValueKey('master-table-refresh-row'),
      visible: visible,
      duration: duration,
      child: status,
    );
  }

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
  late final _searchLifecycle = PageSearchLifecycle(
    onLeave: () {
      _queryRestoreRevision++;
      _removeFullscreenPresentation();
    },
    onReturn: () {
      if (!widget.preserveQueryOnReturn) {
        _platform.clearSessionQuery();
      }
    },
  );
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
      // 升级新增列贴着代码默认位置落位（如货品表「模具名称」紧跟「模具编号」），
      // 而不是被老保存序追到表尾。
      insertNewColumnsAtDeclaredPosition: true,
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
    _normalizeRequiredLeadingColumns();
    if (_widths.length != columns.length) {
      _widths = [
        for (var i = 0; i < columns.length; i++)
          math.max(
            _minimumColumnWidth(context, columns[i]),
            i < _widths.length ? _widths[i] : columns[i].width,
          ),
      ];
    }
    for (var i = 0; i < columns.length; i++) {
      final width = saved.widths[columns[i].key];
      if (width != null) {
        _widths[i] = math.max(_minimumColumnWidth(context, columns[i]), width);
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
      _resetAutoWidths = true;
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
          if (_presentationHiddenKeys.contains(column.key))
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
    tooltip: _platform.canCustomizeColumns ? '添加列' : '显示列',
    onPressed: _addPlatformColumn,
    icon: Icon(
      _platform.canCustomizeColumns
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
                exportable: _columns[i].exportable,
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
  final _borrowedPrimaryControllers =
      Map<ScrollController, _BorrowedPrimaryTableController>.identity();
  bool get _usesPrimaryScroll => widget.primary && !_fullscreen;
  ScrollController? get _verticalScrollController {
    if (!_usesPrimaryScroll) return _bodyV;
    final parent = PrimaryScrollController.maybeOf(context);
    if (parent == null) return null;
    return _borrowedPrimaryControllers.putIfAbsent(
      parent,
      () => _BorrowedPrimaryTableController(parent),
    );
  }

  int? _pendingScrollToEnd;
  int _scrollToEndAttempts = 0;
  bool _scrollToEndScheduled = false;
  final GlobalKey _revealedRowKey = GlobalKey();
  String? _pendingRevealId;
  bool _revealScheduled = false;
  int _revealAttempts = 0;

  void _scheduleReveal() {
    if (_pendingRevealId == null || _revealScheduled || widget.isLoading) {
      return;
    }
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || _pendingRevealId == null || widget.isLoading) return;
      final request = _pendingRevealId;
      final localTarget = _localWindowSlots[('data', request)];
      if (localTarget != null && _localRowWindow.mountedRowCount > 0) {
        _revealScheduled = true;
        unawaited(
          _localRowWindow
              .reveal(
                localTarget,
                alignment: .35,
                isCurrent: () => mounted && _pendingRevealId == request,
              )
              .then((_) {
                if (!mounted) return;
                _revealScheduled = false;
                if (_pendingRevealId == request) _pendingRevealId = null;
                _scheduleReveal();
              }),
        );
        return;
      }
      final target = _revealedRowKey.currentContext;
      if (target != null) {
        _pendingRevealId = null;
        // A row spans the entire horizontally scrollable table. Revealing it
        // on both axes would scroll the identity/name columns out of view.
        final scrollable = Scrollable.maybeOf(target, axis: Axis.vertical);
        final renderObject = target.findRenderObject();
        if (scrollable != null && renderObject != null) {
          scrollable.position.ensureVisible(renderObject, alignment: 0.35);
        }
        return;
      }
      final controller = _verticalScrollController;
      if (controller == null ||
          controller.positions.length != 1 ||
          !controller.position.hasContentDimensions) {
        return;
      }
      final position = controller.position;
      final next = _revealAttempts == 0
          ? 0.0
          : (position.pixels + position.viewportDimension * 0.65).clamp(
              0.0,
              position.maxScrollExtent,
            );
      controller.jumpTo(next);
      if (++_revealAttempts <= widget.items.length + 2) {
        _scheduleReveal();
        WidgetsBinding.instance.scheduleFrame();
      } else {
        _pendingRevealId = null;
      }
    });
  }

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
      if (_localRowWindow.isMounting ||
          _deferredRowMounts.values.any((row) => row.isMounting)) {
        _scheduleScrollToEnd();
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      final target = position.maxScrollExtent;
      if (!target.isFinite || (target - position.pixels).abs() < 0.000001) {
        _pendingScrollToEnd = null;
        return;
      }
      _deferredLeadingEdge = false;
      _deferredTrailingEdge = false;
      _restoringDeferredEdge = true;
      try {
        controller.jumpTo(target);
      } finally {
        _restoringDeferredEdge = false;
      }
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
  // One selected remote caption per logical column, shared by its ordinary
  // header and the frozen header copy.
  final Map<String, MasterFacetBucket> _selectedFacetBuckets = {};
  final Map<String, String> _columnSearches = {};

  bool _serverSearchFor(String key) =>
      widget.serverColumnSearch &&
      widget.columns.any((column) => column.key == key);

  String? _columnSearch(String key) => _serverSearchFor(key)
      ? widget.filters['search.$key']
      : _columnSearches[key];

  void _searchColumn(String key, String? text) {
    final keyword = text?.trim();
    final value = keyword == null || keyword.isEmpty ? null : keyword;
    if (_serverSearchFor(key)) {
      _persistQuery(filterChanges: {key: null, 'search.$key': value});
      if (widget.filters[key] != null) widget.onFilterChanged(key, null);
      widget.onFilterChanged('search.$key', value);
    } else {
      setState(() {
        _rowFilters.remove(key);
        if (value == null) {
          _columnSearches.remove(key);
        } else {
          _columnSearches[key] = value;
        }
        _syncRows();
        _persistQuery(filterChanges: {key: null, 'search.$key': value});
      });
      if (widget.filters[key] != null) widget.onFilterChanged(key, null);
    }
  }

  String? _localSortColumn;
  bool _localSortAscending = true;
  String _queryPreferenceSignature = '';
  String? _queryPreferenceTableKey;
  bool _queryPreferencesPresent = false;
  int _queryRestoreRevision = 0;
  bool get _serverPaged =>
      widget.onPageChange != null ||
      widget.onLoadMore != null ||
      widget.totalPages > 1;
  bool _ownsHeaderFilter(MasterColumnDef<T> column) =>
      !widget.externalFilterKeys.contains(column.key) &&
      ((!_serverPaged && column.filterFromRows) ||
          widget.facets.containsKey(column.key) ||
          widget.serverColumnSearch ||
          column.supportsKeywordSearch ||
          !_serverPaged);
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
    _platform.hasSessionQueryPreferences,
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
    final tableKey = _platform.tableKey;
    final tableChanged =
        _queryPreferenceTableKey != null &&
        _queryPreferenceTableKey != tableKey;
    final previouslyPresent =
        _queryPreferenceTableKey == tableKey && _queryPreferencesPresent;
    _queryPreferenceSignature = signature;
    _queryPreferenceTableKey = tableKey;
    final filtersPresent = _platform.hasSessionQueryPreferences;
    _queryPreferencesPresent = filtersPresent;
    final revision = ++_queryRestoreRevision;
    final lifecycle = _platform.queryLifecycle;
    if (tableChanged) {
      _rowFilters.clear();
      _columnSearches.clear();
      _localSortColumn = null;
      _localSortAscending = true;
    }
    // A changed column set is not a removed preference. It still invalidates
    // pending restores, but must not clear a page's controlled query when no
    // stored query existed. An actual true -> false reset continues below.
    if (!present && !filtersPresent && !previouslyPresent) return;
    final local = <String, String?>{};
    final server = <String, String?>{};
    if (filtersPresent || previouslyPresent) {
      _columnSearches.clear();
      for (final column in _columns) {
        if (!_ownsHeaderFilter(column)) continue;
        final searchKey = 'search.${column.key}';
        final search = filtersPresent && column.supportsKeywordSearch
            ? filters[searchKey]
            : null;
        if (_serverSearchFor(column.key)) {
          if (widget.filters[searchKey] != search) server[searchKey] = search;
        } else if (search != null && search.isNotEmpty) {
          _columnSearches[column.key] = search;
        }
        final value = filtersPresent ? filters[column.key] : null;
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
    }
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
    Map<String, String?> filterChanges = const {},
    String? sort,
    bool? ascending,
    bool sortChanged = false,
  }) {
    final filters = <String, String?>{};
    for (final column in _columns) {
      if (!_ownsHeaderFilter(column)) continue;
      final value = filterChanges.containsKey(column.key)
          ? filterChanges[column.key]
          : column.key == filterKey
          ? filterValue
          : (!_serverPaged &&
                    column.filterFromRows &&
                    !widget.facets.containsKey(column.key)
                ? _rowFilters[column.key]
                : widget.filters[column.key]);
      if (value != null) filters[column.key] = value;
      final searchKey = 'search.${column.key}';
      final search = filterChanges.containsKey(searchKey)
          ? filterChanges[searchKey]
          : filterKey == searchKey
          ? filterValue
          : _columnSearch(column.key);
      if (column.supportsKeywordSearch && search != null && search.isNotEmpty) {
        filters['search.${column.key}'] = search;
      }
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
    _queryPreferencesPresent = true;
    _queryRestoreRevision++;
  }

  // —— 横滚条覆盖层测量 ——
  /// 表体区 Stack / 末行 的测量键。
  final GlobalKey _bodyAreaKey = GlobalKey();
  final GlobalKey _tableChromeKey = GlobalKey();
  final GlobalKey _floatingBatchKey = GlobalKey();
  final _floatingBatchBottomInset = ValueNotifier<double?>(null);
  final Set<ScrollPosition> _floatingBatchAncestorPositions = {};
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

  // Total budget includes capsule padding, exactly once. Measurements belong
  // to the row viewport below the toolbar/header, never the full window/stage.
  double? _floatingBatchHeightLimit;
  double _floatingBatchMeasuredHeight = 0;
  double _floatingBatchMinimumTableHeight = 0;
  Object? _floatingBatchRowScope;
  double _floatingBatchMeasuredRowHeight = 0;
  double _floatingBatchMinimumContentHeight = 0;
  List<T> _floatingBatchRowsSnapshot = [];
  int _floatingBatchDataRevision = 0;

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
  Widget _buildVerticalScrollbar({bool visible = true}) {
    final controller = _verticalScrollController;
    return UtenContentScrollbar(
      controller: controller ?? _bodyV,
      bottomInset: _bodyBottomPad,
      visible: visible,
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
  List<T>? _widthGrowthPool;
  List<double>? _widthGrowthTarget;
  int _widthGrowthOffset = 0;
  int _widthGrowthColumn = 0;

  // Text shaping is UI work even when it runs in a post-frame callback.
  // Bound each batch by cells so wide tables also leave time for input/paint.
  static const _widthMeasureCellBudget = 256;
  static const _widthMeasureTimeBudget = Duration(milliseconds: 2);

  /// 输入控制器的内容可以先于业务 value 改变。按列键合并本帧各输入格需要的宽度，
  /// 避免逐格重建表格；列集合改变后丢弃旧格子的延迟回调。
  final Map<String, double> _inputWidthRequests = {};
  bool _inputWidthGrowthScheduled = false;
  int _inputWidthGeneration = 0;

  /// 上次量宽时生效的字号系数（textScaler.scale(1)）。用户在系统设置改字号档后，
  /// 渲染文字按新字号铺，但列宽缓存不会自动失效——[_ensureWidths] 据此比较触发重算，
  /// 保证字号变大列也跟着变宽（与 floating_capsule_nav_bar 同款 textScaler 处理）。
  TextScaler? _lastScale;
  List<double> _lastColumnMinimums = const [];
  List<Object> _lastRichWidthScopes = const [];
  TextStyle? _lastRichWidthStyle;
  int _richWidthStyleRevision = 0;
  List<double> _lastColumnPadding = const [];
  List<String> _widthColumnKeys = const [];
  final Set<String> _resetWidthKeys = {};
  bool _resetAutoWidths = false;

  /// 当前选中（单击高亮）的行：滚动不刷新数据故高亮常驻，翻页/重查换对象后自然失效。
  T? _selectedItem;

  final _textSelection = UtenTableTextSelection();
  final _localRowWindow = UtenAncestorRowWindowController<_MasterWindowSlot>();
  final _localWindowSlots = <Object, _MasterWindowSlot>{};
  final _deferredRowMounts = <Object, UtenDeferredRowMountController>{};
  final _deferredRowHeights = <Object, double>{};
  final _measurementRowMounts = <Object, UtenDeferredRowMountController>{};
  bool _deferredFallbackActive = false;
  bool _deferredLeadingEdge = false;
  bool _deferredTrailingEdge = false;
  bool _deferredEdgeScheduled = false;
  bool _restoringDeferredEdge = false;
  bool _deferredScrollSequence = false;
  int _deferredEdgeGeneration = 0;
  int _deferredEdgePasses = 0;
  List<String>? _textSelectionColumnKeys;
  List<String>? _textSelectionRowKeys;

  /// 手动双击检测（列表页「单击选中、双击打开」）：上次点击的行键与时刻。
  /// 用 package:clock 的 [clock]（widget 测试环境为 fake clock，随 pump 推进）
  /// 比对时间窗；不用 DoubleTapGestureRecognizer（其竞技场 hold 会延迟单击
  /// 并诱发 FM2 崩溃）。
  String? _lastTapRowKey;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 双击时间窗：比系统 kDoubleTapTimeout(300ms) 略宽，老人双击慢一点也不漏判。
  static const Duration _kDoubleClickWindow = Duration(milliseconds: 350);

  // ===== 行拖拽（长按启动，2026-10-19；widget.rowDrag 非空才有整套状态） =====
  //
  // 拖拽期间的重绘制走 ValueNotifier（幽灵卡跟随光标、落点指示条换行），
  // 不整表 setState——大表拖动每 16ms 重建全部可见单元格会掉帧；
  // 只有拖拽开始/结束（行变淡/恢复）才真正 setState。

  /// 可见数据行的拖拽槽（行键 → 行条目）：拖动中把光标位置映射到悬停行。
  /// itemBuilder 挂载/更新/卸载时登记，虚拟化滚出视口自动注销。
  final Map<String, _RowDragSlotEntry<T>> _dragSlots = {};

  /// 被拖的行（按下时一次定格；宿主重载/展开后行对象重建，拖拽中不再跟随）。
  List<T>? _dragRows;
  // Only the pressed row owns the active gesture recognizer. Expansion or
  // edge scrolling may move it out of the viewport before pointer up arrives.
  final ValueNotifier<String?> _dragOriginKey = ValueNotifier(null);
  Set<String> _dragRowKeys = const <String>{};
  String? _dragLabel;

  /// 悬停目标与落点形态（null = 当前位置不可放）。
  String? _dragTargetKey;
  UtenTableRowDropMode? _dragMode;

  /// 幽灵卡位置（全局坐标）与落点指示条几何（表体 Stack 本地坐标）。
  final ValueNotifier<Offset?> _dragPointerPos = ValueNotifier(null);
  final ValueNotifier<_RowDragIndicatorGeometry?> _dragIndicator =
      ValueNotifier(null);
  OverlayEntry? _dragGhost;

  Timer? _dragAutoScroll;
  Timer? _dragHoverTimer;
  Timer? _dragRetracking;
  String? _dragAutoExpandedKey;
  UtenOverlayLifecycle? _rowDragLifecycle;

  /// 本轮拖拽由哪条手势拾起（长按 / 鼠标纵向拖）：判负一方的 cancel 回调
  /// 只准清自己启动的拖拽，防止竞技场收尾时误撕另一方的现场。
  _RowDragSource? _dragSource;

  bool get _dragActive => _dragRows != null;

  /// 行 → 拖拽行键（与行 RepaintBoundary 同口径：rowKeyOf 优先、idOf 兜底；
  /// 两者都缺的行不参与拖拽槽，长按手势仍可挂但落点解析找不到它）。
  String? _dragKeyOf(T item) {
    final key = widget.rowKeyOf?.call(item) ?? widget.idOf?.call(item);
    return (key == null || key.isEmpty) ? null : key;
  }

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

  List<String> get _requiredLeadingKeys {
    final available = _columns.map((column) => column.key).toSet();
    return [
      ...widget.requiredLeadingColumnKeys.where(available.contains).toSet(),
    ];
  }

  List<String> get _temporaryLeadingKeys {
    if (widget.temporaryLeadingColumnKeys.isEmpty) return const [];
    final available = _columns.map((column) => column.key).toSet();
    final required = _requiredLeadingKeys.toSet();
    return [
      ...widget.temporaryLeadingColumnKeys
          .where((key) => available.contains(key) && !required.contains(key))
          .toSet(),
    ];
  }

  Set<String> get _presentationHiddenKeys {
    final temporary = _temporaryLeadingKeys;
    return temporary.isEmpty
        ? _hiddenKeys
        : ({..._hiddenKeys}..removeAll(temporary));
  }

  Set<String> get _presentationPinnedKeys {
    final temporary = _temporaryLeadingKeys;
    return temporary.isEmpty ? _pinnedKeys : {..._pinnedKeys, ...temporary};
  }

  List<String> get _presentationColumnOrder {
    final temporary = _temporaryLeadingKeys;
    if (temporary.isEmpty) return _columnOrder;
    final leading = [..._requiredLeadingKeys, ...temporary];
    final normalized = utenNormalizePinnedPrefix(
      order: _columnOrder,
      hiddenKeys: _presentationHiddenKeys,
      pinnedKeys: _presentationPinnedKeys,
    );
    return [...leading, ...normalized.where((key) => !leading.contains(key))];
  }

  bool _isRequiredLeading(String key) =>
      _requiredLeadingKeys.contains(key) || _temporaryLeadingKeys.contains(key);

  /// Replace only non-temporary slots so drag/menu changes cannot serialize
  /// the display projection or displace a temporarily promoted field's anchor.
  List<String> _orderWithoutTemporary(List<String> reordered) {
    final temporary = _temporaryLeadingKeys.toSet();
    final queue = reordered.where((key) => !temporary.contains(key)).iterator;
    return [
      for (final key in _columnOrder)
        if (temporary.contains(key))
          key
        else if (queue.moveNext())
          queue.current,
    ];
  }

  void _normalizeRequiredLeadingColumns() {
    final required = _requiredLeadingKeys;
    _hiddenKeys.removeAll(required);
    _pinnedKeys.addAll(required);
    final normalized = utenNormalizePinnedPrefix(
      order: _columnOrder,
      hiddenKeys: _hiddenKeys,
      pinnedKeys: _pinnedKeys,
    );
    _columnOrder = [
      ...required,
      ...normalized.where((key) => !required.contains(key)),
    ];
  }

  /// 全屏状态：true 时正常树让位成 SizedBox.shrink（ScrollController 只挂全屏路由一棵树），
  /// 表格经 RawDialogRoute 全屏路由渲染——走 Navigator 路由栈，故全屏里再开
  /// 「预览打印 / 下载表格」对话框会正常叠在全屏之上（手动 OverlayEntry 会压住路由弹窗）。
  /// [_fsTick] 驱动全屏内容重建（数据/列宽/显隐变化时 bump）。
  bool _fullscreen = false;
  Object? _fullscreenOwner;
  Route<void>? _fullscreenRoute;
  VoidCallback? _returnFullscreenSurface;
  int _fullscreenScrollEpoch = 0;
  final GlobalKey _presentationKey = GlobalKey();
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
  double columnDragWidth(int i) => i < _widths.length
      ? _widths[i]
      : i < _columns.length
      ? _minimumColumnWidth(context, _columns[i])
      : _minColWidth;

  @override
  String columnDragLabel(int i) => i < _columns.length ? _columns[i].label : '';

  /// 该列当前可否拖出隐藏：至少保留一列可见（末列永不 arm，松开 no-op、视觉回弹）。
  @override
  bool columnCanDragHide(int i) =>
      i < _columns.length &&
      !_isRequiredLeading(_columns[i].key) &&
      _visibleCount > 1;

  @override
  void columnDragHideStart(int index) {
    if (index < 0 ||
        index >= _columns.length ||
        _isRequiredLeading(_columns[index].key)) {
      return;
    }
    super.columnDragHideStart(index);
  }

  @override
  void columnReorderStart(int index) {
    if (index < 0 ||
        index >= _columns.length ||
        _isRequiredLeading(_columns[index].key)) {
      return;
    }
    super.columnReorderStart(index);
  }

  /// 松手且 armed：复用既有显隐切换守卫（末列不隐）。
  @override
  void onColumnDragHide(int i) => _toggleColumn(_columns[i].key);

  @override
  List<({int index, double width})> get reorderVisibleColumns => [
    for (final i in _visibleIndices)
      (
        index: i,
        width: i < _widths.length
            ? _widths[i]
            : _minimumColumnWidth(context, _columns[i]),
      ),
  ];

  /// 横拖换位/弹窗排序/右键菜单移动落位：可见序列内搬移，隐藏列保持原锚位；
  /// 固定块前缀不变量兜底（拖过固定块边界的落位被规范化收回到块边界之后）。
  /// 会话内生效（与 _hiddenKeys 同生命周期），全屏内容经 _fsTick 同步重建。
  @override
  void onColumnsReordered(int fromOriginalIndex, int slot) {
    _reorderColumnInto(fromOriginalIndex, slot);
  }

  void _reorderColumnInto(int fromOriginalIndex, int slot) {
    if (fromOriginalIndex < 0 ||
        fromOriginalIndex >= _columns.length ||
        _isRequiredLeading(_columns[fromOriginalIndex].key)) {
      return;
    }
    final visible = _visibleIndices;
    final fromPos = visible.indexOf(fromOriginalIndex);
    if (fromPos < 0) return;
    final seq = [...visible]..removeAt(fromPos);
    final target = slot.clamp(0, seq.length);
    if (target == fromPos) return;
    seq.insert(target, fromOriginalIndex);
    final temporary = _temporaryLeadingKeys.toSet();
    final newVisibleKeys = <String>{
      for (final i in seq)
        if (!temporary.contains(_columns[i].key)) _columns[i].key,
    };
    final queue = <String>[
      for (final i in seq)
        if (!temporary.contains(_columns[i].key)) _columns[i].key,
    ];
    setState(() {
      _columnOrder = utenNormalizePinnedPrefix(
        order: [
          for (final key in _columnOrder)
            newVisibleKeys.contains(key) ? queue.removeAt(0) : key,
        ],
        hiddenKeys: _hiddenKeys,
        pinnedKeys: _pinnedKeys,
      );
      _normalizeRequiredLeadingColumns();
    });
    _fsTick.value++; // 全屏路由内的表格同步重建。
    _persistPlatformLayout();
  }

  /// 表头设置弹窗拖拽排序：在完整列序（含隐藏列）内搬移 key。
  /// onReorderItem 口径：[newIndex] 为 removeAt 后的最终插入位。
  /// 越过固定块边界的搬移由规范化收回（固定列恒为可见前缀）。
  void _reorderColumnByKeys(int oldIndex, int newIndex) {
    final presented = [..._presentationColumnOrder];
    if (oldIndex < 0 || oldIndex >= presented.length) return;
    if (_isRequiredLeading(presented[oldIndex])) return;
    setState(() {
      final key = presented.removeAt(oldIndex);
      presented.insert(newIndex.clamp(0, presented.length), key);
      _columnOrder = utenNormalizePinnedPrefix(
        order: _orderWithoutTemporary(presented),
        hiddenKeys: _hiddenKeys,
        pinnedKeys: _pinnedKeys,
      );
      _normalizeRequiredLeadingColumns();
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  // —— 表头右键菜单（固定/移动/隐藏，2026-09-25）——

  /// 固定在左侧的可见列下标（前缀不变量下即可见序列开头的连续固定列）。
  List<int> get _pinnedVisibleIndices {
    final result = <int>[];
    final pinned = _presentationPinnedKeys;
    for (final i in _visibleIndices) {
      if (!pinned.contains(_columns[i].key)) break;
      result.add(i);
    }
    return result;
  }

  /// 固定区总宽（含行首多选框列）。
  double _pinnedLeadingWidth(List<int> pinnedIndices) =>
      (_hasSelectionColumn ? _selectionColWidth : 0) +
      pinnedIndices.fold(
        0.0,
        (sum, i) => sum + (i < _widths.length ? _widths[i] : 0),
      );

  bool _hasFrozenDataColumns(ScrollController controller) {
    if (!controller.hasClients || controller.positions.length != 1) {
      return false;
    }
    final position = controller.position;
    if (!position.hasViewportDimension || position.pixels <= 0) return false;
    final fallback = _hasSelectionColumn ? _selectionColWidth : 0.0;
    return utenEffectiveFrozenLeadingWidth(
          requestedWidth: _pinnedLeadingWidth(_pinnedVisibleIndices),
          viewportWidth: position.viewportDimension,
          fallbackWidth: fallback,
          trailingWidth: widget.showColumnChooser ? 48 : 0,
        ) >
        fallback;
  }

  /// 固定/取消固定一列：固定 = 记录当前下标后搬到固定块末尾；取消固定 =
  /// 放回固定前的位置（2026-09-25 用户口径「取消固定也要回到对应的地方」）。
  void _toggleColumnPin(String key) {
    if (_isRequiredLeading(key)) return;
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
      _normalizeRequiredLeadingColumns();
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  /// 表头右键菜单的移动动作（向左/右一格、放到最前/最后）。
  void _moveColumnTo(String key, UtenColumnHeaderMove move) {
    if (_isRequiredLeading(key)) return;
    setState(() {
      final temporary = _temporaryLeadingKeys.toSet();
      final moved = utenMoveVisibleColumn(
        order: _columnOrder.where((key) => !temporary.contains(key)).toList(),
        hiddenKeys: _hiddenKeys,
        pinnedKeys: _pinnedKeys,
        key: key,
        move: move,
      );
      _columnOrder = _orderWithoutTemporary(moved);
      _normalizeRequiredLeadingColumns();
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  /// 表头右键菜单条目（能力判定走 kit 纯函数；隐藏复用既有「至少留一列」守卫）。
  List<UtenContextMenuEntry> _headerMenuEntries(int i) {
    final key = _columns[i].key;
    final required = _isRequiredLeading(key);
    final cap = utenColumnHeaderMenuCapabilities(
      order: _presentationColumnOrder,
      hiddenKeys: _presentationHiddenKeys,
      pinnedKeys: _presentationPinnedKeys,
      key: key,
      canHide: columnCanDragHide(i),
    );
    return [
      ...utenColumnHeaderMenuEntries(
        UtenColumnHeaderMenuSpec(
          pinned: cap.pinned,
          canPin: cap.canPin && !required,
          canHide: cap.canHide,
          canMoveLeft: cap.canMoveLeft && !required,
          canMoveRight: cap.canMoveRight && !required,
          canMoveToFront: cap.canMoveToFront && !required,
          canMoveToBack: cap.canMoveToBack && !required,
          onTogglePin: cap.canPin && !required
              ? () => _toggleColumnPin(key)
              : null,
          onHide: cap.canHide ? () => _toggleColumn(key) : null,
          onMoveLeft: cap.canMoveLeft && !required
              ? () => _moveColumnTo(key, UtenColumnHeaderMove.left)
              : null,
          onMoveRight: cap.canMoveRight && !required
              ? () => _moveColumnTo(key, UtenColumnHeaderMove.right)
              : null,
          onMoveToFront: cap.canMoveToFront && !required
              ? () => _moveColumnTo(key, UtenColumnHeaderMove.front)
              : null,
          onMoveToBack: cap.canMoveToBack && !required
              ? () => _moveColumnTo(key, UtenColumnHeaderMove.back)
              : null,
        ),
      ),
      ...platformColumnHeaderDeleteEntries(context, _platform, key),
    ];
  }

  // —— 列宽自动适配 / 手动拖拽 常量 ——
  /// 拖拽命中区半宽：以列右边界为中心、半溢出到相邻列，便于精准抓住边界。
  static const double _gripHalf = 4;

  /// 列宽下限（自动适配与拖拽收窄共同下限，防止列被拖没）。
  static const double _minColWidth = 48;

  double _minimumColumnWidth(BuildContext context, MasterColumnDef<T> column) {
    final minimum = column.minimumWidthOf?.call(context) ?? _minColWidth;
    assert(minimum.isFinite && minimum >= 0);
    // Fixed header controls must also fit after a manual resize. In particular,
    // locally sorted server pages add guidance even without column.info.
    final headerControls =
        _cellPadX * 2 +
        _headerIconAllowance +
        (_headerInfo(column) != null ? _headerInfoWidth(context) : 0) +
        (_presentationPinnedKeys.contains(column.key) ? _pinIconAllowance : 0);
    return math.max(math.max(_minColWidth, minimum), headerControls);
  }

  String? _headerInfo(MasterColumnDef<T> column) {
    final messages = [
      if (column.info != null) column.info!,
      if (_serverPaged &&
          !_serverSearchFor(column.key) &&
          column.supportsKeywordSearch)
        '关键词搜索在当前已加载的数据中匹配；继续加载会加入新的匹配行。',
      if (_serverPaged && widget.onSortChange == null && column.sortable)
        '排序仅影响当前已加载的数据；继续加载或更改查询会改变此范围。',
    ];
    return messages.isEmpty ? null : messages.join('\n');
  }

  double _headerInfoWidth(BuildContext context) =>
      UtenControlMetrics.minimumHitExtent(context, desktop: 32) +
      UtenSpacing.s4;

  double _columnHorizontalPadding(
    BuildContext context,
    MasterColumnDef<T> column,
  ) {
    final padding = column.cellHorizontalPaddingOf?.call(context) ?? _cellPadX;
    assert(padding.isFinite && padding >= 0);
    return padding;
  }

  /// 列宽自动适配上限：超长文本（如备注）默认按此截断+省略号，用户可再拖宽。
  static const double _maxColWidth = 480;

  static const double _cellPadX = UtenSpacing.s12; // 单元格左右内边距（表头/表体一致）
  static const double _headerIconAllowance = 24; // 表头统一菜单图标 + 富余

  /// 固定列标签前的图钉占宽（18 图标 + 4 间距，2026-09-25）。
  static const double _pinIconAllowance = 22;
  static const double _autoFitBuffer = 6; // 防贴边 ellipsis 富余

  /// 多选前导勾选列宽（合成单元格，不计入 _columns / 列宽自动适配 / 列显隐）。
  static const double _selectionColWidth = 48;

  @override
  void initState() {
    super.initState();
    widget.appendRowsSource?.addListener(_appendRowsChanged);
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
    _headerH = UtenTableHorizontalScrollController(
      leadingInset: () => _pinnedLeadingWidth(_pinnedVisibleIndices),
      fallbackLeadingInset: () => _hasSelectionColumn ? _selectionColWidth : 0,
      trailingInset: () => widget.showColumnChooser ? 48 : 0,
    );
    _columnOrder = _columns.map((c) => c.key).toList();
    _hiddenKeys.addAll(
      _columns.where((c) => !c.defaultVisible).map((c) => c.key),
    );
    _normalizeRequiredLeadingColumns();
    _bodyH = UtenTableHorizontalScrollController(
      leadingInset: () => _pinnedLeadingWidth(_pinnedVisibleIndices),
      fallbackLeadingInset: () => _hasSelectionColumn ? _selectionColWidth : 0,
      trailingInset: () => widget.showColumnChooser ? 48 : 0,
    );
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
    _searchLifecycle.attach(context);
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
    // Resume an already-armed, successful explicit pager's one-shot buffer
    // after a popup closes. Initial layout never arms a buffer token.
    _scheduleExplicitBuffer();
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
      final previousBudget = (
        _floatingBatchHeightLimit,
        _floatingBatchMinimumTableHeight,
        _floatingBatchMeasuredHeight,
        _bodyBottomPad,
      );
      _updateFloatingBatchGeometry();
      _updateBodyPad();
      final currentBudget = (
        _floatingBatchHeightLimit,
        _floatingBatchMinimumTableHeight,
        _floatingBatchMeasuredHeight,
        _bodyBottomPad,
      );
      // The fullscreen surface is built in a separate route. setState above
      // rebuilds this route's placeholder, not that surface. Notify it only
      // after an actual budget change; ordinary scroll ticks do not rebuild it.
      if (_fullscreen &&
          _fullscreenOwner != null &&
          previousBudget != currentBudget) {
        _fsTick.value++;
      }
    });
  }

  double _minimumFloatingBatchHeight(BuildContext context) =>
      math.max(
        UtenControlMetrics.minimumHitExtent(
          context,
          desktop: context.scaled(UtenFloatingActionGroup.controlHeight),
        ),
        _floatingBatchMinimumContentHeight,
      ) +
      UtenSpacing.s8 +
      _capsuleOcclusion;

  void _onFloatingBatchMinimumContentHeightChanged(double height) {
    if (!mounted ||
        (_floatingBatchMinimumContentHeight - height).abs() <= 0.5) {
      return;
    }
    setState(() => _floatingBatchMinimumContentHeight = height);
    _scheduleHBarUpdate();
  }

  void _updateFloatingBatchGeometry() {
    if (!_usesBoundedFloatingBatchActions) {
      _clearFloatingBatchAncestors();
      _floatingBatchBottomInset.value = null;
      if (_floatingBatchHeightLimit != null ||
          _floatingBatchMinimumTableHeight != 0 ||
          _floatingBatchMeasuredHeight != 0 ||
          _floatingBatchMinimumContentHeight != 0) {
        setState(() {
          _floatingBatchHeightLimit = null;
          _floatingBatchMinimumTableHeight = 0;
          _floatingBatchMeasuredHeight = 0;
          _floatingBatchRowScope = null;
          _floatingBatchMeasuredRowHeight = 0;
          _floatingBatchMinimumContentHeight = 0;
        });
      }
      return;
    }
    final area = _bodyAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final chrome =
        _tableChromeKey.currentContext?.findRenderObject() as RenderBox?;
    final group =
        _floatingBatchKey.currentContext?.findRenderObject() as RenderBox?;
    if (group == null) {
      _clearFloatingBatchAncestors();
      _floatingBatchBottomInset.value = null;
      if (_floatingBatchHeightLimit != null ||
          _floatingBatchMinimumTableHeight != 0 ||
          _floatingBatchMeasuredHeight != 0 ||
          _floatingBatchMinimumContentHeight != 0) {
        setState(() {
          _floatingBatchHeightLimit = null;
          _floatingBatchMinimumTableHeight = 0;
          _floatingBatchMeasuredHeight = 0;
          _floatingBatchMinimumContentHeight = 0;
          _floatingBatchRowScope = null;
          _floatingBatchMeasuredRowHeight = 0;
        });
      }
      return;
    }
    if (area == null ||
        chrome == null ||
        !area.attached ||
        !chrome.attached ||
        !group.attached ||
        !area.hasSize ||
        !chrome.hasSize ||
        !group.hasSize) {
      return;
    }
    final ancestorPositions = <ScrollPosition>{};
    _bodyAreaKey.currentContext?.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final scrollable = element.state as ScrollableState;
        if (scrollable.position.axis == Axis.vertical) {
          ancestorPositions.add(scrollable.position);
        }
      }
      return true;
    });
    for (final position in _floatingBatchAncestorPositions.difference(
      ancestorPositions,
    )) {
      position.removeListener(_scheduleHBarUpdate);
    }
    for (final position in ancestorPositions.difference(
      _floatingBatchAncestorPositions,
    )) {
      position.addListener(_scheduleHBarUpdate);
    }
    _floatingBatchAncestorPositions
      ..clear()
      ..addAll(ancestorPositions);
    final visible = utenVisiblePaintRect(area);
    final inset = visible == null || visible.isEmpty
        ? null
        : (area.size.height - visible.bottom)
              .clamp(0.0, area.size.height)
              .toDouble();
    if (_floatingBatchBottomInset.value != inset) {
      _floatingBatchBottomInset.value = inset;
    }
    final body = Theme.of(context).textTheme.bodyMedium;
    final rowScope = (
      area.size.width,
      MediaQuery.textScalerOf(context),
      Object.hashAll(_widths),
      body,
      _floatingBatchDataRevision,
      Object.hashAllUnordered(
        _rowFilters.entries.map((entry) => Object.hash(entry.key, entry.value)),
      ),
      _localSortColumn,
      _localSortAscending,
      Object.hashAllUnordered(_expandedGroups),
    );
    if (_floatingBatchRowScope != rowScope) {
      _floatingBatchRowScope = rowScope;
      _floatingBatchMeasuredRowHeight = 0;
    }
    var row = math.max(
      UtenEditableGridCellSpec.heightOf(context),
      MediaQuery.textScalerOf(context).scale(body?.fontSize ?? 14) *
              (body?.height ?? 1.5) +
          UtenSpacing.s16,
    );
    final last = _lastRowKey.currentContext?.findRenderObject() as RenderBox?;
    if (last != null && last.attached && last.hasSize) {
      _floatingBatchMeasuredRowHeight = math.max(
        _floatingBatchMeasuredRowHeight,
        last.size.height,
      );
    }
    // A virtualized last row disappearing during scroll must not shrink the
    // reserved row and repeatedly resize the action viewport.
    row = math.max(row, _floatingBatchMeasuredRowHeight);
    final minimumActions = _minimumFloatingBatchHeight(context);
    final requiredRows = row + _hBarGap + minimumActions + UtenSpacing.s16;
    // The offset measures only actual chrome. Subtracting body height from a
    // loose Column would count spare whitespace and cause a growing feedback loop.
    final leading = area.localToGlobal(Offset.zero, ancestor: chrome).dy;
    final minimumTable = math.max(0.0, leading) + requiredRows;
    final limit = math.max(
      minimumActions,
      math.min(
        UtenFloatingActionGroup.scrollClearance,
        (visible?.height ?? area.size.height) -
            row -
            _hBarGap -
            UtenSpacing.s16,
      ),
    );
    final measured = group.size.height;
    if ((_floatingBatchHeightLimit == null ||
            (_floatingBatchHeightLimit! - limit).abs() > 0.5) ||
        (_floatingBatchMinimumTableHeight - minimumTable).abs() > 0.5 ||
        (_floatingBatchMeasuredHeight - measured).abs() > 0.5) {
      setState(() {
        _floatingBatchHeightLimit = limit;
        _floatingBatchMinimumTableHeight = minimumTable;
        _floatingBatchMeasuredHeight = measured;
      });
    }
  }

  void _clearFloatingBatchAncestors() {
    for (final position in _floatingBatchAncestorPositions) {
      position.removeListener(_scheduleHBarUpdate);
    }
    _floatingBatchAncestorPositions.clear();
  }

  /// 滚动留白独立于横滚条：悬浮动作取共享留白，页面可再提供更大的让位空间。
  void _updateBodyPad() {
    // 即使内容刚好装得下，也要允许把最后一行滚到操作区上方。
    // 本地浮条的实测总高已经含胶囊避让，只补底距和横滚条间隙；
    // 页面自带的 floor 仍另外按胶囊抬升，两者取最大值，不重复叠加。
    final base =
        _usesBoundedFloatingBatchActions &&
            _floatingBatchKey.currentContext == null
        ? math.max(widget.bottomContentPadding, _hBarGap) + _capsuleOcclusion
        : _usesBoundedFloatingBatchActions && _floatingBatchMeasuredHeight > 0
        ? math.max(
            widget.bottomContentPadding + _capsuleOcclusion,
            _floatingBatchMeasuredHeight + UtenSpacing.s16 + _hBarGap,
          )
        : (_hasFloatingBatchActions ? _batchPad : _hBarGap).clamp(
                widget.bottomContentPadding,
                double.infinity,
              ) +
              _capsuleOcclusion;
    final next =
        _usesBoundedFloatingBatchActions && _floatingBatchMeasuredHeight > 0
        ? math.max(
            base,
            _floatingBatchMeasuredHeight +
                UtenSpacing.s16 +
                _hBarGap +
                (_floatingBatchBottomInset.value ?? 0),
          )
        : base;
    if (next != _bodyBottomPad) setState(() => _bodyBottomPad = next);
  }

  /// 末行可量时贴实际末行，始终只保留滑块自身的间距；末行未挂载时钉视口底。
  /// 顶部卡片折叠/展开改变区高、翻页/筛选改变内容高，都会经 LayoutBuilder 重建
  /// 触发重测。（不能用 maxScrollExtent+viewportDimension：primary 表体被强制
  /// 填满联动区，量出来恒等于区高。）
  void _updateHBar() {
    // 空表不定位覆盖层：post-frame 量测会把 _hBarY 拉回非 null，而 Offstage
    // 只是显示兜底——ValueNotifier 状态也须归位，否则空表换有数据前一直挂着
    // 悬浮条状态。提示行（加载/错误）同样不需要横滚条（见 _hasRowContent）。
    if (!_hasRowContent) {
      if (_hBarY.value != null) _hBarY.value = null;
      return;
    }
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

  bool _sameTextSelectionRows(MasterDataTableView<T> before) {
    if (!_sameColumnKeys(before.columns, widget.columns)) return false;
    bool sameRows(List<T> previous, List<T> current) {
      if (listEquals(previous, current)) return true;
      if (previous.length != current.length) return false;
      for (var i = 0; i < previous.length; i++) {
        if (before.idOf?.call(previous[i]) != widget.idOf?.call(current[i]) ||
            before.rowKeyOf?.call(previous[i]) !=
                widget.rowKeyOf?.call(current[i])) {
          return false;
        }
        for (var column = 0; column < widget.columns.length; column++) {
          if (before.columns[column].value(previous[i]) !=
              widget.columns[column].value(current[i])) {
            return false;
          }
        }
      }
      return true;
    }

    if (!sameRows(before.items, widget.items)) return false;
    final previousGroups = before.leadingGroups ?? const [];
    final currentGroups = widget.leadingGroups ?? const [];
    if (identical(previousGroups, currentGroups)) return true;
    if (previousGroups.length != currentGroups.length) return false;
    for (var i = 0; i < previousGroups.length; i++) {
      final previous = previousGroups[i];
      final current = currentGroups[i];
      if (previous.id != current.id ||
          previous.title != current.title ||
          previous.subtitle != current.subtitle ||
          !sameRows(previous.items, current.items)) {
        return false;
      }
    }
    return true;
  }

  @override
  void didUpdateWidget(covariant MasterDataTableView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appendRowsSource != widget.appendRowsSource) {
      oldWidget.appendRowsSource?.removeListener(_appendRowsChanged);
      widget.appendRowsSource?.addListener(_appendRowsChanged);
    }
    // A host may edit a row in place before rebuilding. Retire computed views
    // even when the List and column callbacks retained their identities.
    _displayRowsSource = null;
    _rowFacetScope = null;
    // 拖拽能力被宿主摘除（如切到只读态）：就地取消进行中的拖拽。
    if (widget.rowDrag == null && _dragActive) _cancelRowDrag();
    if (!widget.enableTextSelection ||
        oldWidget.paginationScope != widget.paginationScope ||
        oldWidget.paginationRevision != widget.paginationRevision ||
        !_sameTextSelectionRows(oldWidget)) {
      _textSelection.clear();
    }
    if (!identical(oldWidget.items, widget.items) ||
        !identical(oldWidget.leadingGroups, widget.leadingGroups) ||
        oldWidget.paginationRevision != widget.paginationRevision ||
        oldWidget.paginationScope != widget.paginationScope) {
      _floatingBatchRowScope = null;
      _floatingBatchMeasuredRowHeight = 0;
    }
    if (!identical(oldWidget.rowsController, widget.rowsController)) {
      oldWidget.rowsController?.detachPagination(this);
    }
    final appended = _updatePages(oldWidget);
    if (_queryChanged ||
        widget.paginationScope != _explicitBufferScope ||
        widget.error != null) {
      _cancelExplicitBuffer();
    } else if (_explicitBufferToken != null &&
        widget.currentPage == _explicitBufferPage &&
        !widget.loadingMore &&
        !widget.isLoading &&
        (oldWidget.currentPage != widget.currentPage ||
            oldWidget.loadingMore ||
            oldWidget.isLoading ||
            !identical(oldWidget.items, widget.items) ||
            oldWidget.paginationRevision != widget.paginationRevision)) {
      _explicitBufferDataAccepted = true;
    }
    if (appended) {
      // An endpoint belongs to the loaded window that the user visited.
      // Appending a response must keep that viewport, not follow the new end.
      _deferredLeadingEdge = false;
      _deferredTrailingEdge = false;
    }
    _configurePlatform();
    if (!listEquals(
      oldWidget.temporaryLeadingColumnKeys,
      widget.temporaryLeadingColumnKeys,
    )) {
      _widthsDirty = true;
      _scheduleHBarUpdate();
    }
    // 包括 200 -> 0 / 移除悬浮动作：新布局不再启用覆盖层时也必须撤掉旧留白。
    if (oldWidget.bottomContentPadding != widget.bottomContentPadding ||
        oldWidget.primary != widget.primary ||
        oldWidget.selectable != widget.selectable ||
        oldWidget.showSelectionColumn != widget.showSelectionColumn ||
        (oldWidget.batchActionsBuilder == null) !=
            (widget.batchActionsBuilder == null)) {
      _scheduleHBarUpdate();
    }
    // 列集合变了（数量或 key 序列不同，如报表切 docType）→ 清手动标记、全量重算列宽。
    if (!_sameColumnKeys(oldWidget.columns, widget.columns)) {
      _inputWidthGeneration++;
      _inputWidthRequests.clear();
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
      _widthGrowthPool = null;
      _widthGrowthTarget = null;
      _widthGrowthOffset = 0;
      _widthGrowthColumn = 0;
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
    final requestedReveal = widget.revealRequest != oldWidget.revealRequest;
    if (requestedReveal) {
      _deferredLeadingEdge = false;
      _deferredTrailingEdge = false;
      _pendingRevealId = widget.revealItemId;
      _revealAttempts = 0;
    }
    if (requestedEnd) {
      _deferredLeadingEdge = false;
      _deferredTrailingEdge = false;
      _pendingScrollToEnd = widget.scrollToEndRequest;
      _scrollToEndAttempts = 0;
    } else if ((!appended && oldWidget.currentPage != widget.currentPage) ||
        oldWidget.paginationScope != widget.paginationScope ||
        widget.scrollToEndRequest == 0) {
      _pendingScrollToEnd = null;
    }
    if (!appended &&
        !requestedEnd &&
        !requestedReveal &&
        (oldWidget.currentPage != widget.currentPage || _queryChanged)) {
      _schedulePageStart();
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
    _scheduleExplicitBuffer();
  }

  /// 全屏切换：进入时弹全屏路由（正常树让位）；全屏里再点「退出全屏」pop 该路由。
  /// 同一个 keyed surface 在 pop 时同帧交还正常树，全屏 route 同时退为空占位。
  /// 等到 dispose 后才挂回会先销毁行输入 State；保留两份表格则会双挂滚动位置。
  Future<void> _toggleFullscreen() async {
    // 切全屏会换渲染树，进行中的拖拽手势可能不再回调 onEnd，浮层 target 也在旧树，
    // 统一重置卸下（FM6）。
    columnHeaderDragReset();
    if (_fullscreen) {
      // PopScope 同帧交还表面，再由路由完成退出。
      final route = _fullscreenRoute;
      final navigator = route?.navigator;
      if (route != null && navigator != null && route.isCurrent) {
        navigator.pop();
      } else {
        _removeFullscreenPresentation();
      }
      return;
    }
    final sourceController = _verticalScrollController;
    final sourceOffset = sourceController?.hasClients == true
        ? sourceController!.position.pixels
        : 0.0;
    final owner = Object();
    setState(() {
      _fullscreen = true;
      _fullscreenOwner = owner;
    });
    void returnSurface() {
      if (!mounted || !identical(_fullscreenOwner, owner)) return;
      final targetOffset = _bodyV.hasClients
          ? _bodyV.position.pixels
          : sourceOffset;
      setState(() {
        _fullscreen = false;
        _fullscreenOwner = null;
        _fullscreenRoute = null;
        _returnFullscreenSurface = null;
      });
      _fsTick.value++;
      _restoreFullscreenScroll(targetOffset, fullscreen: false);
      widget.onFullscreenChanged?.call(false);
    }

    final route = RawDialogRoute<void>(
      barrierDismissible: false,
      barrierLabel: '全屏表格', // TODO(l10n): 补 arb
      barrierColor: Colors.transparent, // 内容整屏不透明，无需遮罩色
      pageBuilder: (ctx, _, _) => _FullscreenDisposer(
        // 异常移除 route 的兜底只属于本次全屏，不能关闭后来打开的表面。
        onDisposed: () {
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            returnSurface();
          });
        },
        child: PopScope<void>(
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) returnSurface();
          },
          child: ValueListenableBuilder<int>(
            valueListenable: _fsTick,
            builder: (ctx2, _, _) {
              if (!identical(_fullscreenOwner, owner)) {
                return const SizedBox.shrink();
              }
              final theme = Theme.of(ctx2);
              return Material(
                color: theme.colorScheme.surface,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: _searchLifecycle.wrap(
                      _buildBoundedPresentation(ctx2),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    _fullscreenRoute = route;
    _returnFullscreenSurface = returnSurface;
    widget.onFullscreenChanged?.call(true);
    _restoreFullscreenScroll(sourceOffset, fullscreen: true);
    await Navigator.of(context, rootNavigator: true).push<void>(route);
  }

  void _removeFullscreenPresentation() {
    final route = _fullscreenRoute;
    final returnSurface = _returnFullscreenSurface;
    if (route == null) return;
    // GoRouter can leave a Shell child while this presentation still owns the
    // root Navigator's top route. Remove this exact route after the tree unlocks;
    // popping the current root route could dismiss the newly opened detail.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      returnSurface?.call();
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _restoreFullscreenScroll(double offset, {required bool fullscreen}) {
    final epoch = ++_fullscreenScrollEpoch;
    final scope = widget.paginationScope;
    final page = _currentPage;
    var attempts = 0;
    void schedule() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            epoch != _fullscreenScrollEpoch ||
            _fullscreen != fullscreen ||
            widget.paginationScope != scope ||
            _currentPage != page) {
          return;
        }
        final controller = _verticalScrollController;
        if (controller == null ||
            !controller.hasClients ||
            !controller.position.hasContentDimensions) {
          if (++attempts < 4) schedule();
          return;
        }
        final position = controller.position;
        controller.jumpTo(
          offset.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      });
    }

    schedule();
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
    final scale = textScaler;
    final hasRichWidth = _columns.any(
      (column) => column.measureWidthOf != null,
    );
    var typographyChanged = false;
    if (hasRichWidth) {
      final style = Theme.of(context).textTheme.bodyMedium;
      if (style != _lastRichWidthStyle &&
          (style == null ||
              _lastRichWidthStyle == null ||
              _lastRichWidthStyle!.compareTo(style) ==
                  RenderComparison.layout)) {
        _richWidthStyleRevision++;
        typographyChanged = true;
      }
      _lastRichWidthStyle = style;
    }
    final richContext = hasRichWidth
        ? (
            _richWidthStyleRevision,
            Directionality.of(context),
            UtenControlMetrics.minimumHitExtent(context, desktop: 48),
          )
        : null;
    final richScopes = [
      for (final column in _columns)
        (
          column.measureWidthScope ?? column.measureWidthOf,
          column.measureWidthOf == null ? null : richContext,
        ),
    ];
    if (!listEquals(richScopes, _lastRichWidthScopes)) {
      _lastRichWidthScopes = richScopes;
      _widthsDirty = true;
      _textMeasures.clear();
    }
    final minimums = [
      for (final column in _columns) _minimumColumnWidth(context, column),
    ];
    final padding = [
      for (final column in _columns) _columnHorizontalPadding(context, column),
    ];
    if (!listEquals(minimums, _lastColumnMinimums) ||
        !listEquals(padding, _lastColumnPadding)) {
      _widthsDirty = true;
      _lastColumnMinimums = minimums;
      _lastColumnPadding = padding;
    }
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
    _widthGrowthPool = null;
    _widthGrowthTarget = null;
    _widthGrowthOffset = 0;
    _widthGrowthColumn = 0;
    final keys = [for (final column in _columns) column.key];
    final preserveWidths =
        !_resetAutoWidths &&
        !typographyChanged &&
        _lastScale == scale &&
        listEquals(keys, _widthColumnKeys);
    _lastScale = scale;
    _widthColumnKeys = keys;
    final pool = _widthSamplePool();
    // First layout measures headers only. Even 256 cells can spend hundreds
    // of milliseconds shaping rich Chinese text; the tail is time-budgeted.
    final sample = <T>[];
    final next = List<double>.filled(
      _columns.length,
      _minColWidth,
      growable: true,
    );
    for (var i = 0; i < _columns.length; i++) {
      if (_manualResized.contains(i) && i < _widths.length) {
        next[i] = math.max(minimums[i], _widths[i]);
        continue;
      }
      final def = _columns[i];
      next[i] = _fitColumnWidth(
        context,
        def,
        _measureColumn(context, def, sample, textScaler),
      );
      // Geometry updates (especially tree expansion) must not collapse an
      // already measured column back to its header before the budgeted scan.
      if (preserveWidths &&
          !_resetWidthKeys.contains(def.key) &&
          i < _widths.length) {
        next[i] = math.max(next[i], _widths[i]);
      }
    }
    _resetAutoWidths = false;
    _resetWidthKeys.clear();
    _widths = next;
    if (pool.isNotEmpty) {
      _widthGrowthPool = pool;
      _widthGrowthOffset = 0;
      _widthGrowthColumn = 0;
      _widthGrowthPending = true;
      _scheduleWidthGrowth();
    }
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
    final measure = _textMeasures.putIfAbsent(def.key, _ColumnTextMeasure.new);
    if (!measure.headerMeasured) {
      measure.header = _measureText(
        def.label,
        UtenTableHeader.textStyle(Theme.of(context)),
        textScaler,
      );
      measure.headerMeasured = true;
    }
    // 去重集合只防重复量同一串；过大时清掉(最大宽度已记下，不影响结果)。
    if (measure.seen.length > 4000) measure.seen.clear();
    for (var r = 0; r < pool.length; r++) {
      final text = (def.measureValueOf ?? def.value)(pool[r]) ?? '';
      if (text.isEmpty || !measure.seen.add(text)) continue;
      double width;
      if (def.measureWidthOf case final measureWidth?) {
        width = measureWidth(context, pool[r], textScaler);
      } else {
        final bodyStyle =
            Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
        // Status/progress values use the same bold geometry as their cells.
        final style = utenIsStatusOrProgressColumn(def.key, def.label)
            ? bodyStyle.copyWith(fontWeight: FontWeight.w700)
            : bodyStyle;
        width = _measureText(text, style, textScaler);
      }
      measure.bodyRevision++;
      if (width > measure.body) measure.body = width;
    }
    return measure;
  }

  /// Fit the widest loaded value and the complete header independently. Header
  /// icons do not add empty room to a body value that is already wider.
  double _fitColumnWidth(
    BuildContext context,
    MasterColumnDef<T> def,
    _ColumnTextMeasure measure,
  ) {
    final minimum = _minimumColumnWidth(context, def);
    final maximum = math.max(minimum, _maxColWidth);
    final padding = math.max(_cellPadX, _columnHorizontalPadding(context, def));
    final header =
        measure.header +
        _headerIconAllowance +
        (_headerInfo(def) != null ? _headerInfoWidth(context) : 0) +
        (_presentationPinnedKeys.contains(def.key) ? _pinIconAllowance : 0);
    final text = math.max(header, measure.body);
    final measured = (text + padding * 2 + _autoFitBuffer).clamp(
      minimum,
      maximum,
    );
    if (def.cellBuilder == null || def.minimumWidthOf != null) return measured;
    // A custom cell may contain multiple controls beyond its textual value.
    // Preserve its declared fallback until it supplies an actual minimum.
    return math.max(measured, def.width.clamp(minimum, maximum));
  }

  /// 数据刷新后的增量量宽：挪到本帧之后执行，只量新出现的值；有列需要加宽才重建一次。
  void _scheduleWidthGrowth() {
    if (_widthGrowthScheduled) return;
    _widthGrowthScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _widthGrowthScheduled = false;
      if (!mounted || !_widthGrowthPending) return;
      final textScaler = MediaQuery.textScalerOf(context);
      if (_widthsDirty ||
          _lastScale != textScaler ||
          _widths.length != _columns.length) {
        setState(() => _widthsDirty = true);
        if (_fullscreen) _fsTick.value++;
        return;
      }
      final pool = _widthGrowthPool ??= _widthSamplePool();
      final clock = Stopwatch()..start();
      var measuredCells = 0;
      final next = _widthGrowthTarget ??= List<double>.of(_widths);
      while (_widthGrowthOffset < pool.length && _columns.isNotEmpty) {
        final i = _widthGrowthColumn;
        final row = pool[_widthGrowthOffset];
        // Advance before doing caller-supplied measurement. Every accepted
        // cell is visited once, including a partial row at a slice boundary.
        _widthGrowthColumn++;
        if (_widthGrowthColumn == _columns.length) {
          _widthGrowthColumn = 0;
          _widthGrowthOffset++;
        }
        if (!_manualResized.contains(i)) {
          final def = _columns[i];
          final previous = _textMeasures[def.key]?.bodyRevision ?? 0;
          final measure = _measureColumn(context, def, [row], textScaler);
          if (measure.bodyRevision != previous) {
            measuredCells++;
            final fitted = _fitColumnWidth(context, def, measure);
            if (fitted > next[i] + 0.5) {
              next[i] = fitted;
            }
          }
        }
        // Cached/manual cells do not spend shaping slots. The elapsed limit
        // still applies to every visited cell, including cache-only scans.
        if (measuredCells >= _widthMeasureCellBudget ||
            clock.elapsed >= _widthMeasureTimeBudget) {
          break;
        }
      }
      _widthGrowthPending =
          _columns.isNotEmpty && _widthGrowthOffset < pool.length;
      if (_widthGrowthPending) {
        _scheduleWidthGrowth();
        WidgetsBinding.instance.ensureVisualUpdate();
      } else {
        // Publish one complete geometry update, while scanning still yields
        // every 2ms. Multiple partial widths would relayout every visible row
        // on every slice and make an expanding tree visibly ratchet sideways.
        var grown = false;
        final published = List<double>.of(_widths);
        for (var i = 0; i < published.length; i++) {
          if (!_manualResized.contains(i) && next[i] > published[i] + .5) {
            published[i] = next[i];
            grown = true;
          }
        }
        if (grown) {
          setState(() => _widths = published);
          if (_fullscreen) _fsTick.value++;
        }
        _widthGrowthPool = null;
        _widthGrowthTarget = null;
        _widthGrowthOffset = 0;
        _widthGrowthColumn = 0;
      }
    });
  }

  void _requestInputWidth(
    String columnKey,
    double contentWidth,
    int generation,
  ) {
    if (!mounted ||
        generation != _inputWidthGeneration ||
        !contentWidth.isFinite ||
        contentWidth <= 0) {
      return;
    }
    final index = _columns.indexWhere((column) => column.key == columnKey);
    if (index < 0 ||
        index >= _widths.length ||
        _manualResized.contains(index)) {
      return;
    }
    final column = _columns[index];
    final minimum = _minimumColumnWidth(context, column);
    // Container 的竖向格线也占内侧宽度；不能让同一输入因最后半像素反复加宽。
    final width =
        (contentWidth + _columnHorizontalPadding(context, column) * 2 + 0.5)
            .clamp(minimum, math.max(minimum, _maxColWidth))
            .toDouble();
    if (width <= _widths[index] + 0.5) return;
    _inputWidthRequests.update(
      columnKey,
      (previous) => math.max(previous, width),
      ifAbsent: () => width,
    );
    if (_inputWidthGrowthScheduled) return;
    _inputWidthGrowthScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inputWidthGrowthScheduled = false;
      if (!mounted || _inputWidthRequests.isEmpty) return;
      final requests = Map<String, double>.of(_inputWidthRequests);
      _inputWidthRequests.clear();
      final next = List<double>.of(_widths);
      var grown = false;
      for (final request in requests.entries) {
        final index = _columns.indexWhere(
          (column) => column.key == request.key,
        );
        if (index < 0 ||
            index >= next.length ||
            _manualResized.contains(index)) {
          continue;
        }
        if (request.value > next[index] + 0.5) {
          next[index] = request.value;
          grown = true;
        }
      }
      if (grown) {
        setState(() => _widths = next);
        if (_fullscreen) _fsTick.value++;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
  void deactivate() {
    _cancelRowDrag(rebuild: false);
    super.deactivate();
  }

  @override
  void dispose() {
    _readWindowBinding?.detachPresentation(_readWindowOwner);
    widget.appendRowsSource?.removeListener(_appendRowsChanged);
    _removeFullscreenPresentation();
    // 拖拽中表被卸载（翻页/切路由）：清计时器、键监听与幽灵卡，防止悬挂。
    _searchLifecycle.dispose();
    _textSelection.dispose();
    _dragAutoScroll?.cancel();
    _dragHoverTimer?.cancel();
    _dragRetracking?.cancel();
    _rowDragLifecycle?.dispose();
    _rowDragLifecycle = null;
    _dragGhost?.remove();
    _dragGhost = null;
    _dragPointerPos.dispose();
    _dragIndicator.dispose();
    _dragOriginKey.dispose();
    widget.rowsController?.detachPagination(this);
    _projection?.remove(this);
    _aiSlot.detach();
    _platform.dispose();
    // 跟手浮层/拖拽态由 UtenColumnDragHideHost.dispose（super 链）统一卸除。
    _fsTick.dispose();
    _headerH.dispose();
    _bodyH.dispose();
    _bodyV.dispose();
    for (final controller in _borrowedPrimaryControllers.values) {
      controller.dispose();
    }
    _overlayH.dispose();
    _hBarY.dispose();
    _clearFloatingBatchAncestors();
    _floatingBatchBottomInset.dispose();
    _pageCtrl.dispose();
    _pageFocus.dispose();
    _stickyPagePos?.removeListener(_onStickyPageScroll);
    _sticky?.dispose();
    super.dispose();
  }

  double get _totalWidth {
    var s = _hasSelectionColumn ? _selectionColWidth : 0.0;
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
    final hidden = _presentationHiddenKeys;
    return [
      for (final key in _presentationColumnOrder)
        if (byKey.containsKey(key) && !hidden.contains(key)) byKey[key]!,
    ];
  }

  /// 可见列数（至少 1：[_toggleColumn] 拦住最后一列的隐藏）。
  int get _visibleCount => _columns.length - _presentationHiddenKeys.length;

  /// 切换单列显隐：最后一列不允许隐藏，避免表格没列；隐藏固定列时同时解除固定
  ///（固定列必须在可见序列里，「看不见的固定列」没有意义）。
  void _toggleColumn(String key) {
    if (_isRequiredLeading(key)) return;
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
      final temporary = _temporaryLeadingKeys.toSet();
      final retainedHidden = _hiddenKeys.intersection(temporary);
      _hiddenKeys.clear();
      if (!selectAll && _columns.length > 1) {
        final retained = _requiredLeadingKeys.toSet();
        if (retained.isEmpty) {
          retained.add(
            _columns
                .firstWhere(
                  (column) => !temporary.contains(column.key),
                  orElse: () => _columns.first,
                )
                .key,
          );
        }
        _hiddenKeys.addAll(
          _columns
              .where(
                (column) =>
                    !retained.contains(column.key) &&
                    !temporary.contains(column.key),
              )
              .map((c) => c.key),
        );
      }
      _hiddenKeys.addAll(retainedHidden);
      _pinnedKeys.removeWhere(_hiddenKeys.contains);
      _pinOriginIndex.removeWhere((k, _) => _hiddenKeys.contains(k));
      _normalizeRequiredLeadingColumns();
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

  /// 本表是否实际渲染行首勾选框列（宽 [_selectionColWidth]）。
  /// [MasterDataTableView.showSelectionColumn]=false 的纯阅读勾选表不画列，
  /// 选中语义（单击切勾选/高亮/已选胶囊）不受影响。
  bool get _hasSelectionColumn =>
      widget.selectable && widget.showSelectionColumn;

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
  Widget _boundStretchRow(Widget row, {double? knownHeight}) =>
      widget.selectable
      ? knownHeight != null
            ? SizedBox(height: knownHeight, child: row)
            : IntrinsicHeight(
                child: debugUiWorkSliceObserver == null
                    ? row
                    : _MasterStretchLayoutProbe(child: row),
              )
      : row;

  TextStyle? _plainRowStyle;
  TextScaler? _plainRowScaler;
  double? _plainRowTextHeight;
  ThemeData? _checkboxSourceTheme;
  ThemeData? _checkboxRowTheme;

  ThemeData _selectionCheckboxTheme(ThemeData source) {
    if (!identical(source, _checkboxSourceTheme)) {
      _checkboxSourceTheme = source;
      _checkboxRowTheme = source.copyWith(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
    }
    return _checkboxRowTheme!;
  }

  /// Default cells are single-line Text. Their real line height and checkbox
  /// minimum can be shared instead of walking every cell's intrinsic tree on
  /// every scroll frame. Rich controls retain their original measured path.
  double? _knownPlainRowHeight(ThemeData theme) {
    if (!widget.selectable ||
        widget.leadingOverlayBuilder != null ||
        widget.unselectableLeadingBuilder != null ||
        widget.rowDrag != null ||
        _platform.definitions.isNotEmpty ||
        widget.columns.any((column) => column.cellBuilder != null)) {
      return null;
    }
    final style = theme.textTheme.bodyMedium ?? const TextStyle();
    // An unspecified line height can vary with arbitrary fallback glyphs.
    if (style.height == null) return null;
    final scaler = MediaQuery.textScalerOf(context);
    if (_plainRowTextHeight == null ||
        _plainRowScaler != scaler ||
        _plainRowStyle == null ||
        _plainRowStyle!.compareTo(style) == RenderComparison.layout) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ag国한🙂', style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      _plainRowTextHeight = painter.height;
      painter.dispose();
      _plainRowStyle = style;
      _plainRowScaler = scaler;
    }
    final density =
        theme.checkboxTheme.visualDensity ??
        (theme.useMaterial3 ? VisualDensity.standard : theme.visualDensity);
    final checkbox = _hasSelectionColumn
        ? math.max(0.0, 40 + density.baseSizeAdjustment.dy)
        : 0.0;
    return math.max(
      checkbox,
      _plainRowTextHeight! + widget.dataCellVerticalPadding * 2,
    );
  }

  bool get _expensiveRowMounts =>
      widget.expensiveRowMounts ??
      (widget.listItemBuilder != null ||
          widget.platformCellDecorator != null ||
          widget.columns.any((column) => column.cellBuilder != null));

  /// Input-heavy rows keep their small buffer; ordinary browsing warms a few
  /// rows ahead in both directions, without mounting every loaded page.
  ScrollCacheExtent _rowScrollCache(BuildContext context) =>
      ScrollCacheExtent.pixels(
        _expensiveRowMounts
            ? (UtenEditableGridCellSpec.heightOf(context) + UtenSpacing.s16)
                  .clamp(32.0, 64.0)
            : 240.0,
      );

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
  Object? _rowFacetScope;
  final Map<String, ({List<MasterFacetBucket> buckets, int nullCount})>
  _rowFacetCache = {};

  ({List<MasterFacetBucket> buckets, int nullCount})? _rowFacetsFor(
    MasterColumnDef<T> def,
  ) {
    if (!def.filterFromRows || _serverPaged) return null;
    if ((widget.facets[def.key] ?? const []).isNotEmpty) return null;
    final scope = (_items, _columns);
    if (_rowFacetScope != scope) {
      _rowFacetScope = scope;
      _rowFacetCache.clear();
    }
    final cached = _rowFacetCache[def.key];
    if (cached != null) return cached;
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
    return _rowFacetCache[def.key] = (
      buckets: [
        for (final v in values) MasterFacetBucket(value: v, count: counts[v]!),
      ],
      nullCount: nullCount,
    );
  }

  /// 实际渲染/可勾选的行 = 宿主行 − 本地筛选命不中的行，再按本地排序整理。
  List<T>? _displayRowsSource;
  List<MasterColumnDef<T>>? _displayRowsColumns;
  Map<String, String?> _displayRowsFilters = const {};
  Map<String, String> _displayRowsSearches = const {};
  Object? _displayRowsSort;
  List<T> _displayRowsCache = const [];

  List<T> get _displayItems {
    final sort = (
      _localSortColumn,
      _localSortAscending,
      widget.onSortChange == null,
    );
    if (identical(_displayRowsSource, _items) &&
        identical(_displayRowsColumns, _columns) &&
        _displayRowsSort == sort &&
        mapEquals(_displayRowsFilters, _rowFilters) &&
        mapEquals(_displayRowsSearches, _columnSearches)) {
      return _displayRowsCache;
    }
    _displayRowsSource = _items;
    _displayRowsColumns = _columns;
    _displayRowsSort = sort;
    _displayRowsFilters = Map.of(_rowFilters);
    _displayRowsSearches = Map.of(_columnSearches);
    return _displayRowsCache = _applyRowView(_items);
  }

  List<T> _applyRowView(List<T> source) {
    var rows = source;
    if (_columnSearches.isNotEmpty) {
      final defs = _columnByKey;
      rows = rows
          .where(
            (item) => _columnSearches.entries.every((entry) {
              final def = defs[entry.key];
              return def == null ||
                  !def.supportsKeywordSearch ||
                  matchesKeywordSearch([def.value(item)], entry.value);
            }),
          )
          .toList();
    }
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
        // Resolve presentation and numeric units once per row, not twice for
        // every comparison. Keep blank-last and mixed numeric/text semantics.
        final values = rows.map((row) {
          final text = def.value(row)?.trim() ?? '';
          final number = weight
              ? _weightSortValue(text)
              : numeric
              ? _numericSortValue(text)
              : null;
          return (
            row: row,
            text: text,
            number: number,
            blank: text.isEmpty || text == '—' || (weight && number == null),
          );
        }).toList();
        values.sort((a, b) {
          if (a.blank && b.blank) return 0;
          if (a.blank) return 1;
          if (b.blank) return -1;
          int base;
          if (weight) {
            base = a.number!.compareTo(b.number!);
          } else if (numeric) {
            base = a.number == null || b.number == null
                ? a.text.compareTo(b.text)
                : a.number!.compareTo(b.number!);
          } else {
            base = a.text.compareTo(b.text);
          }
          return asc ? base : -base;
        });
        rows = values.map((entry) => entry.row).toList();
      }
    }
    return rows;
  }

  /// 内联计算、勿缓存到实例字段——全屏 post-frame 间隙会读到旧值。
  Set<String> _pageSelectableIds() => _profileMasterTableWork(
    'master.selection-ids',
    () => _withSelectionReadScope(_collectPageSelectableIds),
  );

  Set<String> _collectPageSelectableIds() {
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
  bool? _headerCheckValue(Set<String> pageIds) {
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
    // 单选互斥（行单击与勾选框同走这里）：勾选=集合只留本行，取消=清空——
    // 点击另一行时上一行自然失选。
    if (widget.singleSelection) {
      widget.onSelectedIdsChanged?.call(
        checked ? <String>{id} : const <String>{},
      );
      _fsTick.value++;
      return;
    }
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
    Widget cell = widget.selectable
        ? Align(alignment: Alignment.centerLeft, child: text)
        : text;
    if (widget.enableTextSelection && value.trim().isNotEmpty) {
      // 光标口径（2026-10-19 二轮）：SelectionArea 里的 Text 自带最内层光标
      // 区域，取最近的 DefaultSelectionStyle.mouseCursor；行 InkWell 会给子树
      // 注入 basic（Windows 上 InkWell 默认箭头），外层包 MouseRegion 赢不了它。
      // 就近注入 text → I 型光标只出现在字体本体上（Text 自带区域就那么大），
      // 单元格空白处仍是行的可点击光标、点击照常选中行。
      cell = DefaultSelectionStyle(
        mouseCursor: SystemMouseCursors.text,
        child: cell,
      );
    }
    return cell;
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
    final inputWidthGeneration = _inputWidthGeneration;
    final custom = MasterDataTableCellScope(
      selected: selected,
      foregroundColor: textStyle.color,
      child: UtenTableCellInputTheme(
        // 读表内联输入格与编辑表同源紧凑规格（2026-10-08 用户口径：全站表格
        // 输入格统一为盘点实盘格尺寸，UtenEditableGridCellSpec）。
        child: DefaultTextStyle.merge(
          style: textStyle,
          child: IconTheme.merge(
            data: IconThemeData(color: textStyle.color),
            child: UtenStatusCellScope(
              enabled: utenIsStatusColumn(column.key, column.label),
              child: UtenTableCellHints(
                child: UtenTableCellAutoWidth(
                  onWidthNeeded: (width) => _requestInputWidth(
                    column.key,
                    width,
                    inputWidthGeneration,
                  ),
                  child: Builder(
                    builder: (cellContext) => builder(cellContext, item),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final aligned = widget.selectable && !column.fillsCellHeight
        ? Align(alignment: Alignment.centerLeft, child: custom)
        : custom;
    // 自定义格同口径：格里有文本内容（value 非空）且框选开启时，就近注入
    // DefaultSelectionStyle(mouseCursor: text)——格内所有 Text 的自带光标区域
    // 都变成 I 型（只在字体本体上），压过行 InkWell 注入的 basic。
    // Keep the ancestor even when the source value is empty. The first saved
    // value must not replace an already activated editor's Element/focus.
    final cursorWrapped = DefaultSelectionStyle(
      mouseCursor:
          widget.enableTextSelection && value != null && value.isNotEmpty
          ? SystemMouseCursors.text
          : DefaultSelectionStyle.of(context).mouseCursor,
      child: aligned,
    );
    if (column.cellBuilderHandlesSemantics) return cursorWrapped;
    return Semantics(
      label: value == null || value.isEmpty
          ? column.label
          : '${column.label}: $value',
      child: cursorWrapped,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!UtenPanelOpeningScope.isReadyOf(context)) {
      return const UtenPanelOpeningPlaceholder();
    }
    _bindPagination();
    _bindReadWindow();
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
          _listPagerAbove(context),
          _buildTable(context),
          if (widget.summaryBar != null && !widget.summaryBarInline)
            _buildSummaryBar(context),
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
      if (sticky == null) return _wrapPresentation(embeddedColumn);
      return UtenStickyWheelGate(
        tracker: sticky,
        onEngage: _onStickyEngage,
        child: _wrapPresentation(embeddedColumn),
      );
    }
    return _buildBoundedPresentation(context);
  }

  Widget _wrapPresentation(Widget child) => KeyedSubtree(
    key: _presentationKey,
    child: Semantics(
      container: true,
      explicitChildNodes: true,
      child: UtenTableSurface(child: child),
    ),
  );

  /// 列表形态（picker 列表）没有表头工具条：分页单独钉在列表上方右角，
  /// 与表格工具条右端的分页同一位次（2026-10-18 分页上移口径）。
  /// 非列表形态/无分页时返回零尺寸占位，保持 Column children 恒非空。
  Widget _listPagerAbove(BuildContext context) {
    if (widget.listItemBuilder == null) return const SizedBox.shrink();
    final pager = _buildToolbarPager(context);
    if (pager == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Align(alignment: AlignmentDirectional.centerEnd, child: pager),
    );
  }

  Widget _buildBoundedPresentation(BuildContext context) {
    // Capture the stage once per table rebuild. Header scrolling only changes
    // height; recreating this stage from the outer LayoutBuilder discards the
    // body's width-only cache and rebuilds every visible cell on each wheel.
    final stage = _buildTableStage(context);
    // 分页已在表头上方工具条右上角（_buildToolbarPager；列表形态经
    // _listPagerAbove 钉在列表上方右角），表格下方不再渲染翻页条。
    final footer = [
      if (widget.summaryBar != null && !widget.summaryBarInline)
        _buildSummaryBar(context),
    ];
    final listPager = _listPagerAbove(context);
    return _wrapPresentation(
      LayoutBuilder(
        builder: (context, constraints) {
          final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
          if (footer.isNotEmpty && constraints.maxHeight < 240 * textScale) {
            return _ShortTablePresentation(
              child: Column(
                children: [
                  listPager,
                  SizedBox(height: 168 * textScale, child: stage),
                  ...footer,
                ],
              ),
            );
          }
          return Column(
            children: [
              listPager,
              Expanded(child: stage),
              ...footer,
            ],
          );
        },
      ),
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
    List<({bool header, MasterDataGroup<T>? group, T? item, Widget? notice})>
    plan,
    double total,
    double viewportWidth,
  ) {
    // 合计条随表体滚动（summaryBarInline）：作为竖向滚动内容的
    // 最后一项（数据行与「加载更多」指示器之后），行少时紧跟末行。
    final summaryInline = widget.summaryBarInline && widget.summaryBar != null;
    final hasFooter = _loadingMore || (!_prepending && _appendError != null);
    final appendStart = plan.length + (hasFooter ? 1 : 0);
    final appendRows = _appendRows;
    final summaryIndex = appendStart + appendRows.length;
    Object planId(int index) {
      final row = plan[index];
      if (row.notice != null) return const ('notice',);
      return row.header
          ? ('group', row.group!.id)
          : ('data', _paginationRowId(row.item as T));
    }

    // Without a business identity the previous row subtree used its slot.
    // Keep that same identity on the new outer admission shell: refreshed
    // value-equivalent objects must not replace live native selectables.
    Object mountId(int index) {
      final item = plan[index].item;
      if (!_automaticPagination &&
          item != null &&
          widget.rowKeyOf?.call(item) == null &&
          widget.idOf?.call(item) == null) {
        return ('slot', index);
      }
      return planId(index);
    }

    final indexes = _automaticPagination
        ? {
            for (var i = 0; i < plan.length; i++)
              ValueKey(('pagination-row', planId(i))): i,
          }
        : null;
    // 拖拽表的槽位 key → 下标：拖拽中宿主展开/收起会插入/移除行，ListView 若按下标
    // 复用会整体重建行元素，进行中的长按/纵向识别器连同 State 一起销毁——指针
    // up 从此无人接收，幽灵卡的全屏层永久遮挡（2026-10-19 用户实测「展开后整页
    // 卡死」）。给到 key→下标映射后元素随 key 平移，识别器存活、拖拽正常收尾。
    final dragSlotIndexes = widget.rowDrag == null
        ? null
        : <ValueKey<String>, int>{
            for (var i = 0; i < plan.length; i++)
              if (plan[i].item case final rowItem?)
                if (widget.rowKeyOf?.call(rowItem) ?? widget.idOf?.call(rowItem)
                    case final dragKey?)
                  if (dragKey.isNotEmpty) ValueKey('row-drag-slot:$dragKey'): i,
          };
    int? childIndex(Key key) {
      for (var i = 0; i < appendRows.length; i++) {
        if (key == ValueKey(('append-row', appendRows[i].key))) {
          return appendStart + i;
        }
      }
      if (key is _DeferredRowKey) key = key.value;
      if (key is! ValueKey) return null;
      return indexes?[key] ?? dragSlotIndexes?[key];
    }

    List<_MasterWindowSlot>? windowSlots;
    Widget buildRow(BuildContext ctx, int i) {
      final slot = windowSlots?[i];
      Widget selectionRow(Widget child) => _rowSelectionArea(
        child,
        onHasSelectionChanged: slot == null
            ? null
            : (selected) => _localRowWindow.retain(slot, selected),
      );
      if (summaryInline && i == summaryIndex) {
        return selectionRow(
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
      if (i >= appendStart && i < summaryIndex) {
        final append = appendRows[i - appendStart];
        return KeyedSubtree(
          key: ValueKey(('append-row', append.key)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAppendRow(theme, append, total, viewportWidth),
              SizedBox(
                key: i == summaryIndex - 1 ? _lastRowKey : null,
                height: 0,
              ),
            ],
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
      // 行区提示（空结果/加载/错误/「无符合」条）：跨满宽钉在视口横滚位，
      // 不随表格内容横向滚动。
      if (row.notice != null) {
        return _ViewportPinnedRow(
          controller: _bodyH,
          contentWidth: total,
          fallbackViewportWidth: viewportWidth,
          child: row.notice!,
        );
      }
      if (row.header) {
        return _trackPaginationRow(
          planId(i),
          false,
          // 分组标题行钉在视口左缘（与合计条/空表提示同款 _ViewportPinnedRow）：
          // 行文案不随表格横向滚动被带走，任何横滚位置都看得见、点得到。
          selectionRow(
            _ViewportPinnedRow(
              controller: _bodyH,
              contentWidth: total,
              fallbackViewportWidth: viewportWidth,
              child: _buildGroupHeader(theme, row.group!),
            ),
          ),
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
        child: debugUiWorkSliceObserver == null
            ? selectionRow(_buildDataRow(theme, item))
            : _MasterRowLayoutProbe(
                child: selectionRow(_buildDataRow(theme, item)),
              ),
      );
      // 末行挂测量键：覆盖层横滚条按末行定位（贴末行下）。
      // 内容超高时末行被虚拟化不挂载 → 横滚条钉表体区底。
      final focused =
          idKey != null && idKey.isNotEmpty && idKey == _pendingRevealId
          ? KeyedSubtree(key: _revealedRowKey, child: rowWidget)
          : rowWidget;
      // The last-row marker must not become an ancestor of the editor. When
      // append drafts disappear during save/recovery, inserting that ancestor
      // would remount the last business row. A paintless sibling keeps the
      // same measured bounds without changing the input subtree.
      final wrapped = Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          focused,
          if (appendRows.isEmpty && i == plan.length - 1)
            Positioned.fill(
              child: IgnorePointer(child: SizedBox(key: _lastRowKey)),
            ),
        ],
      );
      // 行拖拽三件套（rowDrag 非空才有）：槽登记 + 长按拾起手势 + 被拖行淡出。
      // **最外层必须是带 key 的槽**（配合上面的 dragSlotIndexes/findChildIndexCallback）：
      // 展开插行时元素随 key 平移而非按下标重建，进行中的识别器存活。
      // 淡出用常驻 AnimatedOpacity 的 opacity 值切换——条件性包新 widget 同样会
      // 改变结构类型，不允许。
      Widget dragChild = _wrapRowDragAffordance(ctx, item, wrapped);
      if (widget.rowDrag != null) {
        final dragKey = _dragKeyOf(item);
        dragChild = AnimatedOpacity(
          opacity:
              _dragActive && dragKey != null && _dragRowKeys.contains(dragKey)
              ? 0.35
              : 1.0,
          duration: const Duration(milliseconds: 150),
          child: dragChild,
        );
      }
      final draggable = _wrapRowDragSlot(item, dragChild);
      return _trackPaginationRow(
        planId(i),
        row.group == null &&
            !widget.unpagedItems.any(
              (local) => _paginationRowId(local) == _paginationRowId(item),
            ),
        draggable,
      );
    }

    // A variable-height SliverList walks intermediate children on a distant
    // jump. Large local tables instead keep one content-height child and let
    // the shared measured row window locate destination rows directly. Server
    // prepend/pagination and row dragging retain their existing anchor paths.
    final itemCount = summaryIndex + (summaryInline ? 1 : 0);
    if ((widget.virtualized || widget.primary) &&
        !_automaticPagination &&
        widget.onLoadMore == null &&
        widget.rowDrag == null &&
        (widget.rowKeyOf != null || widget.idOf != null)) {
      final ids = <Object>[
        for (var i = 0; i < plan.length; i++) planId(i),
        if (hasFooter) const ('footer',),
        for (final row in appendRows) ('append', row.key),
        if (summaryInline) const ('summary',),
      ];
      final unique = ids.toSet();
      if (unique.length == ids.length) {
        _localWindowSlots.removeWhere((id, _) => !unique.contains(id));
        windowSlots = [
          for (final id in ids)
            _localWindowSlots.putIfAbsent(id, () => _MasterWindowSlot(id)),
        ];
      }
    }
    final bodyStyle = theme.textTheme.bodyMedium;
    final estimatedRowExtent =
        MediaQuery.textScalerOf(context).scale(bodyStyle?.fontSize ?? 14) *
            (bodyStyle?.height ?? 1.5) +
        UtenSpacing.s16;
    final window = windowSlots;
    final stageFallbackRows =
        window == null &&
        plan.length >= UtenAncestorRowWindow.minimumStagedRows;
    _deferredFallbackActive = stageFallbackRows;
    if (window == null) {
      final currentIds = {for (var i = 0; i < plan.length; i++) mountId(i)};
      _deferredRowMounts.removeWhere((id, _) => !currentIds.contains(id));
      if (!_prepending) {
        _deferredRowHeights.removeWhere((id, _) => !currentIds.contains(id));
      }
    }
    Widget buildFallbackRow(BuildContext context, int index) {
      if (index >= plan.length || plan[index].item == null) {
        return buildRow(context, index);
      }
      final id = mountId(index);
      final item = plan[index].item as T;
      final dragId = widget.rowDrag == null ? null : _dragKeyOf(item);
      final key = _automaticPagination
          ? ValueKey(('pagination-row', id))
          : dragId != null && dragId.isNotEmpty
          ? ValueKey('row-drag-slot:$dragId')
          : ValueKey(('deferred-row', id));
      return UtenDeferredRowMount(
        key: _DeferredRowKey(key),
        controller: _deferredRowMounts.putIfAbsent(
          id,
          UtenDeferredRowMountController.new,
        ),
        estimatedExtent: _deferredRowHeights[id] ?? estimatedRowExtent,
        onExtentMeasured: (height) => _deferredRowHeights[id] = height,
        deferNewMounts: stageFallbackRows,
        expensive: _expensiveRowMounts,
        builder: (context) => buildRow(context, index),
      );
    }

    final verticalController = _verticalScrollController;
    final list = ScrollConfiguration(
      behavior: _PrimaryOwnerTableScrollBehavior(
        ScrollConfiguration.of(context),
        verticalController,
      ),
      child: ListView.builder(
        // Borrow the coordinator explicitly. Toggling ListView.primary inserts
        // or removes PrimaryScrollController.none and remounts the row editors.
        controller: verticalController,
        scrollCacheExtent: _rowScrollCache(context),
        primary: false,
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
        findChildIndexCallback:
            window != null ||
                (indexes == null &&
                    dragSlotIndexes == null &&
                    appendRows.isEmpty)
            ? null
            : childIndex,
        padding: EdgeInsets.only(bottom: _bodyBottomPad + _prependBottomSpace),
        itemCount: window == null ? itemCount : 1,
        itemBuilder: window == null
            ? buildFallbackRow
            : (context, _) => UtenAncestorRowWindow<_MasterWindowSlot>(
                controller: _localRowWindow,
                rows: window,
                viewportOnly: true,
                expensiveRows: _expensiveRowMounts,
                preserveRowAnchorOnSourceChange: false,
                estimatedRowExtent: estimatedRowExtent,
                rowBuilder: (context, _, index) => buildRow(context, index),
              ),
      ),
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
    // 避免 ListView 底部留白把横滚条推离末行。空表不包 Scrollbar
    // （0 行时 extent 仍 >0，thumbVisibility:true 会让 thumb 恒显成噪音）。
    final hWrapped = _usesOverlayHBar
        ? hArea
        : (_hasRowContent
              ? Scrollbar(
                  controller: _bodyH,
                  thumbVisibility: true,
                  child: hArea,
                )
              : hArea);
    // 竖向滚动条（上下）已改为表体 Stack 上的覆盖层
    // （见 body Stack children），此处只产出表体本体。
    //
    // 2026-09-22 根治「竖条长度乱跳/越滚越长」：旧 Scrollbar 无
    // controller 时框架对任何通过谓词的通知都重画 thumb（SDK
    // _shouldUpdatePainter：controller 为 null 恒 true，不做轴向过滤），
    // 表体横向 SV（depth 0）的横轴通知会把竖向 thumb 按横向 metrics 重画。
    // 改用自绘 UtenContentScrollbar（controller 驱动，轴向恒对）。
    //
    // 表体内容超出视口即显示竖条，不再依赖折叠头置顶阶段。
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

  bool get _usesBoundedFloatingBatchActions =>
      _hasFloatingBatchActions && (!widget.embedded || _fullscreen);

  bool get _usesOverlayHBar =>
      widget.primary ||
      _hasFloatingBatchActions ||
      widget.bottomContentPadding > 0;

  /// 空表不画横向滚动条（2026-10-10 用户口径）：没有任何数据行（含钉顶的
  /// unpagedItems，它们已并入 _items）也没有前导分组行时，表头骨架仍在但
  /// 内容宽=列宽和>视口会让 thumb 恒显（thumbVisibility:true 且无滚动事件
  /// 永不隐藏），纯属噪音；加载中/错误态的提示行同理不需要横滚条（有意
  /// 降噪）。有任意行内容时行为与原来完全一致。
  bool get _hasRowContent =>
      _appendRows.isNotEmpty ||
      _displayItems.isNotEmpty ||
      (widget.leadingGroups ?? const []).any(
        (g) =>
            g.items.isNotEmpty ||
            (g.total ?? 0) > 0 ||
            g.loading ||
            g.error != null ||
            g.onExpand != null,
      );

  bool _legacyPrefetchScheduled = false;
  int _prefetchCorrectionDepth = 0;

  bool get _prefetchViewportActive {
    if (!mounted) return false;
    // Fullscreen transfers the same keyed table stage to another route. Its
    // original State context stays on the covered source route.
    final presentation = _tableChromeKey.currentContext ?? context;
    return TickerMode.valuesOf(presentation).enabled &&
        (ModalRoute.of(presentation)?.isCurrent ?? true);
  }

  bool _ownsPrefetchNotification(ScrollNotification notification) {
    final sourceContext = notification.context;
    final source = sourceContext == null
        ? null
        : Scrollable.maybeOf(sourceContext)?.position;
    final controller = _verticalScrollController;
    return source != null &&
        controller != null &&
        controller.positions.contains(source);
  }

  void _prefetchAdjacent(ScrollMetrics metrics, {required bool prepend}) {
    if (!_prefetchViewportActive ||
        _prefetchCorrectionDepth != 0 ||
        _restoringDeferredEdge ||
        _hasPendingPageAnchor ||
        !UtenScrollPrefetchPolicy.isNearEdge(
          metrics,
          prepend: prepend,
          fontZoom: UtenDisplayScale.fontZoomOf(context),
        )) {
      return;
    }
    if (!prepend) _maybeTriggerLoadMore(metrics);
    _scheduleAppend(prepend: prepend);
  }

  /// 竖向滚动临近底部时触发 [MasterDataTableView.onLoadMore]。
  /// loadingMore 为 true 期间不重复触发；更多页判断在调用方（见参数文档）。
  void _maybeTriggerLoadMore(ScrollMetrics metrics) {
    if (_appendRows.isNotEmpty ||
        widget.onLoadMore == null ||
        _busy ||
        widget.error != null ||
        _appendError != null ||
        _legacyPrefetchScheduled ||
        !_prefetchViewportActive ||
        !UtenScrollPrefetchPolicy.isNearEdge(
          metrics,
          fontZoom: UtenDisplayScale.fontZoomOf(context),
        )) {
      return;
    }
    _legacyPrefetchScheduled = true;
    final generation = _appendGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _legacyPrefetchScheduled = false;
      if (!mounted ||
          generation != _appendGeneration ||
          !_prefetchViewportActive ||
          _busy ||
          widget.error != null ||
          _appendError != null ||
          _appendRows.isNotEmpty) {
        return;
      }
      final controller = _verticalScrollController;
      if (controller == null ||
          controller.positions.length != 1 ||
          !UtenScrollPrefetchPolicy.isNearEdge(
            controller.position,
            fontZoom: UtenDisplayScale.fontZoomOf(context),
          )) {
        return;
      }
      widget.onLoadMore?.call();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
    _pendingScrollToEnd = null;
    _deferredLeadingEdge = false;
    _deferredTrailingEdge = false;
    _releaseExplicitReadingPage();
    final controller = _verticalScrollController;
    if (controller == null || !controller.hasClients) return;
    _scheduleVisiblePage();
    // At a clamped edge Flutter may emit no ScrollNotification at all. Observe
    // the wheel without claiming it from the normal scroll/zoom machinery.
    final prepend = event.scrollDelta.dy < 0;
    for (final position in controller.positions) {
      _prefetchAdjacent(position, prepend: prepend);
    }
  }

  bool get _hasPendingPageAnchor =>
      _prependMeasureItems != null ||
      _prependAnchor.pending ||
      _appendPage != null;

  void _observeDeferredLeadingEdge(ScrollNotification notification) {
    if (_restoringDeferredEdge ||
        !_deferredFallbackActive ||
        _hasPendingPageAnchor) {
      return;
    }
    final controller = _verticalScrollController;
    final source = notification.context == null
        ? null
        : Scrollable.maybeOf(notification.context!, axis: Axis.vertical);
    if (controller == null ||
        controller.positions.length != 1 ||
        !identical(source?.position, controller.position)) {
      return;
    }
    if (notification is ScrollStartNotification) {
      _deferredScrollSequence = true;
      // Layout can start a ballistic correction after our jump has returned.
      // That is still part of reaching the requested end. A drag or keyboard
      // scroll supersedes it; wheel intent is handled by _onPaginationWheel.
      const scrollKeys = [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.space,
      ];
      if (notification.dragDetails != null ||
          HardwareKeyboard.instance.logicalKeysPressed.any(
            scrollKeys.contains,
          )) {
        _pendingScrollToEnd = null;
      }
    }
    if (notification is ScrollUpdateNotification) {
      if (_deferredScrollSequence || notification.dragDetails != null) {
        _deferredLeadingEdge = notification.metrics.extentBefore <= .5;
        _deferredTrailingEdge =
            !_deferredLeadingEdge && notification.metrics.extentAfter <= .5;
        if (_deferredLeadingEdge || _deferredTrailingEdge) {
          _deferredEdgeGeneration = _appendGeneration;
          _deferredEdgePasses = 0;
          _scheduleDeferredLeadingEdge();
        }
      }
      _deferredScrollSequence = false;
    }
    if (notification is ScrollEndNotification) _deferredScrollSequence = false;
  }

  void _scheduleDeferredLeadingEdge() {
    if ((!_deferredLeadingEdge && !_deferredTrailingEdge) ||
        _deferredEdgeScheduled) {
      return;
    }
    _deferredEdgeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deferredEdgeScheduled = false;
      if (!mounted || (!_deferredLeadingEdge && !_deferredTrailingEdge)) return;
      final controller = _verticalScrollController;
      if (!_deferredFallbackActive ||
          _hasPendingPageAnchor ||
          _deferredEdgeGeneration != _appendGeneration ||
          !_prefetchViewportActive ||
          controller == null ||
          controller.positions.length != 1) {
        _deferredLeadingEdge = false;
        _deferredTrailingEdge = false;
        return;
      }
      final position = controller.position;
      if (_deferredRowMounts.values.any((row) => row.isMounting)) {
        // Waiting for admission does not consume correction attempts. A tall
        // viewport may legitimately need more than 16 frames at four rows/frame.
        _scheduleDeferredLeadingEdge();
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      final target = _deferredLeadingEdge
          ? position.minScrollExtent
          : position.maxScrollExtent;
      if ((position.pixels - target).abs() > 0.000001 &&
          ++_deferredEdgePasses <= 8) {
        // Estimated-to-measured sliver corrections must preserve an explicit
        // endpoint visit. A real prepend still owns its measured anchor.
        _restoringDeferredEdge = true;
        try {
          position.jumpTo(target);
        } finally {
          _restoringDeferredEdge = false;
        }
        _scheduleDeferredLeadingEdge();
        WidgetsBinding.instance.ensureVisualUpdate();
      } else {
        _deferredLeadingEdge = false;
        _deferredTrailingEdge = false;
      }
    });
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
              _observeDeferredLeadingEdge(notification);
              _scheduleHBarUpdate();
              if (notification is ScrollUpdateNotification ||
                  notification is OverscrollNotification ||
                  notification is ScrollEndNotification) {
                _scheduleVisiblePage();
              }
              final direction = UtenScrollPrefetchPolicy.directionOf(
                notification,
              );
              if (direction != 0 && _ownsPrefetchNotification(notification)) {
                if (!_hasPendingPageAnchor &&
                    !_settlingPageLayout &&
                    !_restoringDeferredEdge &&
                    _prefetchCorrectionDepth == 0) {
                  _releaseExplicitReadingPage();
                }
                _prefetchAdjacent(notification.metrics, prepend: direction < 0);
              }
            }
            return false;
          },
          child: Stack(fit: StackFit.expand, children: [_buildTable(context)]),
        ),
      ),
    );
  }

  /// 当前有值的表头筛选列（含「筛空值」哨兵；含 filterFromRows 列的本地筛选）。
  List<String> get _activeFilterKeys => [
    for (final entry in widget.filters.entries)
      if (entry.value != null && entry.value!.isNotEmpty) entry.key,
    for (final entry in _rowFilters.entries)
      if (entry.value != null && entry.value!.isNotEmpty) entry.key,
    for (final key in _columnSearches.keys) 'search.$key',
  ];

  /// 空态「当前有 N 个表头筛选生效」描述真正计入的列 = 有值 − 宿主自管的列。
  ///
  /// 2026-09-28 用户口径：空态「清除筛选」按钮全站退役（分类分段条就在表上方，
  /// 按钮是重复入口）；此 getter 只剩筛选生效数描述一个用途。
  List<String> get _clearableFilterKeys => [
    for (final key in _activeFilterKeys)
      if (!widget.externalFilterKeys.contains(key)) key,
  ];

  /// 全屏切换按钮（2026-10-09 统一骨架起，工具条任何状态同构渲染，空表也有
  /// 全屏入口——例如放大看「类似人员」分组；全屏里 0 行时的退出口保障不变，
  /// 2026-09-10 物料分析被困全屏的反馈仍成立）。高度对齐工具条统一口径 48；
  /// 纯文字无图标（2026-10-08 用户口径）。按钮态靠 `_fsTick` 重建时读 `_fullscreen`。
  Widget _fullscreenToggleButton() => UtenButton(
    key: const ValueKey('master-table-fullscreen-toggle'),
    size: UtenButtonSize.large,
    height: UtenTableToolbar.controlHeight,
    onPressed: _toggleFullscreen,
    child: Text(_fullscreen ? '退出全屏' : '全屏'),
  );

  /// 工具条前缀/动作区的稳定挂载槽（2026-10-09「拼音打一半丢输入法」根因修复）：
  /// loading/错误/空态与数据态的工具条是不同分支的树，直接展开会把调用方控件
  ///（搜索框等）随状态切换销毁重建，焦点与 IME 组合被打断。同一 index 的控件
  /// 经 GlobalKey 重挂载（reparent）保留 Element——文本、焦点、组合全不丢。
  /// key 生命周期随本 State；进入全屏是同帧卸旧挂新，同样走重挂载保命。
  final List<GlobalKey> _leadingActionKeys = [];
  final List<GlobalKey> _toolbarActionKeys = [];

  List<Widget> _stableLeadingActions() {
    final leading = widget.toolbarLeadingActions;
    if (leading == null) return const [];
    while (_leadingActionKeys.length < leading.length) {
      _leadingActionKeys.add(GlobalKey());
    }
    return [
      for (var i = 0; i < leading.length; i++)
        KeyedSubtree(key: _leadingActionKeys[i], child: leading[i]),
    ];
  }

  List<Widget> _stableToolbarActions() {
    final actions = widget.toolbarActions;
    if (actions == null) return const [];
    while (_toolbarActionKeys.length < actions.length) {
      _toolbarActionKeys.add(GlobalKey());
    }
    return [
      for (var i = 0; i < actions.length; i++)
        KeyedSubtree(key: _toolbarActionKeys[i], child: actions[i]),
    ];
  }

  /// 主行为空但仍有前导分组（如「类似人员」）时的紧凑提示行：
  /// 「无符合…」一行小字 + 可选的表头筛选生效数说明，排在分组标题行之前。
  Widget _compactEmptyNotice(ThemeData theme, String? filterNote) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s16,
      vertical: UtenSpacing.s12,
    ),
    child: Row(
      children: [
        Icon(
          Icons.search_off_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            filterNote == null
                ? widget.emptyMessage
                : '${widget.emptyMessage}（$filterNote）',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildTable(BuildContext context) {
    final table = UtenPageScrollbarLayoutBuilder(
      token: _pageLayoutToken,
      builder: (context, lane) => _buildTableWithLane(context, lane),
    );
    return widget.embedded
        ? UtenPageScrollRoleScope.local(child: table)
        : table;
  }

  Widget _buildTableWithLane(BuildContext context, double localLane) {
    _scheduleScrollToEnd();
    _scheduleReveal();
    final table = TableColumnProjectionTarget(
      tableKey: _platform.tableKey,
      owner: this,
      child: _buildProjectedTable(context, localLane),
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

  Widget _buildPickerList(BuildContext context, List<T> rows, Widget? notice) {
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
        ? _applyRowView(_collectRows(_proposedMeasuredPages()))
        : rows;
    final separatorIndexes = {
      for (var i = 0; i < proposed.length; i++)
        _paginationRowId(proposed[i]): i,
    };
    final hasFooter = _loadingMore || (!_prepending && _appendError != null);
    // 空结果/加载/错误提示插在列表首位（列表骨架常驻，与表格同口径）。
    final hasNotice = notice != null;
    final boundedActions = _usesBoundedFloatingBatchActions;
    final list = ListView.builder(
      controller: _bodyV,
      scrollCacheExtent: _rowScrollCache(context),
      primary: false,
      physics: _prependAnchor.wrap(const ClampingScrollPhysics()),
      padding: padding.copyWith(
        bottom:
            padding.bottom +
            _prependBottomSpace +
            (boundedActions ? _bodyBottomPad : 0),
      ),
      itemCount: (hasNotice ? 1 : 0) + rows.length + (hasFooter ? 1 : 0),
      findChildIndexCallback: (key) => indexes[key],
      itemBuilder: (context, index) {
        if (hasNotice && index == 0) {
          return KeyedSubtree(
            key: const ValueKey('picker-list-notice'),
            child: notice,
          );
        }
        final itemIndex = index - (hasNotice ? 1 : 0);
        if (itemIndex == rows.length) {
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
        final item = rows[itemIndex];
        final tile = row(
          item,
          itemIndex,
          separator: itemIndex < rows.length - 1,
        );
        return _trackPaginationRow(
          ('data', _paginationRowId(item)),
          true,
          boundedActions && itemIndex == rows.length - 1
              ? KeyedSubtree(key: _lastRowKey, child: tile)
              : tile,
        );
      },
    );
    final body = Stack(
      key: boundedActions ? _bodyAreaKey : null,
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
        if (_requeryFeedback case final feedback?)
          Positioned(left: 0, right: 0, top: 0, child: feedback),
        if (boundedActions)
          PositionedDirectional(
            start: UtenSpacing.s16,
            end: UtenSpacing.s16,
            bottom: UtenSpacing.s16,
            child: Align(
              alignment: AlignmentDirectional.bottomEnd,
              child: _buildFloatingBatchActions(context),
            ),
          ),
      ],
    );
    // Plain picker consumers retain their existing tiles/footer and paging
    // topology. The public selectable+batch combination shares the exact local
    // row/action budget used by a column table, with no synthetic toolbar.
    if (!boundedActions) {
      return Column(
        mainAxisSize: widget.embedded ? MainAxisSize.min : MainAxisSize.max,
        children: [
          _buildRefreshStatusRow(),
          if (widget.embedded) body else Expanded(child: body),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _scheduleHBarUpdate();
        return _ResponsiveTableChrome(
          toolbar: const SizedBox.shrink(),
          minimumHeight: _floatingBatchMinimumTableHeight,
          compose: (_) => Column(
            key: _tableChromeKey,
            children: [
              _buildRefreshStatusRow(),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }

  Widget _presentBody(Widget child) =>
      widget.bodyPresentationBuilder?.call(context, child) ?? child;

  Widget _buildProjectedTable(BuildContext context, double localLane) =>
      _profileMasterTableWork(
        'master.projected-table',
        () => _buildProjectedTableImpl(context, localLane),
      );

  Widget _buildProjectedTableImpl(BuildContext context, double localLane) {
    final columnKeys = _columns.map((column) => column.key).toSet();
    _selectedFacetBuckets.removeWhere(
      (key, bucket) =>
          !columnKeys.contains(key) || widget.filters[key] != bucket.value,
    );
    final selectionColumns = [
      for (final i in _visibleIndices) _columns[i].key,
      ..._presentationPinnedKeys.map((key) => 'pinned:$key'),
    ];
    if (!listEquals(_textSelectionColumnKeys, selectionColumns)) {
      _textSelection.clear();
      _textSelectionColumnKeys = selectionColumns;
    }
    _projectionOwner = ModalRoute.of(context);
    _publishProjection();
    final theme = Theme.of(context);
    // 嵌入场景（滑窗/picker/弹窗内明细表）默认不显示全屏按钮：整屏路由在受限容器里会铺满
    // 屏幕（详细排产滑窗 bug）。显式 showFullscreenToggle 可覆盖。
    final showFullscreen = widget.showFullscreenToggle ?? !widget.embedded;
    final groups = widget.leadingGroups ?? <MasterDataGroup<T>>[];
    final displayItems = _displayItems;
    final selectionRows = _profileMasterTableWork(
      'master.selection-row-keys',
      () => <String>[
        for (final group in groups)
          if (_expandedGroups.contains(group.id) || group.initiallyExpanded)
            for (final item in group.items) _textSelectionRowKey(item),
        for (final item in displayItems) _textSelectionRowKey(item),
      ],
    );
    if (!listEquals(_textSelectionRowKeys, selectionRows)) {
      _textSelection.clear();
      _textSelectionRowKeys = selectionRows;
    }

    // 行区提示（2026-10-09 用户口径「搜索无结果/加载/错误时表格骨架也要在，页面不许跳」）：
    // 不再整块换空态/错误/加载占位壳——统一渲染同一张表（工具条+表头+列），只有行区
    // 内容随状态变，提示作为一条跨满宽**紧凑行**插在行计划首位（图标+主文案+内联重试，
    // 高度 ~80px；表体被外层收起横幅挤压到百来像素时重试仍在屏内）。
    // 主行为空但仍有前导分组（如搜索 0 命中时的「类似人员」分组）时提示走紧凑条，
    // 分组跟在提示之后——即「无符合人员 / 类似人员」两段式。
    Widget? bodyNotice;
    if (widget.isLoading && _items.isEmpty) {
      bodyNotice = const Padding(
        padding: EdgeInsets.all(UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    } else if (widget.error != null &&
        _appendError == null &&
        widget.unpagedItems.isEmpty) {
      bodyNotice = Padding(
        key: widget.errorKey,
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s12,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                widget.error ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            TextButton.icon(
              onPressed: widget.onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'), // TODO(l10n): 补 arb
            ),
          ],
        ),
      );
    } else if (displayItems.isEmpty && _appendRows.isEmpty) {
      // 空态说明补一行筛选生效数，提示表格为何为空（清除入口在表外分段条/
      // 重新出现行后的列头筛选控件）。
      final activeFilters = _clearableFilterKeys.length;
      final filterNote = activeFilters > 0
          ? '当前有 $activeFilters 个表头筛选生效' // TODO(l10n): 补 arb
          : null;
      // 该分支 displayItems 已空，_hasRowContent 此处即「前导分组是否有行」。
      bodyNotice = _hasRowContent
          ? _compactEmptyNotice(theme, filterNote)
          : Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.emptyMessage,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (filterNote != null) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      filterNote,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            );
    }
    if (widget.listItemBuilder != null) {
      return _buildPickerList(context, displayItems, bodyNotice);
    }
    _ensureWidths(context);
    final total = _totalWidth;
    // 行计划：前导分组（表头下第一区）+ 主数据行。分组折叠=仅一条跨满宽标题行；
    // 展开=其 items 按主表同款列逐行渲染（与主行共用 _widths / _visibleIndices / 横滚）。
    final plan = _profileMasterTableWork('master.row-plan', () {
      final result =
          <
            ({bool header, MasterDataGroup<T>? group, T? item, Widget? notice})
          >[];
      if (bodyNotice != null) {
        result.add((
          header: false,
          group: null,
          item: null,
          notice: bodyNotice,
        ));
      }
      for (final g in groups) {
        if (g.initiallyExpanded) _expandedGroups.add(g.id);
        if (g.items.isEmpty &&
            (g.total ?? 0) == 0 &&
            !g.loading &&
            g.error == null &&
            g.onExpand == null) {
          continue; // 明确 N=0 且不可加载的分组不渲染
        }
        result.add((header: true, group: g, item: null, notice: null));
        if (_expandedGroups.contains(g.id)) {
          for (final it in g.items) {
            result.add((header: false, group: g, item: it, notice: null));
          }
        }
      }
      for (final it in displayItems) {
        result.add((header: false, group: null, item: it, notice: null));
      }
      return result;
    });
    // stretch：列总宽 < 视口宽时（颜色/单位等列少主档）表头与表体撑满视口宽、
    // 内容靠左，而非整体水平居中（Column 默认 crossAxisAlignment.center 会把窄于
    // 视口的表格居中、左右留白）。仅作用于交叉轴（横向），不影响主轴 Flexible(loose)
    // 的「行少收缩、横滚条贴末行」行为。
    //
    // 表头上方工具条：左簇 =「表头设置」列显隐选择 + 全屏 + 前缀按钮（预览打印/
    // 下载表格等，2026-10-18 用户口径：导出类动作靠左与全屏同排）；右簇贴边 =
    // 调用方动作区（刷新等）+ 分页（恒排最右）。宽度足够时右簇固定贴右；窄屏回退
    // 整条 Wrap 流式换行（动作不收缩，Row 会在窄约束溢出，故按可用宽度分流）。
    // 2026-09-25 用户口径：工具条与上方分区栏、下方表格的垂直间距对称
    //（此前只有 bottom 4、top 0，看着贴住上沿）。
    final Widget toolbar = Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final toolbarChildren = [
            if (_platform.error != null)
              PlatformTableStatus(
                error: _platform.error,
                retry: _platform.retryRead,
                loading: _platform.loading,
                failure: _platform.readFailure,
              ),
            if (widget.showColumnChooser)
              UtenColumnChooserButton(
                entries: [
                  for (final c in _columns)
                    UtenColumnChooserEntry(
                      key: c.key,
                      label: c.label,
                      required: _isRequiredLeading(c.key),
                    ),
                ],
                hiddenKeys: _presentationHiddenKeys,
                onToggle: _toggleColumn,
                onToggleAll: _toggleAllColumns,
                order: _presentationColumnOrder,
                onReorder: (oldIndex, newIndex) =>
                    _reorderColumnByKeys(oldIndex, newIndex),
                onReset: _resetPlatformLayout,
              ),
            // 全屏切换：表格放大到整屏显示（行列多时能看更多内容），
            // 再点退出（与空态共用 _fullscreenToggleButton）。
            if (showFullscreen) _fullscreenToggleButton(),
            // 前缀按钮：视图切换类 chip 紧挨全屏按钮（左簇内，Wrap s8 间距）。
            // 走稳定挂载槽：loading/空态/错误态切换时搜索框等控件不重建不失焦。
            ..._stableLeadingActions(),
            // 选择摘要：有悬浮批量动作时随动作进右下悬浮组（见
            // [_buildFloatingBatchActions]）；无悬浮动作的表格仍驻表头上方；
            // 页面自管选择摘要（showSelectionSummary=false）时不驻留。
            if (widget.selectable &&
                widget.showSelectionSummary &&
                !_hasFloatingBatchActions)
              _buildBatchBar(theme),
          ];
          // 右侧贴边簇：调用方动作 + 分页。分页（上一页/下一页/页码/总页数）
          // 上移工具条右上角、与「表头设置 / 全屏」同一行（2026-10-18 用户口径，
          // 原表格下方翻页条退役），恒排最右；无动作也无分页时保持整条 Wrap 流式布局。
          final actions = _stableToolbarActions();
          final pager = _buildToolbarPager(context);
          final trailing = [...actions, ?pager];
          if (trailing.isEmpty) {
            return Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [...toolbarChildren, ...trailing],
            );
          }
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: toolbarChildren,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: trailing,
                  ),
                ),
              ],
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
                children: trailing,
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
      final Widget headerRow = Padding(
        padding: EdgeInsets.only(right: localLane),
        child: SelectionContainer.disabled(
          child: UtenTableHeaderSurface(
            child: LayoutBuilder(
              builder: (context, headerConstraints) => Material(
                color: Colors.transparent,
                child: SingleChildScrollView(
                  controller: _headerH,
                  scrollDirection: Axis.horizontal,
                  child: ColoredBox(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: SizedBox(
                      width: math.max(total, headerConstraints.maxWidth),
                      child: _buildHeaderRow(theme),
                    ),
                  ),
                ),
              ),
            ),
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
        embedded: widget.embedded && !_fullscreen,
        primary: _usesPrimaryScroll,
        virtualized: widget.virtualized,
        fill: _usesBoundedFloatingBatchActions,
        child: _maybeSelectionArea(
          UtenPageScrollbarSource(
            layoutToken: _pageLayoutToken,
            controller: _verticalScrollController ?? _bodyV,
            enabled: !widget.embedded,
            priority: UtenPageScrollbarPriority.table,
            bottomInset: _bodyBottomPad,
            debugLabel: 'master-table-body',
            builder: (context, localVisible) => Stack(
              key: _bodyAreaKey,
              children: [
                Padding(
                  padding: EdgeInsets.only(right: localLane),
                  child: LayoutBuilder(
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
                      return bodyStage = _profileMasterTableWork<Widget>(
                        'master.body-stage',
                        () => _buildBodyStage(
                          context,
                          theme,
                          plan,
                          math.max(total, c.maxWidth),
                          c.maxWidth,
                        ),
                      );
                    },
                  ),
                ),
                // 行拖拽落点指示层（上/下插入线 + 移入高亮框；ValueNotifier 驱动）。
                if (widget.rowDrag != null) _buildRowDragIndicatorLayer(),
                // 竖向内容滚动条（自绘）：thumb 活动带与长度剔除底部让位空白
                // （悬浮批量动作 clearance / bottomContentPadding），滚到底时 thumb
                // 下缘贴内容底而非视口底；可拖、hover 高亮。联动表经
                // 内容超出视口即显示，不受外层折叠阶段限制。
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: UtenScrollGutter.trackWidth,
                  child: _buildVerticalScrollbar(visible: localVisible),
                ),
                if (_prependFeedback case final feedback?)
                  Positioned(
                    left: 0,
                    right: localLane,
                    top: 0,
                    child: feedback,
                  ),
                if (_requeryFeedback case final feedback?)
                  Positioned(
                    left: 0,
                    right: localLane,
                    top: 0,
                    child: feedback,
                  ),
                // 横滚条覆盖层：按内容高度定位（[_hBarY] 为底边 local top）。
                // 内容少 → 贴末行下方（约 1px 空隙）；超高 → 钉表体区底。与 _bodyH 双向同步，
                // 表头经既有 _sync 跟随，底部额外留白不参与定位。空表不挂覆盖层
                // （0 行/仅提示行时 thumb 是噪音，见 _hasRowContent）。
                if (_usesOverlayHBar && _hasRowContent)
                  ValueListenableBuilder<double?>(
                    valueListenable: _hBarY,
                    builder: (context, y, _) => Positioned(
                      left: 0,
                      right: localLane,
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
                // Actions stay above the horizontal scrollbar in hit-test order.
                if (_usesBoundedFloatingBatchActions)
                  ValueListenableBuilder<double?>(
                    valueListenable: _floatingBatchBottomInset,
                    builder: (context, inset, child) => PositionedDirectional(
                      start: UtenSpacing.s16,
                      end: UtenSpacing.s16,
                      bottom: UtenSpacing.s16 + (inset ?? 0),
                      child: Offstage(
                        offstage: inset == null,
                        child: Align(
                          alignment: AlignmentDirectional.bottomEnd,
                          child: child,
                        ),
                      ),
                    ),
                    child: _buildFloatingBatchActions(context),
                  ),
              ],
            ),
          ),
        ),
      );
      // —— 表头/表体组装 ——
      // 吸顶表（stickyHeaderPinned，详情页滚动流内的 embedded 明细表）：表头行+分隔线
      // 顶到视口上沿后钉住（覆盖层），数据行从其下方滚过；表尾推到时随表尾离开
      // （pushed sticky）。流内留同高占位（[_pinnedUnitHeight]，post-frame 实测修正），
      // 整表总高与非吸顶形态一致。普通表原样流内渲染，零结构变化。
      final sticky = _fullscreen ? null : _sticky;
      Widget compose(Widget visibleToolbar) => Column(
        key: _tableChromeKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          visibleToolbar,
          if (sticky == null) ...[
            headerRow,
            headerDivider,
            _buildRefreshStatusRow(),
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
                    _buildRefreshStatusRow(),
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
      if (widget.embedded && !_fullscreen) return compose(toolbar);
      return _ResponsiveTableChrome(
        toolbar: toolbar,
        compose: compose,
        pageOwned: localLane == 0,
        pageParticipant:
            !widget.embedded && UtenPageScrollRoleScope.isPageOf(context),
        minimumHeight: _usesBoundedFloatingBatchActions
            ? _floatingBatchMinimumTableHeight
            : 0,
      );
    }

    return buildStandardTable();
  }

  /// 表体选择区保持稳定，切分类时不撤掉 ListView 的 SelectionRegistrar。
  /// SDK 的行保活节点在祖先 registrar 变 null 后仍可能收到旧文本的 remove，
  /// 此时内部强制解引用会崩溃。禁用文字选择必须放在行保活节点下面。
  Widget _maybeSelectionArea(Widget child) {
    final area = UtenSelectionArea(
      selectionKey: _textSelection.areaKey,
      onSelectionChanged: _textSelection.onSelectionChanged,
      // 2026-09-15 用户口径：表格自带右键行菜单时，只显示自家菜单。右键点到
      // 可选文字上 SelectionArea 会弹框架默认「全选/复制」工具条与行菜单撞车
      //（文字拖选/键盘复制不受影响，只静音右键工具条）。
      contextMenuBuilder: widget.rowMenuBuilder == null
          ? null
          : (_, _) => const SizedBox.shrink(),
      child: child,
    );
    return _presentBody(area);
  }

  /// 显式退出文字选择时只隔离行内容，不改变 ListView 自动创建的
  /// SelectionKeepAlive 的祖先 registrar；行勾选不影响文字选择。
  Widget _rowSelectionArea(
    Widget child, {
    ValueChanged<bool>? onHasSelectionChanged,
  }) => !widget.enableTextSelection
      ? SelectionContainer.disabled(child: child)
      : UtenSelectionLifecycleScope(
          onHasSelectionChanged: onHasSelectionChanged,
          child: child,
        );

  // ===== 行拖拽实现（配置见 UtenTableRowDrag） =====

  /// 给数据行挂拾起手势。两条路（2026-10-19 二轮用户口径「长按也触发、
  /// 按住上下移动了就触发」）：
  /// 1) 按住不动约 250ms 拾起（官方默认 500ms 太钝，显式收紧）；
  /// 2) 鼠标按住并纵向移出 slop 立即拾起——横向移动仍归 SelectionArea 的
  ///    文字框选，两个方向两种语义互不抢。
  /// 纵向识别器只挂鼠标：触屏纵向拖是列表滚动的本能手势，不能抢。
  Widget _wrapRowDragAffordance(
    BuildContext gestureContext,
    T item,
    Widget child,
  ) {
    final drag = widget.rowDrag;
    if (drag == null) return child;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      // Busy/recovery states disable recognizers without unmounting editors.
      gestures: !drag.canDragRow(item)
          ? const {}
          : {
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(
                      duration: const Duration(milliseconds: 250),
                    ),
                    (instance) {
                      instance
                        ..onLongPressStart = (details) {
                          _dragSource = _RowDragSource.longPress;
                          _startRowDrag(
                            gestureContext,
                            item,
                            details.globalPosition,
                          );
                        }
                        ..onLongPressMoveUpdate = (details) {
                          _updateRowDrag(details.globalPosition);
                        }
                        ..onLongPressEnd = (details) {
                          _finishRowDrag(details.globalPosition);
                        }
                        // 纵向识别器赢下竞技场时长按被判负，cancel 只清自己启动的拖拽，
                        // 不能把纵向刚拾起的拖拽一并撕掉。
                        ..onLongPressCancel = () {
                          if (_dragSource == _RowDragSource.longPress) {
                            _cancelRowDrag();
                          }
                        };
                    },
                  ),
              VerticalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    VerticalDragGestureRecognizer
                  >(
                    () => VerticalDragGestureRecognizer(
                      supportedDevices: const {PointerDeviceKind.mouse},
                    ),
                    (instance) {
                      instance
                        ..dragStartBehavior = DragStartBehavior.down
                        ..onStart = (details) {
                          _dragSource = _RowDragSource.vertical;
                          _startRowDrag(
                            gestureContext,
                            item,
                            details.globalPosition,
                          );
                        }
                        ..onUpdate = (details) {
                          _updateRowDrag(details.globalPosition);
                        }
                        ..onEnd = (details) {
                          _finishRowDrag(details.globalPosition);
                        }
                        ..onCancel = () {
                          if (_dragSource == _RowDragSource.vertical) {
                            _cancelRowDrag();
                          }
                        };
                    },
                  ),
            },
      child: child,
    );
  }

  /// 给数据行挂拖拽槽（登记行条目，拖动中按光标位置反查悬停行）。
  Widget _wrapRowDragSlot(T item, Widget child) {
    if (widget.rowDrag == null) return child;
    final key = _dragKeyOf(item);
    if (key == null) return child;
    return _RowDragSlot<T>(
      key: ValueKey('row-drag-slot:$key'),
      slotKey: key,
      item: item,
      registry: _dragSlots,
      dragOriginKey: _dragOriginKey,
      child: child,
    );
  }

  void _startRowDrag(BuildContext ownerContext, T item, Offset global) {
    final drag = widget.rowDrag;
    if (drag == null || !drag.canDragRow(item) || _dragActive) return;
    final rows = drag.dragRowsOf(item);
    if (rows.isEmpty) return;
    // 拖行让位：清文字框选，避免选区与行拖拽在表体上并存。
    if (_textSelection.hasSelection) _textSelection.clear();
    _dragOriginKey.value = _dragKeyOf(item);
    // 用户口径「长按首先是选中这一行」：把按下的行纳入勾选（已在勾选集中
    // 或不可勾选则不动；多选拖整批、单行拖单行）。
    _toggleRow(item, true);
    setState(() {
      _dragRows = rows;
      _dragRowKeys = <String>{
        for (final r in rows)
          if (_dragKeyOf(r) case final k?) k, // ignore: use_null_aware_elements
      };
      _dragLabel = drag.dragLabelOf?.call(item);
      _dragTargetKey = null;
      _dragMode = null;
      _dragAutoExpandedKey = null;
    });
    _dragPointerPos.value = global;
    _dragIndicator.value = null;
    _mountRowDragGhost();
    _rowDragLifecycle = UtenOverlayLifecycle(onUnavailable: _cancelRowDrag);
    _rowDragLifecycle!.attach(ownerContext);
    if (!_dragActive) return;
    // 低频重锚：自动展开插入子行/宿主刷新后，光标不动目标也变了。
    _dragRetracking?.cancel();
    _dragRetracking = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!_dragActive) return;
      final pos = _dragPointerPos.value;
      if (pos != null) _updateRowDragTargets(pos);
    });
    _updateRowDragTargets(global);
  }

  void _updateRowDrag(Offset global) {
    if (!_dragActive) return;
    _dragPointerPos.value = global;
    _scheduleRowDragAutoScroll(global);
    _updateRowDragTargets(global);
  }

  /// 把光标位置解析成悬停行与落点形态，更新指示条与悬停自动展开计时。
  void _updateRowDragTargets(Offset global) {
    if (!_dragActive) return;
    final drag = widget.rowDrag!;
    final entry = _resolveRowDragTarget(global);
    UtenTableRowDropMode? mode;
    if (entry != null) {
      final box = entry.context.findRenderObject();
      if (box is RenderBox && box.attached && box.size.height > 0) {
        final t = box.globalToLocal(global).dy / box.size.height;
        final into = drag.canDropInto;
        final intoAllowed =
            t >= 0.25 &&
            t < 0.75 &&
            into != null &&
            into(entry.item, _dragRows!);
        if (intoAllowed) {
          mode = UtenTableRowDropMode.into;
        } else {
          final upper = intoAllowed ? 0.25 : 0.5;
          final above = t < upper;
          mode = above
              ? UtenTableRowDropMode.above
              : UtenTableRowDropMode.below;
          if (!drag.canDrop(entry.item, _dragRows!)) mode = null;
        }
      }
    }
    final newKey = entry?.key;
    final targetChanged = newKey != _dragTargetKey;
    _dragTargetKey = newKey;
    _dragMode = mode;
    if (targetChanged) {
      _dragHoverTimer?.cancel();
      _dragHoverTimer = null;
      if (entry != null &&
          mode != null &&
          drag.onHoverAutoExpand != null &&
          _dragAutoExpandedKey != entry.key) {
        final key = entry.key;
        final item = entry.item;
        _dragHoverTimer = Timer(drag.hoverAutoExpandDelay, () {
          if (!_dragActive || _dragTargetKey != key) return;
          if (_dragAutoExpandedKey == key) return;
          _dragAutoExpandedKey = key;
          drag.onHoverAutoExpand!(item);
        });
      }
    }
    _updateRowDragIndicator(entry, mode);
  }

  /// 光标位置 → 悬停行条目（越过被拖行本身；多个槽不重叠，取首个命中）。
  _RowDragSlotEntry<T>? _resolveRowDragTarget(Offset global) {
    for (final entry in _dragSlots.values) {
      if (_dragRowKeys.contains(entry.key)) continue;
      final box = entry.context.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      if (box.size.contains(box.globalToLocal(global))) return entry;
    }
    return null;
  }

  void _updateRowDragIndicator(
    _RowDragSlotEntry<T>? entry,
    UtenTableRowDropMode? mode,
  ) {
    if (entry == null || mode == null) {
      _dragIndicator.value = null;
      return;
    }
    final stackBox = _bodyAreaKey.currentContext?.findRenderObject();
    final rowBox = entry.context.findRenderObject();
    if (stackBox is! RenderBox ||
        !stackBox.attached ||
        rowBox is! RenderBox ||
        !rowBox.attached) {
      _dragIndicator.value = null;
      return;
    }
    final topLeft = stackBox.globalToLocal(rowBox.localToGlobal(Offset.zero));
    double top;
    double height;
    switch (mode) {
      case UtenTableRowDropMode.above:
        top = topLeft.dy - 2;
        height = 3;
      case UtenTableRowDropMode.below:
        top = topLeft.dy + rowBox.size.height - 1;
        height = 3;
      case UtenTableRowDropMode.into:
        top = topLeft.dy + 1;
        height = rowBox.size.height - 2;
    }
    _dragIndicator.value = _RowDragIndicatorGeometry(
      left: topLeft.dx + 8,
      width: math.max(80, rowBox.size.width - 16),
      top: top,
      height: height,
      mode: mode,
      label: mode == UtenTableRowDropMode.into
          ? widget.rowDrag?.dragLabelOf?.call(entry.item)
          : null,
    );
  }

  /// 拖到表体上下边缘时自动滚动（离边越近越快）。
  void _scheduleRowDragAutoScroll(Offset global) {
    final box = _bodyAreaKey.currentContext?.findRenderObject();
    ScrollController? controller() {
      if (_bodyV.hasClients && _bodyV.positions.isNotEmpty) return _bodyV;
      final primary = PrimaryScrollController.maybeOf(context);
      if (primary != null &&
          primary.hasClients &&
          primary.positions.isNotEmpty) {
        return primary;
      }
      return null;
    }

    final scroll = controller();
    int? direction;
    if (box is RenderBox && box.attached && scroll != null) {
      final local = box.globalToLocal(global);
      const edge = 64.0;
      if (local.dy >= -24 && local.dy < edge) {
        direction = -1;
      } else if (local.dy > box.size.height - edge &&
          local.dy <= box.size.height + 24) {
        direction = 1;
      }
    }
    if (direction == null) {
      _dragAutoScroll?.cancel();
      _dragAutoScroll = null;
      return;
    }
    if (_dragAutoScroll != null) return;
    _dragAutoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_dragActive ||
          scroll == null ||
          !scroll.hasClients ||
          scroll.positions.isEmpty) {
        _dragAutoScroll?.cancel();
        _dragAutoScroll = null;
        return;
      }
      scroll.position.pointerScroll(direction! * 16);
      final pos = _dragPointerPos.value;
      if (pos != null) _updateRowDragTargets(pos);
    });
  }

  /// 幽灵卡（root Overlay，可越出表体边界）：跟随光标 + 整屏 grabbing 光标。
  void _mountRowDragGhost() {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _dragGhost = OverlayEntry(
      builder: (overlayContext) {
        final theme = Theme.of(overlayContext);
        return Stack(
          children: [
            // 拖拽期间整屏 grabbing 光标；指针事件早已绑定在拾起手势上，这里只
            // 接管鼠标光标与点击兜底。**兜底是硬要求**：拖拽中若宿主重建把行
            // 元素打散、识别器被销毁，指针 up 会无人接收——全屏层若只吞点击，
            // 页面就永久锁死（2026-10-19 用户实测「展开后整页卡死」）。任何一次
            // 按下都就地取消拖拽，保证这条路径永远可解锁；ESC 同效。
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _cancelRowDrag(),
                child: const MouseRegion(
                  cursor: SystemMouseCursors.grabbing,
                  child: SizedBox.expand(),
                ),
              ),
            ),
            ValueListenableBuilder<Offset?>(
              valueListenable: _dragPointerPos,
              builder: (_, pos, _) {
                if (pos == null) return const SizedBox.shrink();
                return Positioned(
                  left: math.max(8, pos.dx + 18),
                  top: math.max(8, pos.dy + 14),
                  child: _buildRowDragGhostCard(theme),
                );
              },
            ),
          ],
        );
      },
    );
    overlay.insert(_dragGhost!);
  }

  Widget _buildRowDragGhostCard(ThemeData theme) {
    final count = _dragRowKeys.length;
    final label = _dragLabel;
    return Material(
      elevation: 10,
      borderRadius: UtenRadius.mdAll,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.drag_indicator_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                (label == null || label.trim().isEmpty) ? '移动行' : label.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (count > 1) ...[
              const SizedBox(width: UtenSpacing.s8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(UtenRadius.pill),
                ),
                child: Text(
                  '$count 行',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _finishRowDrag(Offset global) async {
    if (!_dragActive) return;
    if (_rowDragLifecycle?.isAvailable == false) {
      _cancelRowDrag();
      return;
    }
    final drag = widget.rowDrag!;
    final rows = _dragRows!;
    _updateRowDragTargets(global);
    final targetEntry = _dragTargetKey == null
        ? null
        : _dragSlots[_dragTargetKey!];
    final mode = _dragMode;
    final targetItem = targetEntry?.item;
    _resetRowDragState();
    if (targetItem == null || mode == null) return;
    if (_dragKeyOf(targetItem) case final key?) {
      if (_dragRowKeys.contains(key)) return;
    }
    // 持久化、busy 遮罩、成功/失败反馈与重载全由宿主负责（见 UtenTableRowDrag.onDrop）。
    await drag.onDrop(rows, targetItem, mode);
  }

  void _cancelRowDrag({bool rebuild = true}) {
    if (!_dragActive) return;
    _resetRowDragState(rebuild: rebuild);
  }

  void _resetRowDragState({bool rebuild = true}) {
    _dragAutoScroll?.cancel();
    _dragAutoScroll = null;
    _dragHoverTimer?.cancel();
    _dragHoverTimer = null;
    _dragRetracking?.cancel();
    _dragRetracking = null;
    _rowDragLifecycle?.dispose();
    _rowDragLifecycle = null;
    _dragGhost?.remove();
    _dragGhost = null;
    void resetVisuals() {
      _dragPointerPos.value = null;
      _dragIndicator.value = null;
      _dragOriginKey.value = null;
    }

    if (rebuild) {
      resetVisuals();
    } else {
      // Deactivation can run while the element tree is locked. Stop ownership
      // immediately, then notify any retained row/overlay listeners after it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_dragActive) resetVisuals();
      });
    }
    _dragTargetKey = null;
    _dragMode = null;
    _dragAutoExpandedKey = null;
    _dragSource = null;
    void resetRows() {
      _dragRows = null;
      _dragRowKeys = const <String>{};
      _dragLabel = null;
    }

    if (rebuild) {
      setState(resetRows);
    } else {
      resetRows();
    }
  }

  /// 表体 Stack 里的落点指示层（ValueNotifier 驱动，不整表重建）。
  Widget _buildRowDragIndicatorLayer() => Positioned.fill(
    child: IgnorePointer(
      child: ValueListenableBuilder<_RowDragIndicatorGeometry?>(
        valueListenable: _dragIndicator,
        builder: (context, geo, _) {
          if (geo == null) return const SizedBox.shrink();
          final theme = Theme.of(context);
          return SizedBox.expand(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedPositioned(
                  key: const ValueKey('row-drag-indicator'),
                  duration: const Duration(milliseconds: 110),
                  curve: Curves.easeOutCubic,
                  left: geo.left,
                  top: geo.top,
                  width: geo.width,
                  height: geo.height,
                  child: _buildRowDragIndicatorVisual(theme, geo),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );

  Widget _buildRowDragIndicatorVisual(
    ThemeData theme,
    _RowDragIndicatorGeometry geo,
  ) {
    final color = theme.colorScheme.primary;
    if (geo.mode == UtenTableRowDropMode.into) {
      final label = geo.label?.trim();
      return Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(UtenRadius.sm),
          border: Border.all(color: color, width: 1.6),
        ),
        alignment: Alignment.center,
        child: (label == null || label.isEmpty)
            ? null
            : Container(
                constraints: const BoxConstraints(maxWidth: 320),
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(UtenRadius.pill),
                ),
                child: Text(
                  '移入「$label」',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(UtenRadius.xs),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

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
    return UtenFloatingActionGroup(
      key: _floatingBatchKey,
      onMinimumContentHeightChanged: _usesBoundedFloatingBatchActions
          ? _onFloatingBatchMinimumContentHeightChanged
          : null,
      maxHeight: _usesBoundedFloatingBatchActions
          ? math.max(
              _floatingBatchHeightLimit ?? 0,
              _minimumFloatingBatchHeight(context),
            )
          : null,
      children: children,
    );
  }

  /// 前导分组标题行：计划行仍跨满表宽（_totalWidth），行内容经 [_ViewportPinnedRow]
  /// 钉在视口左缘——表格横向滚动时文案不动，任何横滚位置都看得见、点得到。
  /// 底色取 [MasterDataGroup.tint]（禁用=灰淡底等）；点击切换展开。
  /// 单行布局：图标 + 标题（加粗）+ 副标题（灰、可省略号）+「下拉查看详情」加粗深红 +
  /// 旋转箭头，逐段左起相邻排布（不用 Expanded 推到行尾，2026-10-24 口径）。
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
                  // 文案逐段左起相邻排布，展开提示紧跟其后——不用 Expanded 把
                  // 「下拉查看详情」推到行右端（2026-10-24 口径：行已钉视口左缘，
                  // 右端远在可视区外，提示与文案相邻才看得见）。
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
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (moreLeft && expanded)
                    Padding(
                      padding: const EdgeInsets.only(left: UtenSpacing.s8),
                      child: Text(
                        '仅前 ${group.items.length}/${group.total}', // TODO(l10n): 补 arb
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(width: UtenSpacing.s8),
                  if (expanded && group.loading) ...[
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Flexible(
                      child: Text(
                        '正在加载',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                  ] else if (expanded && hasError)
                    Flexible(
                      child: Tooltip(
                        message: error,
                        child: TextButton.icon(
                          onPressed: group.onRetry ?? group.onExpand,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text(
                            '加载失败，重试',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: Text(
                        group.detailLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: detailStyle,
                      ),
                    ),
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
            // 左线隔开滚过的列头；右线收住末列边缘。
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
    final visibleIndices = _visibleIndices;
    bool showRightDivider(int index) => true;
    // 多选表头三态全选格（合成单元格）：false=本页全未选 / true=全选 / 空=部分。
    // 横滚时钉在视口左缘（[UtenFrozenLeadingColumn]），行内留等宽占位保持列对齐。
    // showSelectionColumn=false 时不渲染（该格与整列一起退场，本变量不再挂载）。
    final pageIds = _hasSelectionColumn
        ? _pageSelectableIds()
        : const <String>{};
    final headerSelectionCell = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(right: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Center(
        child: Checkbox(
          key: const Key('master-data-table-select-all'),
          tristate: true,
          value: _headerCheckValue(pageIds),
          onChanged: pageIds.isEmpty ? null : _onToggleAllPage,
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
            if (_hasSelectionColumn)
              SizedBox(width: _selectionColWidth, child: headerSelectionCell),
            for (final i in pinnedIndices)
              _headerColumnCell(
                theme,
                i,
                frozen: true,
                showRightDivider: showRightDivider(i),
              ),
          ],
        ),
      ),
    );
    return _boundStretchRow(
      // 换位拖动中在表头行上渲染插入位指示线（前导选择列让位）。
      columnHeaderIndicatorOverlay(
        leadingInset: _hasSelectionColumn ? _selectionColWidth : 0,
        child: _withFrozenLeadingRegion(
          controller: _headerH,
          width: _pinnedLeadingWidth(pinnedIndices),
          cell: frozenHeaderRegion,
          row: Row(
            crossAxisAlignment: _selectableCross,
            children: [
              if (_hasSelectionColumn)
                SizedBox(width: _selectionColWidth, child: headerSelectionCell),
              for (final i in visibleIndices)
                _headerColumnCell(
                  theme,
                  i,
                  frozen: false,
                  showRightDivider: showRightDivider(i),
                ),
              if (widget.showColumnChooser)
                SizedBox(width: 48, height: 48, child: _platformAddButton()),
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
      fallbackWidth: _hasSelectionColumn ? _selectionColWidth : 0,
      trailingWidth: widget.showColumnChooser ? 48 : 0,
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
  Widget _headerColumnCell(
    ThemeData theme,
    int i, {
    required bool frozen,
    required bool showRightDivider,
  }) {
    final pinned = _presentationPinnedKeys.contains(_columns[i].key);
    // filterFromRows 列：桶由当前行就地构建、值与回调走组件内部状态；
    // 否则维持宿主 facets/filters/onFilterChanged 的服务端链路。
    final rowFacets = _rowFacetsFor(_columns[i]);
    // 宿主接了 onSortChange → 排序走服务端（sortActive 以宿主状态为准）；
    // 没接（全量加载表）→ sortable 列就地排序，取消排序传 null 列。
    final serverSort = widget.onSortChange != null;
    final sortKey = _columns[i].key;
    final localSortActive = !serverSort && _localSortColumn == sortKey;
    final queryRevision = _queryRestoreRevision;
    final filterCell = _FilterCell(
      label: _columns[i].label,
      filterAction: _columns[i].headerFilterAction,
      facetSearchEnabled: _columns[i].facetSearchEnabled,
      selectedBucket: _selectedFacetBuckets[sortKey],
      onBucketSelected: (bucket) {
        if (bucket == null) {
          _selectedFacetBuckets.remove(sortKey);
        } else {
          _selectedFacetBuckets[sortKey] = bucket;
        }
      },
      loadFacetPage:
          rowFacets == null &&
              (widget.facetPageLoaders.containsKey(sortKey) ||
                  widget.facets.containsKey(sortKey))
          ? widget.facetPageLoaders[sortKey] ??
                (widget.loadFacetPage == null
                    ? null
                    : (search, page) =>
                          widget.loadFacetPage!(sortKey, search, page))
          : null,
      searchScope: (
        widget.facetSearchScope ?? widget.paginationScope,
        _platform.queryLifecycle,
      ),
      isCurrent: () => mounted && queryRevision == _queryRestoreRevision,
      search: _columns[i].supportsKeywordSearch
          ? _columnSearch(_columns[i].key)
          : null,
      onSearch: _columns[i].supportsKeywordSearch
          ? (value) => _searchColumn(_columns[i].key, value)
          : null,
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
      info: _headerInfo(_columns[i]),
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
      onChanged: (value) {
        final key = _columns[i].key;
        setState(() {
          _columnSearches.remove(key);
          if (rowFacets != null) _rowFilters[key] = value;
          _persistQuery(filterChanges: {key: value, 'search.$key': null});
        });
        if (widget.filters['search.$key'] != null) {
          widget.onFilterChanged('search.$key', null);
        }
        if (rowFacets == null) widget.onFilterChanged(key, value);
      },
    );
    // 右键菜单挂在内容外层：桌面右击弹「固定/移动/隐藏」菜单（表头专用 region：
    // 不挂长按——触屏长按/按下即拖已让给列换位/移除手势；并压制系统右键
    // 「全选/复制」工具条，此前右击表头弹的就是那个）。
    final trailing = _columns[i].headerTrailingBuilder?.call(context);
    final Widget content = UtenColumnHeaderMenuRegion(
      entriesBuilder: () => _headerMenuEntries(i),
      child: Row(
        children: [
          Expanded(
            child: frozen
                ? filterCell
                : _buildDraggableHeaderCell(theme, i, filterCell),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: _gripHalf * 2),
              child: trailing,
            ),
        ],
      ),
    );
    return Container(
      width: _widths[i],
      // 表头竖线分隔（与 UtenEditableGrid 表头一致：outline/width1）。
      decoration: BoxDecoration(
        border: Border(
          right: showRightDivider
              ? BorderSide(color: theme.colorScheme.outline)
              : BorderSide.none,
        ),
      ),
      child: Stack(
        children: [
          content,
          // 列边界命中区完整留在当前列内；与编辑表共用鼠标/键盘/RTL/恢复交互。
          // opaque 截获该区点击（避免误开筛选下拉）；横向拖拽改本列宽，
          // 桌面端悬停显示 resize 光标作为可调提示。
          PositionedDirectional(
            end: 0,
            top: 0,
            bottom: 0,
            width: _gripHalf * 2,
            child: UtenColumnResizeHandle(
              label: _columns[i].label,
              onResize: (delta) => _resizeColumn(i, delta),
              onReset: () => _resetColumnWidth(i),
            ),
          ),
        ],
      ),
    );
  }

  /// 拖拽改第 [index] 列宽：按本次横向增量更新，下限 [_minColWidth] 防拖没；
  /// 标记该列已手动调整，后续数据刷新不再自动重算其宽度。
  void _resizeColumn(int index, double dx) {
    final next = math.max(
      _minimumColumnWidth(context, _columns[index]),
      _widths[index] + dx,
    );
    setState(() {
      _widths[index] = next;
      _manualResized.add(index);
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  void _resetColumnWidth(int index) {
    setState(() {
      _manualResized.remove(index);
      _resetWidthKeys.add(_columns[index].key);
      _widthsDirty = true;
    });
    _fsTick.value++;
    _persistPlatformLayout();
  }

  /// 单个数据格：列宽 + 语义底色（cellColor）+ 列间竖线 + 内边距 + 内容。
  /// 底色与文字始终双向保证对比度：深底（如缺口列的 error 实底）切白字，
  /// 浅底（暗色主题下 error/primary/tertiary 等浅色作为底色时）切深字——
  /// 只处理深底会在暗色主题里留下「浅底白字」的不可读组合。
  /// 状态/进度列文字加粗（2026-10-08 用户口径「状态里面得字体统一加粗」）。
  static TextStyle _cellTextStyle(
    TextStyle base,
    Color? onCellColor, {
    required bool bold,
    Color? emphasisColor,
  }) {
    var style = base;
    if (onCellColor != null) style = style.copyWith(color: onCellColor);
    if (bold) style = style.copyWith(fontWeight: FontWeight.w700);
    // 重点核对列红字加粗（2026-10-10 财务口径）：语义底色对比色优先（不叠加，
    // 避免红字压深底不可读），无底色列整列红。
    if (emphasisColor != null && onCellColor == null) {
      style = style.copyWith(color: emphasisColor, fontWeight: FontWeight.w800);
    }
    return style;
  }

  String _textSelectionRowKey(T item) =>
      widget.rowKeyOf?.call(item) ??
      widget.idOf?.call(item) ??
      _columns.map((column) => column.value(item)).join('\u0000');

  Widget _buildDataCell(
    ThemeData theme,
    int columnIndex,
    T item,
    bool selected,
    TextStyle textStyle, {
    required bool showRightDivider,
    bool frozen = false,
  }) {
    final column = _columns[columnIndex];
    // 选中行整行青绿实底（utenTableSelectedRowColor，与编辑网格同款，2026-09-13
    // 全站统一口径、2026-09-22 加深），文字保持常态深色——语义底色（cellColor）在
    // 选中行上让位给统一选中色，保证选中行读作一个整体。
    Widget buildCell() {
      // 状态底色只认列定义的显式 cellColor(ADR-169 逐页独立口径);
      // 未显式映射的状态列保持无色纯文本, 不再按文案关键字猜色。
      final cellColor = selected ? null : column.cellColor?.call(context, item);
      final Color? onCellColor = cellColor == null
          ? null
          : utenSemanticCellForeground(context, cellColor);
      // 状态/进度列文字统一加粗(2026-10-08 用户口径); 格内自定义 builder 经
      // DefaultTextStyle.merge 继承本样式, 自带 color 的 builder 会压掉继承——
      // 状态列 builder 里不许再写死颜色。
      final cellStyle = _cellTextStyle(
        textStyle,
        onCellColor,
        bold: utenIsStatusOrProgressColumn(column.key, column.label),
        emphasisColor: column.emphasized
            ? (Theme.of(context).brightness == Brightness.dark
                  ? UtenColors.errorOnDark
                  : UtenColors.errorText)
            : null,
      );
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
                  right: showRightDivider
                      ? BorderSide(color: theme.colorScheme.outline, width: 0.5)
                      : BorderSide.none,
                )
              : Border(
                  top: BorderSide(color: theme.colorScheme.outline, width: 0.5),
                  bottom: BorderSide(
                    color: theme.colorScheme.outline,
                    width: 0.5,
                  ),
                  right: showRightDivider
                      ? BorderSide(color: theme.colorScheme.outline, width: 0.5)
                      : BorderSide.none,
                ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: _columnHorizontalPadding(context, column),
            vertical: widget.dataCellVerticalPadding,
          ),
          child: _dataCell(column, item, cellStyle, selected),
        ),
      );
    }

    // Selection changes only the colors. Removing the listener wrapper when a
    // row is selected would remount its editor and lose focus/IME composition.
    final listenableOf = column.cellColorListenableOf;
    final cell = listenableOf == null
        ? buildCell()
        : ListenableBuilder(
            listenable: listenableOf(item) ?? const AlwaysStoppedAnimation(0),
            builder: (context, _) => buildCell(),
          );
    if (frozen || !_presentationPinnedKeys.contains(column.key)) return cell;
    return AnimatedBuilder(
      animation: utenTableHorizontalChanges(_bodyH),
      child: cell,
      builder: (context, child) => UtenTableTextSelectionGate(
        enabled: !_hasFrozenDataColumns(_bodyH),
        child: child!,
      ),
    );
  }

  Widget _buildDataRow(ThemeData theme, T item) => _profileMasterTableWork(
    'master.row-build',
    () => UtenTableCellInputTheme(child: _buildDataRowImpl(theme, item)),
  );

  Widget _buildAppendRow(
    ThemeData theme,
    MasterTableAppendRow row,
    double total,
    double viewportWidth,
  ) {
    final line = BorderSide(color: theme.colorScheme.outline, width: 0.5);
    Widget cell(int i) => Container(
      width: _widths[i],
      decoration: BoxDecoration(border: Border(right: line)),
      padding: EdgeInsets.symmetric(
        horizontal: _columnHorizontalPadding(context, _columns[i]),
        vertical: widget.dataCellVerticalPadding,
      ),
      child: row.cellBuilder(context, _columns[i].key),
    );
    Widget cells(List<int> indices, {bool chooser = false}) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_hasSelectionColumn)
            Container(
              width: _selectionColWidth,
              decoration: BoxDecoration(border: Border(right: line)),
            ),
          for (final i in indices) cell(i),
          if (chooser && widget.showColumnChooser) const SizedBox(width: 48),
        ],
      ),
    );
    final pinned = _pinnedVisibleIndices;
    final body = UtenTableCellInputTheme(
      child: DefaultTextStyle.merge(
        style: theme.textTheme.bodyMedium,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: line, right: line),
          ),
          child: _withFrozenLeadingRegion(
            controller: _bodyH,
            width: _pinnedLeadingWidth(pinned),
            cell: ColoredBox(
              color: theme.colorScheme.surface,
              child: cells(pinned),
            ),
            row: cells(_visibleIndices, chooser: true),
          ),
        ),
      ),
    );
    final details = row.detailsBuilder?.call(context, [
      for (final i in _visibleIndices) _columns[i].key,
    ]);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        body,
        if (details != null)
          _ViewportPinnedRow(
            controller: _bodyH,
            contentWidth: total,
            fallbackViewportWidth: viewportWidth,
            child: details,
          ),
      ],
    );
  }

  Widget _buildDataRowImpl(ThemeData theme, T item) {
    final knownHeight = _knownPlainRowHeight(theme);
    final visibleIndices = _visibleIndices;
    bool showRightDivider(int index) => true;
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
    final textStyle = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: widget.rowForegroundColor?.call(item));
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
      data: _selectionCheckboxTheme(Theme.of(context)),
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
        (pinnedIndices.isEmpty && !_hasSelectionColumn)
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
                    if (_hasSelectionColumn)
                      SizedBox(width: _selectionColWidth, child: selectionCell),
                    for (final i in pinnedIndices)
                      _buildDataCell(
                        theme,
                        i,
                        item,
                        selected,
                        textStyle,
                        showRightDivider: showRightDivider(i),
                        frozen: true,
                      ),
                  ],
                ),
                knownHeight: knownHeight,
              ),
            ),
          );
    final undecoratedRow = DecoratedBox(
      // 行间横线：逐行分隔；选中行也用常态横线（底色由下面的 ColoredBox 统一给）。
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: lineColor, width: 0.5),
          right: BorderSide(color: lineColor, width: 0.5),
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
                if (_hasSelectionColumn)
                  SizedBox(width: _selectionColWidth, child: selectionCell),
                for (final i in visibleIndices)
                  _buildDataCell(
                    theme,
                    i,
                    item,
                    selected,
                    textStyle,
                    showRightDivider: showRightDivider(i),
                  ),
                if (widget.showColumnChooser) const SizedBox(width: 48),
              ],
            ),
          ),
          knownHeight: knownHeight,
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
        widget.onRowDoubleTap == null &&
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
      final rowKey =
          widget.rowKeyOf?.call(item) ??
          widget.idOf?.call(item) ??
          'cells:${_columns.map((c) => c.value(item) ?? '').join(' ')}';
      interactive = InkWell(
        onTap: () {
          // 存在文字框选时，单击的第一职责是取消框选（Excel/浏览器口径），
          // 不再顺带切换行选中——否则「点一下想让选区消失」变成「选中了一行」。
          if (_textSelection.hasSelection) {
            _textSelection.clear();
            return;
          }
          if (widget.onRowDoubleTap != null &&
              (widget.canOpenRow?.call(item) ?? true)) {
            final now = clock.now();
            final doubleTap =
                _lastTapRowKey == rowKey &&
                now.difference(_lastTapAt) <= _kDoubleClickWindow;
            _lastTapRowKey = doubleTap ? null : rowKey;
            _lastTapAt = now;
            if (doubleTap) {
              final id = widget.idOf?.call(item);
              if (widget.selectable &&
                  id != null &&
                  !widget.selectedIds.contains(id)) {
                _toggleRow(item, true);
              }
              widget.onRowDoubleTap!(item);
              return;
            }
          }
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
          // 同上：框选存在时单击只清框选，不进入选中/双击判定（清掉后下一击
          // 恢复正常行交互），避免「想关掉选区却把行选中了」。
          if (_textSelection.hasSelection) {
            _textSelection.clear();
            return;
          }
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
        entriesBuilder: () {
          return [
            if (widget.enableTextSelection)
              ..._textSelection.copyMenuEntries(context),
            ...rowMenuBuilder(item),
          ];
        },
        onMenuOpening: selectRowForMenu,
        onActionCompleted: clearSelectionAfterMenuAction,
        child: interactive,
      );
    }
    return interactive;
  }

  /// 工具条右端的紧凑分页（2026-10-18 用户口径：翻页条从表格下方上移到表头
  /// 上方工具条右上角，与「表头设置 / 全屏」同一行；页码输入框收窄）。窄宽下
  /// 逐级降级：先收起跳页框改整段「当前页 / 总页数」，再叠成两行——保持完整
  /// 命中目标，短窗滚动整条表格呈现而不是裁掉控件。
  Widget? _buildToolbarPager(BuildContext context) {
    if (!widget.showPaginationControls || widget.totalPages <= 1) return null;
    final theme = Theme.of(context);
    final canPrev = !_busy && _currentPage > 1;
    final canNext = !_busy && _currentPage < widget.totalPages;
    // 桌面紧凑款：命中目标 32、页码框 40×28、数字 15px 半粗、翻页 icon 24；
    // 触控保持完整 48 目标（缩放补偿）。数字与 icon 比正文更重（2026-10-18
    // 用户口径「数字加粗大一点，特别是翻页 icon」）。
    final touch = UtenControlMetrics.usesTouchTargets(context);
    final hitExtent = UtenControlMetrics.minimumHitExtent(context, desktop: 32);
    final inputExtent = touch ? hitExtent : 28.0;
    final pageInputWidth = touch ? math.max(48.0, hitExtent) : 40.0;
    final pageTextStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
    );
    double widthOf(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: theme.textTheme.bodyMedium),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    void goto(int page) => _gotoPage(page);
    Widget chevron(bool forward) => IconButton(
      key: ValueKey(
        forward ? 'master-table-page-next' : 'master-table-page-previous',
      ),
      constraints: BoxConstraints.tightFor(width: hitExtent, height: hitExtent),
      padding: EdgeInsets.zero,
      onPressed: (forward ? canNext : canPrev) && widget.onPageChange != null
          ? () => goto(_currentPage + (forward ? 1 : -1))
          : null,
      tooltip: forward ? '下一页' : '上一页', // TODO(l10n): 补 arb
      icon: Icon(
        forward ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
        size: 24,
      ),
    );
    // 页码框宽度随已输入位数自动加宽（2026-10-18 用户口径：数字长框变长）：
    // 1 位 = 基础宽，每多一位 +9、封顶 +64；右簇贴右锚定，视觉上向左生长。
    Widget pageField() => ValueListenableBuilder<TextEditingValue>(
      valueListenable: _pageCtrl,
      builder: (context, value, _) {
        final digits = value.text.trim().length;
        final width = math.min(
          pageInputWidth + math.max(0, digits - 1) * 9.0,
          pageInputWidth + 64,
        );
        return SizedBox(
          width: width,
          child: TextFormField(
            errorBuilder: utenTextFieldErrorBuilder,
            controller: _pageCtrl,
            focusNode: _pageFocus,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            textAlignVertical: TextAlignVertical.center,
            style: pageTextStyle,
            decoration: UtenInputDecoration(
              InputDecoration(
                constraints: BoxConstraints(
                  minHeight: inputExtent,
                  maxHeight: inputExtent,
                ),
                isDense: true,
                hintText: '页码', // TODO(l10n): 补 arb
                hintStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 3,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(UtenRadius.control),
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
        );
      },
    );

    final totalText = '/ ${widget.totalPages}'; // TODO(l10n): 补 arb
    final counterText = '$_currentPage / ${widget.totalPages}';
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (!width.isFinite ||
            width >=
                2 * hitExtent +
                    pageInputWidth +
                    widthOf(totalText) +
                    3 * UtenSpacing.s4) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              chevron(false),
              const SizedBox(width: UtenSpacing.s4),
              pageField(),
              const SizedBox(width: UtenSpacing.s4),
              Text(
                totalText,
                style: pageTextStyle?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: UtenSpacing.s4),
              chevron(true),
            ],
          );
        }
        if (width >=
            2 * hitExtent + 2 * UtenSpacing.s8 + widthOf(counterText)) {
          return Row(
            children: [
              chevron(false),
              Expanded(
                child: Text(
                  counterText,
                  textAlign: TextAlign.center,
                  style: pageTextStyle,
                ),
              ),
              chevron(true),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              counterText,
              textAlign: TextAlign.center,
              style: pageTextStyle,
            ),
            const SizedBox(height: UtenSpacing.s4),
            if (width >= 2 * hitExtent + UtenSpacing.s8)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [chevron(false), chevron(true)],
              )
            else
              Column(
                children: [
                  chevron(false),
                  const SizedBox(height: UtenSpacing.s4),
                  chevron(true),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// The status owns one ticker; table rows are outside its animated subtree.
/// Explicit height-factor animation avoids RenderAnimatedSize's child-size
/// correction mutating its own layout when a covered route changes TickerMode.
class _MasterTableRefreshTransition extends StatefulWidget {
  const _MasterTableRefreshTransition({
    super.key,
    required this.visible,
    required this.duration,
    required this.child,
  });

  final bool visible;
  final Duration duration;
  final Widget child;

  @override
  State<_MasterTableRefreshTransition> createState() =>
      _MasterTableRefreshTransitionState();
}

class _MasterTableRefreshTransitionState
    extends State<_MasterTableRefreshTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.visible ? 1 : 0,
  );
  late final _height = CurvedAnimation(
    parent: _controller,
    curve: UtenAnim.standard,
  );
  late Widget _shownChild = widget.child;

  @override
  void didUpdateWidget(covariant _MasterTableRefreshTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) _shownChild = widget.child;
    _controller.duration = widget.duration;
    final target = widget.visible ? 1.0 : 0.0;
    if (widget.duration == Duration.zero) {
      _controller.value = target;
    } else if (widget.visible != oldWidget.visible ||
        widget.duration != oldWidget.duration) {
      widget.visible ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _height.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: _shownChild,
    builder: (_, child) => ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: _height.value,
        child: ExcludeSemantics(
          excluding: _controller.isDismissed,
          child: TickerMode(
            enabled: !_controller.isDismissed,
            child: Offstage(offstage: _controller.isDismissed, child: child!),
          ),
        ),
      ),
    ),
  );
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
    this.loadFacetPage,
    this.searchScope,
    this.isCurrent,
    this.selectedBucket,
    this.onBucketSelected,
    required this.onSearch,
    this.search,
    this.sortKey,
    this.type = 'text',
    this.sortable = false,
    this.sortActive = false,
    this.sortAscending = true,
    this.onSort,
    this.info,
    this.leading,
    this.filterAction,
    this.facetSearchEnabled = false,
  });

  final String label;
  final List<MasterFacetBucket> buckets;
  final int nullCount;
  final String? selected;
  final ValueChanged<String?> onChanged;
  final Future<MasterFacetPage> Function(String search, int page)?
  loadFacetPage;
  final Object? searchScope;
  final bool Function()? isCurrent;
  final MasterFacetBucket? selectedBucket;
  final ValueChanged<MasterFacetBucket?>? onBucketSelected;
  final ValueChanged<String?>? onSearch;
  final String? search;
  final MasterHeaderFilterAction? filterAction;
  final bool facetSearchEnabled;

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
  UtenOverlayLifecycle? _overlayLifecycle;

  /// 文本列输入同时查询候选；回车或按钮另行提交表格关键词。
  TextEditingController? _searchCtl;
  Timer? _searchDebounce;
  int _searchRevision = 0;
  int? _fetchingRevision;
  List<MasterFacetBucket> _remoteBuckets = const [];
  bool _remoteLoading = false;
  bool _remoteHasMore = false;
  bool _remoteFailed = false;
  int _remotePage = 0;
  String _remoteQuery = '';
  bool _remoteComposing = false;
  TextEditingValue? _lastSearchValue;

  /// 切换分类后旧选中值可能不在新 facet：sanitize 退回"所有"。
  String? get _sanitized {
    final validValues = <String>{for (final b in widget.buckets) b.value};
    return (widget.selected == null ||
            widget.loadFacetPage != null ||
            widget.selectedBucket?.value == widget.selected ||
            widget.selected == kMasterFilterNullValue ||
            validValues.contains(widget.selected))
        ? widget.selected
        : null;
  }

  void _open() {
    if (!(widget.isCurrent?.call() ?? true)) return;
    if (_overlay != null) return;
    _searchCtl = TextEditingController(text: widget.search ?? '');
    _remoteComposing = false;
    _lastSearchValue = _searchCtl!.value;
    if (widget.loadFacetPage != null) {
      _searchCtl!.addListener(_remoteEditingChanged);
    }
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
    _overlayLifecycle = UtenOverlayLifecycle(onUnavailable: _close);
    _overlayLifecycle!.attach(context);
    if (_overlay == null) return;
    if (widget.loadFacetPage != null) {
      _searchRemote(_searchCtl!.text, immediate: true);
    }
  }

  void _close() {
    _overlayLifecycle?.dispose();
    _overlayLifecycle = null;
    _searchRevision++;
    _searchDebounce?.cancel();
    _overlay?.remove();
    _overlay = null;
    _searchCtl?.dispose();
    _searchCtl = null;
  }

  @override
  void didUpdateWidget(covariant _FilterCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sortKey != widget.sortKey ||
        oldWidget.searchScope != widget.searchScope ||
        oldWidget.search != widget.search ||
        oldWidget.filterAction?.value != widget.filterAction?.value ||
        oldWidget.filterAction?.enabled != widget.filterAction?.enabled ||
        (oldWidget.onSearch == null) != (widget.onSearch == null) ||
        (oldWidget.loadFacetPage == null) != (widget.loadFacetPage == null)) {
      _close();
    }
  }

  void _searchRemote(String value, {bool immediate = false}) {
    if (!(widget.isCurrent?.call() ?? true)) return;
    _searchDebounce?.cancel();
    final revision = ++_searchRevision;
    _remoteQuery = value.trim();
    _remoteBuckets = const [];
    _remotePage = 0;
    _remoteHasMore = false;
    _remoteFailed = false;
    _remoteLoading = true;
    _overlay?.markNeedsBuild();
    if (immediate) {
      _fetchRemote(revision, 1);
    } else {
      _searchDebounce = Timer(
        const Duration(milliseconds: 250),
        () => _fetchRemote(revision, 1),
      );
    }
  }

  void _remoteEditingChanged() {
    final value = _searchCtl?.value;
    if (value == null ||
        (_lastSearchValue?.text == value.text &&
            _lastSearchValue?.composing == value.composing)) {
      return;
    }
    _lastSearchValue = value;
    _remoteComposing = value.composing.isValid && !value.composing.isCollapsed;
    if (_remoteComposing) {
      _searchDebounce?.cancel();
      _searchRevision++;
      _remoteBuckets = const [];
      _remoteHasMore = false;
      _remoteFailed = false;
      _remoteLoading = false;
      _overlay?.markNeedsBuild();
      return;
    }
    _searchRemote(value.text);
  }

  Future<void> _fetchRemote(int revision, int page) async {
    if (!(widget.isCurrent?.call() ?? true)) return;
    if (_fetchingRevision == revision) return;
    _fetchingRevision = revision;
    _remoteLoading = true;
    _remoteFailed = false;
    _overlay?.markNeedsBuild();
    try {
      final result = await widget.loadFacetPage!(_remoteQuery, page);
      if (!mounted ||
          _overlay == null ||
          revision != _searchRevision ||
          !(widget.isCurrent?.call() ?? true)) {
        return;
      }
      _fetchingRevision = null;
      final byValue = <String, MasterFacetBucket>{
        if (page > 1)
          for (final bucket in _remoteBuckets) bucket.value: bucket,
        for (final bucket in result.items) bucket.value: bucket,
      };
      _remoteBuckets = byValue.values.toList();
      _remoteHasMore = result.hasMore;
      _remotePage = page;
      _remoteLoading = false;
      _overlay?.markNeedsBuild();
    } catch (_) {
      if (!mounted ||
          _overlay == null ||
          revision != _searchRevision ||
          !(widget.isCurrent?.call() ?? true)) {
        return;
      }
      _fetchingRevision = null;
      _remoteLoading = false;
      _remoteFailed = true;
      _overlay?.markNeedsBuild();
    }
  }

  void _select(String? value, {MasterFacetBucket? bucket}) {
    if (!mounted || _overlay == null || !(widget.isCurrent?.call() ?? true)) {
      return;
    }
    widget.onBucketSelected?.call(widget.loadFacetPage == null ? null : bucket);
    widget.onChanged(value);
    _close();
  }

  void _submitSearch() {
    final value = _searchCtl?.value;
    final submit = widget.onSearch;
    if (!mounted ||
        _overlay == null ||
        !(widget.isCurrent?.call() ?? true) ||
        submit == null ||
        value == null ||
        (value.composing.isValid && !value.composing.isCollapsed)) {
      return;
    }
    final text = value.text.trim();
    widget.onBucketSelected?.call(null);
    _close();
    submit(text.isEmpty ? null : text);
  }

  @override
  void deactivate() {
    _close();
    super.deactivate();
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
    final hasFacets =
        widget.loadFacetPage != null ||
        widget.buckets.isNotEmpty ||
        widget.nullCount > 0;
    // 无 facets 且不可排序的列（如部分单据列表的纯标签列头）→ 纯标签，不渲染下拉/排序。
    // 这样文档页可直接复用 MasterDataTableView，与基础资料布局完全一致。
    final interactive =
        widget.filterAction != null ||
        hasFacets ||
        s != null ||
        widget.sortable ||
        widget.onSearch != null;
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
            // _headerInfoWidth，这里只补渲染，不占额外量宽。
            if (widget.info != null) ...[
              const SizedBox(width: UtenSpacing.s4),
              UtenColumnHintIcon(message: widget.info!),
            ],
          ],
        ),
      );
    }
    final filtered =
        widget.filterAction?.value != null ||
        s != null ||
        widget.search != null;
    final highlighted = filtered || widget.sortActive;
    // 选中值用对应桶的展示名（颜色/单位 legacy id → 名称）；找不到回落原值。
    String display;
    if (widget.filterAction?.value != null) {
      display = '${widget.label}：${widget.filterAction!.value}';
    } else if (widget.search != null) {
      display = '${widget.label}：${widget.search}';
    } else if (s == null) {
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
      display =
          sel ??
          (widget.selectedBucket?.value == s
              ? widget.selectedBucket?.display
              : null) ??
          s;
    }

    return CompositedTransformTarget(
      link: _link,
      child: InkWell(
        key: ValueKey('master-column-filter-${widget.sortKey}'),
        onTap: widget.filterAction != null
            ? widget.filterAction!.enabled
                  ? () {
                      if (widget.isCurrent?.call() ?? true) {
                        widget.filterAction!.onTap();
                      }
                    }
                  : null
            : interactive
            ? _open
            : null,
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
                child: Align(
                  alignment: Alignment.centerLeft,
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
              ),
              // 列头说明 ⓘ：悬停出 Tooltip，点击（含手机）弹说明小窗——
              // 自吞点击，不触发排序/筛选菜单。
              if (widget.info != null) ...[
                const SizedBox(width: UtenSpacing.s4),
                UtenColumnHintIcon(message: widget.info!),
              ],
              // 排序与筛选共用一个菜单入口；当前排序方向直接替换下拉箭头。
              if (interactive)
                Icon(
                  widget.sortActive
                      ? (widget.sortAscending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded)
                      : Icons.arrow_drop_down_rounded,
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
    if (!(widget.isCurrent?.call() ?? true)) return;
    widget.onSort?.call(column, ascending);
    _close();
  }

  Widget _buildOverlay(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final sanitized = _sanitized;
    final hasFacets =
        widget.loadFacetPage != null ||
        widget.buckets.isNotEmpty ||
        widget.nullCount > 0;
    final viewport = MediaQuery.sizeOf(ctx);
    final target = context.findRenderObject()! as RenderBox;
    final position = target.localToGlobal(Offset.zero);
    final menuWidth = math.min(320.0, math.max(160.0, viewport.width - 16));
    final menuLeft = position.dx.clamp(
      8.0,
      math.max(8.0, viewport.width - menuWidth - 8),
    );
    final below =
        viewport.height -
        MediaQuery.viewInsetsOf(ctx).bottom -
        position.dy -
        target.size.height -
        8;
    final above = position.dy - 8;
    final openAbove = below < 200 && above > below;
    final menuHeight = math.min(
      400.0,
      math.max(96.0, openAbove ? above : below),
    );

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
          targetAnchor: openAbove ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: openAbove ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(menuLeft - position.dx, openAbove ? -2 : 2),
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(UtenRadius.md),
              clipBehavior: Clip.antiAlias,
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: menuHeight,
                  minWidth: menuWidth,
                  maxWidth: menuWidth,
                ),
                child: StatefulBuilder(
                  builder: (ctx, setOverlayState) {
                    final q = _searchCtl?.text.trim().toLowerCase() ?? '';
                    final buckets = widget.loadFacetPage != null
                        ? _remoteBuckets
                        : rankedKeywordMatches(
                            widget.buckets,
                            q,
                            fields: (bucket) => [bucket.display],
                          );
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onSearch != null ||
                            widget.facetSearchEnabled)
                          Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    key: const Key('uten-column-keyword-input'),
                                    controller: _searchCtl,
                                    autofocus: true,
                                    textInputAction: TextInputAction.search,
                                    style: theme.textTheme.bodyMedium,
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText: widget.label,
                                      prefixIcon: const Icon(
                                        Icons.search_rounded,
                                        size: 18,
                                      ),
                                      prefixIconConstraints:
                                          const BoxConstraints(
                                            minWidth: 32,
                                            minHeight: 32,
                                          ),
                                      suffixIcon: q.isEmpty
                                          ? null
                                          : IconButton(
                                              tooltip: '清空关键词',
                                              icon: const Icon(
                                                Icons.close_rounded,
                                                size: 16,
                                              ),
                                              onPressed: () {
                                                _searchCtl!.clear();
                                                setOverlayState(() {});
                                              },
                                            ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: UtenSpacing.s8,
                                            vertical: UtenSpacing.s8,
                                          ),
                                    ),
                                    onChanged: (_) => setOverlayState(() {}),
                                    onSubmitted: widget.onSearch == null
                                        ? null
                                        : (_) => _submitSearch(),
                                  ),
                                ),
                                if (widget.onSearch != null) ...[
                                  const SizedBox(width: UtenSpacing.s4),
                                  TextButton(
                                    onPressed: _submitSearch,
                                    child: const Text('搜索'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        Flexible(
                          child: UtenDropdownScrollScope(
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
                                        widget.sortActive &&
                                        widget.sortAscending,
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
                                if (hasFacets || widget.onSearch != null) ...[
                                  _menuItem(
                                    ctx,
                                    label: '所有', // TODO(l10n): 补 arb
                                    isSelected:
                                        sanitized == null &&
                                        widget.search == null,
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
                                      onTap: () => _select(b.value, bucket: b),
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
                                  if (_remoteLoading)
                                    const Padding(
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
                                    ),
                                  if (_remoteFailed)
                                    TextButton(
                                      onPressed: () => _fetchRemote(
                                        _searchRevision,
                                        _remotePage + 1,
                                      ),
                                      child: Text(
                                        basicDataL10n(ctx).tableFacetLoadFailed,
                                      ),
                                    ),
                                  if (_remoteHasMore &&
                                      !_remoteLoading &&
                                      !_remoteFailed)
                                    TextButton(
                                      onPressed: () => _fetchRemote(
                                        _searchRevision,
                                        _remotePage + 1,
                                      ),
                                      child: Text(
                                        basicDataL10n(ctx).tableFacetLoadMore,
                                      ),
                                    ),
                                  if (buckets.isEmpty &&
                                      !_remoteLoading &&
                                      !_remoteFailed &&
                                      !_remoteComposing)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: UtenSpacing.s12,
                                        vertical: UtenSpacing.s12,
                                      ),
                                      child: Text(
                                        '无匹配项',
                                        style: theme.textTheme.bodyMedium
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
                style: theme.textTheme.bodyMedium?.copyWith(
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

/// Mounted chrome owns its scroll positions; fullscreen transfers the keyed
/// table surface rather than attaching another viewport to these controllers.
class _ShortTablePresentation extends StatefulWidget {
  const _ShortTablePresentation({required this.child});
  final Widget child;
  @override
  State<_ShortTablePresentation> createState() =>
      _ShortTablePresentationState();
}

class _ShortTablePresentationState extends State<_ShortTablePresentation> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UtenPageScrollRoleScope.local(
    child: NotificationListener<ScrollNotification>(
      onNotification: (notification) => notification.depth == 0,
      child: UtenVerticalScrollbar(
        controller: _scroll,
        child: UtenScrollGutter(
          child: SingleChildScrollView(
            controller: _scroll,
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}

class _ResponsiveTableChrome extends StatefulWidget {
  const _ResponsiveTableChrome({
    required this.toolbar,
    required this.compose,
    this.minimumHeight = 0,
    this.pageOwned = false,
    this.pageParticipant = false,
  });
  final Widget toolbar;
  final Widget Function(Widget toolbar) compose;
  final double minimumHeight;
  final bool pageOwned;
  final bool pageParticipant;

  @override
  State<_ResponsiveTableChrome> createState() => _ResponsiveTableChromeState();
}

class _ResponsiveTableChromeState extends State<_ResponsiveTableChrome> {
  final _toolbarV = ScrollController();
  final _shortStageV = ScrollController();
  bool _independentToolbar = false;
  bool _toolbarCheckScheduled = false;
  Object? _presentationGeometry;

  void _checkToolbarMode() {
    if (_toolbarCheckScheduled || _independentToolbar || !widget.pageOwned) {
      return;
    }
    _toolbarCheckScheduled = true;
    final geometry = _presentationGeometry;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _toolbarCheckScheduled = false;
      if (!mounted ||
          geometry != _presentationGeometry ||
          !widget.pageOwned ||
          _toolbarV.positions.length != 1) {
        return;
      }
      final position = _toolbarV.position;
      if (position.hasContentDimensions &&
          position.maxScrollExtent > position.minScrollExtent) {
        // A genuine separate toolbar presentation keeps its local lane for
        // this geometry; data/empty/Popup changes cannot toggle it back and
        // forth as16px changes wrapping. A real resize starts a new regime.
        setState(() => _independentToolbar = true);
      }
    });
  }

  @override
  void dispose() {
    _toolbarV.dispose();
    _shortStageV.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final minimumHeight = math.max(
        168.0 * math.max(1.0, textScale),
        widget.minimumHeight,
      );
      final height = math.max(constraints.maxHeight, minimumHeight);
      final shortPresentation = height > constraints.maxHeight;
      final geometry = (constraints.maxWidth, constraints.maxHeight, textScale);
      if (_presentationGeometry != geometry) {
        _presentationGeometry = geometry;
        _independentToolbar = false;
      }
      // The page layout claim can change without changing scroll dimensions.
      // Check the new presentation once after its layout, rather than waiting
      // for a wheel event or relying on another metrics notification.
      _checkToolbarMode();
      final localToolbar =
          !widget.pageOwned || shortPresentation || _independentToolbar;
      final minimumToolbar = widget.pageOwned && constraints.maxWidth < 720
          ? 96.0
          : 48.0;
      final toolbarHeight = math.min(
        160.0,
        math.max(minimumToolbar, height * 0.35),
      );
      final visibleToolbar = NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _checkToolbarMode();
          return true;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) => true,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: toolbarHeight),
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              child: UtenPageScrollRoleScope.local(
                child: UtenVerticalScrollbar(
                  controller: _toolbarV,
                  visible: localToolbar,
                  child: UtenScrollGutter.trailing(
                    enabled: localToolbar,
                    child: SingleChildScrollView(
                      controller: _toolbarV,
                      primary: false,
                      child: widget.toolbar,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final stage = NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) => notification.depth == 0,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) => notification.depth == 0,
          child: UtenVerticalScrollbar(
            controller: _shortStageV,
            thumbVisibility: height > constraints.maxHeight,
            child: UtenScrollGutter(
              enabled: shortPresentation,
              child: SingleChildScrollView(
                controller: _shortStageV,
                primary: false,
                child: SizedBox(
                  height: height,
                  child: widget.compose(visibleToolbar),
                ),
              ),
            ),
          ),
        ),
      );
      return UtenPageScrollRoleScope(
        role:
            (shortPresentation && widget.pageParticipant) ||
                !UtenPageScrollRoleScope.isPageOf(context)
            ? UtenPageScrollRole.local
            : UtenPageScrollRole.main,
        child: stage,
      );
    },
  );
}

/// Embedded tables shrink with their content; bounded and fullscreen tables
/// retain a flexible row viewport and scrolling capacity.
class _BodyFlex extends StatelessWidget {
  const _BodyFlex({
    required this.embedded,
    required this.primary,
    required this.virtualized,
    this.fill = false,
    required this.child,
  });

  final bool embedded;
  final bool primary;
  final bool virtualized;
  final bool fill;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      return child;
    }
    // primary（联动折叠）用 tight：表格填满 NestedScrollView body 释放出的空间；
    // 有浮动批量动作也填满本地行区，保持其贴底位置；其余短列表仍可收缩。
    return Flexible(
      fit: primary || virtualized || fill ? FlexFit.tight : FlexFit.loose,
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
        // 左缘钉在可视框左缘：平移量随滚动同步(+offset)，滚动不改变屏幕位置。
        // 行本体仍是跨满表宽的计划行；Align 放松紧约束让提示按「可视框宽(表更
        // 窄时取表宽)」铺开居中——内容中心永远落在可视框内，错误/空态的重试
        // 按钮在任何横滚位置都可点。旧实现按右缘钉把整行左移(offset+viewport-
        // total)，宽表时行内容按表宽居中，中心被推出屏幕外(360px 下重试不可点)。
        final double window = viewport < contentWidth ? viewport : contentWidth;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            child: SizedBox(width: window, child: inner),
          ),
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
  int bodyRevision = 0;
  bool headerMeasured = false;
  double header = 0;
  double body = 0;
  final Set<String> seen = <String>{};
}

// ===== 行拖拽的私有支撑（配置见 components/data_display/uten_table_row_drag.dart） =====

/// 一个可见数据行的拖拽槽条目：行键、当前行对象与该行的 BuildContext
/// （context.findRenderObject() 即行 RenderBox，拖动中做光标→行的反查）。
class _RowDragSlotEntry<T> {
  _RowDragSlotEntry({
    required this.key,
    required this.item,
    required this.context,
  });

  final String key;
  T item;
  final BuildContext context;
}

/// 数据行外圈的拖拽槽：挂载/更新/卸载时维护 [registry]。
/// 带 ValueKey（行键派生），列表重排时元素跟着行走，条目自动换新对象。
class _RowDragSlot<T> extends StatefulWidget {
  const _RowDragSlot({
    super.key,
    required this.slotKey,
    required this.item,
    required this.registry,
    required this.dragOriginKey,
    required this.child,
  });

  final String slotKey;
  final T item;
  final Map<String, _RowDragSlotEntry<T>> registry;
  final ValueListenable<String?> dragOriginKey;
  final Widget child;

  @override
  State<_RowDragSlot<T>> createState() => _RowDragSlotState<T>();
}

class _RowDragSlotState<T> extends State<_RowDragSlot<T>>
    with AutomaticKeepAliveClientMixin<_RowDragSlot<T>> {
  @override
  bool get wantKeepAlive => widget.dragOriginKey.value == widget.slotKey;

  void _updateDragKeepAlive() => updateKeepAlive();

  @override
  void initState() {
    super.initState();
    widget.dragOriginKey.addListener(_updateDragKeepAlive);
    _register();
  }

  void _register() {
    widget.registry[widget.slotKey] = _RowDragSlotEntry<T>(
      key: widget.slotKey,
      item: widget.item,
      context: context,
    );
  }

  @override
  void didUpdateWidget(_RowDragSlot<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.dragOriginKey, widget.dragOriginKey)) {
      oldWidget.dragOriginKey.removeListener(_updateDragKeepAlive);
      widget.dragOriginKey.addListener(_updateDragKeepAlive);
      updateKeepAlive();
    }
    if (oldWidget.slotKey != widget.slotKey) {
      updateKeepAlive();
      if (identical(widget.registry[oldWidget.slotKey]?.context, context)) {
        widget.registry.remove(oldWidget.slotKey);
      }
      _register();
      return;
    }
    // 同一行的新对象（宿主重建行模型）：只刷新条目里的行引用。
    widget.registry[widget.slotKey]?.item = widget.item;
  }

  @override
  void dispose() {
    widget.dragOriginKey.removeListener(_updateDragKeepAlive);
    if (identical(widget.registry[widget.slotKey]?.context, context)) {
      widget.registry.remove(widget.slotKey);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 落点指示条的几何（表体 Stack 本地坐标）与形态。
class _RowDragIndicatorGeometry {
  const _RowDragIndicatorGeometry({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.mode,
    this.label,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final UtenTableRowDropMode mode;
  final String? label;
}

/// Primary owners can change without changing the controller's runtime type.
/// Notify the existing Scrollable to recreate its position for the new owner,
/// while delegating the application's gesture, physics and decoration policy.
class _PrimaryOwnerTableScrollBehavior extends ScrollBehavior {
  const _PrimaryOwnerTableScrollBehavior(this.delegate, this.owner);

  final ScrollBehavior delegate;
  final ScrollController? owner;

  @override
  bool shouldNotify(ScrollBehavior oldDelegate) =>
      oldDelegate is! _PrimaryOwnerTableScrollBehavior ||
      !identical(owner, oldDelegate.owner) ||
      delegate.runtimeType != oldDelegate.delegate.runtimeType ||
      delegate.shouldNotify(oldDelegate.delegate);

  @override
  TargetPlatform getPlatform(BuildContext context) =>
      delegate.getPlatform(context);

  @override
  Set<PointerDeviceKind> get dragDevices => delegate.dragDevices;

  @override
  Set<LogicalKeyboardKey> get pointerAxisModifiers =>
      delegate.pointerAxisModifiers;

  @override
  MultitouchDragStrategy getMultitouchDragStrategy(BuildContext context) =>
      delegate.getMultitouchDragStrategy(context);

  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
    BuildContext context,
  ) => delegate.getKeyboardDismissBehavior(context);

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      delegate.getScrollPhysics(context);

  @override
  GestureVelocityTrackerBuilder velocityTrackerBuilder(BuildContext context) =>
      delegate.velocityTrackerBuilder(context);

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => identical(details.controller, owner)
      ? child // 表体由独立的 UtenContentScrollbar 覆盖层提供竖向滚动条。
      : delegate.buildScrollbar(context, child, details);

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => delegate.buildOverscrollIndicator(context, child, details);
}

/// Scrollable hands its old position to a replacement controller before it
/// asks that controller to create the new position. Keep that transient handoff
/// local: a NestedScrollView coordinator only accepts positions it created.
class _BorrowedPrimaryTableController extends ScrollController {
  _BorrowedPrimaryTableController(this.parent);

  final ScrollController parent;
  final _created = Expando<bool>('borrowed primary table positions');
  final _forwarded = Set<ScrollPosition>.identity();

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    final position = parent.createScrollPosition(
      physics,
      context,
      oldPosition != null && _created[oldPosition] == true ? oldPosition : null,
    );
    _created[position] = true;
    return position;
  }

  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    if (_created[position] == true) {
      parent.attach(position);
      _forwarded.add(position);
    }
  }

  @override
  void detach(ScrollPosition position) {
    if (_forwarded.remove(position)) parent.detach(position);
    super.detach(position);
  }
}

/// 拖拽拾起的手势来源（判负一方的 cancel 不能误撕另一方的现场）。
enum _RowDragSource { longPress, vertical }

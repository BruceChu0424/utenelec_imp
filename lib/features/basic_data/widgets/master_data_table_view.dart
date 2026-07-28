// MasterDataTableView - 基础资料主档通用表格视图（货品/模具/客户/供应商 共用）。
//
// Excel 风格：横排 autofilter 列头（表头跟随表体横滚，无滚动条）+ 逐行数据（列对齐，
// 底部横向滚动条）。表头/表体各自一个横向 ScrollView，双向 listener 同步横滚位置
// （拖底部滚动条表头跟随；列始终对齐）。列头 autofilter 用自定义 Overlay 下拉（锚定
// 列头下方、限高、竖向滚动，不全屏）。翻页（上一页/下一页）后表体竖向回到顶部。
// 搜索框由调用方放在标题行，不在本组件内。

import 'package:flutter/material.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/master_facet.dart';

/// 一列定义：[key]（筛选键，与后端 query 参数对齐）、[label]（列头）、
/// [width]（固定列宽，列对齐用）、[value]（单元格取值）。
class MasterColumnDef<T> {
  const MasterColumnDef({
    required this.key,
    required this.label,
    required this.width,
    required this.value,
    this.type = 'text',
    this.sortable = false,
  });

  final String key;
  final String label;
  final double width;
  final String? Function(T item) value;

  /// 列类型，对齐后端 ReportColumn.type：text / date / number / money / bool。
  /// 用于决定排序菜单文案（date=从远到近/从近到远，数值=从小到大/从大到小）。
  final String type;

  /// 该列是否允许点表头排序（日期/金额/数量等可排序列置 true）。
  final bool sortable;
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
    required this.onRowTap,
    this.sortColumn,
    this.sortAscending = true,
    this.onSortChange,
    this.isLoading = false,
    this.loadingMore = false,
    this.error,
    this.onRetry,
    this.emptyMessage = '暂无数据', // TODO(l10n): 补 arb
    this.currentPage = 1,
    this.totalPages = 1,
    this.onPageChange,
  });

  final List<MasterColumnDef<T>> columns;
  final List<T> items;
  final Map<String, List<MasterFacetBucket>> facets;
  final Map<String, int> nullCounts;
  final Map<String, String?> filters;
  final void Function(String key, String? value) onFilterChanged;
  final void Function(T item) onRowTap;

  /// 当前排序的列 key（与 MasterColumnDef.key 对齐）；null = 不排序（用后端默认顺序）。
  final String? sortColumn;

  /// 当前排序方向：true=升序，false=降序。仅当 [sortColumn] 非空时有效。
  final bool sortAscending;

  /// 列头排序回调：(列 key, 升序) 应用排序；(null, _) 取消排序回到默认。
  /// 报表分页场景下，回调应触发带 sort/order 参数重新请求后端。
  final void Function(String? column, bool ascending)? onSortChange;

  final bool isLoading;
  final bool loadingMore;
  final String? error;
  final VoidCallback? onRetry;
  final String emptyMessage;

  final int currentPage;
  final int totalPages;
  final void Function(int page)? onPageChange;

  @override
  State<MasterDataTableView<T>> createState() => _MasterDataTableViewState<T>();
}

class _MasterDataTableViewState<T> extends State<MasterDataTableView<T>> {
  // 表头/表体横滚同步（早期 Flutter 的 LinkedScrollControllerGroup 在 3.44 已移除，
  // 改用两个普通 ScrollController + 互听 + _syncing 防回环，行为等价）。
  late final ScrollController _headerH;
  late final ScrollController _bodyH;
  // 表体竖向滚动：翻页时 jumpTo(0) 回顶（从第一条开始）。
  late final ScrollController _bodyV;
  // 分页跳转输入框：填数字回车跳页；外部翻页（上一页/下一页/跳页）时同步回当前页。
  late final TextEditingController _pageCtrl;
  bool _syncing = false;

  /// 当前列宽：默认按列内容自动适配最宽值（[MasterColumnDef.width] 不再用于布局，
  /// 保留字段供未来手动覆盖/最小宽度扩展）。用户拖拽后覆盖；自动适配需 BuildContext 的
  /// 文字样式，故在 build 首帧测算（见 [_ensureWidths]）。
  List<double> _widths = const [];

  /// 用户已手动拖拽过的列下标：数据刷新时这些列保留用户宽度，其余按新内容重新适配。
  final Set<int> _manualResized = {};

  /// 列宽待重算标记：列集合或数据变化时置 true，[_ensureWidths] 算完清掉。
  bool _widthsDirty = true;

  /// 当前选中（单击高亮）的行：滚动不刷新数据故高亮常驻，翻页/重查换对象后自然失效。
  T? _selectedItem;

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
  static const double _autoFitBuffer = 6; // 防贴边 ellipsis 富余

  @override
  void initState() {
    super.initState();
    _headerH = ScrollController();
    _bodyH = ScrollController();
    _bodyV = ScrollController();
    _pageCtrl = TextEditingController(text: '${widget.currentPage}');
    _headerH.addListener(() => _sync(_headerH, _bodyH));
    _bodyH.addListener(() => _sync(_bodyH, _headerH));
  }

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing || !dst.hasClients) return;
    _syncing = true;
    dst.jumpTo(src.offset);
    _syncing = false;
  }

  @override
  void didUpdateWidget(covariant MasterDataTableView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列集合变了（数量或 key 序列不同，如报表切 docType）→ 清手动标记、全量重算列宽。
    if (!_sameColumnKeys(oldWidget.columns, widget.columns)) {
      _manualResized.clear();
      _widthsDirty = true;
    } else if (oldWidget.items != widget.items) {
      // 数据变了（翻页/筛选/排序/加载更多）→ 标记重算；已手动调整的列在 _ensureWidths 保留。
      _widthsDirty = true;
    }
    // 翻页（currentPage 变化）→ 表体竖向回顶，从第一条开始。
    if (oldWidget.currentPage != widget.currentPage && _bodyV.hasClients) {
      _bodyV.jumpTo(0);
    }
    // 外部翻页后，跳页输入框同步回当前页（用户未提交的输入被放弃，符合直觉）。
    if (oldWidget.currentPage != widget.currentPage) {
      _pageCtrl.text = '${widget.currentPage}';
    }
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
    if (!_widthsDirty) return;
    _widthsDirty = false;
    final theme = Theme.of(context);
    final headerStyle =
        (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(fontWeight: FontWeight.w700);
    final bodyStyle = theme.textTheme.bodySmall ?? const TextStyle();
    final next =
        List<double>.filled(widget.columns.length, _minColWidth, growable: true);
    final sampleCount = widget.items.length < _autoFitSampleSize
        ? widget.items.length
        : _autoFitSampleSize;
    for (var i = 0; i < widget.columns.length; i++) {
      if (_manualResized.contains(i) && i < _widths.length) {
        next[i] = _widths[i];
        continue;
      }
      final def = widget.columns[i];
      double w = _measureText(def.label, headerStyle);
      for (var r = 0; r < sampleCount; r++) {
        final tw = _measureText(def.value(widget.items[r]) ?? '', bodyStyle);
        if (tw > w) w = tw;
      }
      next[i] = (w +
              _cellPadX * 2 +
              _headerIconAllowance +
              (def.sortable ? _sortIconAllowance : 0) +
              _autoFitBuffer)
          .clamp(_minColWidth, _maxColWidth);
    }
    _widths = next;
  }

  /// 测量单行文本渲染宽度（TextPainter，maxLines:1）。测完 dispose 防泄漏。
  double _measureText(String text, TextStyle style) {
    if (text.isEmpty) return 0;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  @override
  void dispose() {
    _headerH.dispose();
    _bodyH.dispose();
    _bodyV.dispose();
    super.dispose();
  }

  double get _totalWidth => _widths.fold(0.0, (s, w) => s + w);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _buildTable(context)),
        if (widget.totalPages > 1) _buildPager(context),
      ],
    );
  }

  Widget _buildTable(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.isLoading && widget.items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (widget.error != null) {
      return Center(
        child: UtenEmpty.error(
          message: widget.error,
          actionLabel: '重试', // TODO(l10n): 补 arb
          onAction: widget.onRetry,
        ),
      );
    }
    if (widget.items.isEmpty) {
      return Center(
        child: UtenEmpty(
          icon: Icons.table_rows_outlined,
          message: widget.emptyMessage,
        ),
      );
    }
    _ensureWidths(context);
    final total = _totalWidth;
    // stretch：列总宽 < 视口宽时（颜色/单位等列少主档）表头与表体撑满视口宽、
    // 内容靠左，而非整体水平居中（Column 默认 crossAxisAlignment.center 会把窄于
    // 视口的表格居中、左右留白）。仅作用于交叉轴（横向），不影响主轴 Flexible(loose)
    // 的「行少收缩、横滚条贴末行」行为。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 表头：横向跟随表体同步（无可见滚动条），竖向固定（sticky）。
        Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: SingleChildScrollView(
            controller: _headerH,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total,
              child: _buildHeaderRow(theme),
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
        Flexible(
          child: LayoutBuilder(
            builder: (ctx, c) => Scrollbar(
              // 竖向滚动条（上下）：绑表体 ListView 的 _bodyV。置于横向滚动之外层，
              // 使 thumb 固定在视口右边缘、不随横向滚动被带走。竖向 ListView 嵌在
              // 横向 SingleChildScrollView 内层，其滚动通知冒泡到本 Scrollbar 时
              // depth=1（穿过了横向那层 Scrollable），Scrollbar 默认 notificationPredicate
              // (depth==0) 会滤掉 → thumb 不更新；放宽到 depth<=1 才能捕获竖向滚动。
              controller: _bodyV,
              thumbVisibility: true,
              notificationPredicate: (ScrollNotification n) => n.depth <= 1,
              child: Scrollbar(
                // 横向滚动条（左右）：绑 _bodyH，thumb 钉视口底，表头经 _sync 跟随同步。
                controller: _bodyH,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _bodyH,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: total,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: c.maxHeight),
                      child: ListView.builder(
                        controller: _bodyV,
                        shrinkWrap: true,
                        physics: const ClampingScrollPhysics(),
                        padding: EdgeInsets.zero,
                        itemCount: widget.items.length + (widget.loadingMore ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          if (i == widget.items.length) {
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
                          return _buildDataRow(theme, widget.items[i]);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderRow(ThemeData theme) {
    return Row(
      children: [
        for (var i = 0; i < widget.columns.length; i++)
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
                _FilterCell(
                  label: widget.columns[i].label,
                  sortKey: widget.columns[i].key,
                  type: widget.columns[i].type,
                  sortable: widget.columns[i].sortable,
                  sortActive: widget.sortColumn == widget.columns[i].key,
                  sortAscending: widget.sortAscending,
                  onSort: widget.onSortChange,
                  buckets: widget.facets[widget.columns[i].key] ?? const [],
                  nullCount: widget.nullCounts[widget.columns[i].key] ?? 0,
                  selected: widget.filters[widget.columns[i].key],
                  onChanged: (v) =>
                      widget.onFilterChanged(widget.columns[i].key, v),
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
                    onHorizontalDragUpdate: (d) => _resizeColumn(i, d.delta.dx),
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
  }

  Widget _buildDataRow(ThemeData theme, T item) {
    final selected = identical(item, _selectedItem);
    return InkWell(
      onTap: () {
        // 单击高亮该行：滚动时常驻（数据不刷新），翻页/重查换对象后自然失效。
        // 同时照常触发调用方 onRowTap（详情/跳源头单据等），不抢占既有交互。
        setState(() => _selectedItem = item);
        widget.onRowTap(item);
      },
      child: ColoredBox(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        child: Row(
          children: [
            for (var i = 0; i < widget.columns.length; i++)
              SizedBox(
                width: _widths[i],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s12,
                    vertical: UtenSpacing.s8,
                  ),
                  child: Text(
                    widget.columns[i].value(item) ?? '',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPager(BuildContext context) {
    final theme = Theme.of(context);
    final canPrev = widget.currentPage > 1;
    final canNext = widget.currentPage < widget.totalPages;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: (canPrev && widget.onPageChange != null)
                ? () => widget.onPageChange!(widget.currentPage - 1)
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
                    controller: _pageCtrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    // 填数字回车跳页：非法→回当前页；越界→钳制到 [1,totalPages] 并回填。
                    onFieldSubmitted: (v) {
                      final p = int.tryParse(v.trim());
                      final target = p == null
                          ? widget.currentPage
                          : p.clamp(1, widget.totalPages);
                      if (target != widget.currentPage) {
                        widget.onPageChange?.call(target);
                      } else {
                        _pageCtrl.text = '$target';
                      }
                    },
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '/ ${widget.totalPages}', // TODO(l10n): 补 arb
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: (canNext && widget.onPageChange != null)
                ? () => widget.onPageChange!(widget.currentPage + 1)
                : null,
            icon: const Text('下一页'), // TODO(l10n): 补 arb
            label: const Icon(Icons.chevron_right_rounded, size: 20),
          ),
        ],
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
  });

  final String label;
  final List<MasterFacetBucket> buckets;
  final int nullCount;
  final String? selected;
  final ValueChanged<String?> onChanged;

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
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
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
        height: 44,
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
          height: 44,
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
              if (widget.sortable && hasFacets) const SizedBox(width: UtenSpacing.s4),
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
                constraints: const BoxConstraints(maxHeight: 360, maxWidth: 300),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    if (widget.sortable) ...[
                      _menuItem(
                        ctx,
                        label: _sortAscLabel,
                        isSelected: widget.sortActive && widget.sortAscending,
                        onTap: () => _sortSelect(widget.sortKey, true),
                        theme: theme,
                      ),
                      _menuItem(
                        ctx,
                        label: _sortDescLabel,
                        isSelected: widget.sortActive && !widget.sortAscending,
                        onTap: () => _sortSelect(widget.sortKey, false),
                        theme: theme,
                      ),
                      _menuItem(
                        ctx,
                        label: '取消排序', // TODO(l10n): 补 arb
                        isSelected: !widget.sortActive,
                        onTap: () => _sortSelect(null, true),
                        theme: theme,
                      ),
                      if (hasFacets) const Divider(height: 1, thickness: 1),
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
                          label: '空值 (${widget.nullCount})', // TODO(l10n): 补 arb
                          isSelected: sanitized == kMasterFilterNullValue,
                          onTap: () => _select(kMasterFilterNullValue),
                          theme: theme,
                        ),
                      const Divider(height: 1, thickness: 1),
                      for (final b in widget.buckets)
                        _menuItem(
                          ctx,
                          label: b.count > 0
                              ? '${b.display} (${b.count})'
                              : b.display,
                          isSelected: sanitized == b.value,
                          onTap: () => _select(b.value),
                          theme: theme,
                        ),
                    ],
                  ],
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
                  ? Icon(Icons.check_rounded,
                      size: 18, color: theme.colorScheme.primary)
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

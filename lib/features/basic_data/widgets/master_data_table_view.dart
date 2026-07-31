// MasterDataTableView - 基础资料主档通用表格视图（货品/模具/客户/供应商 共用）。
//
// Excel 风格：横排 autofilter 列头（表头跟随表体横滚，无滚动条）+ 逐行数据（列对齐，
// 底部横向滚动条）。表头/表体各自一个横向 ScrollView，双向 listener 同步横滚位置
// （拖底部滚动条表头跟随；列始终对齐）。列头 autofilter 用自定义 Overlay 下拉（锚定
// 列头下方、限高、竖向滚动，不全屏）。翻页（上一页/下一页）后表体竖向回到顶部。
// 搜索框由调用方放在标题行，不在本组件内。

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
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
    this.detailLabel = '下拉详情', // TODO(l10n): 补 arb
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

  /// 标题行右侧的展开提示文案（默认「下拉详情」）。
  final String detailLabel;
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
    this.toolbarActions,
    this.embedded = false,
    this.rowColor,
    this.leadingGroups,
  });

  final List<MasterColumnDef<T>> columns;
  final List<T> items;
  final Map<String, List<MasterFacetBucket>> facets;
  final Map<String, int> nullCounts;
  final Map<String, String?> filters;
  final void Function(String key, String? value) onFilterChanged;
  final void Function(T item) onRowTap;

  /// 表头上方工具条的追加按钮（预览打印 / 下载表格等），排在「表头设置」右侧、
  /// 左对齐挨在一起。调用方通常传深绿大号款（UtenButtonType.primary + large）。
  final List<Widget>? toolbarActions;

  /// 嵌入模式：用于详情页 ListView 等无界高度场景（单据明细只读表）。
  /// 不渲染翻页条、不用 Expanded 撑满，表体按内容收缩。
  final bool embedded;

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

  /// 当前隐藏的列 key 集合：表头上方工具条「列」浮层勾选维护；
  /// 列集合变化（如报表切 docType）时清空（默认全部显示）。
  final Set<String> _hiddenKeys = {};

  /// 全屏状态：true 时正常树让位成 SizedBox.shrink（ScrollController 只挂全屏路由一棵树），
  /// 表格经 showGeneralDialog 全屏路由渲染——走 Navigator 路由栈，故全屏里再开
  /// 「预览打印 / 下载表格」对话框会正常叠在全屏之上（手动 OverlayEntry 会压住路由弹窗）。
  /// [_fsTick] 驱动全屏内容重建（数据/列宽/显隐变化时 bump）。
  bool _fullscreen = false;
  final ValueNotifier<int> _fsTick = ValueNotifier<int>(0);

  /// 当前展开的前导分组 id 集合（点击分组标题行切换）。默认全折叠。
  final Set<String> _expandedGroups = {};

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
      _hiddenKeys.clear(); // 列显隐选择跟随列集合重置（默认全部显示）。
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
    if (_fullscreen) {
      // 在全屏路由内点击：pop 全屏对话框（路由 dispose 后统一复位标志）。
      Navigator.of(context, rootNavigator: true).pop();
      return;
    }
    setState(() => _fullscreen = true);
    await showGeneralDialog<void>(
      context: context,
      barrierLabel: '全屏表格', // TODO(l10n): 补 arb
      barrierColor: Colors.transparent, // 内容整屏不透明，无需遮罩色
      pageBuilder: (ctx, _, _) => _FullscreenDisposer(
        // 路由完全移除后再让正常树接管同一批 ScrollController（见上方注释）。
        onDisposed: () {
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _fullscreen = false);
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
                      Expanded(child: _buildTable(ctx2)),
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
    if (!_widthsDirty) return;
    _widthsDirty = false;
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
      for (final g in (widget.leadingGroups ?? const <MasterDataGroup<T>>[]))
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
      double w = _measureText(def.label, headerStyle);
      for (var r = 0; r < sampleCount; r++) {
        final tw = _measureText(def.value(pool[r]) ?? '', bodyStyle);
        if (tw > w) w = tw;
      }
      next[i] =
          (w +
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
    _fsTick.dispose();
    _headerH.dispose();
    _bodyH.dispose();
    _bodyV.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  double get _totalWidth {
    var s = 0.0;
    for (final i in _visibleIndices) {
      if (i < _widths.length) s += _widths[i];
    }
    return s;
  }

  /// 当前可见列在原列集合中的下标（隐藏列跳过，列宽仍按原下标存 [_widths]）。
  List<int> get _visibleIndices => [
    for (var i = 0; i < widget.columns.length; i++)
      if (!_hiddenKeys.contains(widget.columns[i].key)) i,
  ];

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
        children: [_buildTable(context)],
      );
    }
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
    final groups = widget.leadingGroups ?? const <MasterDataGroup<T>>[];
    final hasGroupRows = groups.any(
      (g) => g.items.isNotEmpty || (g.total ?? 0) > 0,
    );
    // 主数据为空且无任何前导分组 → 空态占位（有分组时仍渲染表头 + 分组行）。
    if (widget.items.isEmpty && !hasGroupRows) {
      return Center(
        child: UtenEmpty(
          icon: Icons.table_rows_outlined,
          message: widget.emptyMessage,
        ),
      );
    }
    _ensureWidths(context);
    final total = _totalWidth;
    // 行计划：前导分组（表头下第一区）+ 主数据行。分组折叠=仅一条跨满宽标题行；
    // 展开=其 items 按主表同款列逐行渲染（与主行共用 _widths / _visibleIndices / 横滚）。
    final plan = <({bool header, MasterDataGroup<T>? group, T? item})>[];
    for (final g in groups) {
      if (g.items.isEmpty && (g.total ?? 0) == 0) continue; // N=0 分组不渲染
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
        // 表头上方工具条：左侧「表头设置」列显隐选择 + 追加按钮（预览打印/下载表格等），
        // 全部左对齐挨在一起，与表格同属一块操作区。
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
          child: Row(
            children: [
              _ColumnChooserButton(
                columns: [
                  for (final c in widget.columns) (key: c.key, label: c.label),
                ],
                hiddenKeys: _hiddenKeys,
                onToggle: _toggleColumn,
                onToggleAll: _toggleAllColumns,
              ),
              const SizedBox(width: UtenSpacing.s8),
              // 全屏切换：表格放大到整屏显示（行列多时能看更多内容），再点退出。
              UtenButton(
                size: UtenButtonSize.large,
                icon: _fullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                onPressed: _toggleFullscreen,
                child: Text(_fullscreen ? '退出全屏' : '全屏'),
              ),
              if (widget.toolbarActions != null)
                for (final a in widget.toolbarActions!) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  a,
                ],
            ],
          ),
        ),
        // 表头：横向跟随表体同步（无可见滚动条），竖向固定（sticky）。
        Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: SingleChildScrollView(
            controller: _headerH,
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: total, child: _buildHeaderRow(theme)),
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
        _BodyFlex(
          embedded: widget.embedded,
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
                          return _buildDataRow(theme, row.item!);
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

  /// 前导分组标题行：跨满表宽（_totalWidth），与表头/数据行同处一个横向 ScrollView，
  /// 故横滚同步、列边界对齐。底色取 [MasterDataGroup.tint]（禁用=浅红等）；点击切换展开。
  /// 右侧「下拉详情 ▾」文字 + 旋转箭头（展开后朝上、文案语义=可收起）。
  Widget _buildGroupHeader(ThemeData theme, MasterDataGroup<T> group) {
    final expanded = _expandedGroups.contains(group.id);
    final tint = group.tint ?? theme.colorScheme.surfaceContainerHigh;
    final moreLeft =
        (group.total ?? group.items.length) > group.items.length;
    return InkWell(
      onTap: () {
        setState(() {
          if (expanded) {
            _expandedGroups.remove(group.id);
          } else {
            _expandedGroups.add(group.id);
          }
        });
        // 全屏路由经 _fsTick 驱动重建；bump 使全屏里展开/折叠同步（与列显隐同款）。
        _fsTick.value++;
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint,
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outline, width: 0.5),
          ),
        ),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (group.subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
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
                ),
              ),
              if (moreLeft && expanded)
                Padding(
                  padding: const EdgeInsets.only(right: UtenSpacing.s8),
                  child: Text(
                    '仅前 ${group.items.length}/${group.total}', // TODO(l10n): 补 arb
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              Text(
                group.detailLabel,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderRow(ThemeData theme) {
    return Row(
      children: [
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
    _fsTick.value++;
  }

  Widget _buildDataRow(ThemeData theme, T item) {
    final selected = identical(item, _selectedItem);
    // 行底色：调用方可按行数据着色（货品按状态）；单击选中把当前色加深加亮。
    final base = widget.rowColor?.call(item);
    final Color rowBg;
    if (selected) {
      rowBg = base != null
          ? base.withValues(alpha: (base.a + 0.22).clamp(0.0, 0.5))
          : theme.colorScheme.primary.withValues(alpha: 0.10);
    } else {
      rowBg = base ?? Colors.transparent;
    }
    return InkWell(
      onTap: () {
        // 单击高亮该行：滚动时常驻（数据不刷新），翻页/重查换对象后自然失效。
        // 同时照常触发调用方 onRowTap（详情/跳源头单据等），不抢占既有交互。
        setState(() => _selectedItem = item);
        _fsTick.value++;
        widget.onRowTap(item);
      },
      child: DecoratedBox(
        // 行间横线：逐行分隔（与表头竖线同 outline 色，网格更深、单元格边界清晰）。
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outline, width: 0.5),
          ),
        ),
        child: ColoredBox(
          color: rowBg,
          child: Row(
            children: [
              for (final i in _visibleIndices)
                Container(
                  width: _widths[i],
                  // 列间竖线：与表头竖线同位置同色，逐格勾勒单元格右边界。
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: theme.colorScheme.outline,
                        width: 0.5,
                      ),
                    ),
                  ),
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
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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

/// 列显隐选择按钮：表头上方工具条左侧「列 x/y」，点开浮层勾选要显示的列
/// （如只勾「单号」就只显示单号列），顶部「全选」一键全部显示 / 仅留首列。
/// 浮层与 [_FilterCell] 同款：锚定按钮下方、限高竖滚、点外部关闭。
class _ColumnChooserButton extends StatefulWidget {
  const _ColumnChooserButton({
    required this.columns,
    required this.hiddenKeys,
    required this.onToggle,
    required this.onToggleAll,
  });

  /// 全部列（key + 展示名），按表格列顺序。
  final List<({String key, String label})> columns;

  /// 当前隐藏的列 key 集合（父组件持有，这里只读展示）。
  final Set<String> hiddenKeys;

  /// 切换单列显隐；最后一列不允许隐藏（父组件保证）。
  final ValueChanged<String> onToggle;

  /// 全选(true=全部显示) / 仅留首列(false)。
  final ValueChanged<bool> onToggleAll;

  @override
  State<_ColumnChooserButton> createState() => _ColumnChooserButtonState();
}

class _ColumnChooserButtonState extends State<_ColumnChooserButton> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  void _open() {
    if (_overlay != null) return;
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
  }

  /// 勾选后浮层内勾选态需同步刷新（OverlayEntry 不随父组件自动重建）。
  void _toggle(String key) {
    widget.onToggle(key);
    _overlay?.markNeedsBuild();
  }

  void _toggleAll(bool selectAll) {
    widget.onToggleAll(selectAll);
    _overlay?.markNeedsBuild();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.columns.length - widget.hiddenKeys.length;
    return CompositedTransformTarget(
      link: _link,
      // 深绿大号白字（UtenButton 默认 primary 实心深绿，与工具条「预览打印/下载表格」同款）。
      child: UtenButton(
        size: UtenButtonSize.large,
        icon: Icons.view_column_outlined,
        onPressed: _open,
        child: Text('表头设置 $visible/${widget.columns.length}'),
      ),
    );
  }

  Widget _buildOverlay(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final allVisible = widget.hiddenKeys.isEmpty;
    final visibleCount = widget.columns.length - widget.hiddenKeys.length;
    return Stack(
      children: [
        // 点菜单外空白关闭。
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
                  maxWidth: 240,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    _checkRow(
                      label: '全选', // TODO(l10n): 补 arb
                      checked: allVisible,
                      enabled: true,
                      bold: true,
                      onTap: () => _toggleAll(!allVisible),
                      theme: theme,
                    ),
                    const Divider(height: 1, thickness: 1),
                    for (final c in widget.columns)
                      _checkRow(
                        label: c.label,
                        checked: !widget.hiddenKeys.contains(c.key),
                        // 最后一列不允许再隐藏，避免表格没列。
                        enabled:
                            widget.hiddenKeys.contains(c.key) ||
                            visibleCount > 1,
                        onTap: () => _toggle(c.key),
                        theme: theme,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _checkRow({
    required String label,
    required bool checked,
    required bool enabled,
    required VoidCallback onTap,
    required ThemeData theme,
    bool bold = false,
  }) {
    final disabledColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.4,
    );
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        child: Row(
          children: [
            Icon(
              checked
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 18,
              color: !enabled
                  ? disabledColor
                  : checked
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                  color: enabled ? null : disabledColor,
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
  const _BodyFlex({required this.embedded, required this.child});

  final bool embedded;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      embedded ? child : Flexible(child: child);
}

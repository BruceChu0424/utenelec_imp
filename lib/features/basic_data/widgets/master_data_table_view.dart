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
  });

  final String key;
  final String label;
  final double width;
  final String? Function(T item) value;
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
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _headerH = ScrollController();
    _bodyH = ScrollController();
    _bodyV = ScrollController();
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
    // 翻页（currentPage 变化）→ 表体竖向回顶，从第一条开始。
    if (oldWidget.currentPage != widget.currentPage && _bodyV.hasClients) {
      _bodyV.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _headerH.dispose();
    _bodyH.dispose();
    _bodyV.dispose();
    super.dispose();
  }

  double get _totalWidth => widget.columns.fold(0.0, (s, c) => s + c.width);

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
    final total = _totalWidth;
    return Column(
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
        // 表体：Expanded 竖向（行多滚动）；横向可滚（与表头同步，底部滚动条）。
        Expanded(
          child: Scrollbar(
            controller: _bodyH,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _bodyH,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: total,
                child: ListView.builder(
                  controller: _bodyV,
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
      ],
    );
  }

  Widget _buildHeaderRow(ThemeData theme) {
    return Row(
      children: [
        for (final col in widget.columns)
          SizedBox(
            width: col.width,
            child: _FilterCell(
              label: col.label,
              buckets: widget.facets[col.key] ?? const [],
              nullCount: widget.nullCounts[col.key] ?? 0,
              selected: widget.filters[col.key],
              onChanged: (v) => widget.onFilterChanged(col.key, v),
            ),
          ),
      ],
    );
  }

  Widget _buildDataRow(ThemeData theme, T item) {
    return InkWell(
      onTap: () => widget.onRowTap(item),
      child: Row(
        children: [
          for (final col in widget.columns)
            SizedBox(
              width: col.width,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                  vertical: UtenSpacing.s8,
                ),
                child: Text(
                  col.value(item) ?? '',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
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
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Text(
              '${widget.currentPage} / ${widget.totalPages}', // TODO(l10n): 补 arb
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
  });

  final String label;
  final List<MasterFacetBucket> buckets;
  final int nullCount;
  final String? selected;
  final ValueChanged<String?> onChanged;

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
    final filtered = s != null;
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
          color: filtered ? theme.colorScheme.primaryContainer : null,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: filtered ? FontWeight.w700 : FontWeight.w600,
                    color: filtered
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: filtered
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
  Widget _buildOverlay(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final sanitized = _sanitized;
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
                    _menuItem(
                      ctx,
                      label: '所有', // TODO(l10n): 补 arb
                      value: null,
                      isSelected: sanitized == null,
                      theme: theme,
                    ),
                    if (widget.nullCount > 0)
                      _menuItem(
                        ctx,
                        label: '空值 (${widget.nullCount})', // TODO(l10n): 补 arb
                        value: kMasterFilterNullValue,
                        isSelected: sanitized == kMasterFilterNullValue,
                        theme: theme,
                      ),
                    const Divider(height: 1, thickness: 1),
                    for (final b in widget.buckets)
                      _menuItem(
                        ctx,
                        label: '${b.display} (${b.count})',
                        value: b.value,
                        isSelected: sanitized == b.value,
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

  Widget _menuItem(
    BuildContext ctx, {
    required String label,
    required String? value,
    required bool isSelected,
    required ThemeData theme,
  }) {
    return InkWell(
      onTap: () => _select(value),
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

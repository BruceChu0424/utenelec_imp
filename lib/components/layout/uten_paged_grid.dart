// Continuous card grid over an already complete source; only visible widgets mount.
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import 'uten_ancestor_row_window.dart';
import 'uten_responsive_grid.dart';

/// Continuous virtual card grid using the shared responsive column rules.
class UtenPagedGrid<T> extends StatefulWidget {
  const UtenPagedGrid({
    super.key,
    required this.items,
    required this.itemBuilder,
    this.pageSize = 20,
    this.spacing = 16,
    this.runSpacing,
    this.padding,
    this.columns,
    this.maxColumns = 6,
    this.minColumns = 1,
    this.physics,
    this.emptyPlaceholder,
  });

  /// Complete authorized source; offscreen cards are virtualized.
  final List<T> items;

  /// 卡片构造器，签名与 [UtenResponsiveGrid.itemBuilder] 一致；
  /// 回调里的 `index` 是**全量列表**的索引（不是当页内索引），便于直接 `items[index]`。
  final Widget Function(BuildContext context, int index, double itemWidth)
  itemBuilder;

  /// Legacy constructor compatibility; this no longer limits visible rows.
  final int pageSize;

  /// 透传给 [UtenResponsiveGrid]：主轴间距。
  final double spacing;

  /// 透传给 [UtenResponsiveGrid]：交叉轴间距（默认与 spacing 相同）。
  final double? runSpacing;

  /// 透传给内部 SingleChildScrollView：外边距（沿用原页面的 padding）。
  final EdgeInsetsGeometry? padding;

  /// 透传给 [UtenResponsiveGrid]：强制列数配置。
  final UtenResponsiveColumns? columns;

  /// 透传给 [UtenResponsiveGrid]：最大/最小列数。
  final int maxColumns;
  final int minColumns;

  /// 滚动物理（默认 null → 平台默认；与 RefreshIndicator 协同时保持默认即可）。
  final ScrollPhysics? physics;

  /// 当页为空时的占位（数据非空但切片为空一般不会发生；留作兜底）。
  final Widget? emptyPlaceholder;

  @override
  State<UtenPagedGrid<T>> createState() => _UtenPagedGridState<T>();
}

class _UtenPagedGridState<T> extends State<UtenPagedGrid<T>> {
  final _ctrl = ScrollController();
  final _windows = <int, UtenAncestorRowWindowController<int>>{};
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width =
          (constraints.maxWidth -
                  (widget.padding
                          ?.resolve(Directionality.of(context))
                          .horizontal ??
                      0))
              .clamp(0.0, double.infinity);
      final columns = utenResponsiveGridColumnsFor(
        context,
        width,
        columns: widget.columns,
        minColumns: widget.minColumns,
        maxColumns: widget.maxColumns,
        spacing: widget.spacing,
      );
      final itemWidth = (width - widget.spacing * (columns - 1)) / columns;
      return SingleChildScrollView(
        controller: _ctrl,
        physics: widget.physics,
        padding: widget.padding,
        child: widget.items.isEmpty && widget.emptyPlaceholder != null
            ? widget.emptyPlaceholder!
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    if (column > 0) SizedBox(width: widget.spacing),
                    SizedBox(
                      width: itemWidth,
                      child: UtenAncestorRowWindow<int>(
                        controller: _windows.putIfAbsent(
                          column,
                          UtenAncestorRowWindowController<int>.new,
                        ),
                        rows: [
                          for (
                            var index = column;
                            index < widget.items.length;
                            index += columns
                          )
                            index,
                        ],
                        expensiveRows: false,
                        deferRowMounts: false,
                        estimatedRowExtent: 180,
                        rowBuilder: (context, index, _) => Padding(
                          padding: EdgeInsets.only(
                            bottom: index + columns < widget.items.length
                                ? widget.runSpacing ?? widget.spacing
                                : 0,
                          ),
                          child: widget.itemBuilder(context, index, itemWidth),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      );
    },
  );
}

/// Complete-list count display. Legacy navigation constructor values are
/// accepted for source compatibility and never render pagination controls.
class UtenGridPager extends StatelessWidget {
  const UtenGridPager({
    super.key,
    required this.currentPage,
    required this.totalPages,
    required this.totalItems,
    required this.onPrev,
    required this.onNext,
    this.onPageChanged,
    this.busy = false,
  });

  /// 当前页（1-based）。
  final int currentPage;

  /// 总页数。
  final int totalPages;

  /// 总条数（仅用于展示「共 N 条」，不影响翻页逻辑）。
  final int totalItems;

  /// 旧调用方兼容参数，连续列表不提供导航。
  final VoidCallback? onPrev;

  /// 旧调用方兼容参数，连续列表不提供导航。
  final VoidCallback? onNext;

  /// 直接跳到目标页；沿用调用方已有的读取和权限保护。
  final ValueChanged<int>? onPageChanged;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        children: [
          Text(
            '共 $totalItems 条', // TODO(l10n): 补 arb
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

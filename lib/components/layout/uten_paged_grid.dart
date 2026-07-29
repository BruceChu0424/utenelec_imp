// UtenPagedGrid - 分页卡片网格（客户端切片）
//
// 解决「列表页一次性把全部数据铺进 UtenResponsiveGrid 一次性构建全部子项」
// 的卡顿（详见 docs/数据迁移/29 P2-5 / 30 §七-5）。
//
// 做法：不改 UtenResponsiveGrid 的对外契约，而是在它外面包一层
// 分页——只把「当页」pageSize 条数据交给 UtenResponsiveGrid，子项永远 ≤ pageSize，
// 从根上消除一次性渲染。底部翻页条样式与 MasterDataTableView 对齐（上一页 / 第x/y页 /
// 下一页，翻页后回顶）。总量 ≤ pageSize 时不显示翻页条，小数据零视觉污染。
//
// 注：UtenResponsiveGrid 已于 2026-07-29 重写为分栏瀑布流 v3
// （Wrap 按行对齐导致矮卡片下方留白、两行视觉间隔过远），本组件行为不变。
//
// 用法（与原 UtenResponsiveGrid 几乎一致，仅把 itemCount 换成 items）：
// ```dart
// UtenPagedGrid(
//   items: claims,                       // 全量数据（组件内部按 pageSize 切片）
//   padding: EdgeInsets.only(top: 16, bottom: 96),
//   itemBuilder: (context, i, w) => _ClaimCard(claim: claims[i]),  // i 仍是全量索引
// )
// ```
//
// 约束：根是 Column(Expanded(滚动网格) + 翻页条)，需要父级给有界高度（通常 Expanded）。
// 想让「换筛选/搜索/关键词后回到第 1 页」时，给组件挂 key：UtenPagedGrid(key: ValueKey(filter), ...)。

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import 'uten_responsive_grid.dart';

/// 分页卡片网格：把全量数据按 [pageSize] 切片，只渲染当页，外裹 [UtenResponsiveGrid]。
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

  /// 全量数据（组件内部只取当页切片交给 [UtenResponsiveGrid]）。
  final List<T> items;

  /// 卡片构造器，签名与 [UtenResponsiveGrid.itemBuilder] 一致；
  /// 回调里的 `index` 是**全量列表**的索引（不是当页内索引），便于直接 `items[index]`。
  final Widget Function(BuildContext context, int index, double itemWidth)
      itemBuilder;

  /// 每页条数（默认 20）。
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
  int _page = 1;
  final ScrollController _ctrl = ScrollController();

  @override
  void didUpdateWidget(covariant UtenPagedGrid<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 数据变化（筛选/刷新/删除）后，页码可能越界 → 收敛到合法范围，避免渲染空页。
    final tp = _totalPages;
    if (_page > tp) {
      _page = tp;
    } else if (_page < 1) {
      _page = 1;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int get _totalPages => widget.items.isEmpty
      ? 1
      : (widget.items.length + widget.pageSize - 1) ~/ widget.pageSize;

  void _goTo(int p) {
    final next = p.clamp(1, _totalPages);
    if (next == _page) return;
    setState(() => _page = next);
    // 翻页回顶（与 MasterDataTableView 一致：从当页第一条开始看）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_ctrl.hasClients) _ctrl.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalPages = _totalPages;
    final start = (_page - 1) * widget.pageSize;
    final end = (start + widget.pageSize).clamp(0, widget.items.length);
    final pageLen = end - start;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            controller: _ctrl,
            physics: widget.physics,
            padding: widget.padding,
            child: pageLen == 0 && widget.emptyPlaceholder != null
                ? widget.emptyPlaceholder!
                : UtenResponsiveGrid(
                    itemCount: pageLen, // ← 只渲染当页：Wrap 子项恒 ≤ pageSize
                    itemBuilder: (c, i, w) =>
                        widget.itemBuilder(c, start + i, w),
                    spacing: widget.spacing,
                    runSpacing: widget.runSpacing,
                    columns: widget.columns,
                    maxColumns: widget.maxColumns,
                    minColumns: widget.minColumns,
                  ),
          ),
        ),
        if (totalPages > 1) buildPager(context, totalPages),
      ],
    );
  }

  Widget buildPager(BuildContext context, int totalPages) =>
      UtenGridPager( // 见下方独立组件（客户端/服务端两种分页复用同一翻页条）
        currentPage: _page,
        totalPages: totalPages,
        totalItems: widget.items.length,
        onPrev: _page > 1 ? () => _goTo(_page - 1) : null,
        onNext: _page < totalPages ? () => _goTo(_page + 1) : null,
      );
}

/// 通用翻页条（上一页 / 第x/y页·共N条 / 下一页）。
///
/// 样式与 `MasterDataTableView._buildPager` 对齐，保持全站分页视觉一致。
/// 两种分页模式复用它：
/// - 客户端切片：`UtenPagedGrid` 内部用它（页码自管）。
/// - 服务端真分页：页面自己持页码 state，watch 后端 `Page`，把当页 items 铺进
///   `UtenResponsiveGrid`，再用本组件做翻页（onPrev/onNext 触发重新拉取）。
///
/// `onPrev`/`onNext` 为 null 时按钮置灰（已到首页/末页）。`totalPages <= 1` 时
/// 调用方应不渲染本组件（小数据无翻页条）。
class UtenGridPager extends StatelessWidget {
  const UtenGridPager({
    super.key,
    required this.currentPage,
    required this.totalPages,
    required this.totalItems,
    required this.onPrev,
    required this.onNext,
  });

  /// 当前页（1-based）。
  final int currentPage;

  /// 总页数。
  final int totalPages;

  /// 总条数（仅用于展示「共 N 条」，不影响翻页逻辑）。
  final int totalItems;

  /// 跳到上一页（首页时由调用方传 null 置灰）。
  final VoidCallback? onPrev;

  /// 跳到下一页（末页时由调用方传 null 置灰）。
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            label: const Text('上一页'), // TODO(l10n): 补 arb
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Text(
              '$currentPage / $totalPages · 共 $totalItems 条', // TODO(l10n): 补 arb
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton.icon(
            onPressed: onNext,
            icon: const Text('下一页'), // TODO(l10n): 补 arb
            label: const Icon(Icons.chevron_right_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

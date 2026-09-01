// UtenFilterToolbar - 「分类分段 + 搜索」统一筛选工具条。
//
// 2026-09-01 全平台 UI 统一的标准范式：凡是页面上有「分类/状态筛选」的地方，
// 一律用本组件呈现，不再手写各种筛选按钮、Chip 行或自成一套的分段样式——
//
// - 分段导航：胶囊 StadiumBorder、与搜索框结构化同高（IntrinsicHeight+stretch）、
//   选中只变背景色不出 ✓ 图标；分段右侧可挂数量时用红色圆数字徽章
//  （UtenSegmentBadgeLabel，count=null/0 不显示，>99 显 99+）；
// - 搜索框：全平台唯一组件 UtenSearchBar（胶囊圆角 + 清除 + 300ms 防抖）；
// - 响应式：宽屏一行（分段 | 搜索 | 弹性 | 尾部），窄屏（< [compactBreakpoint]）
//   分段横向滚动一行 + 搜索换行；
// - 纯分类无搜索的页面只传 [segments]（searchHint 不传即不渲染搜索框）。
//
// 计数口径由调用方负责：应取该分段的「全量」计数（非当前页推算），
// 与后端 pending-count 类接口同源；加载中传 null（徽章不显示）。

import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import '../feedback/uten_segment_badge_label.dart';
import '../inputs/uten_search_bar.dart';

/// 一个分类分段：值 + 文字 + 可选计数徽章。
class UtenFilterSegment<T> {
  const UtenFilterSegment({
    required this.value,
    required this.label,
    this.count,
  });

  final T value;
  final String label;

  /// 该分段的计数；null = 加载中/未知（徽章不显示，不把未知伪装成 0）。
  final int? count;
}

class UtenFilterToolbar<T> extends StatelessWidget {
  const UtenFilterToolbar({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.segmentsKey,
    this.searchKey,
    this.searchHint,
    this.initialSearchValue,
    this.searchController,
    this.onSearchInputChanged,
    this.onSearchChanged,
    this.trailing,
    this.compactBreakpoint = 840,
    this.searchWidth = 360,
  });

  /// 分类分段（建议首段为「全部」）。
  final List<UtenFilterSegment<T>> segments;

  /// 当前选中分段值（单选）。
  final T selected;

  final ValueChanged<T> onSelectionChanged;

  /// 分段按钮 key（页面既有测试/语义锚点透传，如 iqc-type-segments）。
  final Key? segmentsKey;

  /// 搜索框 key（透传）。
  final Key? searchKey;

  /// 搜索提示文案；不传且无 [searchController] 时不渲染搜索框（纯分类工具条）。
  final String? searchHint;

  final String? initialSearchValue;
  final TextEditingController? searchController;

  /// 每次输入同步回调（本地即时过滤用），先于防抖。
  final ValueChanged<String>? onSearchInputChanged;

  /// 300ms 防抖后的回调（发起异步检索用）。
  final ValueChanged<String>? onSearchChanged;

  /// 宽屏行尾内容（如「共 N 条」统计文案）。
  final Widget? trailing;

  /// 低于该宽度切窄屏布局（分段横滚 + 搜索换行）。
  final double compactBreakpoint;

  /// 宽屏搜索框宽度。
  final double searchWidth;

  @override
  Widget build(BuildContext context) {
    final button = SegmentedButton<T>(
      key: segmentsKey,
      // 统一范式：选中只变背景色，不出现 ✓ 图标。高度不在此设置——
      // 分段与搜索框的「严格同高」由下方 IntrinsicHeight+stretch 结构保证
      //（visualDensity 对两侧的折减不一致，minimumSize 各自算高度算不平，
      //  且本 SDK 版本的分段样式会丢弃 minimumSize）。
      showSelectedIcon: false,
      segments: [
        for (final segment in segments)
          ButtonSegment(
            value: segment.value,
            label: UtenSegmentBadgeLabel(
              label: segment.label,
              count: segment.count,
            ),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (selection) => onSelectionChanged(selection.first),
    );
    final showSearch = searchHint != null || searchController != null;
    final search = showSearch
        ? UtenSearchBar(
            key: searchKey,
            hint: searchHint ?? '搜索',
            initialValue: initialSearchValue,
            controller: searchController,
            onInputChanged: onSearchInputChanged,
            onChanged: onSearchChanged,
          )
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < compactBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: button,
              ),
              if (search != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                search,
              ],
              if (trailing != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                trailing!,
              ],
            ],
          );
        }
        // IntrinsicHeight + stretch：分段与搜索框谁高就都拉到同一高度，
        // 密度/字号档变化下两侧永远一致。
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              button,
              if (search != null) ...[
                const SizedBox(width: UtenSpacing.s12),
                SizedBox(width: searchWidth, child: search),
              ],
              if (trailing != null) ...[
                const Spacer(),
                trailing!,
              ],
            ],
          ),
        );
      },
    );
  }
}

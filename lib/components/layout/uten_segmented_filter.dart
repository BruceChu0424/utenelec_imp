// UtenSegmentedFilter - 分段筛选器（用于"全部/待处理/已处理"切换）
//
// 计数形态：一律中性括号 `(N)`（浏览型分段口径，见
// docs/00-项目准则/14-徽章与计数口径.md），数字用等宽字形保证多段对齐。
// 需要红色待办徽章的分段用 UtenFilterToolbar + UtenSegmentBadgeLabel(countForm: actionable)。
// 文档：docs-02-组件库/UtenSegmentedFilter.md（待写）

import 'package:flutter/material.dart';

/// 紧凑分段筛选器；保留 44dp 触摸目标，并支持键盘与选中态语义。
class UtenSegmentedFilter<T> extends StatelessWidget {
  const UtenSegmentedFilter({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<UtenSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: IntrinsicWidth(
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final segment in segments)
                _SegmentButton<T>(
                  segment: segment,
                  selected: selected == segment.value,
                  duration: duration,
                  onTap: () => onChanged(segment.value),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentButton<T> extends StatelessWidget {
  const _SegmentButton({
    required this.segment,
    required this.selected,
    required this.duration,
    required this.onTap,
  });

  final UtenSegment<T> segment;
  final bool selected;
  final Duration duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(8);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: duration,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: EdgeInsets.symmetric(
              horizontal: selected ? 20 : 14,
              vertical: 8,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              borderRadius: radius,
            ),
            child: Text(
              // 计数就地拼在标签里（中性括号形态，符合浏览型分段口径）：**保持单个
              // Text**——分段标签是 28 个页面/组件测试的锚点（find.text('已下达 (1)')），
              // 拆成「标签 + UtenCountSuffix」两个 Text 只为给括号调淡一点颜色，
              // 不值当（2026-09-11 试过，全量测试 28 处红）。数字对齐靠等宽数字字形。
              segment.displayLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class UtenSegment<T> {
  const UtenSegment({required this.value, required this.label, this.count});
  final T value;
  final String label;
  final int? count;

  /// 「标签 (计数)」单串：分段按钮直接渲染它，导出/打印/日志也用同一串。
  /// 计数形态是中性括号（浏览型分段口径，见 docs/00-项目准则/14-徽章与计数口径.md）；
  /// 需要红色待办徽章的分段改用 UtenFilterToolbar + UtenSegmentBadgeLabel。
  String get displayLabel => count != null ? '$label ($count)' : label;
}

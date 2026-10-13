// UtenSegmentedFilter - 分段筛选器（用于"全部/待处理/已处理"切换）
//
// 计数形态：一律中性括号 `(N)`（浏览型分段口径，见
// docs/00-项目准则/14-徽章与计数口径.md），数字用等宽字形保证多段对齐。
// 需要红色待办徽章的分段用 UtenFilterToolbar + UtenSegmentBadgeLabel(countForm: actionable)。
// 文档：docs-02-组件库/UtenSegmentedFilter.md（待写）

import 'package:flutter/material.dart';
import 'uten_segment_row.dart';

/// 紧凑分段筛选器；桌面40、触控48，支持完整分类面板、键盘与选中态语义。
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
    return UtenSegmentRow<T>(
      segments: [
        for (final segment in segments)
          ButtonSegment(
            value: segment.value,
            label: Text(segment.displayLabel),
          ),
      ],
      selected: {selected},
      showSelectedIcon: false,
      onSelectionChanged: (values) => onChanged(values.single),
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

// UtenSegmentedFilter - 分段筛选器（用于"全部/待处理/已处理"切换）
// 文档：docs-02-组件库/UtenSegmentedFilter.md（待写）

import 'package:flutter/material.dart';

/// Uten 分段筛选器
///
/// 比 Material SegmentedButton 更紧凑，常用于列表页的状态筛选。
class UtenSegmentedFilter<T> extends StatelessWidget {
  const UtenSegmentedFilter({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  /// 所有选项
  final List<UtenSegment<T>> segments;

  /// 当前选中的值
  final T selected;

  /// 切换回调
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 宽度自适应：tab 越多越宽、tab 越少越窄（用 IntrinsicWidth + Row.min）
    // 而不是默认的 Expanded 撑满父容器。
    return IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final seg in segments) ...[
              GestureDetector(
                onTap: () => onChanged(seg.value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  // 选中态稍宽：horizontal 20 vs 未选 14，让选中 tab 在视觉上
                  // 比未选中 tab 大一档，提示「当前激活项」。
                  padding: EdgeInsets.symmetric(
                    horizontal: selected == seg.value ? 20 : 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: selected == seg.value
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    seg.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected == seg.value
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 选项
class UtenSegment<T> {
  const UtenSegment({required this.value, required this.label, this.count});
  final T value;
  final String label;
  final int? count;

  String get displayLabel => count != null ? '$label ($count)' : label;
}

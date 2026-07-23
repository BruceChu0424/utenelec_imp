// UtenInfoRow - 详情页键值信息行
// 文档：docs/02-组件库/UtenInfoRow.md（待写）

import 'package:flutter/material.dart';

/// Uten 详情信息行
///
/// 用于详情页展示键值对：标签 + 值，左右对齐。
class UtenInfoRow extends StatelessWidget {
  const UtenInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueWidget,
    this.isImportant = false,
    this.showDivider = true,
  });

  final String label;

  /// 文本值（与 valueWidget 互斥）
  final String? value;

  /// 自定义右侧 Widget（如金额高亮、状态徽章）
  final Widget? valueWidget;

  /// 是否为重点字段（金额、状态等会加粗/变色）
  final bool isImportant;

  /// 是否显示底部分隔线
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 100,
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: valueWidget ??
                    Text(
                      value ?? '—',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            isImportant ? FontWeight.w700 : FontWeight.w400,
                        color: isImportant
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
              ),
            ],
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
      ],
    );
  }
}

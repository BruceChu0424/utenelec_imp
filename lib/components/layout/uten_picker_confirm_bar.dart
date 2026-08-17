// UtenPickerConfirmBar - 滑窗/抽屉选择器统一底部确认栏。
//
// 全站选择滑窗的统一交互契约（二次操作）：点列表项仅高亮勾选，必须再点底部
// 「确定」才把选中值返回给调用方；「取消」（或右上角关闭/遮罩）= 放弃选择。
// 多选场景可带「清空」。视觉沿用 UtenBottomActionBar（surface 吸底 + 顶部细分隔线），
// 与部门选择器既有底栏一致。
import 'package:flutter/material.dart';

import 'uten_bottom_action_bar.dart';

class UtenPickerConfirmBar extends StatelessWidget {
  const UtenPickerConfirmBar({
    super.key,
    required this.selectedCount,
    required this.onConfirm,
    this.onCancel,
    this.selectedLabel,
    this.onClear,
    this.confirmLabel = '确定',
    this.hint,
  });

  /// 已选条数；0 时「确定」禁用、左侧显示引导文案。
  final int selectedCount;

  /// 确认回调（把选中值 pop 回调用方）。
  final VoidCallback? onConfirm;

  /// 取消回调；缺省直接关闭滑窗（pop 无返回值）。
  final VoidCallback? onCancel;

  /// 单选场景的已选项名称（左侧展示「已选择：xxx」）；多选留空显示计数。
  final String? selectedLabel;

  /// 多选场景的清空按钮；null 不显示。
  final VoidCallback? onClear;

  /// 确认按钮文案；多选场景调用方传「确定（n）」。
  final String confirmLabel;

  /// 左侧提示文案覆盖（默认按选中状态自动生成）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSelection = selectedCount > 0;
    final label =
        hint ??
        (selectedCount == 0
            ? '请选择后点「确定」'
            : selectedLabel != null
            ? '已选择：$selectedLabel'
            : '已选择 $selectedCount 项');
    return UtenBottomActionBar(
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: hasSelection
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (onClear != null) ...[
            TextButton(
              onPressed: hasSelection ? onClear : null,
              child: const Text('清空'),
            ),
            const SizedBox(width: 8),
          ],
          TextButton(
            onPressed: onCancel ?? () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: hasSelection ? onConfirm : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }
}

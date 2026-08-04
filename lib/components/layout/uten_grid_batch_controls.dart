// 明细表批量操作控件（与 UtenEditableGrid 配套）。
//
// 编辑页在「明细」标题行右侧放 UtenGridBatchToggle（切换钮，深绿底白字，
// 紧挨「从上游引入」），在其下方放 UtenGridBatchActions（全选/复制/批量删除/粘贴）。
// 批量状态集中在 UtenEditableGridController，故这两个控件直接订阅 controller 即可，
// 不依赖 Riverpod；且它们位于编辑页随页滚动的内容里，不会被 grid 的 sticky 表头覆盖。
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_dialog.dart';
import 'uten_editable_grid.dart';

/// 「批量操作」切换钮：放编辑页「明细」行右侧（从上游引入 旁）。深绿底白字。
class UtenGridBatchToggle<T extends EditableGridRow> extends StatelessWidget {
  const UtenGridBatchToggle({super.key, required this.controller});

  final UtenEditableGridController<T> controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final on = controller.batchMode;
        final disabled = controller.isEmpty;
        final fg = on ? Colors.white : theme.colorScheme.primary;
        return Material(
          color: on
              ? UtenColors.teal800
              : theme.colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: disabled ? null : () => controller.toggleBatchMode(),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.checklist_rounded, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    on ? '退出批量' : '批量操作',
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 批量操作条：批量模式时显 全选/复制选中/批量删除；有缓冲时显 粘贴/粘贴多行。
/// 放编辑页「明细」行下方（随页滚动，不被 sticky 表头覆盖）。
class UtenGridBatchActions<T extends EditableGridRow> extends StatelessWidget {
  const UtenGridBatchActions({
    super.key,
    required this.controller,
    this.cloneRow,
  });

  final UtenEditableGridController<T> controller;

  /// 行克隆函数；非空才显「复制/粘贴」。
  final T Function(T)? cloneRow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasClone = cloneRow != null;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.batchMode && !controller.hasBuffer) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s8,
            bottom: UtenSpacing.s4,
          ),
          child: Wrap(
            spacing: UtenSpacing.s4,
            runSpacing: UtenSpacing.s4,
            children: [
              if (controller.batchMode) ...[
                _btn(
                  theme,
                  controller.allSelected ? '取消全选' : '全选',
                  controller.selectAll,
                ),
                if (hasClone)
                  _btn(
                    theme,
                    '复制选中 (${controller.selectedCount})',
                    controller.selectedCount > 0
                        ? () => controller.copySelected(cloneRow!)
                        : null,
                  ),
                _btn(
                  theme,
                  '批量删除 (${controller.selectedCount})',
                  danger: true,
                  controller.selectedCount > 0
                      ? () => _confirmBatchDelete(context)
                      : null,
                ),
              ],
              if (hasClone && controller.hasBuffer) ...[
                _btn(theme, '粘贴', () => controller.paste(cloneRow!)),
                _btn(theme, '粘贴多行', () => _pasteMany(context)),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _btn(
    ThemeData theme,
    String label,
    VoidCallback? onPressed, {
    bool danger = false,
  }) {
    final color = danger ? theme.colorScheme.error : theme.colorScheme.primary;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  Future<void> _confirmBatchDelete(BuildContext context) async {
    final ok = await UtenDialog.show(
      context,
      title: '批量删除',
      content: Text('确认删除选中的 ${controller.selectedCount} 行明细？'),
      confirmLabel: '删除',
      danger: true,
    );
    if (ok == true) controller.batchDelete();
  }

  Future<void> _pasteMany(BuildContext context) async {
    final n = await _showCountDialog(context);
    if (n != null && n > 0) controller.paste(cloneRow!, count: n);
  }

  Future<int?> _showCountDialog(BuildContext context) {
    final ctrl = TextEditingController(text: '1');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴多行'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '粘贴份数',
            hintText: '1 - 50',
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim()) ?? 0;
              Navigator.pop(ctx, n.clamp(1, 50));
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

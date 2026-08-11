// 主档通用详情面板（货品/模具/客户/供应商 共用）。
//
// 替代各页内联 _openXxxDialog + _row：调用方按期望顺序传入 [MasterDetailRow] 列表，
// 组件统一渲染「双列卡片网格 + 自适应容器 + 底部居中操作按钮」。
// 容器自适应（参照 showUtenPickerSheet）：compact 底部抽屉 / medium+ 居中面板。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';

/// 详情字段行：[value] 为已格式化字符串（调用方负责，如金额 toStringAsFixed）。
/// 空值在面板里显示「—」。
class MasterDetailRow {
  const MasterDetailRow(this.label, this.value);

  final String label;
  final String? value;
}

/// 自适应弹出主档详情。
///
/// [onEdit]/[onDelete] 在 [canEdit] 为真时显示；按钮触发会先关闭本面板（pop）再回调，
/// 调用方负责后续（如开编辑表单、弹删除确认）。
Future<void> showMasterDetailSheet({
  required BuildContext context,
  required String title,
  required List<MasterDetailRow> rows,
  bool canEdit = false,
  VoidCallback? onEdit,
  VoidCallback? onDelete,
}) {
  final body = _MasterDetailBody(
    title: title,
    rows: rows,
    canEdit: canEdit,
    onEdit: onEdit,
    onDelete: onDelete,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (_) => body,
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.88,
        ),
        child: body,
      ),
    ),
  );
}

class _MasterDetailBody extends StatelessWidget {
  const _MasterDetailBody({
    required this.title,
    required this.rows,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
  });

  final String title;
  final List<MasterDetailRow> rows;
  final bool canEdit;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final twoColumn = !context.breakpoint.isCompact;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(theme, context),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: _grid(theme, twoColumn),
            ),
          ),
          const Divider(height: 1),
          _actions(context),
        ],
      ),
    );
  }

  Widget _grid(ThemeData theme, bool twoColumn) {
    final colCount = twoColumn ? 2 : 1;
    final rows2 = <Widget>[];
    for (var i = 0; i < rows.length; i += colCount) {
      final first = rows[i];
      final second = i + 1 < rows.length ? rows[i + 1] : null;
      rows2.add(
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _cell(theme, first)),
              if (colCount > 1) ...[
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: second != null
                      ? _cell(theme, second)
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows2,
    );
  }

  Widget _header(ThemeData theme, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _cell(ThemeData theme, MasterDetailRow r) {
    final hasValue = r.value != null && r.value!.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            r.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hasValue ? r.value! : '—',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canEdit && onEdit != null) ...[
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.edit_outlined,
              onPressed: () {
                Navigator.of(context).pop();
                onEdit!();
              },
              child: const Text('编辑'), // TODO(l10n): 补 arb
            ),
            const SizedBox(width: UtenSpacing.s8),
          ],
          if (canEdit && onDelete != null) ...[
            UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.delete_outline,
              onPressed: () {
                Navigator.of(context).pop();
                onDelete!();
              },
              child: const Text('删除'), // TODO(l10n): 补 arb
            ),
            const SizedBox(width: UtenSpacing.s8),
          ],
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
  }
}

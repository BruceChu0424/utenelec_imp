// 主档通用详情面板（货品/模具/客户/供应商 共用）。
//
// 替代各页内联 _openXxxDialog + _row：调用方按期望顺序传入 [MasterDetailRow] 列表，
// 组件统一渲染与编辑表单相同的自适应字段网格、对象历史与操作按钮。
// 容器自适应（参照 showUtenPickerSheet）：compact 底部抽屉 / medium+ 居中面板。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_form_grid.dart';
import 'master_record_history_panel.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';

/// 详情字段行：[value] 为已格式化字符串（调用方负责，如金额 toStringAsFixed）。
/// 空值在面板里显示「—」。
class MasterDetailRow {
  const MasterDetailRow(this.label, this.value);

  final String label;
  final String? value;
}

class MasterDetailAction {
  const MasterDetailAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.type = UtenButtonType.tonal,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final UtenButtonType type;
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
  bool canDelete = false,
  VoidCallback? onToggleStatus,
  String statusActionLabel = '变更状态',
  VoidCallback? onEdit,
  VoidCallback? onDelete,
  List<MasterDetailAction> extraActions = const [],
  String? historyEntityType,
  String? historyRecordId,
  VoidCallback? onHistoryChanged,
  Widget Function(BuildContext, Widget)? dialogScopeBuilder,
  bool Function()? isCurrent,
}) {
  final body = _MasterDetailBody(
    title: title,
    rows: rows,
    canEdit: canEdit,
    canDelete: canDelete,
    onToggleStatus: onToggleStatus,
    statusActionLabel: statusActionLabel,
    onEdit: onEdit,
    onDelete: onDelete,
    extraActions: extraActions,
    historyEntityType: historyEntityType,
    historyRecordId: historyRecordId,
    onHistoryChanged: onHistoryChanged,
    isCurrent: isCurrent,
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
      builder: (ctx) => dialogScopeBuilder?.call(ctx, body) ?? body,
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final frame = UtenDialogFrame(
        shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
        child: ConstrainedBox(
          // 2026-09-14：宽度随屏幕放缩（原固定 560 太小；客户/供应商已改详情整页，
          // 其余主档弹窗同样受益），网格列数按实际宽度自适应。
          constraints: BoxConstraints(
            maxWidth: (MediaQuery.sizeOf(ctx).width * 0.92).clamp(560.0, 840.0),
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.88,
          ),
          child: body,
        ),
      );
      return dialogScopeBuilder?.call(ctx, frame) ?? frame;
    },
  );
}

class _MasterDetailBody extends StatelessWidget {
  const _MasterDetailBody({
    required this.title,
    required this.rows,
    required this.canEdit,
    required this.canDelete,
    required this.onToggleStatus,
    required this.statusActionLabel,
    required this.onEdit,
    required this.onDelete,
    required this.extraActions,
    required this.historyEntityType,
    required this.historyRecordId,
    required this.onHistoryChanged,
    required this.isCurrent,
  });

  final String title;
  final List<MasterDetailRow> rows;
  final bool canEdit;
  final bool canDelete;
  final VoidCallback? onToggleStatus;
  final String statusActionLabel;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final List<MasterDetailAction> extraActions;
  final String? historyEntityType;
  final String? historyRecordId;
  final VoidCallback? onHistoryChanged;
  final bool Function()? isCurrent;

  bool _current(BuildContext context) =>
      context.mounted && (isCurrent?.call() ?? true);

  void _act(BuildContext context, [VoidCallback? action]) {
    if (!_current(context)) return;
    if (isCurrent != null && ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.of(context).pop();
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(theme, context),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: UtenFormGrid(
                columns: 4,
                maxColumns: 4,
                minFieldWidth: 260,
                children: [for (final row in rows) _cell(theme, row)],
              ),
            ),
          ),
          const Divider(height: 1),
          _actions(context),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, BuildContext context) {
    final detailRoute = ModalRoute.of(context);
    final navigator = Navigator.of(context);
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
          if (historyEntityType != null && historyRecordId != null)
            MasterRecordHistoryAction(
              entityType: historyEntityType!,
              recordId: historyRecordId,
              onChanged: () {
                if (!_current(context)) return;
                if (detailRoute != null && detailRoute.isActive) {
                  navigator.removeRoute(detailRoute);
                }
                onHistoryChanged?.call();
              },
            ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => _act(context),
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
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        children: [
          for (final action in extraActions)
            UtenButton(
              type: action.type,
              icon: action.icon,
              onPressed: () {
                _act(context, action.onPressed);
              },
              child: Text(action.label),
            ),
          if (onToggleStatus != null)
            UtenButton(
              type: statusActionLabel == '停用' || statusActionLabel == '禁用'
                  ? UtenButtonType.danger
                  : UtenButtonType.secondary,
              icon: statusActionLabel == '停用' || statusActionLabel == '禁用'
                  ? Icons.block_rounded
                  : Icons.check_circle_outline_rounded,
              onPressed: () {
                _act(context, onToggleStatus);
              },
              child: Text(statusActionLabel),
            ),
          if (canEdit && onEdit != null)
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.edit_outlined,
              onPressed: () {
                _act(context, onEdit);
              },
              child: const Text('编辑'), // TODO(l10n): 补 arb
            ),
          if (canDelete && onDelete != null)
            UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.delete_outline,
              onPressed: () {
                _act(context, onDelete);
              },
              child: const Text('删除'), // TODO(l10n): 补 arb
            ),
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => _act(context),
            child: const Text('关闭'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
  }
}

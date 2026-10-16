// 员工资料核对更正页私有部件。建议只读，最终值只来自人事手动输入。
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/input/china_input_formatters.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/id_card_utils.dart';
import '../models/hr_reconcile_plan.dart';

class HrReconcileFinalValue {
  const HrReconcileFinalValue(this.value);
  final String value;
}

/// 由页面持有，滚动不丢；建议和旧版采用状态不会写入这个 controller。
class HrReconcileRowDraft {
  final TextEditingController manual = TextEditingController();
  String get manualText => manual.text.trim();
  String? get manualProblem =>
      manualText.isEmpty ? null : IdCardUtils.problemOf(manualText);
  bool get manualValid => manualText.isNotEmpty && manualProblem == null;
  bool get isDirty => manualText.isNotEmpty;
  void dispose() => manual.dispose();
}

/// 空值或非法手输均不能回退采用建议；只读/非支持字段不会成为提交项。
HrReconcileFinalValue? hrReconcileFinalValue(
  HrReconcileItem item,
  HrReconcileRowDraft? draft,
) {
  if (!item.permitted ||
      item.field != 'idNumber' ||
      item.writePath != 'CHANGE_IDENTITY' ||
      draft?.manualValid != true) {
    return null;
  }
  return HrReconcileFinalValue(
    IdCardUtils.normalize(draft!.manualText) ?? draft.manualText,
  );
}

/// 行类型标签：修改=primary / 仅提示=warning / 一致=中性。
class HrReconcileKindTag extends StatelessWidget {
  const HrReconcileKindTag({
    super.key,
    required this.rowNo,
    required this.kind,
  });

  final int rowNo;
  final HrReconcileRowKind kind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (String label, Color? color) = switch (kind) {
      HrReconcileRowKind.update => (l10n.hrReconcileKindUpdate, null),
      HrReconcileRowKind.info => (l10n.hrReconcileKindInfo, UtenColors.warning),
      HrReconcileRowKind.same => (
        l10n.hrReconcileKindSame,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    final effective = color ?? theme.colorScheme.primary;
    return Container(
      key: ValueKey('hr-reconcile-kind-$rowNo'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: effective.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(UtenRadius.sm),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: effective,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 所有把握类型统一手动填写。格内仅输入框及必要校验错误。
class HrReconcileIdNumberCell extends StatelessWidget {
  const HrReconcileIdNumberCell({
    super.key,
    required this.rowNo,
    required this.item,
    required this.editable,
    this.draft,
    this.onManualChanged,
  });
  final int rowNo;
  final HrReconcileItem item;
  final bool editable;
  final HrReconcileRowDraft? draft;
  final VoidCallback? onManualChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      key: ValueKey('hr-reconcile-manual-$rowNo'),
      controller: draft?.manual,
      enabled: editable && item.permitted,
      inputFormatters: ChinaInputFormatters.residentId,
      style: Theme.of(context).textTheme.bodySmall,
      onChanged: (_) => onManualChanged?.call(),
      decoration: UtenInputDecoration(
        InputDecoration(
          isDense: true,
          hintText: l10n.hrReconcileManualHint,
          counterText: '',
          error: switch (draft?.manualProblem) {
            final problem? => UtenFieldMessage.error(problem),
            null => null,
          },
        ),
      ),
    );
  }
}

/// 说明/结果列：notes 逐条 + 执行结果上色。ADR-169 档位：已更正=绿 /
/// 部分=紫（部分完成族）/ 跳过=灰（未处理的中性态）/ 失败=红。
class HrReconcileNotesCell extends StatelessWidget {
  const HrReconcileNotesCell({super.key, required this.row});

  final HrReconcileRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final notes = [for (final item in row.items) ...item.notes];
    final outcome = row.items
        .map((item) => item.outcome)
        .nonNulls
        .toList(growable: false);
    if (notes.isEmpty && outcome.isEmpty && row.result == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final note in notes)
          Text(
            note,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            softWrap: true,
          ),
        for (final o in outcome)
          Text(
            o.message == null || o.message!.isEmpty
                ? _itemOutcomeLabel(l10n, o.status)
                : '${_itemOutcomeLabel(l10n, o.status)}：${o.message}',
            key: ValueKey('hr-reconcile-outcome-${row.rowNo}'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: _statusColor(
                o.status == HrReconcileOutcomeStatus.applied
                    ? HrReconcileRowResultStatus.applied
                    : o.status == HrReconcileOutcomeStatus.skipped
                    ? HrReconcileRowResultStatus.skipped
                    : HrReconcileRowResultStatus.failed,
              ),
              fontWeight: FontWeight.w600,
            ),
            softWrap: true,
          ),
        if (row.result case final result?)
          Text(
            result.message == null || result.message!.isEmpty
                ? _rowResultLabel(l10n, result.status)
                : '${_rowResultLabel(l10n, result.status)}：${result.message}',
            key: ValueKey('hr-reconcile-row-result-${row.rowNo}'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: _statusColor(result.status),
              fontWeight: FontWeight.w700,
            ),
            softWrap: true,
          ),
      ],
    );
  }
}

String _itemOutcomeLabel(
  AppLocalizations l10n,
  HrReconcileOutcomeStatus status,
) => switch (status) {
  HrReconcileOutcomeStatus.applied => l10n.hrReconcileResultApplied,
  HrReconcileOutcomeStatus.skipped => l10n.hrReconcileResultSkipped,
  HrReconcileOutcomeStatus.failed => l10n.hrReconcileResultFailed,
};

String _rowResultLabel(
  AppLocalizations l10n,
  HrReconcileRowResultStatus status,
) => switch (status) {
  HrReconcileRowResultStatus.applied => l10n.hrReconcileResultApplied,
  HrReconcileRowResultStatus.partial => l10n.hrReconcileResultPartial,
  HrReconcileRowResultStatus.skipped => l10n.hrReconcileResultSkipped,
  HrReconcileRowResultStatus.failed => l10n.hrReconcileResultFailed,
};

Color _statusColor(HrReconcileRowResultStatus status) => switch (status) {
  HrReconcileRowResultStatus.applied => UtenColors.statusSuccess,
  HrReconcileRowResultStatus.partial => UtenColors.statusViolet,
  HrReconcileRowResultStatus.skipped => UtenColors.statusNeutral,
  HrReconcileRowResultStatus.failed => UtenColors.statusDanger,
};

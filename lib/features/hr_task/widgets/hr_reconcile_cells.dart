// 员工资料核对更正页(HrReconcilePage，ADR-160)的页面私有部件：
// 把握徽标(含依据 Tooltip) / 行类型标签 / 证件号码格(UtenRevisionCell +
// 候选 chips + 手输区) / 说明·结果列，以及页面行草稿(手输 controller +
// 采用状态，滚动不丢)。
//
// 只做展示与本地草稿，不读接口；提交语义(最终值 = 手输 > 候选 > 建议)的纯函数
// [hrReconcileFinalValue] 也在这里，页面与单元格共用同一份真值。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_revision_cell.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/input/china_input_formatters.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/id_card_utils.dart';
import '../models/hr_reconcile_plan.dart';

/// 最终值来源：手输 / 候选 / 服务端建议。
enum HrReconcileValueSource { manual, candidate, suggestion }

/// 一行里「已给出」的最终值（apply 只带这些行）。
class HrReconcileFinalValue {
  const HrReconcileFinalValue(this.value, this.source, {this.candidateIndex});

  final String value;
  final HrReconcileValueSource source;
  final int? candidateIndex;
}

/// 行草稿：手输 controller + 采用状态，由页面 State 持有（`Map<rowNo>`），
/// 滚动/翻页不丢；dispose 由页面统一释放。
class HrReconcileRowDraft {
  final TextEditingController manual = TextEditingController();

  /// null = 跟随服务端 preselected；true/false = 用户显式采用/取消建议。
  bool? adoptedOverride;

  /// 选中的候选下标（null = 未选）；点已选候选再点一次取消。
  int? candidateIndex;

  String get manualText => manual.text.trim();

  /// 手输非空但没通过校验时的那句话（来自 IdCardUtils，可直接给用户看）。
  String? get manualProblem =>
      manualText.isEmpty ? null : IdCardUtils.problemOf(manualText);

  bool get manualValid => manualText.isNotEmpty && manualProblem == null;

  /// 有未执行的本地改动（离开拦截用）。
  bool get isDirty =>
      manualText.isNotEmpty ||
      adoptedOverride != null ||
      candidateIndex != null;

  void dispose() {
    manual.dispose();
  }
}

/// 最终值解析（apply 语义）：手输合法值 > 选中候选 > 已采用建议；没有返回 null。
///
/// 手输非空但不合法 = 未给出最终值（红字提示，不入提交）。
HrReconcileFinalValue? hrReconcileFinalValue(
  HrReconcileItem item,
  HrReconcileRowDraft? draft,
) {
  if (draft != null) {
    if (draft.manualValid) {
      return HrReconcileFinalValue(
        IdCardUtils.normalize(draft.manualText) ?? draft.manualText,
        HrReconcileValueSource.manual,
      );
    }
    final index = draft.candidateIndex;
    if (index != null &&
        index >= 0 &&
        index < item.candidates.length &&
        draft.manualText.isEmpty) {
      return HrReconcileFinalValue(
        item.candidates[index].value,
        HrReconcileValueSource.candidate,
        candidateIndex: index,
      );
    }
  }
  final adopted = draft?.adoptedOverride ?? item.preselected;
  final suggestion = item.newValue;
  if (adopted && suggestion != null && suggestion.isNotEmpty) {
    return HrReconcileFinalValue(suggestion, HrReconcileValueSource.suggestion);
  }
  return null;
}

/// 两个等长号码的逐位差异（1-based）；长度不等按前缀比，多出的位不计。
/// 打码值不调用（masked 直接关高亮）。
List<int> hrReconcileDiffPositions(String? before, String after) {
  if (before == null || before.isEmpty) return const [];
  final length = before.length < after.length ? before.length : after.length;
  return [
    for (var i = 0; i < length; i++)
      if (before[i] != after[i]) i + 1,
  ];
}

/// 把握徽标：高=success 实底 / 中=warning / 需人工=error 描边 / 无候选=灰。
/// 色值走 ADR-169 状态实底色板：高=statusSuccess / 中=statusOrange（把握
/// 中间档的风险色，橙比亮琥珀作浅底文字更可读）/ 需人工=statusDanger 描边 /
/// 无候选随正文灰。
/// [basisLabel] 非空时悬停/长按出 Tooltip 解释建议依据(生日锚点/校验位求解…，
/// 2026-10-06 原「依据」列退役并入此处)。
class HrReconcileTierBadge extends StatelessWidget {
  const HrReconcileTierBadge({
    super.key,
    required this.itemNo,
    required this.tier,
    this.basisLabel,
  });

  final int itemNo;
  final HrReconcileTier tier;

  /// 建议依据文案(如「生日锚点」)；null=无依据不出 Tooltip。
  final String? basisLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (
      String label,
      bool filled,
      bool outlined,
      Color color,
    ) = switch (tier) {
      HrReconcileTier.high => (
        l10n.hrReconcileTierHigh,
        true,
        false,
        UtenColors.statusSuccess,
      ),
      HrReconcileTier.medium => (
        l10n.hrReconcileTierMedium,
        false,
        false,
        UtenColors.statusOrange,
      ),
      HrReconcileTier.manual => (
        l10n.hrReconcileTierManual,
        false,
        true,
        UtenColors.statusDanger,
      ),
      HrReconcileTier.none => (
        l10n.hrReconcileTierNone,
        false,
        false,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    final badge = Container(
      key: ValueKey('hr-reconcile-tier-$itemNo'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? color : null,
        border: outlined ? Border.all(color: color) : null,
        borderRadius: BorderRadius.circular(UtenRadius.sm),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: filled ? Colors.white : color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (basisLabel == null || basisLabel!.isEmpty) return badge;
    return Tooltip(message: l10n.hrReconcileBasisOf(basisLabel!), child: badge);
  }
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

/// 证件号码格：UtenRevisionCell 旧/新对照 + 采用按钮 + 候选 chips +
/// 可疑位提示 + 手输区（controller 在页面草稿里，滚动不丢）。
class HrReconcileIdNumberCell extends StatelessWidget {
  const HrReconcileIdNumberCell({
    super.key,
    required this.rowNo,
    required this.item,
    required this.masked,
    required this.editable,
    this.draft,
    this.onAdoptToggled,
    this.onCandidateToggled,
    this.onManualChanged,
  });

  final int rowNo;
  final HrReconcileItem item;

  /// !viewPii：旧/新值都是打码串，不做差异位高亮。
  final bool masked;

  /// 能改（canApply && permitted && 行未执行）。
  final bool editable;
  final HrReconcileRowDraft? draft;
  final VoidCallback? onAdoptToggled;
  final ValueChanged<int>? onCandidateToggled;
  final VoidCallback? onManualChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (!item.permitted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          if (item.permissionLabel case final label?) ...[
            const SizedBox(width: 4),
            Flexible(child: Text(label, style: theme.textTheme.bodySmall)),
          ],
        ],
      );
    }

    final draft = this.draft;
    final finalValue = hrReconcileFinalValue(item, draft);
    // 显示值：最终值优先；没有最终值时仍显示建议(未采用态)，让「改成什么」可见。
    final after = finalValue?.value ?? item.newValue;
    final diffPositions = switch (finalValue?.source) {
      HrReconcileValueSource.candidate =>
        item.candidates[finalValue!.candidateIndex!].diffPositions,
      HrReconcileValueSource.manual =>
        masked || item.oldValue == null
            ? const <int>[]
            : hrReconcileDiffPositions(item.oldValue, finalValue!.value),
      _ => item.diffPositions,
    };
    final showManual =
        editable &&
        (item.tier == HrReconcileTier.manual ||
            item.tier == HrReconcileTier.none);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        UtenRevisionCell(
          before: item.oldValue,
          after: after,
          changedPositions: diffPositions,
          masked: masked,
          emptyText: l10n.hrReconcileIdEmpty,
          afterTrailing: _afterTrailing(context, l10n, finalValue),
        ),
        if (editable && item.candidates.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s4),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            children: [
              for (var i = 0; i < item.candidates.length; i++)
                _candidateChip(context, i, draft?.candidateIndex == i),
            ],
          ),
        ],
        if (item.suspectPositions.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s4),
          Text(
            l10n.hrReconcileSuspectHint(
              item.suspectPositions.map((p) => '$p').join('、'),
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (showManual) ...[
          const SizedBox(height: UtenSpacing.s8),
          SizedBox(
            width: 260,
            child: TextField(
              key: ValueKey('hr-reconcile-manual-$rowNo'),
              controller: draft?.manual,
              enabled: editable,
              inputFormatters: ChinaInputFormatters.residentId,
              style: theme.textTheme.bodySmall,
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
            ),
          ),
        ],
      ],
    );
  }

  /// 新值行尾部：已采用=对勾(可撤销)；建议在但未采用=「采用」小按钮。
  Widget? _afterTrailing(
    BuildContext context,
    AppLocalizations l10n,
    HrReconcileFinalValue? finalValue,
  ) {
    if (!editable || item.newValue == null) return null;
    final theme = Theme.of(context);
    if (finalValue?.source == HrReconcileValueSource.suggestion) {
      return Tooltip(
        message: l10n.hrReconcileUnadopt,
        child: InkWell(
          key: ValueKey('hr-reconcile-adopted-$rowNo'),
          onTap: onAdoptToggled,
          child: const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: UtenColors.statusSuccess,
          ),
        ),
      );
    }
    if (finalValue != null) return null;
    return SizedBox(
      height: 26,
      child: TextButton(
        key: ValueKey('hr-reconcile-adopt-$rowNo'),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onAdoptToggled,
        child: Text(
          l10n.hrReconcileAdopt,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _candidateChip(BuildContext context, int index, bool selected) {
    final candidate = item.candidates[index];
    final theme = Theme.of(context);
    final label = candidate.probability == null
        ? candidate.value
        : '${candidate.value} · ${(candidate.probability! * 100).round()}%';
    return InputChip(
      key: ValueKey('hr-reconcile-candidate-$rowNo-$index'),
      label: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: selected ? FontWeight.w700 : null,
        ),
      ),
      selected: selected,
      showCheckmark: false,
      onPressed: editable ? () => onCandidateToggled?.call(index) : null,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
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

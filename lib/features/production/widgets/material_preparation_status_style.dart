import 'package:flutter/material.dart';

import '../../../core/theme/uten_colors.dart';
import '../models/production_flow_stage.dart';

/// Preparation status colors describe the current work, never the supply route.
/// Workshop execution keeps its more detailed ready/partial-ready badge palette.
enum MaterialPreparationStatusPhase {
  pending,
  processing,
  awaitingReceipt,
  completed,
  blocked,
  cancelled,
  unknown,
}

MaterialPreparationStatusPhase materialPreparationStatusPhase({
  ProductionFlowStage? stage,
  String? facetKey,
  String? actualState,
}) {
  final state = actualState?.trim().toUpperCase() ?? '';
  if (state == 'CANCELLED' ||
      state == 'CANCELED' ||
      state == 'REVERSED' ||
      state.endsWith('_CANCELLED') ||
      state.endsWith('_CANCELED') ||
      state.endsWith('_REVERSED')) {
    return MaterialPreparationStatusPhase.cancelled;
  }
  if (facetKey == 'blocked' ||
      facetKey == 'routePending' ||
      stage?.isRoutePending == true ||
      stage?.tone == ProductionFlowTone.decide ||
      stage?.tone == ProductionFlowTone.waitPlanning) {
    return MaterialPreparationStatusPhase.blocked;
  }
  if (stage?.tone == ProductionFlowTone.done || facetKey == 'covered') {
    return MaterialPreparationStatusPhase.completed;
  }
  if (stage == null || stage.key == 'UNKNOWN') {
    return switch (facetKey) {
      'pendingIssue' => MaterialPreparationStatusPhase.pending,
      'inTransit' => MaterialPreparationStatusPhase.awaitingReceipt,
      _ => MaterialPreparationStatusPhase.unknown,
    };
  }
  // Receive/inspect/stock-in are the same arrival phase for BUY and SC; the
  // subcontract return wait (after materials were sent out) belongs to it too.
  if (stage.tone == ProductionFlowTone.waiting ||
      (stage.key.startsWith('BUY_') && stage.stepIndex >= 3) ||
      (stage.key.startsWith('SC_') && stage.stepIndex >= 4)) {
    return MaterialPreparationStatusPhase.awaitingReceipt;
  }
  return stage.stepIndex == 0
      ? MaterialPreparationStatusPhase.pending
      : MaterialPreparationStatusPhase.processing;
}

class MaterialPreparationStatusStyle {
  const MaterialPreparationStatusStyle({
    required this.phase,
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final MaterialPreparationStatusPhase phase;
  final Color background;
  final Color foreground;
  final IconData icon;

  factory MaterialPreparationStatusStyle.resolve(
    ThemeData theme, {
    ProductionFlowStage? stage,
    String? facetKey,
    String? actualState,
    MaterialPreparationStatusPhase? phase,
  }) {
    final resolved =
        phase ??
        materialPreparationStatusPhase(
          stage: stage,
          facetKey: facetKey,
          actualState: actualState,
        );
    final dark = theme.brightness == Brightness.dark;
    final (
      lightBackground,
      lightForeground,
      semantic,
      darkForeground,
      icon,
    ) = switch (resolved) {
      MaterialPreparationStatusPhase.pending => (
        UtenColors.warningBg,
        UtenColors.warningText,
        UtenColors.warning,
        UtenColors.warningOnDark,
        Icons.schedule_rounded,
      ),
      MaterialPreparationStatusPhase.processing => (
        UtenColors.tealSurface,
        UtenColors.teal700,
        UtenColors.teal500,
        UtenColors.teal300,
        Icons.play_circle_outline_rounded,
      ),
      MaterialPreparationStatusPhase.awaitingReceipt => (
        UtenColors.infoBg,
        UtenColors.infoText,
        UtenColors.info,
        UtenColors.infoOnDark,
        Icons.move_to_inbox_outlined,
      ),
      MaterialPreparationStatusPhase.completed => (
        UtenColors.successBg,
        UtenColors.successText,
        UtenColors.success,
        UtenColors.successOnDark,
        Icons.task_alt_rounded,
      ),
      MaterialPreparationStatusPhase.blocked => (
        UtenColors.errorBg,
        UtenColors.errorText,
        UtenColors.error,
        UtenColors.errorOnDark,
        Icons.error_outline_rounded,
      ),
      MaterialPreparationStatusPhase.cancelled => (
        UtenColors.surfaceMid,
        UtenColors.textSecondary,
        UtenColors.slate400,
        UtenColors.slate300,
        Icons.cancel_outlined,
      ),
      MaterialPreparationStatusPhase.unknown => (
        UtenColors.surfaceMid,
        UtenColors.textSecondary,
        UtenColors.slate400,
        UtenColors.slate300,
        Icons.help_outline_rounded,
      ),
    };
    return MaterialPreparationStatusStyle(
      phase: resolved,
      background: dark
          ? Color.alphaBlend(
              semantic.withValues(alpha: 0.18),
              theme.colorScheme.surface,
            )
          : lightBackground,
      foreground: dark ? darkForeground : lightForeground,
      icon: icon,
    );
  }
}

/// The table column owns the full-cell background; this shared content keeps
/// icon and text identical in the preparation table and all three issue pages.
class MaterialPreparationStatusLabel extends StatelessWidget {
  const MaterialPreparationStatusLabel({
    super.key,
    required this.label,
    required this.style,
  });

  final String label;
  final MaterialPreparationStatusStyle style;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(style.icon, size: 18, color: style.foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              // 2026-10-06 行高统一口径：状态文字单行省略号，全量文字由本组件
              // 的 Semantics(container) 播报，行高不随状态文案折行变化。
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: style.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

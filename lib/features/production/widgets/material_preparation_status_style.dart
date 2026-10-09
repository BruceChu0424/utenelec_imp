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

  factory MaterialPreparationStatusStyle.resolve({
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
    // ADR-169 状态实底色板：深色实底 + 成套前景，明暗两主题同一对色。
    // 未下达=灰(等自己动手)、执行中=青绿(他方在干)、在途=琥珀(等外部到货)、
    // 完成=绿、阻断=红、取消/未知=灰(靠图标区分)。
    final (background, foreground, icon) = switch (resolved) {
      MaterialPreparationStatusPhase.pending => (
        UtenColors.statusNeutral,
        Colors.white,
        Icons.schedule_rounded,
      ),
      MaterialPreparationStatusPhase.processing => (
        UtenColors.statusTeal,
        Colors.white,
        Icons.play_circle_outline_rounded,
      ),
      MaterialPreparationStatusPhase.awaitingReceipt => (
        UtenColors.warningStrong,
        UtenColors.onWarningStrong,
        Icons.move_to_inbox_outlined,
      ),
      MaterialPreparationStatusPhase.completed => (
        UtenColors.statusSuccess,
        Colors.white,
        Icons.task_alt_rounded,
      ),
      MaterialPreparationStatusPhase.blocked => (
        UtenColors.statusDanger,
        Colors.white,
        Icons.error_outline_rounded,
      ),
      MaterialPreparationStatusPhase.cancelled => (
        UtenColors.statusNeutral,
        Colors.white,
        Icons.cancel_outlined,
      ),
      MaterialPreparationStatusPhase.unknown => (
        UtenColors.statusNeutral,
        Colors.white,
        Icons.help_outline_rounded,
      ),
    };
    return MaterialPreparationStatusStyle(
      phase: resolved,
      background: background,
      foreground: foreground,
      icon: icon,
    );
  }
}

/// 相位样式的消费方：表格列 cellColor 铺 [MaterialPreparationStatusStyle.background]，
/// 格内文字/图标继承表格注入的对比度前景与加粗（格内容不许写死颜色），
/// 图标可取 [MaterialPreparationStatusStyle.icon]。格内已不再用独立 Label 组件
/// （其成套前景在选中行 cellColor 让位后会留白字，2026-10-08 已删）。

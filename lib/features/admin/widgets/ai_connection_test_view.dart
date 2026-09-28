// 连接测试结果: 网络连通 / 密钥验证 / 模型可用 / JSON 输出 四步, 逐步 ✓/!/✗ + 耗时 + 大白话建议。
//
// 与服务端 TestResult 对齐: 每步 OK / WARN / FAILED / SKIPPED 各有图标与说明;
// 底部总结优先用服务端的 summary(通过但有提示、失败原因), 全部通过时用本地文案。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/ai_provider_models.dart';
import 'ai_settings_labels.dart';

class AiConnectionTestView extends StatelessWidget {
  const AiConnectionTestView({
    super.key,
    required this.result,
    required this.running,
  });

  /// 最近一次测试结果; 还没测过为 null。
  final AiConnectionTestResult? result;

  /// 正在测试(结果未回来)。
  final bool running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final result = running ? null : this.result;
    final steps = result == null
        ? [
            for (final key in AiConnectionTestStep.order)
              AiConnectionTestStep(key: key, status: AiTestStepStatus.skipped),
          ]
        : result.orderedSteps;
    final outcome = result?.outcome;
    final (badgeLabel, badgeType) = switch (outcome) {
      null => (l10n.aiSettingsTesting, UtenStatusBadgeType.info),
      AiTestOutcome.passed => (
        l10n.aiSettingsTestPassedShort,
        UtenStatusBadgeType.success,
      ),
      AiTestOutcome.warning => (
        l10n.aiSettingsTestWarnShort,
        UtenStatusBadgeType.warning,
      ),
      AiTestOutcome.failed => (
        l10n.aiSettingsTestFailedShort,
        UtenStatusBadgeType.danger,
      ),
    };
    final summary = result == null ? null : _summaryText(result, l10n);
    // 服务端把失败原因同时放在步骤说明与总结里: 总结已经写了, 步骤下就不再重复。
    final failure = result?.firstFailure;
    final duplicateDetail = failure != null && failure.message == summary
        ? failure.key
        : null;
    return Semantics(
      container: true,
      liveRegion: true,
      label: l10n.aiSettingsTestResultTitle,
      child: Container(
        key: const ValueKey('ai-connection-test-view'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.network_check_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    l10n.aiSettingsTestResultTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (running || this.result != null)
                  UtenStatusBadge(
                    key: const ValueKey('ai-connection-test-badge'),
                    label: badgeLabel,
                    type: badgeType,
                    size: UtenStatusBadgeSize.small,
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            for (var i = 0; i < steps.length; i++)
              _StepRow(
                key: ValueKey('ai-test-step-${steps[i].key}'),
                step: steps[i],
                spinning: running && i == 0,
                hideDetail: steps[i].key == duplicateDetail,
              ),
            if (summary != null && outcome != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              _Summary(outcome: outcome, text: summary),
            ],
          ],
        ),
      ),
    );
  }

  /// 底部一句话: 全部通过用本地文案; 有提示/没通过优先用服务端的总结(含具体原因与做法)。
  static String _summaryText(
    AiConnectionTestResult result,
    AppLocalizations l10n,
  ) {
    final failure = result.firstFailure;
    return switch (result.outcome) {
      AiTestOutcome.passed => l10n.aiSettingsTestPassed,
      AiTestOutcome.warning =>
        result.message ?? l10n.aiSettingsTestPassedWithNotes,
      AiTestOutcome.failed =>
        failure?.advice ??
            result.message ??
            failure?.message ??
            l10n.aiSettingsTestFailed,
    };
  }
}

/// 步骤状态对应的前景色(浅色/深色主题各一档)。
Color _statusColor(AiTestStepStatus status, ThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  return switch (status) {
    AiTestStepStatus.passed =>
      dark ? UtenColors.successOnDark : UtenColors.success,
    AiTestStepStatus.warning =>
      dark ? UtenColors.warningOnDark : UtenColors.warning,
    AiTestStepStatus.failed => dark ? UtenColors.errorOnDark : UtenColors.error,
    AiTestStepStatus.skipped => theme.colorScheme.outline,
  };
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    super.key,
    required this.step,
    required this.spinning,
    required this.hideDetail,
  });

  final AiConnectionTestStep step;
  final bool spinning;

  /// 说明与底部总结一字不差时不再重复。
  final bool hideDetail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final dark = theme.brightness == Brightness.dark;
    final color = _statusColor(step.status, theme);
    final Widget icon = spinning
        ? SizedBox(
            width: 20,
            height: 20,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: theme.colorScheme.primary,
                backgroundColor: theme.colorScheme.primaryContainer,
              ),
            ),
          )
        : switch (step.status) {
            AiTestStepStatus.passed => Icon(
              Icons.check_circle_rounded,
              size: 20,
              color: color,
              semanticLabel: l10n.aiSettingsTestPassedShort,
            ),
            AiTestStepStatus.warning => Icon(
              Icons.error_rounded,
              size: 20,
              color: color,
              semanticLabel: l10n.aiSettingsTestWarnShort,
            ),
            AiTestStepStatus.failed => Icon(
              Icons.cancel_rounded,
              size: 20,
              color: color,
              semanticLabel: l10n.aiSettingsTestFailedShort,
            ),
            AiTestStepStatus.skipped => Icon(
              Icons.radio_button_unchecked_rounded,
              size: 20,
              color: color,
              semanticLabel: l10n.aiSettingsStepSkipped,
            ),
          };
    // 失败步骤下写「出了什么问题」, 单独下发的「怎么办」放在底部总结里, 不重复。
    final detail = hideDetail || spinning
        ? null
        : step.status == AiTestStepStatus.failed
        ? step.message ?? step.advice
        : step.message;
    final detailColor = switch (step.status) {
      AiTestStepStatus.failed => color,
      AiTestStepStatus.warning =>
        dark ? UtenColors.warningOnDark : UtenColors.warningText,
      AiTestStepStatus.passed ||
      AiTestStepStatus.skipped => theme.colorScheme.onSurfaceVariant,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  aiTestStepLabel(l10n, step),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: step.status == AiTestStepStatus.skipped && !spinning
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface,
                  ),
                ),
                if (detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s2),
                    child: Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: detailColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (step.latencyMs != null && !spinning)
            Padding(
              padding: const EdgeInsets.only(left: UtenSpacing.s8),
              child: Text(
                l10n.aiSettingsLatency(step.latencyMs!),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.outcome, required this.text});

  final AiTestOutcome outcome;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final (background, foreground, icon) = switch (outcome) {
      AiTestOutcome.passed => (
        dark
            ? UtenColors.success.withValues(alpha: 0.16)
            : UtenColors.successBg,
        dark ? UtenColors.successOnDark : UtenColors.successText,
        Icons.verified_rounded,
      ),
      AiTestOutcome.warning => (
        dark
            ? UtenColors.warning.withValues(alpha: 0.16)
            : UtenColors.warningBg,
        dark ? UtenColors.warningOnDark : UtenColors.warningText,
        Icons.info_outline_rounded,
      ),
      AiTestOutcome.failed => (
        dark ? UtenColors.error.withValues(alpha: 0.16) : UtenColors.errorBg,
        dark ? UtenColors.errorOnDark : UtenColors.errorText,
        Icons.lightbulb_outline_rounded,
      ),
    };
    return Container(
      key: const ValueKey('ai-connection-test-summary'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.controlAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

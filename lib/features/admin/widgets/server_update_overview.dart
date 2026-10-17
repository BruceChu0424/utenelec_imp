import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../models/server_operations.dart';
import 'server_update_dialog_guard.dart';

/// Presentation only: callbacks still pass through the page's live owner,
/// capability, CAS and uncertain-outcome guards.
class ServerUpdateOverview extends StatelessWidget {
  const ServerUpdateOverview({
    super.key,
    required this.status,
    required this.job,
    required this.loading,
    required this.starting,
    required this.writable,
    required this.onCheck,
    required this.onReview,
    required this.onRefresh,
    required this.onCancel,
    this.receipt,
    this.error,
    this.errorCode,
    this.uncertainRequestId,
  });

  final ServerOperationsStatus? status;
  final ServerUpdateJob? job, receipt;
  final bool loading, starting, writable;
  final String? error, errorCode, uncertainRequestId;
  final VoidCallback? onCheck, onReview, onRefresh, onCancel;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final value = status;
    final cards = <Widget>[
      _SummaryCard(
        icon: Icons.dns_outlined,
        title: l.serverUpdateCurrentVersion,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _VersionValue(
              value?.currentVersion ?? l.serverUpdateNotChecked,
              key: const ValueKey('server-current-version'),
            ),
            const SizedBox(height: UtenSpacing.s16),
            if (value?.serverTimeZone != null)
              _MetaText(l.serverUpdateTimeZone, value!.serverTimeZone!),
            Text(l.serverUpdateManual, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      _SummaryCard(
        icon: value?.updateAvailable == true
            ? Icons.new_releases_outlined
            : Icons.verified_outlined,
        title: value?.updateAvailable == true
            ? l.serverUpdateAvailableVersion
            : l.serverUpdateKnownVersion,
        accent: value?.updateAvailable == true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _VersionValue(
              value?.latestVersion ?? l.serverUpdateNotChecked,
              key: const ValueKey('server-latest-version'),
              accent: value?.updateAvailable == true,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              value?.updateAvailable == true
                  ? l.serverUpdateReadyHint
                  : value?.lastCheckedAt == null
                  ? l.serverUpdateNoCheckResult
                  : l.serverUpdateNoNewVersion,
              style: theme.textTheme.bodySmall,
            ),
            if (value?.updateAvailable == true && value?.canUpdate == true) ...[
              const SizedBox(height: UtenSpacing.s16),
              UtenButton(
                key: const ValueKey('server-update-available'),
                icon: Icons.system_update_alt_rounded,
                onPressed: onReview,
                child: Text(l.serverUpdateView),
              ),
            ],
          ],
        ),
      ),
      _SummaryCard(
        icon: Icons.manage_search_rounded,
        title: l.serverUpdatePhaseChecking,
        trailing: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenButton(
              key: const ValueKey('server-update-start'),
              type: value?.updateAvailable == true
                  ? UtenButtonType.secondary
                  : UtenButtonType.primary,
              icon: Icons.manage_search_rounded,
              isLoading: starting,
              onPressed: onCheck,
              child: Text(l.serverUpdateCheck),
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (value?.lastCheckedAt != null)
              _MetaText(
                l.serverUpdateLastChecked,
                DisplayDateTime.beijing(
                  value!.lastCheckedAt!.toIso8601String(),
                ),
              ),
            Text(l.serverUpdateLocalOnly, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          UtenInlineNotice(
            key: const ValueKey('server-update-error'),
            level: UtenInlineNoticeLevel.error,
            title: errorCode == null
                ? null
                : '${l.serverUpdateErrorCode} · $errorCode',
            message: error,
          ),
          const SizedBox(height: UtenSpacing.s16),
        ],
        UtenResponsiveGrid(
          itemCount: cards.length,
          maxColumns: 3,
          columns: const UtenResponsiveColumns(expanded: 3),
          itemBuilder: (_, index, _) => cards[index],
        ),
        if (!writable) ...[
          const SizedBox(height: UtenSpacing.s16),
          Text(l.serverUpdateReadOnly, style: theme.textTheme.bodySmall),
        ],
        if (value?.sourceConfigured == false) ...[
          const SizedBox(height: UtenSpacing.s16),
          UtenInlineNotice(
            level: UtenInlineNoticeLevel.warning,
            title: l.serverUpdateUnconfigured,
            message: l.serverUpdateUnconfiguredHint,
          ),
        ],
        if (value != null && !value.available) ...[
          const SizedBox(height: UtenSpacing.s16),
          UtenInlineNotice(
            level: UtenInlineNoticeLevel.warning,
            title: value.failure?.title ?? l.serverUpdateUnavailable,
            message: value.failure?.reason ?? l.serverUpdateServiceUnknown,
          ),
          if (value.failure != null)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(l.serverUpdateFailureDetails),
              children: [
                _MetaText(l.serverUpdateErrorCode, value.failure!.code),
                _MetaText(
                  l.serverUpdateFailedStage,
                  serverUpdatePhaseLabel(context, value.failure!.phase ?? ''),
                ),
                if (value.failure!.suggestion != null)
                  Text(
                    '${l.serverUpdateNextStep}：${value.failure!.suggestion}',
                  ),
              ],
            ),
        ],
        if (value?.manualOnly == false || value?.timerActive == true) ...[
          const SizedBox(height: UtenSpacing.s12),
          const Text('服务器仍报告旧自动检查计划，请联系管理员核对。'),
        ],
        if (uncertainRequestId != null) ...[
          const SizedBox(height: UtenSpacing.s24),
          UtenInlineNotice(
            level: UtenInlineNoticeLevel.warning,
            title: l.serverUpdatePending,
            message: l.serverUpdatePendingHint,
          ),
          const SizedBox(height: UtenSpacing.s8),
          _MetaText(l.serverUpdateRequestId, _identifier(uncertainRequestId!)),
        ],
        if (receipt != null && receipt!.id != job?.id) ...[
          const SizedBox(height: UtenSpacing.s24),
          UtenInlineNotice(
            key: const ValueKey('server-update-original-receipt'),
            title: l.serverUpdateReceiptStatus,
            message:
                '${serverUpdateJobTitle(context, receipt!)}\n${l.serverUpdateRequestId}：${_identifier(receipt!.requestId)}',
          ),
        ],
        const SizedBox(height: UtenSpacing.s24),
        if (job != null)
          ServerUpdateJobPanel(
            job: job!,
            timeZone: value?.serverTimeZone,
            onRefresh: onRefresh,
            onCancel: onCancel,
          )
        else ...[
          Text(l.serverUpdateNoJob, style: theme.textTheme.titleMedium),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            l.serverUpdateNoJobHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
    this.accent = false,
  });
  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;
  final bool accent;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: accent
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: UtenSpacing.s16),
            child,
          ],
        ),
      ),
    );
  }
}

class _VersionValue extends StatelessWidget {
  const _VersionValue(this.value, {super.key, this.accent = false});
  final String value;
  final bool accent;
  @override
  Widget build(BuildContext context) => Text(
    value,
    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      color: accent ? Theme.of(context).colorScheme.primary : null,
    ),
  );
}

class ServerVersionComparison extends StatelessWidget {
  const ServerVersionComparison({super.key, required this.status});
  final ServerOperationsStatus? status;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final value = status;
    Widget version(
      String label,
      String text, {
      required Key key,
      bool accent = false,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          text,
          key: key,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: accent ? theme.colorScheme.primary : null,
          ),
        ),
      ],
    );
    final current = version(
      l.serverUpdateCurrentVersion,
      value?.currentVersion ?? l.serverUpdateNotChecked,
      key: const ValueKey('server-current-version'),
    );
    final available = version(
      value?.updateAvailable == true
          ? l.serverUpdateAvailableVersion
          : l.serverUpdateKnownVersion,
      value?.latestVersion ?? l.serverUpdateNotChecked,
      key: const ValueKey('server-latest-version'),
      accent: value?.updateAvailable == true,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Builder(
          builder: (context) {
            final minimum =
                180 * MediaQuery.textScalerOf(context).scale(14) / 14;
            if (serverUpdateDialogContentWidth(context) >= minimum * 2 + 32) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: current),
                  const SizedBox(width: UtenSpacing.s24),
                  Expanded(child: available),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                current,
                const SizedBox(height: UtenSpacing.s24),
                available,
              ],
            );
          },
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (value?.updateAvailable != true)
          Text(
            value?.lastCheckedAt == null
                ? l.serverUpdateNoCheckResult
                : l.serverUpdateNoNewVersion,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class ServerUpdateJobPanel extends StatefulWidget {
  const ServerUpdateJobPanel({
    super.key,
    required this.job,
    this.timeZone,
    this.onRefresh,
    this.onCancel,
  });
  final ServerUpdateJob job;
  final String? timeZone;
  final VoidCallback? onRefresh, onCancel;

  @override
  State<ServerUpdateJobPanel> createState() => _JobPanelState();
}

class _JobPanelState extends State<ServerUpdateJobPanel> {
  bool _copied = false;

  @override
  void didUpdateWidget(ServerUpdateJobPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.job.id != widget.job.id ||
        oldWidget.job.requestId != widget.job.requestId) {
      _copied = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final job = widget.job;
    final failure = job.failure;
    final failed = job.state == 'FAILED' || job.recoveryRequired;
    final title = serverUpdateJobTitle(context, job);
    final tone = failed ? theme.colorScheme.error : theme.colorScheme.primary;
    final phases = job.mode == 'CHECK_ONLY'
        ? ['CHECKING', 'DONE']
        : [
            'CHECKING',
            'DOWNLOADING',
            'BACKING_UP',
            'MIGRATING',
            'ACTIVATING',
            'HEALTH_CHECK',
            'DONE',
          ];
    final index = phases.indexOf(job.phase);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.serverUpdateRecentJob,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              failed
                  ? Icons.error_outline_rounded
                  : job.succeeded
                  ? Icons.check_circle_outline_rounded
                  : job.state == 'CANCELLED'
                  ? Icons.event_busy_outlined
                  : Icons.update_rounded,
              color: tone,
              size: 24,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                title,
                key: const ValueKey('server-update-job-state'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (job.state == 'SCHEDULED') ...[
          Text(
            '${l.serverUpdateScheduledAt}：${job.displayLocalTime ?? job.scheduledAt?.toUtc().toIso8601String() ?? l.serverUpdateNotChecked}（${job.displayLocalTime == null ? 'UTC' : widget.timeZone ?? l.serverUpdateTimeZone}）',
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(l.serverUpdateScheduleWait),
          if (widget.onCancel != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            Align(
              alignment: Alignment.centerLeft,
              child: UtenButton(
                key: const ValueKey('server-update-cancel'),
                type: UtenButtonType.secondary,
                onPressed: widget.onCancel,
                child: const Text('取消预约'),
              ),
            ),
          ],
        ],
        if (job.state == 'RUNNING' || job.state == 'QUEUED') ...[
          const LinearProgressIndicator(),
          const SizedBox(height: UtenSpacing.s16),
        ],
        if (job.state != 'SCHEDULED' && job.state != 'CANCELLED')
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s12,
            children: [
              for (var i = 0; i < phases.length; i++)
                Semantics(
                  label:
                      '${serverUpdatePhaseLabel(context, phases[i])}${i == index ? ' · ${l.serverUpdateProgress}' : ''}',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        job.succeeded || i < index
                            ? Icons.check_circle_outline
                            : failed && i == index
                            ? Icons.error_outline
                            : i == index
                            ? Icons.pending_outlined
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: i == index && failed
                            ? tone
                            : job.succeeded || i <= index
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Text(
                        serverUpdatePhaseLabel(context, phases[i]),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: i == index ? FontWeight.w600 : null,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        if (failed) ...[
          const SizedBox(height: UtenSpacing.s16),
          Container(
            key: const ValueKey('server-update-failure-summary'),
            padding: const EdgeInsets.all(UtenSpacing.s16),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
              border: Border(left: BorderSide(color: tone, width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (failure?.title != null) ...[
                  Text(failure!.title!, style: theme.textTheme.titleSmall),
                  const SizedBox(height: UtenSpacing.s8),
                ],
                Text(failure?.reason ?? l.serverUpdateLegacyFailure),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  job.recoveryRequired
                      ? l.serverUpdateRecovery
                      : failure?.originalServicePreserved == true
                      ? l.serverUpdateServicePreserved
                      : l.serverUpdateServiceUnknown,
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  '${l.serverUpdateNextStep}：${failure?.suggestion ?? (job.recoveryRequired ? l.serverUpdateRecoveryHint : l.serverUpdateCheckBeforeRetry)}',
                ),
                if (failure?.retrySafe == true && !job.recoveryRequired) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    l.serverUpdateRetryCheckHint,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (widget.onRefresh != null) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: widget.onRefresh,
                      child: Text(l.serverUpdateRefresh),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: UtenSpacing.s16),
        ExpansionTile(
          key: ValueKey(('server-update-job-details', job.id)),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: UtenSpacing.s12),
          title: Text(
            failed ? l.serverUpdateFailureDetails : l.serverUpdateDetails,
            style: theme.textTheme.titleSmall,
          ),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (failed) ...[
                  _MetaText(
                    l.serverUpdateFailedStage,
                    serverUpdatePhaseLabel(
                      context,
                      failure?.phase ?? job.phase,
                    ),
                  ),
                  _MetaText(
                    l.serverUpdateErrorCode,
                    failure?.code ?? l.serverUpdatePhaseUnknown,
                  ),
                  if (failure?.exitCode != null)
                    _MetaText(l.serverUpdateExitCode, '${failure!.exitCode}'),
                ],
                _MetaText(l.serverUpdateRequestId, _identifier(job.requestId)),
                _MetaText(l.serverUpdateJobId, _identifier(job.id)),
                if (job.startedAt != null)
                  _MetaText(
                    l.serverUpdateStartedAt,
                    DisplayDateTime.beijing(job.startedAt!.toIso8601String()),
                  ),
                if (job.finishedAt != null)
                  _MetaText(
                    l.serverUpdateFinishedAt,
                    DisplayDateTime.beijing(job.finishedAt!.toIso8601String()),
                  ),
                if (job.migrationRequired != null)
                  Text(
                    job.migrationRequired!
                        ? l.serverUpdateMigrationRequired
                        : l.serverUpdateMigrationNotRequired,
                  ),
                if (job.health != null) Text(_health(context, job.health)),
                const SizedBox(height: UtenSpacing.s12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: UtenButton(
                    key: const ValueKey('server-update-copy-diagnostics'),
                    type: UtenButtonType.secondary,
                    icon: Icons.copy_rounded,
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: serverUpdateDiagnostics(job)),
                      );
                      if (mounted) setState(() => _copied = true);
                    },
                    child: Text(
                      _copied
                          ? l.serverUpdateDiagnosticsCopied
                          : l.serverUpdateCopyDiagnostics,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

String serverUpdateJobTitle(BuildContext context, ServerUpdateJob job) {
  final l = AppLocalizations.of(context);
  if (job.recoveryRequired) return l.serverUpdateRecovery;
  return switch (job.state) {
    'QUEUED' => l.serverUpdateQueued,
    'RUNNING' =>
      job.mode == 'CHECK_ONLY' ? l.serverUpdateChecking : l.serverUpdateRunning,
    'SCHEDULED' => l.serverUpdateScheduled,
    'CANCELLED' => l.serverUpdateCancelled,
    'SUCCEEDED' =>
      job.mode == 'CHECK_ONLY' ? l.serverUpdateCheckDone : l.serverUpdateDone,
    'FAILED' => l.serverUpdateFailed,
    _ => l.serverUpdateUnknownState,
  };
}

String serverUpdatePhaseLabel(BuildContext context, String phase) {
  final l = AppLocalizations.of(context);
  return switch (phase) {
    'CHECKING' => l.serverUpdatePhaseChecking,
    'DOWNLOADING' => l.serverUpdatePhaseDownload,
    'BACKING_UP' => l.serverUpdatePhaseBackup,
    'MIGRATING' => l.serverUpdatePhaseMigrate,
    'ACTIVATING' => l.serverUpdatePhaseActivate,
    'HEALTH_CHECK' => l.serverUpdatePhaseHealth,
    'DONE' => l.serverUpdatePhaseDone,
    _ => l.serverUpdatePhaseUnknown,
  };
}

String serverUpdateDiagnostics(ServerUpdateJob job) => [
  'requestId=${_identifier(job.requestId)}',
  'jobId=${_identifier(job.id)}',
  'state=${_identifier(job.state)}',
  'phase=${_identifier(job.failure?.phase ?? job.phase)}',
  if (job.failure != null) ...[
    'code=${job.failure!.code}',
    if (job.failure!.reason != null) 'reason=${job.failure!.reason}',
    'recoveryRequired=${job.recoveryRequired}',
    if (job.failure!.originalServicePreserved != null)
      'originalServicePreserved=${job.failure!.originalServicePreserved}',
    'nextAction=${job.failure!.nextAction}',
    if (job.failure!.exitCode != null) 'exitCode=${job.failure!.exitCode}',
  ],
].join('\n');

String _identifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}$').hasMatch(value) &&
        safeServerOperationText(value) != null
    ? value
    : 'unavailable';

String _health(BuildContext context, Object? value) {
  final l = AppLocalizations.of(context);
  if (value is Map) return _health(context, value['status']);
  if (value == true || const ['UP', 'HEALTHY', 'PASS'].contains(value)) {
    return l.serverUpdateHealthPass;
  }
  if (value == false || const ['DOWN', 'FAILED'].contains(value)) {
    return l.serverUpdateHealthFailed;
  }
  return l.serverUpdateHealthUnknown;
}

class _MetaText extends StatelessWidget {
  const _MetaText(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
    child: Text('$label：$value', style: Theme.of(context).textTheme.bodySmall),
  );
}

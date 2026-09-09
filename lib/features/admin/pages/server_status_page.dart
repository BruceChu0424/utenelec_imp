import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../models/server_status.dart';
import '../repositories/server_status_repository.dart';

class ServerStatusPage extends ConsumerStatefulWidget {
  const ServerStatusPage({super.key});

  @override
  ConsumerState<ServerStatusPage> createState() => _ServerStatusPageState();
}

class _ServerStatusPageState extends ConsumerState<ServerStatusPage>
    with WidgetsBindingObserver {
  ServerStatusSnapshot? _snapshot;
  Timer? _timer;
  Timer? _staleTimer;
  bool _loading = false;
  bool _failed = false;
  bool _denied = false;
  bool _foreground = true;
  bool? _routeVisible;
  int _generation = 0;

  bool get _hasPermission =>
      ref.read(currentPermissionsProvider).contains(Perm.serverStatusView);
  bool get _active =>
      mounted &&
      _foreground &&
      (_routeVisible ?? true) &&
      _hasPermission &&
      !_denied;
  AppLocalizations get _l10n => AppLocalizations.of(context);
  bool get _fresh =>
      !_failed && _snapshot != null && !_snapshot!.isStale(clock.now());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setVisible(ModalRoute.of(context)?.isCurrent ?? true);
  }

  void _setVisible(bool value) {
    if (_routeVisible == value) return;
    _routeVisible = value;
    _timer?.cancel();
    _staleTimer?.cancel();
    if (_active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_active) unawaited(_refresh());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    _staleTimer?.cancel();
    if (_active) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!_active || _loading) return;
    _timer?.cancel();
    final generation = ++_generation;
    setState(() => _loading = true);
    _scheduleStaleState();
    try {
      final next = await ref.read(serverStatusRepositoryProvider).load();
      if (!mounted || generation != _generation || !_hasPermission) return;
      setState(() {
        _snapshot = next;
        _failed = false;
      });
      _scheduleStaleState();
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failed = true;
        if (error is ApiException &&
            (error.code == 'FORBIDDEN' || error.code == 'UNAUTHORIZED')) {
          _denied = true;
          _snapshot = null;
        }
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        // One-shot scheduling after completion guarantees a single request,
        // including slow responses, manual refresh and foreground changes.
        if (_active) {
          _timer = Timer(Duration(seconds: _snapshot?.pollSeconds ?? 15), () {
            if (_active) unawaited(_refresh());
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _staleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _scheduleStaleState() {
    _staleTimer?.cancel();
    final snapshot = _snapshot;
    if (!_active || snapshot?.sampledAt == null) return;
    final expires = snapshot!.sampledAt!.add(
      Duration(seconds: snapshot.pollSeconds * 2),
    );
    final delay = expires.difference(clock.now()).inMilliseconds + 1;
    if (delay > 0) {
      _staleTimer = Timer(Duration(milliseconds: delay), () {
        if (_active) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.serverStatusView);
    ref.listen(currentPermissionsProvider, (previous, next) {
      if (!next.contains(Perm.serverStatusView)) {
        _timer?.cancel();
        _staleTimer?.cancel();
        _generation++;
        setState(() => _snapshot = null);
      } else if (previous?.contains(Perm.serverStatusView) != true) {
        _denied = false;
        if (_active) unawaited(_refresh());
      }
    });
    ref.listen(pageResumeProvider, (_, next) {
      if (next.location.isNotEmpty) {
        _setVisible(next.location == RouteName.adminServerStatus);
      }
    });
    final l10n = _l10n;
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.serverStatusTitle,
        showBackButton: true,
        showPagePermissionAction: false,
        actions: [
          if (allowed && !_denied)
            IconButton(
              key: const Key('server-status-refresh'),
              tooltip: l10n.serverStatusRefresh,
              onPressed: _loading ? null : _refresh,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: !allowed || _denied
          ? Center(
              child: UtenEmpty(
                icon: Icons.lock_outline_rounded,
                message: l10n.serverStatusAccessRequired,
              ),
            )
          : SafeArea(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: UtenContentContainer(
                    selectable: false,
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s20,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _overview(),
                        if (_fresh && _snapshot!.alerts.isNotEmpty) ...[
                          const SizedBox(height: UtenSpacing.s16),
                          _alerts(),
                        ],
                        const SizedBox(height: UtenSpacing.s24),
                        _sectionTitle(l10n.serverStatusResources),
                        const SizedBox(height: UtenSpacing.s12),
                        _grid(_resourceCards()),
                        const SizedBox(height: UtenSpacing.s24),
                        _sectionTitle(l10n.serverStatusStorage),
                        const SizedBox(height: UtenSpacing.s12),
                        _grid([
                          if (_snapshot?.disks.isNotEmpty == true)
                            for (final disk in _snapshot!.disks) _disk(disk)
                          else
                            _disk(null),
                        ]),
                        const SizedBox(height: UtenSpacing.s24),
                        _sectionTitle(l10n.serverStatusDataProtection),
                        const SizedBox(height: UtenSpacing.s12),
                        _grid([_database(), _backup()]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _overview() {
    final theme = Theme.of(context);
    final status = _fresh ? _snapshot!.status : ServerHealthStatus.unknown;
    final color = _statusColor(context, status);
    final message = _failed
        ? _l10n.serverStatusRefreshFailed
        : _snapshot?.sampledAt == null
        ? _l10n.serverStatusCollecting
        : !_fresh
        ? _l10n.serverStatusStale
        : _l10n.serverStatusOverviewHint;
    return UtenCard(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: UtenRadius.lgAll,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Icon(Icons.dns_outlined, color: color, size: 32),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _l10n.serverStatusOverview,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      _StatusBadge(
                        status: status,
                        key: const Key('server-status-overall'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s16),
            Text(
              message,
              key: const Key('server-status-freshness'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _fresh ? theme.colorScheme.onSurfaceVariant : color,
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
            Wrap(
              spacing: UtenSpacing.s24,
              runSpacing: UtenSpacing.s12,
              children: [
                _meta(_l10n.serverStatusUpdatedAt, _date(_snapshot?.sampledAt)),
                _meta(
                  _l10n.serverStatusEnvironment,
                  _available(_snapshot?.environment),
                ),
                _meta(
                  _l10n.serverStatusVersion,
                  _available(_snapshot?.applicationVersion),
                ),
                _meta(
                  _l10n.serverStatusUptime,
                  _uptime(_snapshot?.uptimeSeconds),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              _l10n.serverStatusPolling(_snapshot?.pollSeconds ?? 15),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _meta(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: UtenSpacing.s4),
      Text(
        value,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    ],
  );

  Widget _sectionTitle(String title) => Text(
    title,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
  );

  Widget _grid(List<Widget> cards) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth < 600
          ? 1
          : constraints.maxWidth < 1150
          ? 2
          : 4;
      final columns = cards.length.clamp(1, available);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var start = 0; start < cards.length; start += columns) ...[
            if (start > 0) const SizedBox(height: UtenSpacing.s16),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (
                    var index = start;
                    index < (start + columns).clamp(0, cards.length);
                    index++
                  ) ...[
                    if (index > start) const SizedBox(width: UtenSpacing.s16),
                    Expanded(child: cards[index]),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    },
  );

  List<Widget> _resourceCards() {
    final metrics = {
      for (final metric in _snapshot?.metrics ?? const <ServerMetric>[])
        metric.key: metric,
    };
    return [
      for (final key in {
        'cpu',
        'memory',
        'jvm_memory',
        'db_pool',
        ...metrics.keys,
      })
        _metric(key, metrics[key]),
    ];
  }

  Widget _metric(String key, ServerMetric? metric) {
    final status = _effective(metric?.status, missing: metric?.value == null);
    final unit = metric?.unit == 'MILLISECONDS'
        ? 'ms'
        : metric?.unit == 'PERCENT'
        ? '%'
        : '';
    return _MetricCard(
      key: ValueKey('server-metric-$key'),
      title: switch (key) {
        'cpu' => _l10n.serverStatusCpu,
        'memory' => _l10n.serverStatusMemory,
        'jvm_memory' => _l10n.serverStatusAppMemory,
        'db_pool' => _l10n.serverStatusDbPool,
        _ => metric?.label ?? key,
      },
      icon: switch (key) {
        'cpu' => Icons.memory_rounded,
        'memory' => Icons.storage_rounded,
        'jvm_memory' => Icons.layers_outlined,
        _ => Icons.hub_outlined,
      },
      status: status,
      value: _number(metric?.value),
      unit: unit,
      percent: metric?.unit == 'PERCENT' ? metric?.value : null,
      detail: _detail(metric?.detail),
      tooltip: _threshold(
        metric?.warningThreshold,
        metric?.criticalThreshold,
        unit,
      ),
      facts: [
        if (metric?.usedBytes != null)
          (_l10n.serverStatusUsed, _bytes(metric!.usedBytes)),
        if (metric?.totalBytes != null)
          (_l10n.serverStatusCapacity, _bytes(metric!.totalBytes)),
        if (metric?.freeBytes != null)
          (_l10n.serverStatusFree, _bytes(metric!.freeBytes)),
      ],
    );
  }

  Widget _disk(ServerDisk? disk) => _MetricCard(
    key: ValueKey('server-disk-${disk?.key ?? 'unknown'}'),
    title: disk?.label.isNotEmpty == true
        ? disk!.label
        : _l10n.serverStatusDisk,
    icon: Icons.storage_outlined,
    status: _effective(disk?.status, missing: disk?.usedPercent == null),
    value: _number(disk?.usedPercent),
    unit: '%',
    percent: disk?.usedPercent,
    detail: _detail(disk?.detail),
    tooltip: _threshold(disk?.warningThreshold, disk?.criticalThreshold, '%'),
    facts: [
      (_l10n.serverStatusUsed, _bytes(disk?.usedBytes)),
      (_l10n.serverStatusFree, _bytes(disk?.freeBytes)),
      (_l10n.serverStatusCapacity, _bytes(disk?.totalBytes)),
    ],
  );

  Widget _database() {
    final database = _snapshot?.database;
    return _MetricCard(
      key: const Key('server-database'),
      title: _l10n.serverStatusDatabase,
      icon: Icons.dns_outlined,
      status: _effective(database?.status),
      value: _number(database?.responseMs),
      unit: 'ms',
      detail: _detail(database?.detail),
      tooltip: _l10n.serverStatusDatabaseHint,
      facts: [
        (_l10n.serverStatusResponse, '${_number(database?.responseMs)} ms'),
        (
          _l10n.serverStatusConnections,
          '${_number(database?.connections)} / ${_number(database?.maxConnections)}',
        ),
      ],
    );
  }

  Widget _backup() {
    final backup = _snapshot?.backup;
    return _MetricCard(
      key: const Key('server-backup'),
      title: _l10n.serverStatusBackup,
      icon: Icons.cloud_done_outlined,
      status: _effective(backup?.status),
      value: _number(backup?.ageHours),
      unit: _l10n.serverStatusHours,
      detail: _detail(backup?.detail),
      tooltip: _threshold(
        backup?.warningAfterHours,
        backup?.criticalAfterHours,
        _l10n.serverStatusHours,
      ),
      facts: [(_l10n.serverStatusLastBackup, _date(backup?.lastSuccessAt))],
    );
  }

  Widget _alerts() => UtenCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(_l10n.serverStatusAttention),
        for (final alert in _snapshot!.alerts)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _statusIcon(alert.status),
                  color: _statusColor(context, alert.status),
                  size: 20,
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alert.message,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (alert.suggestion.isNotEmpty)
                        Text(
                          alert.suggestion,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  ServerHealthStatus _effective(
    ServerHealthStatus? status, {
    bool missing = false,
  }) => !_fresh || missing
      ? ServerHealthStatus.unknown
      : status ?? ServerHealthStatus.unknown;
  String _detail(String? detail) => _failed
      ? _l10n.serverStatusRefreshFailed
      : _snapshot?.sampledAt != null && !_fresh
      ? _l10n.serverStatusStale
      : detail?.isNotEmpty == true
      ? detail!
      : _l10n.serverStatusNotCollected;
  String _available(String? value) => value?.isNotEmpty == true ? value! : '—';
  String _date(DateTime? value) {
    if (value == null) return '—';
    final wallTime = ChinaDateTime.fromInstant(value);
    return '${ChinaDateTime.formatDateTime(wallTime)}:${wallTime.second.toString().padLeft(2, '0')}';
  }

  String _number(double? value) => value == null
      ? '—'
      : value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
  String _bytes(double? value) {
    if (value == null) return '—';
    if (value >= 1024 * 1024 * 1024) {
      return '${_number(value / (1024 * 1024 * 1024))} GiB';
    }
    if (value >= 1024 * 1024) return '${_number(value / (1024 * 1024))} MiB';
    return '${_number(value / 1024)} KiB';
  }

  String _uptime(double? value) {
    if (value == null) return '—';
    final duration = Duration(seconds: value.toInt());
    return _l10n.serverStatusUptimeValue(
      duration.inDays,
      duration.inHours % 24,
      duration.inMinutes % 60,
    );
  }

  String _threshold(double? warning, double? critical, String unit) =>
      warning == null || critical == null
      ? _l10n.serverStatusThresholdUnknown
      : _l10n.serverStatusThresholds(
          '${_number(warning)}$unit',
          '${_number(critical)}$unit',
        );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    super.key,
    required this.title,
    required this.icon,
    required this.status,
    required this.value,
    required this.unit,
    required this.detail,
    required this.tooltip,
    this.percent,
    this.facts = const [],
  });
  final String title, value, unit, detail, tooltip;
  final IconData icon;
  final ServerHealthStatus status;
  final double? percent;
  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _statusColor(context, status);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: theme.colorScheme.onSurfaceVariant, size: 22),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              UtenFieldHintIcon(info: tooltip),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                value,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (unit.isNotEmpty)
                Text(
                  unit,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          _StatusBadge(status: status),
          if (percent != null) ...[
            const SizedBox(height: UtenSpacing.s16),
            ExcludeSemantics(
              child: LinearProgressIndicator(
                value: (percent! / 100).clamp(0, 1),
                minHeight: 6,
                borderRadius: BorderRadius.circular(UtenRadius.pill),
                color: color,
                backgroundColor: color.withValues(alpha: 0.12),
              ),
            ),
          ],
          if (facts.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s16),
            for (final fact in facts)
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                child: Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s4,
                  children: [
                    Text(
                      fact.$1,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      fact.$2,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({super.key, required this.status});
  final ServerHealthStatus status;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return UtenStatusBadge(
      label: switch (status) {
        ServerHealthStatus.normal => l10n.serverStatusNormal,
        ServerHealthStatus.warning => l10n.serverStatusWarning,
        ServerHealthStatus.critical => l10n.serverStatusCritical,
        ServerHealthStatus.unknown => l10n.serverStatusUnknown,
      },
      icon: _statusIcon(status),
      type: switch (status) {
        ServerHealthStatus.normal => UtenStatusBadgeType.success,
        ServerHealthStatus.warning => UtenStatusBadgeType.warning,
        ServerHealthStatus.critical => UtenStatusBadgeType.danger,
        ServerHealthStatus.unknown => UtenStatusBadgeType.neutral,
      },
    );
  }
}

IconData _statusIcon(ServerHealthStatus status) => switch (status) {
  ServerHealthStatus.normal => Icons.check_circle_outline_rounded,
  ServerHealthStatus.warning => Icons.warning_amber_rounded,
  ServerHealthStatus.critical => Icons.error_outline_rounded,
  ServerHealthStatus.unknown => Icons.help_outline_rounded,
};

Color _statusColor(BuildContext context, ServerHealthStatus status) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (status) {
    ServerHealthStatus.normal =>
      dark ? UtenColors.successOnDark : UtenColors.successText,
    ServerHealthStatus.warning =>
      dark ? UtenColors.warningOnDark : UtenColors.warningText,
    ServerHealthStatus.critical =>
      dark ? UtenColors.errorOnDark : UtenColors.errorText,
    ServerHealthStatus.unknown => Theme.of(
      context,
    ).colorScheme.onSurfaceVariant,
  };
}

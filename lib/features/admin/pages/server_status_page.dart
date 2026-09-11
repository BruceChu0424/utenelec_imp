import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_animated_number.dart';
import '../../../components/data_display/uten_gauge_ring.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_live_pulse_dot.dart';
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
import '../../basic_data/widgets/master_data_table_view.dart';
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

  /// 采样成功次数；只驱动总览的脉冲点，不参与任何数据判断。
  int _pulse = 0;

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
        _pulse++;
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
    final extras = _snapshot?.extras ?? const <ServerMetric>[];
    final jobs = _snapshot?.jobs ?? const <ServerJob>[];
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
                        if (extras.isNotEmpty) ...[
                          const SizedBox(height: UtenSpacing.s24),
                          // TODO(l10n): 补 arb
                          _sectionTitle('平台运行指标'),
                          const SizedBox(height: UtenSpacing.s12),
                          _grid([for (final extra in extras) _extra(extra)]),
                        ],
                        if (jobs.isNotEmpty) ...[
                          const SizedBox(height: UtenSpacing.s24),
                          // TODO(l10n): 补 arb
                          _sectionTitle('定时任务'),
                          const SizedBox(height: UtenSpacing.s12),
                          _jobs(jobs),
                        ],
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
    final ring = UtenGaugeRing(
      key: const Key('server-status-ring'),
      value: _fresh ? _worstPercent() : null,
      status: _gauge(status),
      label: _l10n.serverStatusOverview,
      statusText: _statusLabel(status),
      caption: _overviewCaption(),
      size: 168,
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                _l10n.serverStatusOverview,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            UtenLivePulseDot(
              key: const Key('server-status-pulse'),
              pulse: _pulse,
              stale: !_fresh,
              color: color,
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        _StatusBadge(status: status, key: const Key('server-status-overall')),
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
            _meta(_l10n.serverStatusUptime, _uptime(_snapshot?.uptimeSeconds)),
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
    );
    return UtenCard(
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 560
            ? Row(
                children: [
                  ring,
                  const SizedBox(width: UtenSpacing.s24),
                  Expanded(child: details),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(child: ring),
                  const SizedBox(height: UtenSpacing.s16),
                  details,
                ],
              ),
      ),
    );
  }

  /// 总览环的值：最差的百分比指标（含磁盘），没有可用百分比时为空环。
  double? _worstPercent() {
    double? worst;
    for (final metric in _snapshot!.metrics) {
      if (metric.unit != 'PERCENT' || metric.value == null) continue;
      if (worst == null || metric.value! > worst) worst = metric.value;
    }
    for (final disk in _snapshot!.disks) {
      final value = disk.usedPercent;
      if (value == null) continue;
      if (worst == null || value > worst) worst = value;
    }
    return worst;
  }

  String _overviewCaption() {
    if (!_fresh) return _l10n.serverStatusUnknown;
    final count = _snapshot!.alerts.length;
    // TODO(l10n): 补 arb
    return count == 0 ? '暂无预警项' : '需要留意 $count 项';
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
    final title = switch (key) {
      'cpu' => _l10n.serverStatusCpu,
      'memory' => _l10n.serverStatusMemory,
      'jvm_memory' => _l10n.serverStatusAppMemory,
      'db_pool' => _l10n.serverStatusDbPool,
      _ => metric?.label ?? key,
    };
    return _MetricCard(
      key: ValueKey('server-metric-$key'),
      title: title,
      icon: switch (key) {
        'cpu' => Icons.memory_rounded,
        'memory' => Icons.storage_rounded,
        'jvm_memory' => Icons.layers_outlined,
        _ => Icons.hub_outlined,
      },
      status: status,
      detail: _detail(metric?.detail),
      tooltip: _threshold(
        metric?.warningThreshold,
        metric?.criticalThreshold,
        '%',
      ),
      ring: UtenGaugeRing(
        value: _fresh ? metric?.value : null,
        status: _gauge(status),
        label: title,
        statusText: _statusLabel(status),
        warning: metric?.warningThreshold,
        critical: metric?.criticalThreshold,
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

  /// 附加指标：带告警阈值的计数走圆环，其余（会话数、附件容量）走数字卡。
  Widget _extra(ServerMetric metric) {
    final status = _effective(metric.status, missing: metric.value == null);
    final bytes = metric.unit == 'BYTES';
    final ringed = !bytes && metric.criticalThreshold != null;
    return _MetricCard(
      key: ValueKey('server-extra-${metric.key}'),
      title: metric.label,
      icon: switch (metric.key) {
        'threads' => Icons.timeline_rounded,
        'errors' => Icons.report_gmailerrorred_rounded,
        'sessions' => Icons.people_alt_outlined,
        'outbox' => Icons.outbox_outlined,
        'attachments' => Icons.folder_copy_outlined,
        _ => Icons.insights_outlined,
      },
      status: status,
      detail: _detail(metric.detail),
      tooltip: _threshold(
        metric.warningThreshold,
        metric.criticalThreshold,
        '',
      ),
      ring: ringed
          ? UtenGaugeRing(
              value: _fresh ? metric.value : null,
              status: _gauge(status),
              label: metric.label,
              statusText: _statusLabel(status),
              unit: '',
              max: metric.criticalThreshold!,
              warning: metric.warningThreshold,
              critical: metric.criticalThreshold,
            )
          : null,
      headline: ringed
          ? null
          : _BigNumber(
              value: _fresh ? metric.value : null,
              text: bytes ? _bytes(_fresh ? metric.value : null) : null,
              color: _statusColor(context, status),
            ),
      facts: [
        if (metric.criticalThreshold != null)
          // TODO(l10n): 补 arb
          ('告警值', _number(metric.criticalThreshold)),
      ],
    );
  }

  Widget _disk(ServerDisk? disk) {
    final status = _effective(disk?.status, missing: disk?.usedPercent == null);
    final title = disk?.label.isNotEmpty == true
        ? disk!.label
        : _l10n.serverStatusDisk;
    return _MetricCard(
      key: ValueKey('server-disk-${disk?.key ?? 'unknown'}'),
      title: title,
      icon: Icons.storage_outlined,
      status: status,
      detail: _detail(disk?.detail),
      tooltip: _threshold(disk?.warningThreshold, disk?.criticalThreshold, '%'),
      ring: UtenGaugeRing(
        value: _fresh ? disk?.usedPercent : null,
        status: _gauge(status),
        label: title,
        statusText: _statusLabel(status),
        warning: disk?.warningThreshold,
        critical: disk?.criticalThreshold,
      ),
      facts: [
        (_l10n.serverStatusUsed, _bytes(disk?.usedBytes)),
        (_l10n.serverStatusFree, _bytes(disk?.freeBytes)),
        (_l10n.serverStatusCapacity, _bytes(disk?.totalBytes)),
      ],
    );
  }

  Widget _database() {
    final database = _snapshot?.database;
    final status = _effective(database?.status);
    final maximum = database?.maxConnections;
    // 响应耗时单独按 200ms / 1000ms 着色，不跟随连接数的整体状态。
    final response = database?.responseMs;
    final responseStatus = _effective(
      response == null
          ? ServerHealthStatus.unknown
          : response >= 1000
          ? ServerHealthStatus.critical
          : response >= 200
          ? ServerHealthStatus.warning
          : ServerHealthStatus.normal,
      missing: response == null,
    );
    return _MetricCard(
      key: const Key('server-database'),
      title: _l10n.serverStatusDatabase,
      icon: Icons.dns_outlined,
      status: status,
      detail: _detail(database?.detail),
      tooltip: _l10n.serverStatusDatabaseHint,
      ring: UtenGaugeRing(
        value: _fresh ? database?.connections : null,
        status: _gauge(status),
        label: _l10n.serverStatusConnections,
        statusText: _statusLabel(status),
        unit: '',
        max: maximum == null || maximum <= 0 ? 100 : maximum,
        warning: maximum == null ? null : maximum * 0.8,
        critical: maximum == null ? null : maximum * 0.95,
        caption:
            '${_number(_fresh ? database?.connections : null)} / ${_number(_fresh ? maximum : null)}',
      ),
      headline: _BigNumber(
        value: _fresh ? response : null,
        unit: 'ms',
        color: _statusColor(context, responseStatus),
      ),
      facts: [
        (_l10n.serverStatusResponse, '${_number(_fresh ? response : null)} ms'),
      ],
    );
  }

  Widget _backup() {
    final backup = _snapshot?.backup;
    final status = _effective(backup?.status);
    final critical = backup?.criticalAfterHours;
    return _MetricCard(
      key: const Key('server-backup'),
      title: _l10n.serverStatusBackup,
      icon: Icons.cloud_done_outlined,
      status: status,
      detail: _detail(backup?.detail),
      tooltip: _threshold(
        backup?.warningAfterHours,
        backup?.criticalAfterHours,
        _l10n.serverStatusHours,
      ),
      ring: UtenGaugeRing(
        value: _fresh ? backup?.ageHours : null,
        status: _gauge(status),
        label: _l10n.serverStatusBackup,
        statusText: _statusLabel(status),
        unit: _l10n.serverStatusHours,
        max: critical == null || critical <= 0 ? 48 : critical,
        warning: backup?.warningAfterHours,
        critical: critical,
      ),
      facts: [(_l10n.serverStatusLastBackup, _date(backup?.lastSuccessAt))],
    );
  }

  Widget _jobs(List<ServerJob> jobs) => UtenCard(
    child: MasterDataTableView<ServerJob>(
      embedded: true,
      columns: [
        MasterColumnDef(
          key: 'label',
          // TODO(l10n): 补 arb
          label: '任务',
          width: 240,
          value: (job) => job.label,
        ),
        MasterColumnDef(
          key: 'status',
          // TODO(l10n): 补 arb
          label: '状态',
          width: 120,
          value: (job) => _statusLabel(_effective(job.status)),
          cellBuilder: (context, job) =>
              _StatusBadge(status: _effective(job.status), small: true),
        ),
        MasterColumnDef(
          key: 'lastStartAt',
          // TODO(l10n): 补 arb
          label: '上次开始',
          width: 170,
          value: (job) => _date(job.lastStartAt),
        ),
        MasterColumnDef(
          key: 'lastEndAt',
          // TODO(l10n): 补 arb
          label: '上次结束',
          width: 170,
          value: (job) => _date(job.lastEndAt),
        ),
        MasterColumnDef(
          key: 'lastErrorType',
          // TODO(l10n): 补 arb
          label: '上次错误',
          width: 170,
          value: (job) => job.lastErrorType ?? '—',
        ),
        MasterColumnDef(
          key: 'detail',
          // TODO(l10n): 补 arb
          label: '说明',
          width: 320,
          value: (job) => job.detail,
        ),
      ],
      items: jobs,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      // 超过 2 个周期未执行由后端判定为 WARNING，这里按状态染底色。
      rowColor: (job) {
        final status = _effective(job.status);
        return status == ServerHealthStatus.warning ||
                status == ServerHealthStatus.critical
            ? _statusColor(context, status).withValues(alpha: 0.08)
            : null;
      },
      // TODO(l10n): 补 arb
      emptyMessage: '本次启动后尚未记录到定时任务',
    ),
  );

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

  String _statusLabel(ServerHealthStatus status) => switch (status) {
    ServerHealthStatus.normal => _l10n.serverStatusNormal,
    ServerHealthStatus.warning => _l10n.serverStatusWarning,
    ServerHealthStatus.critical => _l10n.serverStatusCritical,
    ServerHealthStatus.unknown => _l10n.serverStatusUnknown,
  };

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

/// 圆环/数字 + 状态徽章 + 事实行 + 口径说明的统一指标卡。
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    super.key,
    required this.title,
    required this.icon,
    required this.status,
    required this.detail,
    required this.tooltip,
    this.ring,
    this.headline,
    this.facts = const [],
  });
  final String title, detail, tooltip;
  final IconData icon;
  final ServerHealthStatus status;

  /// 圆环；为空时只显示 [headline]。
  final Widget? ring;

  /// 圆环下方（或替代圆环）的大数字，例如数据库响应耗时。
  final Widget? headline;
  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          const SizedBox(height: UtenSpacing.s12),
          if (ring != null) Align(child: ring),
          if (headline != null) ...[
            if (ring != null) const SizedBox(height: UtenSpacing.s8),
            Align(child: headline),
          ],
          const SizedBox(height: UtenSpacing.s12),
          Align(child: _StatusBadge(status: status)),
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

/// 非百分比指标的大数字（响应耗时、附件容量等）。
class _BigNumber extends StatelessWidget {
  const _BigNumber({
    required this.value,
    required this.color,
    this.unit = '',
    this.text,
  });
  final double? value;
  final Color color;
  final String unit;

  /// 已格式化的文本（例如字节），给定后不做数字滚动。
  final String? text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: color,
    );
    return Wrap(
      spacing: UtenSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (text != null)
          Text(
            text!,
            style: style?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          )
        else
          UtenAnimatedNumber(value: value, style: style),
        if (unit.isNotEmpty)
          Text(unit, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({super.key, required this.status, this.small = false});
  final ServerHealthStatus status;
  final bool small;
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
      size: small ? UtenStatusBadgeSize.small : UtenStatusBadgeSize.medium,
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

UtenGaugeStatus _gauge(ServerHealthStatus status) => switch (status) {
  ServerHealthStatus.normal => UtenGaugeStatus.normal,
  ServerHealthStatus.warning => UtenGaugeStatus.warning,
  ServerHealthStatus.critical => UtenGaugeStatus.critical,
  ServerHealthStatus.unknown => UtenGaugeStatus.unknown,
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

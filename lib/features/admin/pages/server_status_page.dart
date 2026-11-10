import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_animated_number.dart';
import '../../../components/data_display/uten_gauge_ring.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_live_pulse_dot.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/paging/read_view_activity.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/badges/effective_badge_summary_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/server_status.dart';
import '../models/server_storage.dart';
import '../providers/server_status_snapshot_cache.dart';
import '../providers/server_operations_access.dart';
import '../repositories/server_status_repository.dart';
import '../repositories/server_storage_repository.dart';

class ServerStatusPage extends ConsumerWidget {
  const ServerStatusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = (
      ref.watch(authenticatedScopeProvider),
      ref.watch(apiBaseUrlProvider),
    );
    return _ServerStatusSession(key: ValueKey(owner));
  }
}

class _ServerStatusSession extends ConsumerStatefulWidget {
  const _ServerStatusSession({super.key});

  @override
  ConsumerState<_ServerStatusSession> createState() => _ServerStatusPageState();
}

class _ServerStatusPageState extends ConsumerState<_ServerStatusSession>
    with WidgetsBindingObserver, ReadViewActivityMixin<_ServerStatusSession> {
  @override
  Future<void> onReadViewResumed() => _refresh();
  late final Object _owner;
  bool get _current =>
      mounted &&
      _owner ==
          (ref.read(authenticatedScopeProvider), ref.read(apiBaseUrlProvider));
  ServerStatusSnapshot? _snapshot;
  Timer? _timer;
  Timer? _staleTimer;
  bool _loading = false;
  bool _failed = false;
  bool _denied = false;
  bool _foreground = true;
  bool? _routeVisible;
  int _generation = 0;

  /// 存储分区视图（按内容保存在哪分区）来自 server-storage 接口，与 15 秒
  /// 状态轮询分开拉：成功后至少隔 60 秒才再拉，拉不到就退回逐盘圆环卡。
  ServerStorageSummary? _storage;
  DateTime? _storageLoadedAt;
  bool _storageLoading = false;
  int _storageGeneration = 0;

  /// 采样成功次数；只驱动总览的脉冲点，不参与任何数据判断。
  int _pulse = 0;

  // 2026-09-22 全站表格滚动口径：后台任务表表头吸顶，置顶后才显示页面滚动条。
  final ScrollController _pageScroll = ScrollController();
  final ValueNotifier<bool> _jobsPinned = ValueNotifier<bool>(false);

  bool get _hasPermission => ref.read(serverOperationsVisibleProvider);
  bool get _active =>
      _current &&
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
    _owner = (
      ref.read(authenticatedScopeProvider),
      ref.read(apiBaseUrlProvider),
    );
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    // 第一帧就用共享缓存把总览画出来，不等自己那趟请求回来（用户反馈「运行总览
    // 要等好一会才出现」就是在等这趟往返）。过期的缓存不用——宁可显示占位，
    // 也不摆一个下一帧就被标成「已过期」的旧读数。详见
    // providers/server_status_snapshot_cache.dart。
    final cached = ref.read(serverStatusSnapshotCacheProvider);
    if (cached != null && !cached.isStale(clock.now())) _snapshot = cached;
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
    if (!value) _retireReads();
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
    if (!_foreground) _retireReads();
    if (_active) unawaited(_refresh());
  }

  void _retireReads() {
    _generation++;
    _storageGeneration++;
    _loading = false;
    _storageLoading = false;
  }

  Future<void> _refresh() async {
    if (!_active || _loading) return;
    _timer?.cancel();
    final generation = ++_generation;
    bool current() => _active && generation == _generation;
    setState(() => _loading = true);
    _scheduleStaleState();
    try {
      final next = await readViewActivity.runRead(
        current,
        () => ref.read(serverStatusRepositoryProvider).load(),
        slot: 'status',
      );
      if (!current()) return;
      // 回写缓存：下次进页面第一帧直接用，不必再等一趟。
      ref.read(serverStatusSnapshotCacheProvider.notifier).state = next;
      setState(() {
        _snapshot = next;
        _failed = false;
        _pulse++;
      });
      _scheduleStaleState();
      unawaited(_loadStorage());
    } catch (error) {
      if (isRetiredViewRead(error)) return;
      if (!_current || generation != _generation) return;
      setState(() {
        _failed = true;
        if (error is ApiException &&
            (error.code == 'FORBIDDEN' || error.code == 'UNAUTHORIZED')) {
          _denied = true;
          _snapshot = null;
        }
      });
    } finally {
      if (_current && generation == _generation) {
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
    _retireReads();
    _timer?.cancel();
    _staleTimer?.cancel();
    _pageScroll.dispose();
    _jobsPinned.dispose();
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

  Future<void> _loadStorage() async {
    if (!_active || _storageLoading) return;
    final now = clock.now();
    final loadedAt = _storageLoadedAt;
    if (loadedAt != null &&
        now.difference(loadedAt) < const Duration(seconds: 60)) {
      return;
    }
    _storageLoading = true;
    final generation = ++_storageGeneration;
    bool current() => _active && generation == _storageGeneration;
    try {
      final summary = await readViewActivity.runRead(
        current,
        () => ref.read(serverStorageRepositoryProvider).summary(),
        slot: 'storage',
      );
      if (!current()) return;
      setState(() {
        _storage = summary.available && summary.volumes.isNotEmpty
            ? summary
            : null;
        _storageLoadedAt = now;
      });
    } catch (_) {
      // 存储清单暂时拉不到时保留上一次结果或退回逐盘卡，不影响状态轮询。
    } finally {
      if (generation == _storageGeneration) _storageLoading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = ref.watch(serverOperationsVisibleProvider);
    ref.listen(serverOperationsVisibleProvider, (previous, next) {
      if (!next) {
        _timer?.cancel();
        _staleTimer?.cancel();
        _retireReads();
        setState(() => _snapshot = null);
      } else if (previous != true) {
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
    // 待更新版本数随徽章汇总带回(serverOperations.updates, 只对有更新权限的人
    // 有数, 其余人为 0 不显徽章)。工作台的「服务器更新」卡已退役, 本页按钮是
    // 更新的常驻入口, 数字让人不点进去就知道该更新了。
    final pendingUpdates = ref.watch(
      effectiveBadgeSummaryProvider.select(
        (s) => s.entryTodo(BadgeEntry.serverUpdateAvailable),
      ),
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.serverStatusTitle,
        showBackButton: true,
        showPagePermissionAction: false,
        actions: [
          if (allowed && !_denied)
            UtenRefreshButton(
              key: const Key('server-status-refresh'),
              tooltip: l10n.serverStatusRefresh,
              busy: _loading,
              onRefresh: _refresh,
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
                child: UtenGridPageScrollbar(
                  pinned: _jobsPinned,
                  controller: _pageScroll,
                  child: SingleChildScrollView(
                    controller: _pageScroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: UtenContentContainer(
                      selectable: false,
                      // compact 悬浮胶囊避让：滚到底末块要能越过胶囊
                      padding: EdgeInsets.fromLTRB(
                        0,
                        UtenSpacing.s20,
                        0,
                        math.max(
                          UtenSpacing.s20,
                          UtenCapsuleNavScope.occlusionOf(context),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _overview(),
                          const SizedBox(height: UtenSpacing.s16),
                          Wrap(
                            spacing: UtenSpacing.s12,
                            runSpacing: UtenSpacing.s8,
                            children: [
                              UtenButton(
                                type: UtenButtonType.secondary,
                                icon: Icons.system_update_alt_rounded,
                                onPressed: () => context.push(
                                  RouteName.adminServerOperations,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('服务器更新'),
                                    // 徽章 count<=0 自行收起, 无数时按钮只剩文字。
                                    if (pendingUpdates > 0) ...[
                                      const SizedBox(width: UtenSpacing.s8),
                                      UtenNotificationBadge(
                                        key: const Key(
                                          'server-update-pending-badge',
                                        ),
                                        count: pendingUpdates,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              UtenButton(
                                type: UtenButtonType.secondary,
                                icon: Icons.storage_rounded,
                                onPressed: () =>
                                    context.push(RouteName.adminServerStorage),
                                child: const Text('存储管理'),
                              ),
                            ],
                          ),
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
                          _storageSection(),
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
                            _sectionTitle('后台自动任务'),
                            const SizedBox(height: UtenSpacing.s12),
                            _jobs(jobs),
                          ],
                        ],
                      ),
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
        : null;
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
            UtenFieldHintIcon(
              info:
                  '${_l10n.serverStatusOverviewHint}\n\n'
                  '${_l10n.serverStatusPolling(_snapshot?.pollSeconds ?? 15)}',
              dense: true,
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
        if (message != null) ...[
          const SizedBox(height: UtenSpacing.s16),
          Text(
            message,
            key: const Key('server-status-freshness'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: _fresh ? theme.colorScheme.onSurfaceVariant : color,
            ),
          ),
        ],
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
      'jvm_memory' => metric?.label ?? 'Java 堆内存',
      'process_memory' => metric?.label ?? '应用常驻内存',
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
        'process_memory' => Icons.memory_rounded,
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

  /// 2026-11-10 用户要求：存储余量按「内容保存在哪」分区展示——每块存储
  /// 区域一张卡（数据库与备份区 / 上传文件区 / 系统与程序区），区里显示
  /// 占用条、剩余量和该区内容的明细，说明收进标题旁的提示弹层；存储清单
  /// 接口不可用时退回逐盘圆环卡。
  Widget _storageSection() {
    final storage = _storage;
    if (storage == null || storage.volumes.isEmpty) {
      return _grid([
        if (_snapshot?.disks.isNotEmpty == true)
          for (final disk in _snapshot!.disks) _disk(disk)
        else
          _disk(null),
      ]);
    }
    final zones = _storageZones(storage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < zones.length; index++) ...[
          if (index > 0) const SizedBox(height: UtenSpacing.s12),
          zones[index],
        ],
      ],
    );
  }

  List<Widget> _storageZones(ServerStorageSummary storage) {
    final rowsByVolume = <String, List<ServerStorageCategory>>{};
    for (final category in storage.categories) {
      final volumeId = category.volumeId;
      if (volumeId == null) continue;
      rowsByVolume.putIfAbsent(volumeId, () => []).add(category);
    }
    final entries = <({int rank, _StorageZoneCard card})>[];
    for (final volume in storage.volumes) {
      // SYSTEM 类是覆盖整个系统根的概览，与「已安装的程序版本」等明细重叠，
      // 分区明细里不重复列出。
      final rows = (rowsByVolume[volume.id] ?? const <ServerStorageCategory>[])
          .where((row) => row.kind != 'SYSTEM')
          .toList();
      final spec = _zoneSpec(volume.mount, volume.label);
      entries.add((
        rank: _zoneRank(volume.mount),
        card: _StorageZoneCard(
          key: ValueKey('server-storage-zone-${volume.id}'),
          name: spec.name,
          icon: spec.icon,
          hint: spec.hint,
          mount: volume.mount,
          totalBytes: volume.totalBytes,
          usedBytes: volume.usedBytes,
          freeBytes: volume.freeBytes,
          rows: rows,
        ),
      ));
    }
    entries.sort((a, b) => a.rank.compareTo(b.rank));
    return [for (final entry in entries) entry.card];
  }

  ({String name, IconData icon, String hint}) _zoneSpec(
    String? mount,
    String fallbackLabel,
  ) => switch (mount) {
    '/data' => (
      name: '数据库与备份区',
      icon: Icons.dns_outlined,
      hint:
          '公司最核心的数据都保存在这块大容量硬盘上：数据库本体、每天凌晨自动生成的全量备份，'
          '以及数据库和附件一起打包的配套备份。\n\n超过一年的老附件会自动搬到这块盘的冷存区，'
          '要用时系统自动调取，无需人工处理。这块盘由两块硬盘做了镜像冗余，任何一块坏掉数据仍然完整；'
          '超龄的旧备份每天自动删除，不需要人工清理。',
    ),
    final String path when path.startsWith('/var/lib/uten-imp-media') => (
      name: '上传文件区',
      icon: Icons.cloud_upload_outlined,
      hint:
          '大家平时上传的附件和客户端安装包保存在这块独立的固态硬盘上，上传、下载、预览速度快。\n\n'
          '公司文件库的文件和一年内上传的资料常驻这块盘；最近有人下载过的文件无论多老都留在这里。'
          '只有既超过一年、又长期没人使用的老资料才会自动搬到数据库与备份区的大硬盘上，不影响使用。',
    ),
    '/' => (
      name: '系统与程序区',
      icon: Icons.settings_suggest_outlined,
      hint:
          '操作系统、ERP 程序本体和运行日志在这里。\n\n每次版本更新会保留旧版本以便回退；'
          '超龄的旧版本和日志会被自动清理。',
    ),
    _ => (
      name: fallbackLabel.isEmpty ? '存储区域' : fallbackLabel,
      icon: Icons.storage_outlined,
      hint: '服务器上的一块存储区域，用于保存运行所需的数据。',
    ),
  };

  int _zoneRank(String? mount) => switch (mount) {
    '/data' => 0,
    final String path when path.startsWith('/var/lib/uten-imp-media') => 1,
    '/' => 2,
    _ => 3,
  };

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
    showBorder: false,
    child: MasterDataTableView<ServerJob>(
      tableKey:
          'features.admin.pages.server_status_page.ServerStatusPageState._jobs.1',
      embedded: true,
      stickyHeaderPinned: _jobsPinned,
      columns: [
        MasterColumnDef(
          key: 'status',
          // TODO(l10n): 补 arb
          label: '状态',
          width: 72,
          filterFromRows: true,
          facetSearchEnabled: true,
          value: (job) => _statusLabel(_effective(job.status)),
          // 2026-09-27 用户口径「格内胶囊改单元格背景色」：健康色铺整格。
          cellColor: (context, job) => utenStatusBadgeCellColor(
            _serverStatusBadgeType(_effective(job.status)),
          ),
        ),
        MasterColumnDef(
          key: 'label',
          // TODO(l10n): 补 arb
          label: '任务',
          width: 240,
          value: (job) => job.label,
        ),
        MasterColumnDef(
          key: 'lastStartAt',
          // TODO(l10n): 补 arb
          label: '上次开始',
          width: 170,
          type: 'date',
          sortable: true,
          filterFromRows: true,
          value: (job) => _date(job.lastStartAt),
        ),
        MasterColumnDef(
          key: 'lastEndAt',
          // TODO(l10n): 补 arb
          label: '上次结束',
          width: 170,
          type: 'date',
          sortable: true,
          filterFromRows: true,
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
      // 连续失败 / 疑似卡住 / 长时间没轮到执行由后端判定为 WARNING 或 CRITICAL,
      // 名称与说明也由后端用人话给出 (ScheduledTaskCatalog); 这里只按状态染底色。
      rowColor: (job) {
        final status = _effective(job.status);
        return status == ServerHealthStatus.warning ||
                status == ServerHealthStatus.critical
            ? _statusColor(context, status).withValues(alpha: 0.08)
            : null;
      },
      // TODO(l10n): 补 arb
      emptyMessage: '本次启动后尚未记录到后台自动任务',
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
    return ChinaDateTime.formatDateTime(wallTime, seconds: true);
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

/// 存储分区卡：一块「内容保存在哪」的存储区域一张卡。剩余量最突出，
/// 占用条按状态着色，区内各类内容逐行列出；挂载路径等技术说明收进
/// 标题旁的提示弹层，不给不熟悉的用户添堵。
class _StorageZoneCard extends StatelessWidget {
  const _StorageZoneCard({
    super.key,
    required this.name,
    required this.icon,
    required this.hint,
    required this.mount,
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
    required this.rows,
  });

  final String name;
  final IconData icon;
  final String hint;
  final String? mount;
  final int? totalBytes, usedBytes, freeBytes;
  final List<ServerStorageCategory> rows;

  static String _plainBytes(int? value) {
    if (value == null) return '—';
    const g = 1024 * 1024 * 1024;
    if (value >= 1024 * g) {
      return '${(value / (1024 * g)).toStringAsFixed(1)}T';
    }
    if (value >= g) return '${(value / g).toStringAsFixed(1)}G';
    if (value >= 1024 * 1024) return '${(value / (1024 * 1024)).round()}M';
    return '$value';
  }

  ServerHealthStatus get _status {
    final total = totalBytes, used = usedBytes;
    if (total == null || total <= 0 || used == null) {
      return ServerHealthStatus.unknown;
    }
    final ratio = used / total;
    if (ratio >= 0.9) return ServerHealthStatus.critical;
    if (ratio >= 0.8) return ServerHealthStatus.warning;
    return ServerHealthStatus.normal;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status;
    final color = _statusColor(context, status);
    final total = totalBytes, used = usedBytes;
    final double? ratio = total != null && total > 0 && used != null
        ? used / total
        : null;
    final mountText = mount;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Flexible(
                child: Text(
                  name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              UtenFieldHintIcon(
                info: mountText == null ? hint : '$hint\n\n挂载位置：$mountText',
                dense: true,
              ),
              const Spacer(),
              Text(
                '剩余 ${_plainBytes(freeBytes)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          ClipRRect(
            borderRadius: BorderRadius.circular(UtenRadius.xs),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              color: color,
              backgroundColor: theme.colorScheme.onSurface.withValues(
                alpha: 0.08,
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            ratio == null
                ? '已用 ${_plainBytes(usedBytes)} / 共 ${_plainBytes(totalBytes)}'
                : '已用 ${_plainBytes(usedBytes)} / 共 ${_plainBytes(totalBytes)}'
                      '（已用 ${(ratio * 100).toStringAsFixed(0)}%）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (rows.isNotEmpty) ...[
            const Divider(height: UtenSpacing.s20),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _categoryDisplayName(row),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    Text(
                      _plainBytes(row.logicalBytes),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

String _categoryDisplayName(ServerStorageCategory row) => switch (row.kind) {
  'RELEASES' => '已安装的程序版本',
  'RELEASE_STAGING' => '更新下载暂存',
  'PREACTIVATION_BACKUPS' => '升级前数据库备份',
  'PAIRED_BACKUPS' => '配套备份（数据库＋附件）',
  'DATABASE' => '数据库',
  'UPLOADS' => '上传的附件',
  'LEGACY_UPLOADS' => '旧版上传的附件',
  'LOGS' => '运行日志',
  'CACHE' => '运行缓存',
  _ => row.displayLabel,
};

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
      type: _serverStatusBadgeType(status),
    );
  }
}

IconData _statusIcon(ServerHealthStatus status) => switch (status) {
  ServerHealthStatus.normal => Icons.check_circle_outline_rounded,
  ServerHealthStatus.warning => Icons.warning_amber_rounded,
  ServerHealthStatus.critical => Icons.error_outline_rounded,
  ServerHealthStatus.unknown => Icons.help_outline_rounded,
};

/// 健康状态 → 徽章类型（徽章与表格状态列整格底色同源）。
UtenStatusBadgeType _serverStatusBadgeType(ServerHealthStatus status) =>
    switch (status) {
      ServerHealthStatus.normal => UtenStatusBadgeType.success,
      ServerHealthStatus.warning => UtenStatusBadgeType.warning,
      ServerHealthStatus.critical => UtenStatusBadgeType.danger,
      ServerHealthStatus.unknown => UtenStatusBadgeType.neutral,
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

// AdminAiUsagePage - AI 用量看板(ADR-164; 页面文档 docs/03-页面/AI服务设置页.md)
//
// 超级管理员看全站 AI 消耗: 今日 token/调用/活跃人数/停用人数(预算进度双通道)、
// 窗口趋势(时/日/月/年)、人员用量表(排序/筛选/分页), 行点击进人员详情,
// 行尾可设按人限额与停用。
//
// 安全:
//   * 路由 /admin/* 要求 authorization:manage; 服务端 Controller 另校验 superAdmin;
//     页内再叠 _settingsOwner 同款门禁(会话/快照/服务器/权限任一变化即失效)。
//   * 读端点不写数据; 限额编辑走独立面板(保存要求再认证)。
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_animated_number.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_snapshot_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/ai_usage_dashboard_models.dart';
import '../repositories/ai_usage_dashboard_repository.dart';
import '../widgets/ai_usage_limit_editor.dart';
import '../widgets/ai_usage_trend_card.dart';

Object? _usageOwner(WidgetRef ref, {bool watch = false}) {
  final scope = watch
      ? ref.watch(authenticatedScopeProvider)
      : ref.read(authenticatedScopeProvider);
  final session = watch
      ? ref.watch(sessionProvider)
      : ref.read(sessionProvider);
  final snapshot = confirmedSessionSnapshot(
    watch
        ? ref.watch(sessionSnapshotProvider)
        : ref.read(sessionSnapshotProvider),
  );
  final server = watch
      ? ref.watch(apiBaseUrlProvider)
      : ref.read(apiBaseUrlProvider);
  final permissions = watch
      ? ref.watch(currentPermissionsProvider)
      : ref.read(currentPermissionsProvider);
  if (scope == null ||
      scope.actorId != null ||
      scope.readOnly ||
      snapshot == null ||
      session.user?.id != scope.userId ||
      session.user?.superAdmin != true ||
      !permissions.contains(Perm.authorizationManage)) {
    return null;
  }
  return (scope, snapshot.generation, server);
}

class AdminAiUsagePage extends ConsumerWidget {
  const AdminAiUsagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = _usageOwner(ref, watch: true);
    if (owner == null) {
      final l10n = AppLocalizations.of(context);
      return Scaffold(
        appBar: UtenAppBar(
          title: l10n.aiUsageTitle,
          leading: const UtenBackButton(),
        ),
        body: UtenEmpty.error(
          key: const ValueKey('ai-usage-error'),
          message: l10n.aiSettingsNoAccess,
        ),
      );
    }
    return _AdminAiUsageSession(key: ValueKey(owner));
  }
}

class _AdminAiUsageSession extends ConsumerStatefulWidget {
  const _AdminAiUsageSession({super.key});

  @override
  ConsumerState<_AdminAiUsageSession> createState() => _AdminAiUsagePageState();
}

class _AdminAiUsagePageState extends ConsumerState<_AdminAiUsageSession> {
  late final Object? _owner;
  bool get _current => mounted && _owner != null && _owner == _usageOwner(ref);

  static const _pageSize = 20;

  AiUsageWindow _window = AiUsageWindow.day;
  AiUsageDashboard? _data;
  bool _loading = false;
  String? _error;
  bool _noAccess = false;
  int _loadSeq = 0;

  // 人员表的客户端查询态(数据 ≤500 全量拉取, 就地筛选/排序/分页)。
  String? _statusFilter;
  String? _sortColumn;
  bool _sortAscending = false;
  int _page = 0;

  AiUsageDashboardRepository get _repository =>
      ref.read(aiUsageDashboardRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _owner = _usageOwner(ref);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool quiet = false}) async {
    if (!_current) return;
    final seq = ++_loadSeq;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await _repository.dashboard(_window);
      if (!_current || seq != _loadSeq) return;
      setState(() {
        _data = data;
        _loading = false;
        _error = null;
        _noAccess = false;
        _page = _page.clamp(0, _totalPages(data) - 1);
      });
    } on ApiException catch (error) {
      if (!_current || seq != _loadSeq) return;
      _onLoadFailed(
        error.message,
        noAccess:
            error.httpStatus == 401 ||
            error.httpStatus == 403 ||
            error.code == 'FORBIDDEN',
      );
    } catch (_) {
      if (!mounted || !_current || seq != _loadSeq) return;
      _onLoadFailed(AppLocalizations.of(context).aiUsageLoadFailed);
    }
  }

  void _onLoadFailed(String message, {bool noAccess = false}) {
    if (_data != null) {
      // 已有数据时刷新失败: 保留旧数据, 只提示。
      setState(() => _loading = false);
      context.appError(message);
      return;
    }
    setState(() {
      _loading = false;
      _error = message;
      _noAccess = noAccess;
    });
  }

  Future<void> _refresh() async {
    if (_loading) return;
    await _load(quiet: _data != null);
  }

  void _onWindowChanged(AiUsageWindow window) {
    if (window == _window) return;
    setState(() {
      _window = window;
      _statusFilter = null;
      _sortColumn = null;
      _page = 0;
    });
    _load();
  }

  Future<void> _editLimits(AiUsagePerson person) async {
    final saved = await showAiUsageLimitEditor(
      context,
      target: AiUsageLimitTarget.fromPerson(person),
    );
    if (!mounted) return;
    // 保存与否都静默刷新: 取消也可能只是看过后关掉, 数据仍可能被别处改过。
    if (saved) {
      await _load(quiet: true);
    }
  }

  // ---- 人员表的就地查询 ----

  static int _totalPages(AiUsageDashboard data) =>
      math.max(1, (data.people.length + _pageSize - 1) ~/ _pageSize);

  static String _statusKey(AiUsagePerson person) => person.disabled
      ? 'disabled'
      : person.overLimit
      ? 'over'
      : 'normal';

  static String _statusLabel(AppLocalizations l10n, AiUsagePerson person) =>
      switch (_statusKey(person)) {
        'disabled' => l10n.aiUsageStatusDisabled,
        'over' => l10n.aiUsageStatusOverLimit,
        _ => l10n.aiUsageStatusNormal,
      };

  static UtenStatusBadgeType _statusBadgeType(AiUsagePerson person) =>
      switch (_statusKey(person)) {
        'disabled' => UtenStatusBadgeType.danger,
        'over' => UtenStatusBadgeType.warning,
        _ => UtenStatusBadgeType.neutral,
      };

  List<AiUsagePerson> get _visiblePeople {
    var rows = _data?.people ?? const <AiUsagePerson>[];
    final filter = _statusFilter;
    if (filter != null) {
      rows = rows.where((row) => _statusKey(row) == filter).toList();
    }
    final column = _sortColumn;
    if (column != null) {
      int valueOf(AiUsagePerson row) =>
          column == 'today' ? row.todayTokens : row.windowTokens;
      final sorted = List.of(rows)
        ..sort(
          (a, b) => _sortAscending
              ? valueOf(a).compareTo(valueOf(b))
              : valueOf(b).compareTo(valueOf(a)),
        );
      rows = sorted;
    }
    return rows;
  }

  List<MasterFacetBucket> get _statusFacets {
    final l10n = AppLocalizations.of(context);
    final counts = <String, int>{};
    for (final person in _data?.people ?? const <AiUsagePerson>[]) {
      final key = _statusKey(person);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final order = ['disabled', 'over', 'normal'];
    return [
      for (final key in order)
        if ((counts[key] ?? 0) > 0)
          MasterFacetBucket(
            value: key,
            count: counts[key]!,
            label: switch (key) {
              'disabled' => l10n.aiUsageStatusDisabled,
              'over' => l10n.aiUsageStatusOverLimit,
              _ => l10n.aiUsageStatusNormal,
            },
          ),
    ];
  }

  String _relativeLastUsed(AppLocalizations l10n, String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final instant = DisplayDateTime.instantOf(iso);
    if (instant == null) return '—';
    final age = clock.now().difference(instant);
    if (age.isNegative || age.inMinutes < 1) {
      return l10n.aiUsageLastUsedJustNow;
    }
    if (age.inMinutes < 60) {
      return l10n.aiUsageLastUsedMinutesAgo(age.inMinutes);
    }
    if (age.inHours < 24) return l10n.aiUsageLastUsedHoursAgo(age.inHours);
    if (age.inDays <= 30) return l10n.aiUsageLastUsedDaysAgo(age.inDays);
    return DisplayDateTime.beijing(iso, fallback: '—');
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final data = _data;
    final Widget body;
    if (_loading && data == null) {
      body = const _LoadingSkeleton();
    } else if (_error != null && data == null) {
      body = UtenEmpty.error(
        key: const ValueKey('ai-usage-error'),
        message: _noAccess ? l10n.aiSettingsNoAccess : _error!,
        actionLabel: _noAccess ? null : l10n.aiSettingsRetry,
        onAction: _noAccess ? null : _load,
      );
    } else {
      body = RefreshIndicator(onRefresh: _refresh, child: _content(l10n, data));
    }
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.aiUsageTitle,
        leading: const UtenBackButton(),
        actions: [
          IconButton(
            key: const ValueKey('ai-usage-refresh'),
            tooltip: l10n.aiSettingsRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: UtenContentContainer(child: body),
    );
  }

  Widget _content(AppLocalizations l10n, AiUsageDashboard? data) {
    return ListView(
      key: const ValueKey('ai-usage-list'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      children: [
        _KpiRow(data: data),
        const SizedBox(height: UtenSpacing.s16),
        UtenSegmentedFilter<AiUsageWindow>(
          key: const ValueKey('ai-usage-window-filter'),
          segments: [
            for (final window in AiUsageWindow.values)
              UtenSegment(
                value: window,
                label: aiUsageWindowLabel(l10n, window),
              ),
          ],
          selected: _window,
          onChanged: _loading ? (value) {} : _onWindowChanged,
        ),
        const SizedBox(height: UtenSpacing.s12),
        AiUsageTrendCard(
          points: data?.series ?? const <AiUsageSeriesPoint>[],
          title: '${aiUsageWindowLabel(l10n, _window)} · ${l10n.aiUsageTrend}',
        ),
        const SizedBox(height: UtenSpacing.s16),
        _peopleCard(l10n, data),
        const SizedBox(height: UtenSpacing.s24),
      ],
    );
  }

  Widget _peopleCard(AppLocalizations l10n, AiUsageDashboard? data) {
    final theme = Theme.of(context);
    final people = _visiblePeople;
    final totalPages = math.max(
      1,
      (people.length + _pageSize - 1) ~/ _pageSize,
    );
    final page = _page.clamp(0, totalPages - 1);
    final pageRows = people.skip(page * _pageSize).take(_pageSize).toList();
    return UtenCard(
      key: const ValueKey('ai-usage-people-card'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.group_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  l10n.aiUsagePeople,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (data != null)
                Text(
                  '${people.length}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            aiUsageWindowLabel(l10n, _window),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          MasterDataTableView<AiUsagePerson>(
            tableKey:
                'features.admin.pages.admin_ai_usage_page.PeopleTable.build.1',
            key: const Key('ai-usage-people-table'),
            embedded: true,
            isLoading: _loading && data == null,
            items: pageRows,
            columns: _columns(l10n),
            facets: {'status': _statusFacets},
            nullCounts: const {},
            filters: {if (_statusFilter != null) 'status': _statusFilter},
            onFilterChanged: (key, value) => setState(() {
              if (key == 'status') _statusFilter = value;
              _page = 0;
            }),
            onRowTap: (person) {
              // 已删除员工: 统计行保留但不可再进详情/改限额(users 行已不存在)。
              if (person.deleted) return;
              context.push(RouteName.adminAiUsagePerson(person.userId));
            },
            rowKeyOf: (person) => person.userId,
            sortColumn: _sortColumn,
            sortAscending: _sortAscending,
            onSortChange: (column, ascending) => setState(() {
              _sortColumn = column;
              _sortAscending = ascending;
              _page = 0;
            }),
            currentPage: page + 1,
            totalPages: totalPages,
            onPageChange: (target) => setState(() => _page = target - 1),
            paginationScope: (_window, _statusFilter, _sortColumn),
            paginationRevision: data,
            emptyMessage: l10n.aiUsageEmpty,
          ),
        ],
      ),
    );
  }

  List<MasterColumnDef<AiUsagePerson>> _columns(AppLocalizations l10n) {
    return [
      MasterColumnDef(
        key: 'person',
        label: l10n.aiUsageColPerson,
        width: 220,
        value: (row) => row.name,
        cellBuilder: (context, row) {
          final theme = Theme.of(context);
          final subtitle = [
            for (final part in [row.code, row.department])
              if (part.isNotEmpty) part,
          ].join(' · ');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                row.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // 已删除员工灰态(名字是服务端回退名「已删除员工」)。
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: row.deleted
                      ? theme.colorScheme.onSurfaceVariant
                      : null,
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          );
        },
      ),
      MasterColumnDef(
        key: 'window',
        label: l10n.aiUsageColWindow,
        width: 150,
        type: 'number',
        sortable: true,
        value: (row) => formatAiUsageNumber(row.windowTokens),
        cellBuilder: (context, row) {
          final theme = Theme.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatAiUsageNumber(row.windowTokens),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                l10n.aiUsageColCalls(row.windowCalls),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          );
        },
      ),
      MasterColumnDef(
        key: 'today',
        label: l10n.aiUsageColToday,
        width: 130,
        type: 'number',
        sortable: true,
        value: (row) => formatAiUsageNumber(row.todayTokens),
      ),
      MasterColumnDef(
        key: 'limit',
        label: l10n.aiUsageColLimit,
        width: 140,
        value: (row) => row.dailyTokenLimit == null
            ? l10n.aiUsageLimitFollowGlobal
            : formatAiUsageNumber(row.dailyTokenLimit!),
      ),
      MasterColumnDef(
        key: 'status',
        label: l10n.aiUsageColStatus,
        width: 110,
        value: (row) => _statusLabel(l10n, row),
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, row) => Semantics(
          excludeSemantics: true,
          label: '${l10n.aiUsageColStatus} ${_statusLabel(l10n, row)}',
          child: Align(
            alignment: Alignment.centerLeft,
            child: UtenStatusBadge(
              key: ValueKey('ai-usage-status-${row.userId}'),
              label: _statusLabel(l10n, row),
              type: _statusBadgeType(row),
              size: UtenStatusBadgeSize.small,
            ),
          ),
        ),
      ),
      MasterColumnDef(
        key: 'lastUsed',
        label: l10n.aiUsageColLastUsed,
        width: 140,
        value: (row) => _relativeLastUsed(l10n, row.lastUsedAt),
      ),
      MasterColumnDef(
        key: 'actions',
        label: l10n.aiUsageSetLimits,
        width: 96,
        value: (row) => l10n.aiUsageSetLimits,
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, row) => Semantics(
          button: true,
          excludeSemantics: true,
          label: '${l10n.aiUsageSetLimits} ${row.name}',
          child: Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: ValueKey('ai-usage-limit-${row.userId}'),
              tooltip: l10n.aiUsageSetLimits,
              icon: const Icon(Icons.tune_rounded, size: 20),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              // 已删除员工没有 users 行, 不能再设限额。
              onPressed: row.deleted ? null : () => _editLimits(row),
            ),
          ),
        ),
      ),
    ];
  }
}

/// KPI 四卡: 今日消耗(预算进度双通道)/今日调用/今日活跃人数/已停用人数。
class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.data});

  final AiUsageDashboard? data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? 4 : 2;
        const gap = UtenSpacing.s8;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            SizedBox(
              width: width,
              child: _TodayTokensCard(data: data, compact: columns == 2),
            ),
            SizedBox(
              width: width,
              child: _MetricCard(
                key: const ValueKey('ai-usage-kpi-today-calls'),
                label: l10n.aiUsageTodayCalls,
                value: data?.todayCalls,
                icon: Icons.call_made_rounded,
              ),
            ),
            SizedBox(
              width: width,
              child: _MetricCard(
                key: const ValueKey('ai-usage-kpi-active-users'),
                label: l10n.aiUsageActiveUsers,
                value: data?.activeUsersToday,
                icon: Icons.person_outline_rounded,
              ),
            ),
            SizedBox(
              width: width,
              child: _MetricCard(
                key: const ValueKey('ai-usage-kpi-disabled'),
                label: l10n.aiUsageDisabledCount,
                value: data?.disabledCount,
                icon: Icons.block_rounded,
                danger: true,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 预算进度色: ≥100% danger、≥80% warning、其余 primary(与环形表同阈值)。
Color _budgetColor(BuildContext context, double ratio) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  if (ratio >= 1) {
    return dark ? UtenColors.errorOnDark : UtenColors.errorText;
  }
  if (ratio >= 0.8) {
    return dark ? UtenColors.warningOnDark : UtenColors.warningText;
  }
  return theme.colorScheme.primary;
}

class _TodayTokensCard extends StatelessWidget {
  const _TodayTokensCard({required this.data, required this.compact});

  final AiUsageDashboard? data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final budget = data?.dailyTokenBudget ?? 0;
    final today = data?.todayTokens;
    final ratio = budget > 0 && today != null ? today / budget : null;
    final color = ratio == null
        ? theme.colorScheme.primary
        : _budgetColor(context, ratio.clamp(0.0, double.infinity));
    return UtenCard(
      key: const ValueKey('ai-usage-kpi-today-tokens'),
      padding: EdgeInsets.all(compact ? UtenSpacing.s12 : UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Icon(Icons.bolt_rounded, size: 21, color: color),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.aiUsageTodayTokens,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    UtenAnimatedNumber(
                      value: today?.toDouble(),
                      format: (value) => formatAiUsageNumber(value.toInt()),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: ratio?.clamp(0.0, 1.0),
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          // 数值常显 + 进度条双通道: 颜色只强调, 文字始终给全值。
          Text(
            l10n.aiUsageBudgetOf(
              formatAiUsageNumber(today ?? 0),
              formatAiUsageNumber(budget),
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: ratio != null && ratio >= 0.8
                  ? color
                  : theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 简单计数卡(今日调用/活跃人数/已停用人数; 停用人数数字用 danger 色)。
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.danger = false,
  });

  final String label;
  final int? value;
  final IconData icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = danger ? theme.colorScheme.error : theme.colorScheme.primary;
    return UtenCard(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Icon(icon, size: 21, color: color),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                UtenAnimatedNumber(
                  value: value?.toDouble(),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: danger ? color : null,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 首次加载的骨架: KPI 行 + 趋势卡 + 人员表的轮廓。
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('ai-usage-skeleton'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        Row(
          children: [
            Expanded(child: UtenSkeleton(height: 112, borderRadius: 14)),
            SizedBox(width: UtenSpacing.s8),
            Expanded(child: UtenSkeleton(height: 112, borderRadius: 14)),
            SizedBox(width: UtenSpacing.s8),
            Expanded(child: UtenSkeleton(height: 112, borderRadius: 14)),
            SizedBox(width: UtenSpacing.s8),
            Expanded(child: UtenSkeleton(height: 112, borderRadius: 14)),
          ],
        ),
        SizedBox(height: UtenSpacing.s16),
        UtenSkeleton(height: 44, borderRadius: 999),
        SizedBox(height: UtenSpacing.s12),
        UtenSkeleton(height: 200, borderRadius: 14),
        SizedBox(height: UtenSpacing.s16),
        UtenSkeleton(height: 280, borderRadius: 14),
      ],
    );
  }
}

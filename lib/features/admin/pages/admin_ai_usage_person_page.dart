// AdminAiUsagePersonPage - 单个人员的 AI 用量详情(ADR-164)。
//
// 从看板人员表行点进(或深链 /admin/ai-usage/:userId): 今日消耗 vs 限额环形表、
// 窗口趋势、按用途/按服务商分布、最近使用列表; 停用账号顶部横幅提示,
// 「设置限额」打开按人限额编辑面板。
//
// 安全: 与看板页同门禁(/admin/* 守卫 + 页内超管校验); 限额编辑走独立面板。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_gauge_ring.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_snapshot_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/ai_usage_dashboard_models.dart';
import '../repositories/ai_usage_dashboard_repository.dart';
import '../widgets/ai_usage_limit_editor.dart';
import '../widgets/ai_usage_trend_card.dart';

Object? _personOwner(WidgetRef ref, {bool watch = false}) {
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

class AdminAiUsagePersonPage extends ConsumerWidget {
  const AdminAiUsagePersonPage({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = _personOwner(ref, watch: true);
    final l10n = AppLocalizations.of(context);
    if (owner == null) {
      return Scaffold(
        appBar: UtenAppBar(
          title: l10n.aiUsageTitle,
          leading: const UtenBackButton(),
        ),
        body: UtenEmpty.error(
          key: const ValueKey('ai-usage-person-error'),
          message: l10n.aiSettingsNoAccess,
        ),
      );
    }
    return _AdminAiUsagePersonSession(
      key: ValueKey((owner, userId)),
      userId: userId,
    );
  }
}

class _AdminAiUsagePersonSession extends ConsumerStatefulWidget {
  const _AdminAiUsagePersonSession({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<_AdminAiUsagePersonSession> createState() =>
      _AdminAiUsagePersonPageState();
}

class _AdminAiUsagePersonPageState
    extends ConsumerState<_AdminAiUsagePersonSession> {
  late final Object? _owner;
  bool get _current => mounted && _owner != null && _owner == _personOwner(ref);

  AiUsageWindow _window = AiUsageWindow.day;
  AiUsagePersonDetail? _detail;
  bool _loading = false;
  String? _error;
  bool _noAccess = false;
  int _loadSeq = 0;

  AiUsageDashboardRepository get _repository =>
      ref.read(aiUsageDashboardRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _owner = _personOwner(ref);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant _AdminAiUsagePersonSession oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _detail = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
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
      final detail = await _repository.person(widget.userId, _window);
      if (!_current || seq != _loadSeq) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _error = null;
        _noAccess = false;
      });
    } on ApiException catch (error) {
      if (!_current || seq != _loadSeq) return;
      final noAccess =
          error.httpStatus == 401 ||
          error.httpStatus == 403 ||
          error.code == 'FORBIDDEN';
      if (_detail != null) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _loading = false;
        _error = noAccess
            ? AppLocalizations.of(context).aiSettingsNoAccess
            : error.message;
        _noAccess = noAccess;
      });
    } catch (_) {
      if (!mounted || !_current || seq != _loadSeq) return;
      if (_detail != null) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _loading = false;
        _error = AppLocalizations.of(context).aiUsageLoadFailed;
      });
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    await _load(quiet: _detail != null);
  }

  void _onWindowChanged(AiUsageWindow window) {
    if (window == _window) return;
    setState(() => _window = window);
    _load();
  }

  Future<void> _editLimits() async {
    final detail = _detail;
    if (detail == null) return;
    final saved = await showAiUsageLimitEditor(
      context,
      target: AiUsageLimitTarget.fromDetail(detail),
    );
    if (!mounted) return;
    if (saved) {
      await _load(quiet: true);
    }
  }

  // ---- 界面 ----

  String get _title {
    final detail = _detail;
    if (detail == null) return '';
    return detail.code.isEmpty
        ? detail.name
        : '${detail.name} · ${detail.code}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final detail = _detail;
    final Widget body;
    if (_loading && detail == null) {
      body = const _LoadingSkeleton();
    } else if (_error != null && detail == null) {
      body = UtenEmpty.error(
        key: const ValueKey('ai-usage-person-error'),
        message: _noAccess || _error!.isEmpty
            ? l10n.aiUsagePersonMissing
            : _error!,
        actionLabel: l10n.aiSettingsRetry,
        onAction: _load,
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: _content(l10n, detail),
      );
    }
    return Scaffold(
      appBar: UtenAppBar(
        title: _title.isEmpty ? l10n.aiUsageTitle : _title,
        subtitle: detail == null ? null : aiUsageWindowLabel(l10n, _window),
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.adminAiUsage),
        ),
        actions: [
          IconButton(
            key: const ValueKey('ai-usage-person-set-limits'),
            tooltip: l10n.aiUsageSetLimits,
            icon: const Icon(Icons.tune_rounded),
            onPressed: detail == null ? null : _editLimits,
          ),
          IconButton(
            key: const ValueKey('ai-usage-person-refresh'),
            tooltip: l10n.aiSettingsRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: UtenContentContainer(child: body),
    );
  }

  Widget _content(AppLocalizations l10n, AiUsagePersonDetail? detail) {
    return ListView(
      key: const ValueKey('ai-usage-person-list'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      children: [
        if (detail?.limits.disabled == true) ...[
          UtenInlineNotice(
            key: const ValueKey('ai-usage-person-disabled-banner'),
            level: UtenInlineNoticeLevel.error,
            message: l10n.aiUsageDisabledBanner,
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        _gaugeCard(l10n, detail),
        const SizedBox(height: UtenSpacing.s16),
        UtenSegmentedFilter<AiUsageWindow>(
          key: const ValueKey('ai-usage-person-window-filter'),
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
          points: detail?.series ?? const <AiUsageSeriesPoint>[],
          title: '${aiUsageWindowLabel(l10n, _window)} · ${l10n.aiUsageTrend}',
        ),
        const SizedBox(height: UtenSpacing.s16),
        UtenResponsiveGrid(
          itemCount: 2,
          spacing: UtenSpacing.s12,
          columns: const UtenResponsiveColumns(medium: 1, expanded: 2),
          itemBuilder: (context, index, _) => index == 0
              ? _DistributionCard(
                  key: const ValueKey('ai-usage-person-by-purpose'),
                  title: l10n.aiUsageByPurpose,
                  icon: Icons.category_outlined,
                  rows: detail?.byPurpose ?? const <AiUsageDistribution>[],
                  emptyText: l10n.aiUsageEmpty,
                )
              : _DistributionCard(
                  key: const ValueKey('ai-usage-person-by-provider'),
                  title: l10n.aiUsageByProvider,
                  icon: Icons.dns_outlined,
                  rows: detail?.byProvider ?? const <AiUsageDistribution>[],
                  emptyText: l10n.aiUsageEmpty,
                ),
        ),
        const SizedBox(height: UtenSpacing.s16),
        _RecentUsesCard(detail: detail),
        const SizedBox(height: UtenSpacing.s24),
      ],
    );
  }

  /// 顶部环形卡: 今日消耗 vs 限额(无限额按全站预算), 右侧给状态与限额明细。
  Widget _gaugeCard(AppLocalizations l10n, AiUsagePersonDetail? detail) {
    final gaugeMax = detail?.gaugeMax;
    final today = detail?.todayTokens ?? 0;
    final limit = detail?.limits.dailyTokenLimit;
    final ratio = gaugeMax == null || gaugeMax <= 0 ? null : today / gaugeMax;
    final status = ratio == null
        ? UtenGaugeStatus.unknown
        : ratio >= 1
        ? UtenGaugeStatus.critical
        : ratio >= 0.8
        ? UtenGaugeStatus.warning
        : UtenGaugeStatus.normal;
    final gauge = UtenGaugeRing(
      value: ratio == null ? null : today.toDouble(),
      max: (gaugeMax ?? 100).toDouble(),
      status: status,
      label: l10n.aiUsageTodayTokens,
      unit: '',
      warning: gaugeMax == null ? null : gaugeMax * 0.8,
      critical: gaugeMax?.toDouble(),
      statusText: l10n.aiUsageTodayLabel,
      valueText: gaugeMax == null
          ? formatAiUsageNumber(today)
          : '${formatAiUsageNumber(today)} / ${formatAiUsageNumber(gaugeMax)}',
      caption: limit == null ? l10n.aiUsageNoPersonalLimit : null,
    );
    final badgeType = detail == null
        ? UtenStatusBadgeType.neutral
        : detail.limits.disabled
        ? UtenStatusBadgeType.danger
        : (limit != null && limit > 0 && today >= limit)
        ? UtenStatusBadgeType.warning
        : UtenStatusBadgeType.neutral;
    final badgeLabel = detail == null
        ? l10n.aiUsageStatusNormal
        : detail.limits.disabled
        ? l10n.aiUsageStatusDisabled
        : (limit != null && limit > 0 && today >= limit)
        ? l10n.aiUsageStatusOverLimit
        : l10n.aiUsageStatusNormal;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenStatusBadge(label: badgeLabel, type: badgeType),
        const SizedBox(height: UtenSpacing.s12),
        _InfoLine(
          label: l10n.aiUsageTodayCalls,
          value: formatAiUsageNumber(detail?.todayCalls ?? 0),
        ),
        _InfoLine(
          label: l10n.aiUsageLimitTokensLabel,
          value: limit == null
              ? l10n.aiUsageLimitFollowGlobal
              : formatAiUsageNumber(limit),
        ),
        _InfoLine(
          label: l10n.aiUsageLimitJobsLabel,
          value: detail?.limits.dailyJobLimit == null
              ? l10n.aiUsageLimitFollowGlobal
              : formatAiUsageNumber(detail!.limits.dailyJobLimit!),
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenButton(
          key: const ValueKey('ai-usage-person-set-limits-button'),
          type: UtenButtonType.secondary,
          height: 44,
          icon: Icons.tune_rounded,
          onPressed: detail == null ? null : _editLimits,
          child: Text(l10n.aiUsageSetLimits),
        ),
      ],
    );
    return UtenCard(
      key: const ValueKey('ai-usage-person-gauge-card'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              children: [
                Center(child: gauge),
                const SizedBox(height: UtenSpacing.s16),
                info,
              ],
            );
          }
          return Row(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Center(child: gauge),
              ),
              const SizedBox(width: UtenSpacing.s24),
              Expanded(child: info),
            ],
          );
        },
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 按用途/按服务商分布卡: 每行 label + 数值常显(calls/tokens) + 横向比例条。
class _DistributionCard extends StatelessWidget {
  const _DistributionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.rows,
    required this.emptyText,
  });

  final String title;
  final IconData icon;
  final List<AiUsageDistribution> rows;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final peak = rows.fold<int>(
      0,
      (value, row) => value > row.tokens ? value : row.tokens,
    );
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (rows.isEmpty)
            Text(
              emptyText,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final row in rows) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    l10n.aiUsageColCalls(row.calls),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Text(
                    l10n.aiUsageTokensUnit(formatAiUsageNumber(row.tokens)),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s4),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: peak > 0 ? (row.tokens / peak).clamp(0.0, 1.0) : 0,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
            ],
        ],
      ),
    );
  }
}

/// 最近使用列表(近 20 条, 照审计面板 _ActivityTile 的精简版)。
class _RecentUsesCard extends StatelessWidget {
  const _RecentUsesCard({required this.detail});

  final AiUsagePersonDetail? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final uses = detail?.recentUses ?? const <AiUsageRecentUse>[];
    return UtenCard(
      key: const ValueKey('ai-usage-person-recent'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.history_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  l10n.aiUsageRecentUses,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          if (uses.isEmpty)
            Text(
              l10n.aiUsageEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final use in uses)
              ExpansionTile(
                key: ValueKey('ai-usage-recent-${use.jobId}'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                title: Text(
                  use.question.isEmpty
                      ? _kindLabel(l10n, use.kind)
                      : use.question,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_kindLabel(l10n, use.kind)} · ${_statusLabel(l10n, use.status)} · '
                  '${DisplayDateTime.beijing(use.createdAt, fallback: '—')}',
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (use.question.isNotEmpty)
                          SelectableText(use.question),
                        Text(
                          l10n.aiUsageTokensUnit(
                            formatAiUsageNumber(use.tokens),
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        ],
      ),
    );
  }

  static String _kindLabel(AppLocalizations l10n, String kind) =>
      switch (kind) {
        'ERP_CHAT' => l10n.aiAuditKindChat,
        'ERP_DOCUMENT_ROUTE' => l10n.aiAuditKindDocument,
        'SALES_DOCUMENT_INTAKE' => l10n.aiAuditKindSales,
        _ => l10n.aiAuditKindOther,
      };

  static String _statusLabel(AppLocalizations l10n, String status) =>
      switch (status) {
        'SUCCEEDED' => l10n.aiAuditSucceeded,
        'FAILED' => l10n.aiAuditFailed,
        'CANCELLED' => l10n.aiAuditCancelled,
        'QUEUED' || 'PENDING' => l10n.aiAuditQueued,
        'RUNNING' => l10n.aiAuditRunning,
        _ => status,
      };
}

/// 首次加载的骨架: 环形卡 + 趋势卡 + 两张分布卡的轮廓。
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('ai-usage-person-skeleton'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UtenSkeleton(height: 220, borderRadius: 14),
        SizedBox(height: UtenSpacing.s16),
        UtenSkeleton(height: 44, borderRadius: 999),
        SizedBox(height: UtenSpacing.s12),
        UtenSkeleton(height: 200, borderRadius: 14),
        SizedBox(height: UtenSpacing.s16),
        Row(
          children: [
            Expanded(child: UtenSkeleton(height: 180, borderRadius: 14)),
            SizedBox(width: UtenSpacing.s12),
            Expanded(child: UtenSkeleton(height: 180, borderRadius: 14)),
          ],
        ),
      ],
    );
  }
}

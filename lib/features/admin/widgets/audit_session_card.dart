import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../models/audit_event_presentation.dart';
import '../models/audit_log_entry.dart';
import '../models/audit_session.dart';

typedef AuditSessionEventLoader =
    Future<AuditSessionEventPage> Function({
      String? cursorAt,
      int? cursorId,
      int? snapshotAuditId,
    });

/// 审计中心只展示会话摘要；点击后进入独立路由查看时间线。
class AuditSessionCard extends StatelessWidget {
  const AuditSessionCard({
    required this.session,
    required this.onOpen,
    super.key,
  });

  final AuditSessionSummary session;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final actor = auditSessionActor(session);
    final status = auditSessionStatusLabel(session);
    final loginAt = auditBeijingTime(session.loginAt, fallback: '开始时间未知');
    final lastAt = auditBeijingTime(
      session.lastActivityAt ?? session.firstActivityAt,
      fallback: '暂无活动时间',
    );
    final logoutAt = session.logoutAt == null
        ? null
        : auditBeijingTime(session.logoutAt, fallback: '退出时间未知');
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: [
        '登录会话',
        '操作人 $actor',
        '状态 $status',
        '开始时间 $loginAt',
        if (logoutAt != null) '退出时间 $logoutAt' else '最后活动 $lastAt',
        '人工操作 ${session.operationCount} 项',
        if (session.failureCount > 0) '失败 ${session.failureCount} 项',
        if (session.postLogoutCount > 0) '退出后操作 ${session.postLogoutCount} 项',
        '点击进入会话时间线',
      ].join('，'),
      child: UtenCard(
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          borderRadius: UtenRadius.lgAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('audit-session-${session.sessionId}'),
            onTap: onOpen,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 112),
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 620;
                    final content = AuditSessionSummaryContent(
                      session: session,
                      compact: compact,
                    );
                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          content,
                          const SizedBox(height: UtenSpacing.s12),
                          const _OpenTimelineHint(compact: true),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: content),
                        const SizedBox(width: UtenSpacing.s16),
                        const _OpenTimelineHint(compact: false),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuditSessionSummaryPanel extends StatelessWidget {
  const AuditSessionSummaryPanel({required this.session, super.key});

  final AuditSessionSummary session;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: LayoutBuilder(
        builder: (context, constraints) => AuditSessionSummaryContent(
          session: session,
          compact: constraints.maxWidth < 620,
          detailed: true,
        ),
      ),
    );
  }
}

class AuditSessionSummaryContent extends StatelessWidget {
  const AuditSessionSummaryContent({
    required this.session,
    required this.compact,
    this.detailed = false,
    super.key,
  });

  final AuditSessionSummary session;
  final bool compact;
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = auditSessionStatusLabel(session);
    final statusColor = auditSessionStatusColor(
      theme.colorScheme,
      session.status,
    );
    final loginAt = auditBeijingTime(session.loginAt, fallback: '开始时间未知');
    final lastAt = auditBeijingTime(
      session.lastActivityAt ?? session.firstActivityAt,
      fallback: '暂无活动时间',
    );
    final logoutAt = session.logoutAt == null
        ? null
        : auditBeijingTime(session.logoutAt, fallback: '退出时间未知');
    final startLabel = session.startLabel?.trim().isNotEmpty == true
        ? session.startLabel!.trim()
        : '建立会话';
    final device = [session.deviceLabel?.trim(), session.devicePlatform?.trim()]
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet()
        .join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: UtenRadius.mdAll,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.person_outline_rounded,
                size: 20,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            Text(
              auditSessionActor(session),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (session.actorDepartment?.trim().isNotEmpty == true)
              Text(
                session.actorDepartment!.trim(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            _StatusBadge(
              label: status,
              status: session.status,
              color: statusColor,
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          logoutAt == null
              ? '$startLabel $loginAt → 最后活动 $lastAt'
              : '$startLabel $loginAt → $logoutAt',
          maxLines: compact && !detailed ? 4 : null,
          overflow: compact && !detailed ? TextOverflow.ellipsis : null,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            height: 1.5,
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            _Metric(label: '人工操作', value: session.operationCount),
            if (session.eventCount != session.operationCount)
              _Metric(label: '时间线事件', value: session.eventCount),
            _Metric(label: '成功', value: session.successCount),
            if (session.failureCount > 0)
              _Metric(label: '失败', value: session.failureCount, emphasis: true),
          ],
        ),
        if (device.isNotEmpty ||
            session.refreshCredentialStatusLabel?.trim().isNotEmpty == true ||
            (detailed && session.lastIp?.trim().isNotEmpty == true)) ...[
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s8,
            children: [
              if (device.isNotEmpty)
                _Evidence(icon: Icons.devices_outlined, text: '设备 $device'),
              if (detailed && session.lastIp?.trim().isNotEmpty == true)
                _Evidence(
                  icon: Icons.lan_outlined,
                  text: '最近网络地址 ${session.lastIp!.trim()}',
                ),
              if (session.refreshCredentialStatusLabel?.trim().isNotEmpty ==
                  true)
                _Evidence(
                  icon: Icons.key_outlined,
                  text: '会话凭证 ${session.refreshCredentialStatusLabel!.trim()}',
                ),
            ],
          ),
        ],
        if (session.postLogoutCount > 0 || session.timelinePartial) ...[
          const SizedBox(height: UtenSpacing.s12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Text(
              session.postLogoutCount > 0
                  ? '退出后仍记录 ${session.postLogoutCount} 项操作，需重点核查。'
                  : '部分旧事件缺少会话标识，当前时间线可能不完整。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                fontWeight: FontWeight.w700,
                height: 1.45,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 会话详情页的可分页时间线。首次显示即加载，不依赖列表卡展开。
///
/// 该组件返回 Sliver，必须直接放在 CustomScrollView.slivers 中；事件按需
/// 构建，连续加载更早记录时不会把全部历史节点一次性重排。
class AuditSessionTimeline extends StatefulWidget {
  const AuditSessionTimeline({
    required this.sessionId,
    required this.loadEvents,
    required this.onOpenEvent,
    this.snapshotAuditId,
    super.key,
  });

  final String sessionId;
  final int? snapshotAuditId;
  final AuditSessionEventLoader loadEvents;
  final ValueChanged<AuditLogEntry> onOpenEvent;

  @override
  State<AuditSessionTimeline> createState() => _AuditSessionTimelineState();
}

class _AuditSessionTimelineState extends State<AuditSessionTimeline> {
  List<AuditLogEntry> _events = const [];
  String? _nextCursorAt;
  int? _nextCursorId;
  int? _eventSnapshotAuditId;
  bool _hasMore = false;
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loading = false;
      _load(reset: true);
    });
  }

  @override
  void didUpdateWidget(covariant AuditSessionTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.snapshotAuditId != widget.snapshotAuditId) {
      _generation++;
      _events = const [];
      _nextCursorAt = null;
      _nextCursorId = null;
      _eventSnapshotAuditId = null;
      _hasMore = false;
      _error = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(reset: true);
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    if (_loading) return;
    final generation = ++_generation;
    final requestedSnapshot = reset
        ? widget.snapshotAuditId
        : _eventSnapshotAuditId ?? widget.snapshotAuditId;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _events = const [];
        _nextCursorAt = null;
        _nextCursorId = null;
        _hasMore = false;
      }
    });
    try {
      final page = await widget.loadEvents(
        cursorAt: reset ? null : _nextCursorAt,
        cursorId: reset ? null : _nextCursorId,
        snapshotAuditId: requestedSnapshot,
      );
      if (!mounted || generation != _generation) return;
      final knownIds = reset
          ? <int>{}
          : _events.map((event) => event.id).toSet();
      final appended = page.items
          .where((event) => knownIds.add(event.id))
          .toList(growable: false);
      setState(() {
        _events = reset ? appended : [..._events, ...appended];
        _nextCursorAt = page.nextCursorAt;
        _nextCursorId = page.nextCursorId;
        _eventSnapshotAuditId = page.snapshotAuditId;
        _hasMore =
            page.hasMore &&
            page.nextCursorAt != null &&
            page.nextCursorId != null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _events.isEmpty ? '会话时间线加载失败' : '更多会话事件加载失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _events.isEmpty) {
      return const SliverToBoxAdapter(child: _TimelineLoading());
    }
    if (_error != null && _events.isEmpty) {
      return SliverToBoxAdapter(
        child: AuditSessionLoadError(
          message: _error!,
          onRetry: () => _load(reset: true),
        ),
      );
    }
    if (!_loading && _events.isEmpty) {
      return const SliverToBoxAdapter(child: _TimelineEmpty());
    }
    return SliverList.builder(
      itemCount: _events.length + 1,
      itemBuilder: (context, index) {
        if (index < _events.length) {
          return AuditSessionTimelineEvent(
            entry: _events[index],
            first: index == 0,
            last: index == _events.length - 1 && !_hasMore,
            onTap: () => widget.onOpenEvent(_events[index]),
          );
        }
        if (_error != null) {
          return AuditSessionLoadError(
            message: _error!,
            onRetry: () => _load(reset: false),
          );
        }
        if (_hasMore) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: Align(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 220, minHeight: 48),
                child: FilledButton.tonalIcon(
                  key: ValueKey('audit-session-load-more-${widget.sessionId}'),
                  onPressed: _loading ? null : () => _load(reset: false),
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.expand_more_rounded),
                  label: Text(_loading ? '正在加载...' : '加载更早的操作'),
                ),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}

class AuditSessionTimelineEvent extends StatelessWidget {
  const AuditSessionTimelineEvent({
    required this.entry,
    required this.first,
    required this.last,
    required this.onTap,
    super.key,
  });

  final AuditLogEntry entry;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = auditBeijingTime(entry.createdAt, fallback: '时间未知');
    final action = entry.actionLabel?.trim().isNotEmpty == true
        ? entry.actionLabel!.trim()
        : '该记录缺少操作名称映射';
    final summary = auditEventNarrative(entry);
    final failed = auditEventFailed(entry);
    final outcome = entry.resultLabel?.trim().isNotEmpty == true
        ? entry.resultLabel!.trim()
        : failed
        ? '失败'
        : '成功';
    final nodeColor = failed
        ? theme.colorScheme.error
        : entry.riskLevel == 'low'
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    final objectEvidence = auditEventObjectEvidence(entry);
    final page = entry.pageLabel?.trim();
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: [
        time,
        '具体操作 $action',
        summary,
        ?objectEvidence,
        '结果 $outcome',
        if (entry.riskLevel != 'low') '风险 ${auditRiskLabel(entry.riskLevel)}',
        '点击查看完整审计详情',
      ].join('，'),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CustomPaint(
              painter: _TimelineRailPainter(
                color: nodeColor,
                centerColor: theme.colorScheme.surface,
                lineColor: theme.colorScheme.outlineVariant,
                first: first,
                last: last,
              ),
              child: const SizedBox(width: 28),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: Material(
                  color: theme.colorScheme.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(
                    borderRadius: UtenRadius.mdAll,
                    side: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('audit-session-event-${entry.id}'),
                    onTap: onTap,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 88),
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: UtenSpacing.s8,
                                    runSpacing: UtenSpacing.s4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        time,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme.colorScheme.primary,
                                              fontWeight: FontWeight.w700,
                                              fontFeatures: const [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                      ),
                                      _TinyLabel(
                                        label: outcome,
                                        color: failed
                                            ? theme.colorScheme.error
                                            : theme.colorScheme.tertiary,
                                      ),
                                      if (entry.riskLevel != 'low')
                                        _TinyLabel(
                                          label: auditRiskLabel(
                                            entry.riskLevel,
                                          ),
                                          color: theme.colorScheme.error,
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: UtenSpacing.s8),
                                  Text(
                                    action,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      height: 1.45,
                                    ),
                                  ),
                                  if (summary != action) ...[
                                    const SizedBox(height: UtenSpacing.s4),
                                    Text(
                                      summary,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(height: 1.45),
                                    ),
                                  ],
                                  if (objectEvidence != null) ...[
                                    const SizedBox(height: UtenSpacing.s4),
                                    Text(
                                      objectEvidence,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                            height: 1.45,
                                          ),
                                    ),
                                  ],
                                  if (page?.isNotEmpty == true) ...[
                                    const SizedBox(height: UtenSpacing.s4),
                                    Text(
                                      '操作页面 $page',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuditSessionLoadError extends StatelessWidget {
  const AuditSessionLoadError({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      label: '$message，可以重新加载',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: UtenRadius.mdAll,
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          children: [
            Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
            OutlinedButton.icon(
              key: const ValueKey('audit-session-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpenTimelineHint extends StatelessWidget {
  const _OpenTimelineHint({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: compact
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        Text(
          '查看会话时间线',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: UtenSpacing.s4),
        Icon(
          Icons.arrow_forward_rounded,
          size: 20,
          color: theme.colorScheme.primary,
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.status,
    required this.color,
  });

  final String label;
  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(auditSessionStatusIcon(status), size: 15, color: color),
          const SizedBox(width: UtenSpacing.s4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  final String label;
  final int value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = emphasis
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: emphasis
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.55)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        '$label $value',
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _Evidence extends StatelessWidget {
  const _Evidence({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: UtenSpacing.s4),
              child: Icon(
                icon,
                size: 17,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextSpan(text: text),
        ],
      ),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _TinyLabel extends StatelessWidget {
  const _TinyLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TimelineLoading extends StatelessWidget {
  const _TimelineLoading();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '正在加载会话时间线',
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s32),
        child: Column(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(height: UtenSpacing.s12),
            Text('正在加载会话时间线...'),
          ],
        ),
      ),
    );
  }
}

class _TimelineEmpty extends StatelessWidget {
  const _TimelineEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '该会话暂无可展示的人工操作',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s24),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            Icon(
              Icons.fact_check_outlined,
              size: 32,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '该会话暂无可展示的人工操作',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '系统自动任务不会混入人员操作时间线。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineRailPainter extends CustomPainter {
  const _TimelineRailPainter({
    required this.color,
    required this.centerColor,
    required this.lineColor,
    required this.first,
    required this.last,
  });

  final Color color;
  final Color centerColor;
  final Color lineColor;
  final bool first;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    const nodeY = 20.0;
    final x = size.width / 2;
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2;
    if (!first) canvas.drawLine(Offset(x, 0), Offset(x, nodeY), linePaint);
    if (!last) {
      canvas.drawLine(Offset(x, nodeY), Offset(x, size.height), linePaint);
    }
    canvas.drawCircle(Offset(x, nodeY), 7, Paint()..color = color);
    canvas.drawCircle(Offset(x, nodeY), 3, Paint()..color = centerColor);
  }

  @override
  bool shouldRepaint(covariant _TimelineRailPainter oldDelegate) =>
      color != oldDelegate.color ||
      centerColor != oldDelegate.centerColor ||
      lineColor != oldDelegate.lineColor ||
      first != oldDelegate.first ||
      last != oldDelegate.last;
}

String auditBeijingTime(String? value, {required String fallback}) =>
    DisplayDateTime.beijing(
      value,
      fallback: fallback,
    ).replaceFirst('(北京)', '(北京时间)');

String auditSessionActor(AuditSessionSummary session) =>
    AuditEventPresentation.actorLabel(
      actorDisplay: session.actorDisplay,
      actorAccount: session.actorAccount,
    );

String auditSessionStatusLabel(AuditSessionSummary session) {
  final provided = session.statusLabel?.trim();
  if (provided?.isNotEmpty == true) return provided!;
  return switch (session.status.trim().toLowerCase()) {
    'active' || 'online' => '仍在线',
    'logged_out' || 'logout' => '已退出',
    'normal_logout' => '正常退出',
    'expired' => '已过期',
    'no_logout_record' => '结束状态待核查',
    'security_terminated' => '安全中断',
    'activity_after_logout' => '退出后仍有操作',
    'revoked' || 'interrupted' || 'abnormal' || 'reuse_detected' => '异常中断',
    _ => '状态待核查',
  };
}

Color auditSessionStatusColor(ColorScheme colors, String status) =>
    switch (status.trim().toLowerCase()) {
      'active' || 'online' => colors.primary,
      'logged_out' || 'logout' || 'normal_logout' => colors.tertiary,
      'expired' || 'no_logout_record' => colors.onSurfaceVariant,
      'security_terminated' ||
      'activity_after_logout' ||
      'revoked' ||
      'interrupted' ||
      'abnormal' ||
      'reuse_detected' => colors.error,
      _ => colors.onSurfaceVariant,
    };

IconData auditSessionStatusIcon(String status) =>
    switch (status.trim().toLowerCase()) {
      'active' || 'online' => Icons.wifi_rounded,
      'logged_out' || 'logout' || 'normal_logout' => Icons.logout_rounded,
      'expired' => Icons.schedule_rounded,
      'no_logout_record' => Icons.help_outline_rounded,
      'security_terminated' ||
      'activity_after_logout' ||
      'revoked' ||
      'interrupted' ||
      'abnormal' ||
      'reuse_detected' => Icons.warning_amber_rounded,
      _ => Icons.help_outline_rounded,
    };

String auditEventNarrative(AuditLogEntry entry) =>
    AuditEventPresentation.salesViewNarrative(
      action: entry.action,
      targetName: entry.targetName,
    ) ??
    (entry.summary?.trim().isNotEmpty == true
        ? entry.summary!.trim()
        : entry.actionLabel?.trim().isNotEmpty == true
        ? [
            entry.actionLabel!.trim(),
            if (entry.targetName?.trim().isNotEmpty == true)
              entry.targetName!.trim(),
          ].join(' · ')
        : '该记录缺少可读操作说明，需要补充映射');

String? auditEventObjectEvidence(AuditLogEntry entry) {
  final rawObject = entry.objectLabel?.trim();
  final object = rawObject?.isNotEmpty == true && rawObject != '其他业务对象'
      ? rawObject
      : null;
  final displayName = AuditEventPresentation.safeBusinessReference(
    entry.targetDisplayName,
  );
  final businessCode = AuditEventPresentation.safeBusinessReference(
    entry.targetBusinessCode,
  );
  final legacyCode = AuditEventPresentation.safeBusinessReference(
    entry.targetLegacyCode,
  );
  final compatibleTarget = AuditEventPresentation.safeBusinessReference(
    entry.targetName,
  );
  final parts = <String>[
    if (object != null) '业务对象 $object',
    if (displayName != null && displayName != object) '对象名称 $displayName',
    if (businessCode != null) '业务编号 $businessCode',
    if (legacyCode != null) '旧系统编号 $legacyCode',
    if (displayName == null &&
        businessCode == null &&
        legacyCode == null &&
        compatibleTarget != null)
      '名称或单据编号 $compatibleTarget',
  ];
  if (parts.isNotEmpty) {
    if (parts.length == 1 && object != null) {
      parts.add('可读业务编号未记录');
    }
    return parts.join(' · ');
  }
  return '该记录缺少业务对象和业务编号映射，需要补录';
}

bool auditEventFailed(AuditLogEntry entry) =>
    (entry.statusCode != null && entry.statusCode! >= 400) ||
    const {
      'failure',
      'failed',
      'denied',
    }.contains(entry.result?.trim().toLowerCase());

String auditRiskLabel(String risk) => switch (risk.trim().toLowerCase()) {
  'critical' => '严重风险',
  'high' => '高风险',
  'medium' => '中风险',
  _ => '低风险',
};

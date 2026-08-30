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

/// 一次稳定 sessionId 一张卡；折叠时只展示摘要，展开后才懒加载事件。
class AuditSessionCard extends StatefulWidget {
  const AuditSessionCard({
    required this.session,
    required this.snapshotAuditId,
    required this.loadEvents,
    required this.onOpenEvent,
    super.key,
  });

  final AuditSessionSummary session;
  final int snapshotAuditId;
  final AuditSessionEventLoader loadEvents;
  final ValueChanged<AuditLogEntry> onOpenEvent;

  @override
  State<AuditSessionCard> createState() => _AuditSessionCardState();
}

class _AuditSessionCardState extends State<AuditSessionCard> {
  List<AuditLogEntry> _events = const [];
  String? _nextCursorAt;
  int? _nextCursorId;
  int? _eventSnapshotAuditId;
  bool _hasMore = false;
  bool _expanded = false;
  bool _loaded = false;
  bool _loading = false;
  String? _error;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant AuditSessionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.sessionId != widget.session.sessionId ||
        oldWidget.snapshotAuditId != widget.snapshotAuditId) {
      _generation++;
      _events = const [];
      _nextCursorAt = null;
      _nextCursorId = null;
      _eventSnapshotAuditId = null;
      _hasMore = false;
      _expanded = false;
      _loaded = false;
      _loading = false;
      _error = null;
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
    final requestedCursorAt = reset ? null : _nextCursorAt;
    final requestedCursorId = reset ? null : _nextCursorId;
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
        cursorAt: requestedCursorAt,
        cursorId: requestedCursorId,
        snapshotAuditId: requestedSnapshot,
      );
      if (!mounted || generation != _generation) return;
      final existingIds = reset
          ? <int>{}
          : _events.map((event) => event.id).toSet();
      final appended = page.items
          .where((event) => existingIds.add(event.id))
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
        _loaded = true;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _events.isEmpty ? '会话时间线加载失败' : '更多会话事件加载失败';
      });
    }
  }

  void _onExpansionChanged(bool expanded) {
    setState(() => _expanded = expanded);
    if (expanded && !_loaded && !_loading) {
      _load(reset: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final actor = AuditEventPresentation.actorLabel(
      actorDisplay: session.actorDisplay,
      actorAccount: session.actorAccount,
    );
    final startLabel = session.startLabel?.trim().isNotEmpty == true
        ? session.startLabel!.trim()
        : '建立会话';
    final loginAt = _beijing(session.loginAt, fallback: '开始时间未知');
    final lastActivityAt = _beijing(
      session.lastActivityAt ?? session.firstActivityAt,
      fallback: '暂无活动时间',
    );
    final logoutAt = session.logoutAt == null
        ? null
        : _beijing(session.logoutAt, fallback: '退出时间未知');
    final status = _statusLabel(session);
    final semanticsLabel = [
      '用户会话',
      actor,
      '开始方式 $startLabel',
      '状态 $status',
      '开始时间 $loginAt',
      if (logoutAt != null) '退出 $logoutAt' else '最后活动 $lastActivityAt',
      '操作 ${session.operationCount} 项',
      if (session.failureCount > 0) '失败 ${session.failureCount} 项',
      if (session.postLogoutCount > 0) '退出后操作 ${session.postLogoutCount} 项',
      _expanded ? '已展开' : '已折叠',
    ].join('，');

    return Semantics(
      container: true,
      label: semanticsLabel,
      child: UtenCard(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          key: ValueKey('audit-session-${session.sessionId}'),
          onExpansionChanged: _onExpansionChanged,
          tilePadding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s16,
            vertical: UtenSpacing.s8,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            0,
            UtenSpacing.s16,
            UtenSpacing.s16,
          ),
          title: _AuditSessionHeader(
            session: session,
            actor: actor,
            startLabel: startLabel,
            loginAt: loginAt,
            lastActivityAt: lastActivityAt,
            logoutAt: logoutAt,
            status: status,
          ),
          children: [
            const Divider(height: 1),
            const SizedBox(height: UtenSpacing.s12),
            _buildTimelineBody(),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineBody() {
    if (_loading && _events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: UtenSpacing.s8),
            Text('正在加载会话时间线...'),
          ],
        ),
      );
    }
    if (_error != null && _events.isEmpty) {
      return _AuditSessionLoadError(
        message: _error!,
        onRetry: () => _load(reset: true),
      );
    }
    if (_loaded && _events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Text('该会话暂无可展示的人工操作。', textAlign: TextAlign.center),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < _events.length; index++)
          _AuditSessionTimelineEvent(
            entry: _events[index],
            first: index == 0,
            last: index == _events.length - 1 && !_hasMore,
            onTap: () => widget.onOpenEvent(_events[index]),
          ),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          _AuditSessionLoadError(
            message: _error!,
            onRetry: () => _load(reset: false),
          ),
        ] else if (_hasMore) ...[
          const SizedBox(height: UtenSpacing.s8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              key: ValueKey(
                'audit-session-load-more-${widget.session.sessionId}',
              ),
              onPressed: _loading ? null : () => _load(reset: false),
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more_rounded),
              label: Text(_loading ? '加载中...' : '加载更多事件'),
            ),
          ),
        ],
      ],
    );
  }
}

class _AuditSessionHeader extends StatelessWidget {
  const _AuditSessionHeader({
    required this.session,
    required this.actor,
    required this.startLabel,
    required this.loginAt,
    required this.lastActivityAt,
    required this.logoutAt,
    required this.status,
  });

  final AuditSessionSummary session;
  final String actor;
  final String startLabel;
  final String loginAt;
  final String lastActivityAt;
  final String? logoutAt;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _statusColor(theme.colorScheme, session.status);
    final device = [session.deviceLabel?.trim(), session.devicePlatform?.trim()]
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet()
        .join(' · ');
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  actor,
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s8,
                    vertical: UtenSpacing.s4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: UtenRadius.smAll,
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _statusIcon(session.status),
                        size: 15,
                        color: statusColor,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Text(
                        status,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              logoutAt == null
                  ? '$startLabel $loginAt → 最后活动 $lastActivityAt'
                  : '$startLabel $loginAt → $logoutAt',
              maxLines: constraints.maxWidth < 420 ? 3 : 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                height: 1.45,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s4,
              children: [
                _SessionMetric(label: '操作', value: session.operationCount),
                if (session.eventCount != session.operationCount)
                  _SessionMetric(label: '时间线', value: session.eventCount),
                if (session.failureCount > 0)
                  _SessionMetric(label: '失败', value: session.failureCount),
              ],
            ),
            if (device.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '设备 $device',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (session.refreshCredentialStatusLabel?.trim().isNotEmpty ==
                true) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '会话凭证 ${session.refreshCredentialStatusLabel!.trim()}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (session.postLogoutCount > 0 || session.timelinePartial) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                session.postLogoutCount > 0
                    ? '退出后仍记录 ${session.postLogoutCount} 项操作，需核查。'
                    : '部分旧事件缺少会话标识，时间线可能不完整。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SessionMetric extends StatelessWidget {
  const _SessionMetric({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '$label $value',
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _AuditSessionTimelineEvent extends StatelessWidget {
  const _AuditSessionTimelineEvent({
    required this.entry,
    required this.first,
    required this.last,
    required this.onTap,
  });

  final AuditLogEntry entry;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = _beijing(entry.createdAt, fallback: '时间未知');
    final summary =
        AuditEventPresentation.salesViewNarrative(
          action: entry.action,
          targetName: entry.targetName,
        ) ??
        (entry.summary?.trim().isNotEmpty == true
            ? entry.summary!.trim()
            : entry.actionLabel?.trim().isNotEmpty == true
            ? entry.actionLabel!.trim()
            : '已记录操作');
    final failed =
        (entry.statusCode != null && entry.statusCode! >= 400) ||
        const {
          'failure',
          'failed',
          'denied',
        }.contains(entry.result?.trim().toLowerCase());
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
    return Semantics(
      button: true,
      label: '$time，$summary，$outcome，点击查看审计详情',
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CustomPaint(
              painter: _TimelineRailPainter(
                color: nodeColor,
                lineColor: theme.colorScheme.outlineVariant,
                first: first,
                last: last,
              ),
              child: const SizedBox(width: 28),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
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
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              time,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            Text(
                              summary,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            Text(
                              [
                                outcome,
                                if (entry.riskLevel != 'low') '需关注',
                              ].join(' · '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: failed
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
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

class _TimelineRailPainter extends CustomPainter {
  const _TimelineRailPainter({
    required this.color,
    required this.lineColor,
    required this.first,
    required this.last,
  });

  final Color color;
  final Color lineColor;
  final bool first;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    const nodeY = 18.0;
    final x = size.width / 2;
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2;
    if (!first) canvas.drawLine(Offset(x, 0), Offset(x, nodeY), linePaint);
    if (!last) {
      canvas.drawLine(Offset(x, nodeY), Offset(x, size.height), linePaint);
    }
    canvas.drawCircle(Offset(x, nodeY), 6, Paint()..color = color);
    canvas.drawCircle(Offset(x, nodeY), 3, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _TimelineRailPainter oldDelegate) =>
      color != oldDelegate.color ||
      lineColor != oldDelegate.lineColor ||
      first != oldDelegate.first ||
      last != oldDelegate.last;
}

class _AuditSessionLoadError extends StatelessWidget {
  const _AuditSessionLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        children: [
          Text(
            message,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          OutlinedButton.icon(
            key: const ValueKey('audit-session-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

String _beijing(String? value, {required String fallback}) =>
    DisplayDateTime.beijing(
      value,
      fallback: fallback,
    ).replaceFirst('(北京)', '(北京时间)');

String _statusLabel(AuditSessionSummary session) {
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

Color _statusColor(ColorScheme colors, String status) => switch (status
    .trim()
    .toLowerCase()) {
  'active' || 'online' => colors.primary,
  'logged_out' || 'logout' => colors.tertiary,
  'normal_logout' => colors.tertiary,
  'expired' => colors.onSurfaceVariant,
  'no_logout_record' => colors.onSurfaceVariant,
  'security_terminated' || 'activity_after_logout' => colors.error,
  'revoked' || 'interrupted' || 'abnormal' || 'reuse_detected' => colors.error,
  _ => colors.onSurfaceVariant,
};

IconData _statusIcon(String status) => switch (status.trim().toLowerCase()) {
  'active' || 'online' => Icons.wifi_rounded,
  'logged_out' || 'logout' => Icons.logout_rounded,
  'normal_logout' => Icons.logout_rounded,
  'expired' => Icons.schedule_rounded,
  'no_logout_record' => Icons.help_outline_rounded,
  'security_terminated' ||
  'activity_after_logout' => Icons.warning_amber_rounded,
  'revoked' ||
  'interrupted' ||
  'abnormal' ||
  'reuse_detected' => Icons.warning_amber_rounded,
  _ => Icons.help_outline_rounded,
};

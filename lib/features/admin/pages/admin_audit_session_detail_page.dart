import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/audit_log_entry.dart';
import '../models/audit_session.dart';
import '../repositories/audit_log_repository.dart';
import '../widgets/audit_session_card.dart';
import 'admin_audit_log_page.dart';

/// 一次登录会话的独立调查页面。
///
/// 支持列表 push 和 URL 深链：路由 extra 只用于首屏即时展示，页面仍会按 sessionId
/// 从服务端读取权威摘要，再以同一 snapshotAuditId 分页加载完整时间线。
class AdminAuditSessionDetailPage extends ConsumerStatefulWidget {
  const AdminAuditSessionDetailPage({
    required this.sessionId,
    this.initialSummary,
    this.routeSnapshotAuditId,
    super.key,
  });

  final String sessionId;
  final AuditSessionSummary? initialSummary;
  final int? routeSnapshotAuditId;

  @override
  ConsumerState<AdminAuditSessionDetailPage> createState() =>
      _AdminAuditSessionDetailPageState();
}

class _AdminAuditSessionDetailPageState
    extends ConsumerState<AdminAuditSessionDetailPage> {
  AuditSessionSummary? _summary;
  bool _loadingSummary = true;
  String? _summaryError;
  int _summaryGeneration = 0;
  int _timelineGeneration = 0;

  @override
  void initState() {
    super.initState();
    _summary = widget.initialSummary;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadSummary();
    });
  }

  @override
  void didUpdateWidget(covariant AdminAuditSessionDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _summaryGeneration++;
      _summary = widget.initialSummary;
      _summaryError = null;
      _timelineGeneration++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadSummary();
      });
    }
  }

  @override
  void dispose() {
    _summaryGeneration++;
    super.dispose();
  }

  Future<void> _loadSummary({bool latest = false}) async {
    final generation = ++_summaryGeneration;
    setState(() {
      _loadingSummary = true;
      _summaryError = null;
    });
    try {
      final summary = await ref
          .read(auditLogRepositoryProvider)
          .sessionSummary(
            sessionId: widget.sessionId,
            snapshotAuditId: latest ? null : widget.routeSnapshotAuditId,
          );
      if (!mounted || generation != _summaryGeneration) return;
      setState(() {
        _summary = summary;
        _loadingSummary = false;
        _summaryError = null;
      });
    } catch (error) {
      if (!mounted || generation != _summaryGeneration) return;
      setState(() {
        _loadingSummary = false;
        _summaryError = error is ApiException
            ? error.message
            : '会话摘要加载失败，请检查网络后重试。';
      });
    }
  }

  Future<void> _refresh() async {
    await _loadSummary(latest: true);
    if (!mounted) return;
    setState(() => _timelineGeneration++);
  }

  int? get _timelineSnapshotAuditId {
    final summarySnapshot = _summary?.snapshotAuditId ?? 0;
    if (summarySnapshot > 0) return summarySnapshot;
    final routeSnapshot = widget.routeSnapshotAuditId ?? 0;
    return routeSnapshot > 0 ? routeSnapshot : null;
  }

  Future<AuditSessionEventPage> _loadEvents({
    String? cursorAt,
    int? cursorId,
    int? snapshotAuditId,
  }) => ref
      .read(auditLogRepositoryProvider)
      .sessionEvents(
        sessionId: widget.sessionId,
        cursorAt: cursorAt,
        cursorId: cursorId,
        snapshotAuditId: snapshotAuditId,
      );

  Future<void> _openEvent(AuditLogEntry entry) =>
      showAuditLogDetailViewer(context: context, ref: ref, entry: entry);

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final titleActor = summary == null ? null : auditSessionActor(summary);
    return Scaffold(
      appBar: UtenAppBar(
        title: '会话时间线',
        subtitle: titleActor == null
            ? '按一次登录查看完整人员操作'
            : '$titleActor · ${auditSessionStatusLabel(summary!)}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.adminAuditLogs),
        ),
        actions: [
          IconButton(
            key: const ValueKey('audit-session-detail-refresh'),
            tooltip: '刷新会话',
            onPressed: _loadingSummary ? null : _refresh,
            icon: _loadingSummary
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
        showPagePermissionAction: false,
      ),
      body: SafeArea(
        child: UtenContentContainer.narrow(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s16,
            bottom: UtenSpacing.s24,
          ),
          child: _buildBody(summary),
        ),
      ),
    );
  }

  Widget _buildBody(AuditSessionSummary? summary) {
    if (summary == null && _loadingSummary) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: '正在加载会话摘要',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (summary == null) {
      return Center(
        child: AuditSessionLoadError(
          message: _summaryError ?? '未找到该登录会话。',
          onRetry: _loadSummary,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        key: const ValueKey('audit-session-detail-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverToBoxAdapter(child: _PageIntroduction()),
          const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s16)),
          SliverToBoxAdapter(child: AuditSessionSummaryPanel(session: summary)),
          if (_summaryError != null) ...[
            const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s12)),
            SliverToBoxAdapter(
              child: AuditSessionLoadError(
                message: '摘要刷新失败，当前仍显示上一次结果。',
                onRetry: _loadSummary,
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s24)),
          const SliverToBoxAdapter(child: _TimelineHeading()),
          const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s12)),
          AuditSessionTimeline(
            key: ValueKey(
              'audit-session-timeline-${widget.sessionId}-'
              '$_timelineGeneration',
            ),
            sessionId: widget.sessionId,
            snapshotAuditId: _timelineSnapshotAuditId,
            loadEvents: _loadEvents,
            onOpenEvent: _openEvent,
          ),
          const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s24)),
        ],
      ),
    );
  }
}

class _PageIntroduction extends StatelessWidget {
  const _PageIntroduction();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '一次登录，一条完整时间线',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '登录、查看、修改、下载和退出归入同一会话。所有时间统一为北京时间，'
            '系统自动任务不会混入人员操作。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineHeading extends StatelessWidget {
  const _TimelineHeading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: UtenRadius.mdAll,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.timeline_rounded,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '人员操作时间线',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '最新操作在前。点击具体记录，可查看操作人、业务对象、'
                '对象名称、业务编号、旧系统编号及访问证据。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

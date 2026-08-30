import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/audit_event_presentation.dart';
import '../models/audit_log_entry.dart';
import '../models/audit_session.dart';
import '../repositories/audit_log_repository.dart';
import '../widgets/audit_session_card.dart';

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

  Future<void> _openEvent(AuditLogEntry entry) async {
    final panel = _AuditEventDetailPanel(
      auditId: entry.id,
      loader: () => ref.read(auditLogRepositoryProvider).detail(entry.id),
    );
    final width = MediaQuery.sizeOf(context).width;
    if (width < 720) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: panel),
      );
      return;
    }
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭操作详情',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, _, _) => SafeArea(
        child: Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(dialogContext).colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(20),
              ),
              side: BorderSide(
                color: Theme.of(dialogContext).colorScheme.outlineVariant,
              ),
            ),
            child: SizedBox(width: 720, height: double.infinity, child: panel),
          ),
        ),
      ),
      transitionBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      ),
    );
  }

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
              backTo(context, defaultPath: RouteName.adminAuditLogs),
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
      child: ListView(
        key: const ValueKey('audit-session-detail-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const _PageIntroduction(),
          const SizedBox(height: UtenSpacing.s16),
          AuditSessionSummaryPanel(session: summary),
          if (_summaryError != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            AuditSessionLoadError(
              message: '摘要刷新失败，当前仍显示上一次结果。',
              onRetry: _loadSummary,
            ),
          ],
          const SizedBox(height: UtenSpacing.s24),
          const _TimelineHeading(),
          const SizedBox(height: UtenSpacing.s12),
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
                '名称或单据编号及访问证据。',
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

class _AuditEventDetailPanel extends StatefulWidget {
  const _AuditEventDetailPanel({required this.auditId, required this.loader});

  final int auditId;
  final Future<AuditLogDetail> Function() loader;

  @override
  State<_AuditEventDetailPanel> createState() => _AuditEventDetailPanelState();
}

class _AuditEventDetailPanelState extends State<_AuditEventDetailPanel> {
  late Future<AuditLogDetail> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  void _retry() => setState(() => _future = widget.loader());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AuditLogDetail>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Column(
            children: [
              _DetailHeader(auditId: widget.auditId),
              const Expanded(child: Center(child: CircularProgressIndicator())),
            ],
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          final error = snapshot.error;
          return Column(
            children: [
              _DetailHeader(auditId: widget.auditId),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s24),
                    child: AuditSessionLoadError(
                      message: error is ApiException
                          ? error.message
                          : '操作详情加载失败。',
                      onRetry: _retry,
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            _DetailHeader(auditId: widget.auditId),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s20,
                  0,
                  UtenSpacing.s20,
                  UtenSpacing.s24,
                ),
                child: _AuditEventDetailContent(detail: snapshot.data!),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.auditId});

  final int auditId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '操作详情 #$auditId',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: '关闭操作详情',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _AuditEventDetailContent extends StatelessWidget {
  const _AuditEventDetailContent({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final actor = AuditEventPresentation.actorLabel(
      actorDisplay: detail.actorDisplay,
      actorAccount: detail.actorAccount,
    );
    final action = detail.actionLabel?.trim().isNotEmpty == true
        ? detail.actionLabel!.trim()
        : '未登记操作名称';
    final rawObject = detail.objectLabel?.trim();
    final object = rawObject?.isNotEmpty == true && rawObject != '其他业务对象'
        ? rawObject
        : null;
    final targetName = detail.targetName?.trim();
    final targetId = detail.targetId?.trim();
    final result = detail.resultLabel?.trim().isNotEmpty == true
        ? detail.resultLabel!.trim()
        : '结果未记录';
    final page = detail.pageLabel?.trim();
    final requestMethod = _requestMethodLabel(detail.httpMethod);
    final device = detail.device;
    final devicePlatform =
        [
              device?.platform?.trim(),
              device?.browserName?.trim(),
              device?.osVersion?.trim(),
            ]
            .whereType<String>()
            .where((value) => value.isNotEmpty)
            .toSet()
            .join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                detail.summary?.trim().isNotEmpty == true
                    ? detail.summary!.trim()
                    : [
                        action,
                        ?object,
                        if (targetName?.isNotEmpty == true) targetName,
                      ].join(' · '),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  _DetailTag(label: result),
                  _DetailTag(
                    label: auditRiskLabel(detail.riskLevel),
                    danger: detail.riskLevel != 'low',
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s16),
        _DetailSection(
          title: '谁在什么时候做了什么',
          icon: Icons.person_search_outlined,
          rows: [
            ('操作人', actor),
            if (detail.actorDepartment?.trim().isNotEmpty == true)
              ('所属部门', detail.actorDepartment!.trim()),
            if (detail.actorPosition?.trim().isNotEmpty == true)
              ('岗位', detail.actorPosition!.trim()),
            ('操作时间', auditBeijingTime(detail.createdAt, fallback: '时间未记录')),
            ('具体操作', action),
            ('操作结果', result),
            ('风险等级', auditRiskLabel(detail.riskLevel)),
            if (detail.riskReason?.trim().isNotEmpty == true)
              ('风险原因', detail.riskReason!.trim()),
          ],
        ),
        const SizedBox(height: UtenSpacing.s16),
        _DetailSection(
          title: '查看或操作了哪个业务对象',
          icon: Icons.description_outlined,
          rows: [
            if (object != null) ('业务对象类型', object),
            (
              '业务名称或单据编号',
              targetName?.isNotEmpty == true ? targetName! : '业务编号未记录',
            ),
            if (targetId?.isNotEmpty == true) ('系统对象标识', targetId!),
            if (page?.isNotEmpty == true) ('所在页面', page!),
          ],
          warning: object == null ? '该条旧日志未保存明确的业务对象类型，仅展示当时实际留存的可核查信息。' : null,
        ),
        const SizedBox(height: UtenSpacing.s16),
        _DetailSection(
          title: '访问与设备证据',
          icon: Icons.shield_outlined,
          rows: [
            if (detail.ip?.trim().isNotEmpty == true)
              ('网络地址', detail.ip!.trim()),
            if (device != null) ('设备', device.displayLabel),
            if (devicePlatform.isNotEmpty) ('设备环境', devicePlatform),
            if (requestMethod != null) ('请求方式', requestMethod),
            if (detail.statusCode != null)
              ('请求结果码', detail.statusCode.toString()),
            if (detail.durationMs != null) ('处理耗时', '${detail.durationMs} 毫秒'),
            if (detail.requestId?.trim().isNotEmpty == true)
              ('请求追踪号', detail.requestId!.trim()),
          ],
        ),
        const SizedBox(height: UtenSpacing.s16),
        _DetailSection(
          title: '数据变化',
          icon: Icons.difference_outlined,
          rows: [
            (
              '变化明细',
              detail.changeSummary?.trim().isNotEmpty == true
                  ? detail.changeSummary!.trim()
                  : '本次操作未产生可展示的字段变化。',
            ),
          ],
        ),
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.icon,
    required this.rows,
    this.warning,
  });

  final String title;
  final IconData icon;
  final List<(String, String)> rows;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
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
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          for (var index = 0; index < rows.length; index++) ...[
            _DetailRow(label: rows[index].$1, value: rows[index].$2),
            if (index != rows.length - 1)
              const Divider(height: UtenSpacing.s16),
          ],
          if (warning != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            Text(
              warning!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w700,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 480;
        final labelWidget = Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        );
        final valueWidget = SelectableText(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              labelWidget,
              const SizedBox(height: UtenSpacing.s4),
              valueWidget,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 128, child: labelWidget),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(child: valueWidget),
          ],
        );
      },
    );
  }
}

class _DetailTag extends StatelessWidget {
  const _DetailTag({required this.label, this.danger = false});

  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = danger ? theme.colorScheme.error : theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String? _requestMethodLabel(String? value) =>
    switch (value?.trim().toUpperCase()) {
      'GET' => '读取',
      'POST' => '提交',
      'PUT' => '整体更新',
      'PATCH' => '局部更新',
      'DELETE' => '删除',
      _ => null,
    };

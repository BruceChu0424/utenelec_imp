import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../models/server_operations.dart';
import '../providers/server_operations_access.dart';
import '../repositories/server_operations_repository.dart';
import '../widgets/server_update_source_editor.dart';
import '../widgets/server_update_schedule_dialog.dart';

class ServerOperationsPage extends ConsumerWidget {
  const ServerOperationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ref.watch(serverOperationsOwnerProvider);
    final allowed = ref.watch(serverOperationsVisibleProvider);
    return _ServerOperationsSession(key: ValueKey((owner, allowed)));
  }
}

class _ServerOperationsSession extends ConsumerStatefulWidget {
  const _ServerOperationsSession({super.key});
  @override
  ConsumerState<_ServerOperationsSession> createState() =>
      _ServerOperationsState();
}

class _ServerOperationsState extends ConsumerState<_ServerOperationsSession>
    with WidgetsBindingObserver {
  late final Object? _owner;
  ServerOperationsStatus? _status;
  ServerUpdateJob? _job;
  Timer? _poll;
  bool _loading = false, _starting = false, _foreground = true, _visible = true;
  int _sequence = 0;
  String? _error,
      _uncertainRequestId,
      _offerAfterRequestId,
      _cancelPendingJobId;
  bool _offerOpen = false;
  bool get _current =>
      mounted &&
      _owner != null &&
      _owner == ref.read(serverOperationsOwnerProvider) &&
      ref.read(serverOperationsVisibleProvider);
  bool get _active => _current && _foreground && _visible;
  ServerOperationsRepository get _repository =>
      ref.read(serverOperationsRepositoryProvider);

  bool get _canStart =>
      _current &&
      !_loading &&
      !_starting &&
      _error == null &&
      _job?.recoveryRequired != true &&
      _uncertainRequestId == null &&
      (_job == null || _job!.terminal) &&
      ref.read(serverOperationsWritableProvider) &&
      _status?.available == true &&
      _status?.canUpdate == true &&
      _status?.sourceConfigured == true &&
      _status?.sourceRevision?.isNotEmpty == true &&
      _status?.currentVersion?.isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    _owner = ref.read(serverOperationsOwnerProvider);
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _poll?.cancel();
    if (_active) unawaited(_load());
  }

  @override
  void dispose() {
    _sequence++;
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _schedule() {
    _poll?.cancel();
    if (!_active) return;
    if (_job?.running == true || _uncertainRequestId != null) {
      _poll = Timer(
        Duration(seconds: _job?.state == 'SCHEDULED' ? 30 : 5),
        () => _load(),
      );
    }
  }

  /// Reads host-local durable state only. Never starts an OSS check.
  Future<void> _load() async {
    if (!_active || _loading || _starting) return;
    final sequence = ++_sequence;
    final repository = _repository;
    _poll?.cancel();
    setState(() => _loading = true);
    try {
      final status = await repository.status();
      if (!_current || sequence != _sequence) return;
      var job = status.latestJob;
      // A submitted request with no HTTP receipt must be found, not resubmitted.
      if (_uncertainRequestId != null &&
          job?.requestId != _uncertainRequestId) {
        job = await repository.latestJob();
        if (!_current || sequence != _sequence) return;
      }
      setState(() {
        _status = status;
        _job = job;
        _error = null;
        if (job?.requestId == _uncertainRequestId) _uncertainRequestId = null;
        if (job?.id == _cancelPendingJobId && job?.state != 'SCHEDULED') {
          _cancelPendingJobId = null;
        }
      });
    } catch (error) {
      if (!_current || sequence != _sequence) return;
      setState(
        () => _error = error is ApiException
            ? error.message
            : '无法读取服务器更新状态，请稍后刷新。',
      );
    } finally {
      if (_current && sequence == _sequence) {
        setState(() => _loading = false);
        _schedule();
        if (_offerAfterRequestId != null &&
            _job?.requestId == _offerAfterRequestId &&
            _job?.terminal == true) {
          _offerAfterRequestId = null;
          if (_job?.succeeded == true && _status?.updateAvailable == true) {
            unawaited(_offerUpdate());
          }
        }
      }
    }
  }

  Future<void> _start() async {
    if (!_canStart) return;
    await _submit('CHECK_ONLY', _status!);
  }

  Future<void> _offerUpdate() async {
    if (!_canStart ||
        _offerOpen ||
        _status?.updateAvailable != true ||
        _status?.latestVersion == null) {
      return;
    }
    final expected = _status!;
    _offerOpen = true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => UtenAlertDialog(
        title: Text('发现新版本 ${expected.latestVersion}'),
        content: const Text(
          '可立即更新，或预约服务器当地时间凌晨 02:00 / 03:00 更新。\n\n更新将下载并验签，先备份，再迁移数据库、激活版本并检查健康状态；期间服务可能暂时中断。',
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            key: const ValueKey('server-update-schedule'),
            onPressed:
                expected.serverTime == null || expected.serverTimeZone == null
                ? null
                : () => Navigator.pop(context, 'schedule'),
            child: const Text('预约更新'),
          ),
          UtenButton(
            key: const ValueKey('server-update-confirm'),
            onPressed: () => Navigator.pop(context, 'now'),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
    _offerOpen = false;
    if (!_current || !_canStart || choice == null) return;
    if (choice == 'now') {
      await _submit(
        'CHECK_AND_UPDATE',
        expected,
        targetVersion: expected.latestVersion,
      );
    } else if (choice == 'schedule') {
      if (!mounted) return;
      final preview = await showDialog<ServerUpdateSchedulePreview>(
        context: context,
        builder: (_) => ServerUpdateScheduleDialog(status: expected),
      );
      if (!_current || !_canStart || preview == null) return;
      await _submit(
        'SCHEDULE_UPDATE',
        expected,
        targetVersion: expected.latestVersion,
        scheduledAt: preview.scheduledAt,
      );
    }
  }

  Future<void> _submit(
    String mode,
    ServerOperationsStatus expected, {
    String? targetVersion,
    String? scheduledAt,
  }) async {
    if (!_canStart) return;
    final requestId = const Uuid().v4();
    if (mode == 'CHECK_ONLY') _offerAfterRequestId = requestId;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final job = await _repository.startUpdate(
        requestId: requestId,
        expectedSourceRevision: expected.sourceRevision!,
        expectedCurrentVersion: expected.currentVersion!,
        mode: mode,
        targetVersion: targetVersion,
        scheduledAt: scheduledAt,
      );
      if (!_current) return;
      setState(() => _job = job);
    } catch (error) {
      if (!_current) return;
      final certainRejection =
          error is ApiException &&
          error.httpStatus != null &&
          error.httpStatus! >= 400 &&
          error.httpStatus! < 500;
      setState(() {
        _uncertainRequestId = certainRejection ? null : requestId;
        _error = certainRejection
            ? error.message
            : '更新请求结果尚未确认。正在核对服务器原作业，请勿重复启动。';
      });
    } finally {
      if (_current) {
        setState(() => _starting = false);
        _schedule();
        if (_job?.terminal == true && _uncertainRequestId == null) {
          unawaited(_load());
        }
      }
    }
  }

  bool _canCancel(ServerUpdateJob job) =>
      _current &&
      !_loading &&
      !_starting &&
      _cancelPendingJobId == null &&
      job.state == 'SCHEDULED' &&
      _status?.available == true &&
      _status?.canUpdate == true &&
      ref.read(serverOperationsWritableProvider) &&
      (ref.read(isSuperAdminProvider) ||
          (job.actorId != null &&
              job.actorId == ref.read(authenticatedScopeProvider)?.userId));

  Future<void> _cancel(ServerUpdateJob job) async {
    if (!_canCancel(job)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => UtenAlertDialog(
        title: const Text('取消此次预约更新'),
        content: const Text('只取消尚未开始的预约。已经开始的备份、迁移或激活不会被强行中断。'),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留预约'),
          ),
          UtenButton(
            type: UtenButtonType.danger,
            key: const ValueKey('server-update-cancel-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消预约'),
          ),
        ],
      ),
    );
    if (!_current || confirmed != true || !_canCancel(job)) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final result = await _repository.cancel(
        job.id,
        requestId: const Uuid().v4(),
      );
      if (!_current) return;
      if (result.id != job.id) {
        throw const FormatException('Invalid cancellation receipt');
      }
      setState(() => _job = result);
    } catch (error) {
      if (!_current) return;
      setState(() {
        _cancelPendingJobId = job.id;
        _error = '取消结果尚未确认，正在核对此预约的原作业状态，不会重复提交。';
      });
    } finally {
      if (_current) {
        setState(() => _starting = false);
        _schedule();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed =
        ref.watch(serverOperationsVisibleProvider) && _owner != null;
    ref.listen(pageResumeProvider, (_, next) {
      if (next.location.isEmpty) return;
      final visible = next.location == RouteName.adminServerOperations;
      if (_visible == visible) return;
      _visible = visible;
      _poll?.cancel();
      if (_active) unawaited(_load());
    });
    final status = _status;
    return Scaffold(
      appBar: UtenAppBar(
        title: '服务器更新',
        showBackButton: true,
        showPagePermissionAction: false,
        actions: [
          IconButton(
            key: const ValueKey('server-operations-refresh'),
            tooltip: '刷新本机状态',
            onPressed: allowed && !_loading && !_starting ? _load : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: !allowed
          ? const UtenEmpty(icon: Icons.lock_outline, message: '没有服务器运维查看权限')
          : SafeArea(
              child: SingleChildScrollView(
                child: UtenContentContainer.narrow(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loading && status == null)
                        const LinearProgressIndicator(),
                      if (_error != null) ...[
                        UtenInlineNotice(
                          level: UtenInlineNoticeLevel.error,
                          message: _error,
                        ),
                        const SizedBox(height: UtenSpacing.s16),
                      ],
                      UtenCard(
                        child: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '当前公司服务器',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                              Text('当前版本：${status?.currentVersion ?? '尚未确认'}'),
                              if (status?.lastCheckedAt != null)
                                Text(
                                  '上次检查时间：${DisplayDateTime.beijing(status!.lastCheckedAt!.toIso8601String())}',
                                ),
                              if (status?.serverTimeZone != null)
                                Text('服务器时区：${status!.serverTimeZone}'),
                              Text(
                                status?.manualOnly == true
                                    ? '检查方式：纯手动；预约仅在指定时间执行'
                                    : status?.manualOnly == false
                                    ? '服务器报告存在旧自动检查计划，请联系管理员核对'
                                    : '检查方式：尚未确认',
                              ),
                              if (status?.timerActive != null)
                                Text(
                                  '自动拉取定时器：${status!.timerActive! ? '仍启用（需处理）' : '已停用'}',
                                ),
                              if (status?.message != null)
                                Text(status!.message!),
                              if (status != null && !status.available)
                                const Text('当前服务器未提供运维执行能力。'),
                              const SizedBox(height: UtenSpacing.s16),
                              UtenButton(
                                key: const ValueKey('server-update-start'),
                                icon: Icons.manage_search_rounded,
                                isLoading: _starting,
                                onPressed: _canStart ? _start : null,
                                child: const Text('检查版本更新'),
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                              const Text(
                                '进入页面、刷新和查看进度只读取此服务器状态。手动检查版本或预约到点执行时才访问发布源。',
                              ),
                              if (status?.sourceConfigured == false)
                                const Text('发布源尚未配置，请由超级管理员完成配置。'),
                            ],
                          ),
                        ),
                      ),
                      if (status?.updateAvailable == true &&
                          status?.canUpdate == true) ...[
                        const SizedBox(height: UtenSpacing.s16),
                        UtenInlineNotice(
                          title: '发现新版本 ${status?.latestVersion ?? ''}',
                          message: '这是上次检查的结果。版本激活成功后清除提醒，平时不会连接发布源。',
                          trailing: Badge(
                            label: const Text('1'),
                            child: UtenButton(
                              key: const ValueKey('server-update-available'),
                              type: UtenButtonType.secondary,
                              onPressed: _canStart ? _offerUpdate : null,
                              child: const Text('查看更新'),
                            ),
                          ),
                        ),
                      ],
                      if (_uncertainRequestId != null) ...[
                        const SizedBox(height: UtenSpacing.s16),
                        const UtenInlineNotice(
                          level: UtenInlineNoticeLevel.warning,
                          title: '正在核对原作业',
                          message: '连接恢复后将继续显示服务器保存的作业结果。不会自动重新提交更新。',
                        ),
                      ],
                      if (_job != null) ...[
                        const SizedBox(height: UtenSpacing.s16),
                        _jobCard(_job!),
                      ],
                      const SizedBox(height: UtenSpacing.s16),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        icon: Icons.storage_rounded,
                        onPressed: () =>
                            context.push(RouteName.adminServerStorage),
                        child: const Text('存储管理'),
                      ),
                      if (ref.watch(serverSourceVisibleProvider) &&
                          status?.canConfigureSource == true) ...[
                        const SizedBox(height: UtenSpacing.s24),
                        ServerUpdateSourceEditor(
                          busy: _job?.running == true || _starting,
                          onSaved: _load,
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s24),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _jobCard(ServerUpdateJob job) {
    final theme = Theme.of(context);
    final phases = job.mode == 'CHECK_ONLY'
        ? const [('CHECKING', '检查版本'), ('DONE', '完成')]
        : const [
            ('CHECKING', '检查'),
            ('DOWNLOADING', '下载并验签'),
            ('BACKING_UP', '备份'),
            ('MIGRATING', '数据库迁移'),
            ('ACTIVATING', '激活'),
            ('HEALTH_CHECK', '健康检查'),
            ('DONE', '完成'),
          ];
    final index = phases.indexWhere((phase) => phase.$1 == job.phase);
    final title = switch (job.state) {
      'QUEUED' => '更新作业已排队',
      'RUNNING' => '正在更新',
      'SCHEDULED' => '更新已预约',
      'CANCELLED' => '预约已取消',
      'SUCCEEDED' => job.mode == 'CHECK_ONLY' ? '版本检查完成' : '更新检查已完成',
      'FAILED' => '更新作业失败',
      'RECOVERY_REQUIRED' => '需要恢复处理',
      _ => '作业状态尚未确认',
    };
    return UtenCard(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              key: const ValueKey('server-update-job-state'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text('作业编号：${job.id}'),
            if (job.scheduledAt != null)
              Text(
                job.displayLocalTime != null
                    ? '预约执行：${job.displayLocalTime}（${_status?.serverTimeZone ?? '服务器当地时间'}）'
                    : '预约执行：${job.scheduledAt!.toUtc().toIso8601String()}（UTC）；服务器时区 ${_status?.serverTimeZone ?? '待确认'}',
              ),
            if (job.state == 'SCHEDULED')
              const Text('等待预约时间，届时重新检查版本、权限与发布源后执行。'),
            if (job.targetVersion != null) Text('目标版本：${job.targetVersion}'),
            if (job.startedAt != null)
              Text(
                '开始：${DisplayDateTime.beijing(job.startedAt!.toIso8601String())}',
              ),
            if (job.finishedAt != null)
              Text(
                '结束：${DisplayDateTime.beijing(job.finishedAt!.toIso8601String())}',
              ),
            const SizedBox(height: UtenSpacing.s12),
            if (job.state == 'RUNNING' || job.state == 'QUEUED')
              const LinearProgressIndicator(),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              children: [
                for (var i = 0; i < phases.length; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        job.succeeded || i < index
                            ? Icons.check_circle_outline
                            : i == index
                            ? Icons.pending_outlined
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: job.succeeded || i <= index
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 4),
                      Text(phases[i].$2),
                    ],
                  ),
              ],
            ),
            if (job.message != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(job.message!),
            ],
            if (job.migrationRequired != null)
              Text(job.migrationRequired! ? '此版本包含数据库迁移' : '此版本无需数据库迁移'),
            if (job.health != null) Text('健康验收：${_health(job.health)}'),
            if (job.recoveryRequired)
              const UtenInlineNotice(
                level: UtenInlineNoticeLevel.error,
                message: '请联系超级管理员核查恢复点与服务健康，完成恢复前不要重新提交更新。',
              ),
            if (_canCancel(job)) ...[
              const SizedBox(height: UtenSpacing.s12),
              UtenButton(
                key: const ValueKey('server-update-cancel'),
                type: UtenButtonType.secondary,
                onPressed: () => _cancel(job),
                child: const Text('取消预约'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _health(Object? value) {
    if (value == true ||
        value == 'UP' ||
        value == 'HEALTHY' ||
        value == 'PASS') {
      return '通过';
    }
    if (value == false || value == 'DOWN' || value == 'FAILED') return '未通过';
    if (value is Map) {
      final status = value['status'];
      if (status is String) return _health(status);
    }
    return '请查看作业说明';
  }
}

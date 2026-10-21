import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../models/server_operations.dart';
import '../providers/server_operations_access.dart';
import '../repositories/server_operations_repository.dart';
import '../repositories/server_operation_outcome.dart';
import '../widgets/server_update_source_editor.dart';
import '../widgets/server_update_schedule_dialog.dart';
import '../widgets/server_update_dialog_guard.dart';
import '../widgets/server_update_overview.dart';

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
  final _sourceEditorKey = GlobalKey();
  ServerOperationsStatus? _status;
  ServerUpdateJob? _job;
  ServerUpdateJob? _receiptJob;
  String? _watchJobId;
  Timer? _poll;
  bool _loading = false, _starting = false, _foreground = true, _visible = true;
  int _sequence = 0;
  String? _error,
      _errorCode,
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
      _receiptJob?.recoveryRequired != true &&
      _status?.failure?.recoveryRequired != true &&
      _uncertainRequestId == null &&
      _cancelPendingJobId == null &&
      _watchJobId == null &&
      _status?.latestJob?.running != true &&
      (_job == null || _job!.terminal) &&
      ref.read(serverOperationsWritableProvider) &&
      _status?.available == true &&
      _status?.canUpdate == true &&
      _status?.sourceConfigured == true &&
      _status?.sourceRevision?.isNotEmpty == true &&
      _status?.currentVersion?.isNotEmpty == true;

  bool get _canReviewUpdate =>
      _canStart &&
      _job?.state != 'FAILED' &&
      _receiptJob?.state != 'FAILED' &&
      _job?.recoveryRequired != true;

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
    if (_job?.running == true ||
        _status?.latestJob?.running == true ||
        _watchJobId != null ||
        _uncertainRequestId != null ||
        _cancelPendingJobId != null) {
      _poll = Timer(
        Duration(seconds: _job?.state == 'SCHEDULED' ? 30 : 5),
        () => _load(),
      );
    }
  }

  /// Reads host-local durable state only. Never starts an OSS check.
  Future<void> _load({bool preserveNotice = false}) async {
    if (!_active || _loading || _starting) return;
    final sequence = ++_sequence;
    final repository = _repository;
    _poll?.cancel();
    setState(() => _loading = true);
    try {
      final status = await repository.status();
      if (!_current || sequence != _sequence) return;
      var uncertain = _uncertainRequestId;
      var cancelling = _cancelPendingJobId;
      var watching = _watchJobId;
      var receipt = _receiptJob;
      String? readError, readErrorCode;
      // The request UUID is the durable update job ID. A newer company job
      // must never replace resolution of our original submission/cancellation.
      final targets = {?uncertain, ?cancelling, ?watching};
      for (final id in targets) {
        ServerUpdateJob found;
        try {
          found = status.latestJob?.id == id
              ? status.latestJob!
              : await repository.job(id);
          if (!_current || sequence != _sequence) return;
          if (found.id != id ||
              (id == uncertain && found.requestId != uncertain)) {
            throw const FormatException('Invalid original job receipt');
          }
        } catch (error) {
          if (!_current || sequence != _sequence) return;
          readError = '暂未确认原作业结果。正在继续查询原作业，不会重复提交更新或取消请求。';
          readErrorCode = error is ApiException
              ? safeServerOperationCode(error.code)
              : null;
          continue;
        }
        receipt = found;
        if (id == uncertain) uncertain = null;
        if (id == cancelling && found.state != 'SCHEDULED') cancelling = null;
        if (found.running) {
          watching = id;
        } else if (watching == id || id == _uncertainRequestId) {
          watching = null;
        }
      }
      setState(() {
        _status = status;
        _receiptJob = receipt;
        _job = status.latestJob ?? receipt;
        _uncertainRequestId = uncertain;
        _cancelPendingJobId = cancelling;
        _watchJobId = watching;
        _error = readError ?? (preserveNotice ? _error : null);
        _errorCode = readErrorCode ?? (preserveNotice ? _errorCode : null);
      });
    } catch (error) {
      if (!_current || sequence != _sequence) return;
      setState(() {
        _error = error is ApiException
            ? safeServerOperationText(error.message) ?? '无法读取服务器更新状态，请稍后刷新。'
            : '无法读取服务器更新状态，请稍后刷新。';
        _errorCode = error is ApiException
            ? safeServerOperationCode(error.code)
            : null;
      });
    } finally {
      if (_current && sequence == _sequence) {
        setState(() => _loading = false);
        _schedule();
        final original = _receiptJob?.requestId == _offerAfterRequestId
            ? _receiptJob
            : _job;
        if (_offerAfterRequestId != null &&
            original?.requestId == _offerAfterRequestId &&
            original?.terminal == true) {
          _offerAfterRequestId = null;
          if (original?.succeeded == true && _status?.updateAvailable == true) {
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
    if (!_canReviewUpdate ||
        _offerOpen ||
        _status?.updateAvailable != true ||
        _status?.latestVersion == null) {
      return;
    }
    final expected = _status!;
    _offerOpen = true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => ServerUpdateDialogGuard(
        child: UtenAlertDialog(
          alignment: Alignment.center,
          title: Text('发现新版本 ${expected.latestVersion}'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ServerVersionComparison(status: expected),
                const SizedBox(height: UtenSpacing.s16),
                const Text('确认后会下载并验签、备份数据，再执行迁移与健康检查。更新期间服务可能短暂中断；也可预约凌晨执行。'),
              ],
            ),
          ),
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.pop(context),
              child: const Text('暂不更新'),
            ),
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
      ),
    );
    _offerOpen = false;
    if (!_current || !_canReviewUpdate || choice == null) return;
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
        builder: (_) => ServerUpdateDialogGuard(
          child: ServerUpdateScheduleDialog(status: expected),
        ),
      );
      if (!_current || !_canReviewUpdate || preview == null) return;
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
    if (mode != 'CHECK_ONLY' && !_canReviewUpdate) return;
    if (_status?.sourceRevision != expected.sourceRevision ||
        _status?.currentVersion != expected.currentVersion ||
        (mode != 'CHECK_ONLY' && _status?.latestVersion != targetVersion)) {
      setState(() => _error = '版本或发布源状态已变化，请刷新并重新核对后再操作。');
      return;
    }
    final requestId = const Uuid().v4();
    if (mode == 'CHECK_ONLY') _offerAfterRequestId = requestId;
    setState(() {
      _starting = true;
      _error = null;
      _errorCode = null;
      _receiptJob = null;
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
      setState(() {
        _job = job;
        _receiptJob = job;
        _watchJobId = job.running ? job.id : null;
      });
    } catch (error) {
      if (!_current) return;
      final certainRejection = serverOperationDefinitelyRejected(error);
      setState(() {
        _uncertainRequestId = certainRejection ? null : requestId;
        _watchJobId = certainRejection ? null : requestId;
        if (certainRejection) _offerAfterRequestId = null;
        _error = certainRejection
            ? safeServerOperationText((error as ApiException).message) ??
                  '服务器拒绝了此次操作，请刷新状态后核对。'
            : '更新请求结果尚未确认。正在核对服务器原作业，请勿重复启动。';
        _errorCode = error is ApiException
            ? safeServerOperationCode(error.code)
            : null;
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
      _error == null &&
      _uncertainRequestId == null &&
      _cancelPendingJobId == null &&
      _job?.id == job.id &&
      _job?.state == 'SCHEDULED' &&
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
      builder: (context) => ServerUpdateDialogGuard(
        child: UtenAlertDialog(
          alignment: Alignment.center,
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
      ),
    );
    if (!_current || confirmed != true || !_canCancel(job)) return;
    setState(() {
      _starting = true;
      _error = null;
      _errorCode = null;
    });
    var refreshAfterRejection = false;
    try {
      final result = await _repository.cancel(
        job.id,
        requestId: const Uuid().v4(),
      );
      if (!_current) return;
      if (result.id != job.id) {
        throw const FormatException('Invalid cancellation receipt');
      }
      setState(() {
        _job = result;
        _receiptJob = result;
        _watchJobId = result.running ? result.id : null;
      });
    } catch (error) {
      if (!_current) return;
      final certain = serverOperationDefinitelyRejected(error);
      refreshAfterRejection = certain;
      setState(() {
        _cancelPendingJobId = certain ? null : job.id;
        _error = certain
            ? safeServerOperationText((error as ApiException).message) ??
                  '服务器拒绝取消预约，请刷新状态后核对。'
            : '取消结果尚未确认，正在核对此预约的原作业状态，不会重复提交。';
        _errorCode = error is ApiException
            ? safeServerOperationCode(error.code)
            : null;
      });
    } finally {
      if (_current) {
        setState(() => _starting = false);
        _schedule();
        if (refreshAfterRejection && _active) {
          unawaited(_load(preserveNotice: true));
        }
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
    final l = AppLocalizations.of(context);
    final status = _status;
    final canConfigureSource =
        ref.watch(serverSourceVisibleProvider) &&
        status?.available == true &&
        status?.canConfigureSource == true;
    return Scaffold(
      appBar: UtenAppBar(
        title: '服务器更新',
        showBackButton: true,
        showPagePermissionAction: false,
        actions: [
          UtenRefreshButton(
            key: const ValueKey('server-operations-refresh'),
            tooltip: l.serverUpdateRefresh,
            busy: _loading,
            enabled: allowed && !_starting,
            onRefresh: _load,
          ),
        ],
      ),
      body: !allowed
          ? const UtenEmpty(icon: Icons.lock_outline, message: '没有服务器运维查看权限')
          : SafeArea(
              child: SingleChildScrollView(
                child: UtenContentContainer(
                  selectable: false,
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ServerUpdateOverview(
                        status: status,
                        job: _job,
                        loading: _loading,
                        starting: _starting,
                        writable: ref.watch(serverOperationsWritableProvider),
                        error: _error,
                        errorCode: _errorCode,
                        receipt: _receiptJob,
                        uncertainRequestId: _uncertainRequestId,
                        onCheck: _canStart ? _start : null,
                        onReview: _canReviewUpdate ? _offerUpdate : null,
                        onRefresh: !_loading && !_starting ? _load : null,
                        onCancel: _job != null && _canCancel(_job!)
                            ? () => _cancel(_job!)
                            : null,
                      ),
                      const SizedBox(height: UtenSpacing.s24),
                      const Divider(),
                      const SizedBox(height: UtenSpacing.s12),
                      Text(
                        l.serverUpdateManagement,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      UtenResponsiveGrid(
                        itemCount: canConfigureSource ? 2 : 1,
                        maxColumns: canConfigureSource ? 2 : 1,
                        minItemWidth: 280,
                        columns: const UtenResponsiveColumns(expanded: 2),
                        itemBuilder: (_, index, _) {
                          if (index == 0 && canConfigureSource) {
                            return ServerUpdateSourceEditor(
                              key: _sourceEditorKey,
                              busy:
                                  _job?.running == true ||
                                  _receiptJob?.running == true ||
                                  _job?.recoveryRequired == true ||
                                  _receiptJob?.recoveryRequired == true ||
                                  _status?.failure?.recoveryRequired == true ||
                                  _watchJobId != null ||
                                  _uncertainRequestId != null ||
                                  _cancelPendingJobId != null ||
                                  _starting,
                              onSaved: _load,
                            );
                          }
                          return UtenCard(
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(
                                UtenSpacing.s16,
                              ),
                              leading: const Icon(Icons.storage_outlined),
                              title: Text(
                                l.serverUpdateStorage,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              subtitle: Text(
                                status?.platformUnsupported == true
                                    ? '查看数据库、附件登记与后端内存'
                                    : '查看空间占用、恢复点与可清理资源',
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () =>
                                  context.push(RouteName.adminServerStorage),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

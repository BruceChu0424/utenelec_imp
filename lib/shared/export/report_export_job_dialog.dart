import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../../components/feedback/uten_progress_dialog.dart';
import '../../components/inputs/uten_field_hint_icon.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/network/business_precision_coordinator.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/utils/china_datetime.dart';
import '../providers/export_context_epoch_provider.dart';
import 'report_export_jobs.dart';

/// One reusable task surface for the six ordinary report export adapters.
/// Polling is sequential and stops on close, failure or a reader boundary.
class ReportExportJobDialog extends ConsumerStatefulWidget {
  const ReportExportJobDialog({
    super.key,
    required this.client,
    required this.request,
    required this.store,
    required this.stillCurrent,
    required this.onDownload,
    this.canCreateNew,
  });

  final ReportExportJobsClient client;
  final ReportExportJobRequest request;
  final ReportExportPendingStore store;
  final bool Function() stillCurrent;
  final bool Function()? canCreateNew;

  /// 下载已生成的文件。在通用进度弹窗里执行: 通过 [progress] 汇报字节进度,
  /// 用户点取消时 `progress.isCancelled` 为 true, 调用方应停止传输。
  final Future<void> Function(ReportExportJob job, UtenProgressSession progress)
  onDownload;

  @override
  ConsumerState<ReportExportJobDialog> createState() =>
      _ReportExportJobDialogState();
}

class _ReportExportJobDialogState extends ConsumerState<ReportExportJobDialog> {
  bool get _canCreateNew => _current && (widget.canCreateNew?.call() ?? true);
  Timer? _poll;
  ReportExportJobRequest? _unresolved;
  ReportExportPrecisionResume? _unresolvedPrecision;
  ReportExportJob? _job;
  List<ReportExportJob> _recent = const [];
  bool _busy = false;
  bool _previousTask = false;
  bool _showWait = false;
  String _waitTitle = '正在处理导出任务';
  bool _retired = false;
  String? _error;
  int _generation = 0;
  final _actionScopeKey = Object();

  bool _sameStore(ReportExportPendingStore a, ReportExportPendingStore b) =>
      a.key == b.key && identical(a.preferences, b.preferences);

  bool get _current {
    final actionCurrent = Zone.current[_actionScopeKey];
    return mounted &&
        !_retired &&
        widget.stillCurrent() &&
        (actionCurrent is! bool Function() || actionCurrent());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void dispose() {
    _generation++;
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReportExportJobDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client) ||
        !_sameStore(oldWidget.store, widget.store) ||
        !identical(oldWidget.request, widget.request) ||
        oldWidget.stillCurrent != widget.stillCurrent) {
      // A different owner must reopen explicitly; an old operation cannot
      // silently become a new actor's create or download.
      _retire();
    }
  }

  void _retire() {
    _poll?.cancel();
    _generation++;
    if (!mounted || _retired) return;
    setState(() {
      _retired = true;
      _job = null;
      _recent = const [];
      _unresolved = null;
      _unresolvedPrecision = null;
      _busy = false;
      _showWait = false;
      _error = '账号、权限或服务器已变化，请关闭后重新打开导出';
    });
  }

  Future<void> _perform(
    Future<void> Function() action, {
    bool showWait = true,
    String title = '正在处理导出任务',
  }) async {
    if (!_current || _busy) return;
    final generation = ++_generation;
    final owner = widget;
    bool current() =>
        mounted &&
        !_retired &&
        generation == _generation &&
        identical(owner.client, widget.client) &&
        _sameStore(owner.store, widget.store) &&
        identical(owner.request, widget.request) &&
        owner.stillCurrent == widget.stillCurrent &&
        owner.stillCurrent();
    _poll?.cancel();
    setState(() {
      _busy = true;
      _showWait = showWait;
      _waitTitle = title;
      _error = null;
    });
    try {
      if (showWait) {
        // Mount the existing modal's busy portal, then paint its root entry.
        await WidgetsBinding.instance.endOfFrame;
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!current()) return;
      await runZoned<Future<void>>(
        action,
        zoneValues: {_actionScopeKey: current},
      );
    } catch (error) {
      if (!current()) return;
      if (error is ApiException &&
          ({401, 403}.contains(error.httpStatus) ||
              isSessionBoundaryError(error))) {
        _retire();
        return;
      }
      if (current()) {
        setState(() {
          _error = error is ApiException ? error.message : '任务状态暂时无法确认，请核查原任务';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        if (current()) {
          setState(() {
            _busy = false;
            _showWait = false;
          });
        } else {
          _retire();
        }
      }
    }
  }

  Future<void> _restore() => _perform(() async {
    final precision = widget.store.readPrecisionResume();
    if (precision != null) {
      _previousTask = true;
      _unresolvedPrecision = precision;
      await _verifyPrecisionReceipt();
      return;
    }
    final pending = widget.store.read();
    if (pending != null) {
      _previousTask = true;
      _unresolved = pending;
      await _accept(await widget.client.read(pending.id));
      return;
    }
    final recent = await widget.client.recent();
    if (!_current) return;
    _recent = recent
        .where(
          (job) =>
              job.domain == widget.request.domain &&
              job.report == widget.request.report &&
              job.format == widget.request.format,
        )
        .toList(growable: false);
    if (_recent.isEmpty && _canCreateNew) {
      await _create(widget.request, currentScope: true);
    } else if (_recent.isEmpty) {
      setState(() => _error = '当前账号没有可恢复的同类任务；重新读取完整结果后可新建导出');
    }
  }, title: '正在恢复导出任务');

  Future<void> _create(
    ReportExportJobRequest request, {
    bool currentScope = false,
  }) async {
    if (!_current || currentScope && !_canCreateNew) return;
    // Retain the original request before sending. A lost receipt must never
    // turn into a fresh ID on retry, dialog reopen or application reload.
    await widget.store.save(request);
    if (!_current) {
      if (currentScope) await widget.store.resolve(request.id);
      return;
    }
    if (currentScope && !_canCreateNew) {
      await widget.store.resolve(request.id);
      throw ApiException(
        'OUTPUT_RESULT_RETIRED',
        '完整结果已退休，新任务尚未发送；请重新读取，原任务仍保留',
      );
    }
    // New jobs keep the complete-result fence through identity verification
    // and the actual HTTP command. Original retries keep their frozen owner
    // scope and ID even after a replacement list has been retired.
    final client = currentScope
        ? ReportExportJobsClient(
            widget.client.api,
            await widget.client.api.captureRequestScope(
              isCurrent: () => _canCreateNew,
            ),
          )
        : widget.client;
    if (client.scope.identity != widget.client.scope.identity) {
      throw AuthenticatedRequestScope.changed();
    }
    _unresolved = request;
    _job = null;
    _recent = const [];
    if (currentScope) _previousTask = false;
    await _accept(await client.create(request));
  }

  Future<void> _accept(
    ReportExportJob job, {
    bool precisionConfirmed = false,
  }) async {
    if (!_current) return;
    if (precisionConfirmed && _unresolvedPrecision != null) {
      await widget.store.resolvePrecisionResume(
        _unresolvedPrecision!.requestId,
      );
      if (!_current) {
        return;
      }
      _unresolvedPrecision = null;
    }
    await widget.store.resolve(job.id);
    if (!_current) return;
    _unresolved = null;
    _job = job;
    _recent = const [];
    if (job.active) {
      _poll = Timer(const Duration(seconds: 1), () {
        if (!_current) {
          if (mounted) _retire();
          return;
        }
        _verify(automatic: true);
      });
    }
  }

  Future<void> _verify({bool automatic = false}) => _perform(
    () async {
      if (_unresolvedPrecision != null) {
        await _verifyPrecisionReceipt();
        return;
      }
      final id = _unresolved?.id ?? _job?.id;
      if (id != null) await _accept(await widget.client.read(id));
    },
    showWait: !automatic,
    title: '正在核查导出任务',
  );
  Future<void> _verifyPrecisionReceipt() async {
    final request = _unresolvedPrecision;
    if (request == null) {
      return;
    }
    final receipt = await widget.client.precisionReceipt(request);
    if (!_current) {
      return;
    }
    if (receipt != null) {
      await _accept(receipt, precisionConfirmed: true);
    } else {
      await _accept(await widget.client.read(request.jobId));
    }
  }

  Future<void> _sendPrecision(
    ReportExportPrecisionResume request, {
    required bool retry,
  }) async {
    await widget.store.savePrecisionResume(request);
    if (!_current) {
      return;
    }
    _unresolvedPrecision = request;
    try {
      await _accept(
        await widget.client.resumePrecision(request),
        precisionConfirmed: true,
      );
    } on ApiException catch (error) {
      if (_current &&
          !retry &&
          error.hasResponseCode &&
          (error.httpStatus == 400 ||
              error.httpStatus == 422 ||
              error.httpStatus == 409 && error.code == 'CONFLICT')) {
        await widget.store.resolvePrecisionResume(request.requestId);
        if (!_current) return;
        _unresolvedPrecision = null;
      }
      rethrow;
    }
  }

  Future<void> _choosePrecision() => _perform(() async {
    final job = _job, required = _job?.precisionRequirement;
    if (job == null ||
        required == null ||
        !job.awaitingPrecision ||
        (job.precisionChoices.length >= 32 &&
            !job.precisionChoices.containsKey(required.key))) {
      if (job != null && job.precisionChoices.length >= 32) {
        setState(() => _error = '本任务已保留32组本次选择，无法再新增；原任务与选择仍保留，请保留任务编号核对');
      }
      return;
    }
    if (job.precisionChoices.containsKey(required.key) &&
        !required.selectionRejected) {
      throw StateError('本项原精度仍待核对，请核查原任务，不循环重新选择');
    }
    final choice = await BusinessPrecisionCoordinator.instance.ask(
      required,
      isCurrent: () => _current,
    );
    if (!_current || choice == null) {
      return;
    }
    await _sendPrecision(
      ReportExportPrecisionResume.create(job, choice),
      retry: false,
    );
  }, title: '正在处理精度请求');

  Future<void> _newExport() => _perform(() async {
    if (!_canCreateNew) return;
    final request = ReportExportJobRequest.fromJson({
      ...widget.request.json,
      'id': const Uuid().v4(),
    });
    await _create(request, currentScope: true);
  }, title: '正在创建导出任务');

  Future<void> _download() => _perform(
    () async {
      final job = _job;
      if (job == null || !job.downloadable) return;
      // 文件下载用通用进度弹窗显示字节进度(总量=任务文件大小), 可取消;
      // 取消只是不再接收, 原任务文件仍在, 可以再次下载。
      final finished = await showUtenProgress<bool>(
        context,
        title: '正在下载导出文件',
        icon: Icons.file_download_outlined,
        initialStatus: '正在下载文件',
        initialDetail: job.bytes > 0 ? formatUtenBytes(job.bytes) : null,
        isCurrent: () => mounted && _current,
        action: (progress) async {
          await widget.onDownload(job, progress);
          return !progress.isCancelled;
        },
      );
      if (finished == true && mounted && _current) Navigator.of(context).pop();
    },
    // 进度弹窗自带遮罩与取消, 不再叠加转圈遮罩。
    showWait: false,
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(exportContextEpochProvider, (previous, next) {
      if (previous != next) _retire();
    });
    final job = _job;
    final unresolved = _unresolved;
    final unresolvedPrecision = _unresolvedPrecision;
    final scheme = Theme.of(context).colorScheme;
    final info = [
      if (_previousTask)
        '原任务仍按当时的范围生成，下载不会改成本次刚选择的范围。需要本次范围时，核对原任务后使用「按当前筛选新建」。',
      if (job?.active == true) '可稍后回来查看；关闭窗口不会取消任务。',
      if (job?.awaitingPrecision == true)
        '尚未生成可下载文件。选择后按原任务、原筛选重新读取，会使用新的读取时点。',
      if (unresolvedPrecision != null) '原精度续处理结果尚未确认，请核查原回执或原样重试，不再次选择。',
      if (unresolved != null) '上次创建结果尚未确认，请先核查原任务。',
    ].join('\n\n');
    return Stack(
      children: [
        UtenAlertDialog(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(_previousTask ? '原导出任务' : '报表导出任务')),
              if (info.isNotEmpty) ...[
                const SizedBox(width: UtenSpacing.s4),
                UtenFieldHintIcon(info: info),
              ],
            ],
          ),
          showCloseButton: true,
          onClose: () => Navigator.of(context).pop(),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (job?.active == true) ...[
                // 全项目统一进度条(样式单点维护); 总数已知显示真实进度, 否则扫动。
                UtenProgressBar(value: job!.progressFraction),
                const SizedBox(height: UtenSpacing.s16),
              ],
              if (job != null) ...[
                Text(
                  job.progressFraction == null
                      ? job.statusLabel
                      : '${job.statusLabel} ${(job.progressFraction! * 100).round()}%',
                  key: const ValueKey('report-export-job-status'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  job.totalRows == null
                      ? '已处理 ${job.rows} 行'
                      : '已处理 ${job.rows} / ${job.totalRows} 行',
                ),
                if (job.snapshotAt != null)
                  Text(
                    '数据快照：${ChinaDateTime.formatIsoInstant(job.snapshotAt!)}',
                  ),
                if (job.error?.isNotEmpty == true)
                  Text(job.error!, style: TextStyle(color: scheme.error)),
                if (job.awaitingPrecision) const Text('文件状态：尚未生成可下载文件'),
              ] else if (unresolved != null) ...[
                const Text('上次创建结果尚未确认'),
                const SizedBox(height: UtenSpacing.s8),
                SelectableText('任务编号：${unresolved.id}'),
              ] else if (_recent.isNotEmpty) ...[
                const Text('最近的同类导出任务'),
                const SizedBox(height: UtenSpacing.s8),
                for (final recent in _recent.take(10))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${recent.statusLabel} · ${recent.rows} 行'),
                    subtitle: recent.createdAt == null
                        ? null
                        : Text(
                            ChinaDateTime.formatIsoInstant(recent.createdAt!),
                          ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy
                        ? null
                        : () => _perform(() async {
                            _previousTask = true;
                            await _accept(await widget.client.read(recent.id));
                          }, title: '正在核查导出任务'),
                  ),
              ],
              if (unresolvedPrecision != null) const Text('原精度续处理结果尚未确认'),
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
          actions: [
            if (!_retired && (job != null || unresolved != null))
              UtenButton(
                type: UtenButtonType.tonal,
                onPressed: _busy ? null : _verify,
                child: const Text('核查任务'),
              ),
            if (!_retired && unresolved != null)
              UtenButton(
                onPressed: _busy
                    ? null
                    : () => _perform(() => _create(unresolved)),
                child: const Text('按原编号重试'),
              ),
            if (!_retired && unresolvedPrecision != null)
              UtenButton(
                onPressed: _busy
                    ? null
                    : () => _perform(
                        () => _sendPrecision(unresolvedPrecision, retry: true),
                        title: '正在核对原精度请求',
                      ),
                child: const Text('重试原精度请求'),
              ),
            if (!_retired &&
                unresolvedPrecision == null &&
                job?.awaitingPrecision == true &&
                job?.precisionRequirement != null)
              UtenButton(
                onPressed: _busy ? null : _choosePrecision,
                child: const Text('选择精度并继续原任务'),
              ),
            if (!_retired &&
                unresolvedPrecision == null &&
                job != null &&
                (job.active || job.awaitingPrecision) &&
                !job.cancelRequested)
              UtenButton(
                type: UtenButtonType.tonal,
                onPressed: _busy
                    ? null
                    : () => _perform(
                        () async => _accept(await widget.client.cancel(job.id)),
                        title: '正在取消导出任务',
                      ),
                child: const Text('取消任务'),
              ),
            if (!_retired && job?.downloadable == true)
              UtenButton(
                onPressed: _busy ? null : _download,
                child: const Text('下载文件'),
              ),
            if (!_retired &&
                unresolved == null &&
                unresolvedPrecision == null &&
                job?.active != true)
              UtenButton(
                type: UtenButtonType.tonal,
                onPressed: _busy || !_canCreateNew ? null : _newExport,
                child: const Text('按当前筛选新建'),
              ),
          ],
        ),
        if (_busy && _showWait && !_retired)
          UtenBusyOverlay(title: _waitTitle, showDoNotLeaveHint: false),
      ],
    );
  }
}

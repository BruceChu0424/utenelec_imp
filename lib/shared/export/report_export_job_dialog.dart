import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
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
  });

  final ReportExportJobsClient client;
  final ReportExportJobRequest request;
  final ReportExportPendingStore store;
  final bool Function() stillCurrent;
  final Future<void> Function(ReportExportJob job) onDownload;

  @override
  ConsumerState<ReportExportJobDialog> createState() =>
      _ReportExportJobDialogState();
}

class _ReportExportJobDialogState extends ConsumerState<ReportExportJobDialog> {
  Timer? _poll;
  ReportExportJobRequest? _unresolved;
  ReportExportPrecisionResume? _unresolvedPrecision;
  ReportExportJob? _job;
  List<ReportExportJob> _recent = const [];
  bool _busy = false;
  bool _retired = false;
  String? _error;

  bool get _current => mounted && !_retired && widget.stillCurrent();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _retire() {
    _poll?.cancel();
    if (!mounted) return;
    setState(() {
      _retired = true;
      _job = null;
      _recent = const [];
      _unresolved = null;
      _unresolvedPrecision = null;
      _busy = false;
      _error = '账号、权限或服务器已变化，请关闭后重新打开导出';
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (!_current || _busy) return;
    _poll?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (error is ApiException &&
          ({401, 403}.contains(error.httpStatus) ||
              isSessionBoundaryError(error))) {
        _retire();
        return;
      }
      if (_current) {
        setState(() {
          _error = error is ApiException ? error.message : '任务状态暂时无法确认，请核查原任务';
        });
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      } else if (mounted) {
        _retire();
      }
    }
  }

  Future<void> _restore() => _perform(() async {
    final precision = widget.store.readPrecisionResume();
    if (precision != null) {
      _unresolvedPrecision = precision;
      await _verifyPrecisionReceipt();
      return;
    }
    final pending = widget.store.read();
    if (pending != null) {
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
    if (_recent.isEmpty) await _create(widget.request);
  });

  Future<void> _create(ReportExportJobRequest request) async {
    if (!_current) return;
    // Retain the original request before sending. A lost receipt must never
    // turn into a fresh ID on retry, dialog reopen or application reload.
    await widget.store.save(request);
    if (!_current) return;
    _unresolved = request;
    await _accept(await widget.client.create(request));
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
        _verify();
      });
    }
  }

  Future<void> _verify() => _perform(() async {
    if (_unresolvedPrecision != null) {
      await _verifyPrecisionReceipt();
      return;
    }
    final id = _unresolved?.id ?? _job?.id;
    if (id != null) await _accept(await widget.client.read(id));
  });
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
      if (!retry &&
          error.hasResponseCode &&
          (error.httpStatus == 400 ||
              error.httpStatus == 422 ||
              error.httpStatus == 409 && error.code == 'CONFLICT')) {
        await widget.store.resolvePrecisionResume(request.requestId);
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
  });

  Future<void> _newExport() => _perform(() async {
    final request = ReportExportJobRequest.fromJson({
      ...widget.request.json,
      'id': const Uuid().v4(),
    });
    await _create(request);
  });

  Future<void> _download() => _perform(() async {
    final job = _job;
    if (job == null || !job.downloadable) return;
    await widget.onDownload(job);
    if (mounted && _current) Navigator.of(context).pop();
  });

  @override
  Widget build(BuildContext context) {
    ref.listen(exportContextEpochProvider, (previous, next) {
      if (previous != next) _retire();
    });
    final job = _job;
    final unresolved = _unresolved;
    final unresolvedPrecision = _unresolvedPrecision;
    final scheme = Theme.of(context).colorScheme;
    return UtenAlertDialog(
      title: const Text('报表导出任务'),
      showCloseButton: true,
      onClose: () => Navigator.of(context).pop(),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_busy || job?.active == true) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: UtenSpacing.s16),
          ],
          if (job != null) ...[
            Text(
              job.statusLabel,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text('已处理 ${job.rows} 行'),
            if (job.snapshotAt != null)
              Text('数据快照：${ChinaDateTime.formatIsoInstant(job.snapshotAt!)}'),
            if (job.error?.isNotEmpty == true)
              Text(job.error!, style: TextStyle(color: scheme.error)),
            if (job.active) const Text('可稍后回来查看；关闭窗口不会取消任务。'),
            if (job.awaitingPrecision)
              const Text('尚未生成可下载文件。选择后按原任务、原筛选重新读取，会使用新的读取时点。'),
            if (unresolvedPrecision != null)
              const Text('原精度续处理结果尚未确认，请核查原回执或原样重试，不再次选择。'),
          ] else if (unresolved != null) ...[
            const Text('上次创建结果尚未确认，请先核查原任务。'),
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
                    : Text(ChinaDateTime.formatIsoInstant(recent.createdAt!)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy
                    ? null
                    : () => _perform(
                        () async =>
                            _accept(await widget.client.read(recent.id)),
                      ),
              ),
          ],
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
            onPressed: _busy ? null : () => _perform(() => _create(unresolved)),
            child: const Text('按原编号重试'),
          ),
        if (!_retired && unresolvedPrecision != null)
          UtenButton(
            onPressed: _busy
                ? null
                : () => _perform(
                    () => _sendPrecision(unresolvedPrecision, retry: true),
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
            onPressed: _busy ? null : _newExport,
            child: const Text('按当前筛选新建'),
          ),
      ],
    );
  }
}

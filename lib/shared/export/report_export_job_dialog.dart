import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/authenticated_request_scope.dart';
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

  Future<void> _accept(ReportExportJob job) async {
    if (!_current) return;
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
    final id = _unresolved?.id ?? _job?.id;
    if (id != null) await _accept(await widget.client.read(id));
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
        if (!_retired && job != null && job.active && !job.cancelRequested)
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
        if (!_retired && unresolved == null && job?.active != true)
          UtenButton(
            type: UtenButtonType.tonal,
            onPressed: _busy ? null : _newExport,
            child: const Text('按当前筛选新建'),
          ),
      ],
    );
  }
}

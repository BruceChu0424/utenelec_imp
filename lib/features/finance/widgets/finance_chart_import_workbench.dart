import '../shared/finance_complete_summary_read.dart';
import 'finance_summary_scope_field.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_dialog_modules.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/performance/responsive_data_codec.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../shared/finance_original_command.dart';
import '../shared/finance_workbench_panel.dart';
import 'finance_entry_file_picker.dart';

List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) Map<String, dynamic>.from(row),
];
bool _importId(Object? value) =>
    value is String && Uuid.isValidUUIDFormat(fromString: value);

Future<bool> showFinanceChartImportWorkbench(
  BuildContext context, {
  String? resumeDraftId,
}) async =>
    await showFinanceWorkbenchPanel<bool>(
      context: context,
      builder: (_) => FinanceChartImportWorkbench(resumeDraftId: resumeDraftId),
    ) ??
    false;

/// Only opaque server previews and the original upload identity are durable.
/// Workbook bytes and parsed source rows never enter the local form draft.
class FinanceChartImportWorkbench extends ConsumerStatefulWidget {
  const FinanceChartImportWorkbench({this.resumeDraftId, super.key});
  final String? resumeDraftId;
  @override
  ConsumerState<FinanceChartImportWorkbench> createState() =>
      _ChartImportState();
}

class _ChartImportState extends ConsumerState<FinanceChartImportWorkbench>
    with FormDraftMixin<FinanceChartImportWorkbench> {
  bool _ready = false, _busy = false, _menuOpen = false, _changed = false;
  Map<String, dynamic>? _upload, _preview, _pending, _retired;
  String? _previewId, _error;
  List<Map<String, dynamic>> _recent = [];
  FinanceSummaryScope _recentScope = FinanceSummaryScope.active;
  int _recentRead = 0;
  int _epoch = 0;
  bool get _canRead =>
      ref.read(authenticatedScopeProvider) != null &&
      const {
        Perm.financeReportView,
        Perm.financeViewAll,
      }.every(ref.read(currentPermissionsProvider).contains);
  bool get _canWrite =>
      _canRead &&
      financeOriginalIdentityCanMutate(ref.read(authenticatedScopeProvider)) &&
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit);
  bool get _current => mounted && formDraftIdentityIsCurrent && _canRead;
  bool get _financialPending => _pending != null;
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _busy || _menuOpen;
  @override
  bool get formDraftCanReplaySubmission => _financialPending;
  @override
  bool get formDraftRequiresOriginalReceipt => _financialPending;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.financeChartImport.spec();
  @override
  Object formDraftReadBoundaryIdentity(SensitiveReadBoundary value) =>
      SensitiveReadBoundary(
        identity: value.identity,
        api: value.api,
        permissions: {...value.permissions}..remove(Perm.paymentStyleEdit),
        superAdmin: value.superAdmin,
      );
  @override
  Map<String, dynamic> captureFormDraft() => {
    'schema': 1,
    'upload': _upload,
    'previewId': _previewId,
    'pending': _pending,
    'retired': _retired,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['schema'] != 1 ||
        data['previewId'] != null && !_importId(data['previewId'])) {
      throw const FormatException('原科目预览身份不完整，草稿继续保留');
    }
    final upload = data['upload'] is Map
        ? Map<String, dynamic>.from(data['upload'] as Map)
        : null;
    if (upload != null &&
        (upload['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(upload['sha256'] as String) ||
            upload['sourceName'] is! String ||
            (upload['sourceName'] as String).isEmpty ||
            upload['storageSize'] is! int ||
            (upload['storageSize'] as int) <= 0 ||
            (upload['storageSize'] as int) > 15 * 1024 * 1024)) {
      throw const FormatException('原上传的校验、文件名或大小不完整');
    }
    _upload = upload;
    _previewId = data['previewId'] as String?;
    _pending = data['pending'] is Map
        ? Map<String, dynamic>.from(data['pending'] as Map)
        : null;
    _retired = data['retired'] is Map
        ? Map<String, dynamic>.from(data['retired'] as Map)
        : null;
    if (_pending != null) {
      _command(_pending!);
      if (_pending!['sourceId'] != _previewId) {
        throw const FormatException('原命令与预览目标不一致');
      }
    }
    if (_retired != null) {
      final command = _retired!['command'], receipt = _retired!['receipt'];
      if (command is! Map ||
          receipt is! Map ||
          receipt['outcome'] != 'CANCELLED_UNWRITTEN') {
        throw const FormatException('原导入停止凭据不完整');
      }
      _command(
        Map<String, dynamic>.from(command),
      ).verify(Map<String, dynamic>.from(receipt));
    }
  }

  FinanceOriginalCommand _command(Map<String, dynamic> value) {
    final apply = value['operation'] == 'CHART_IMPORT_APPLY';
    final source = value['sourceId'], body = value['body'];
    if (!const {
          'CHART_IMPORT_APPLY',
          'CHART_IMPORT_REPREVIEW',
        }.contains(value['operation']) ||
        !_importId(source) ||
        !_importId(value['sourceImportId']) ||
        value['sourceSha'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sourceSha'] as String) ||
        value['actorId'] != ref.read(authenticatedScopeProvider)?.userId ||
        body is! Map ||
        body.length != 1 ||
        apply && body['importId'] != source ||
        !apply &&
            (body['requestId'] is! String ||
                !Uuid.isValidUUID(fromString: body['requestId'] as String))) {
      throw const FormatException('原导入请求、账号或预览身份不完整');
    }
    return FinanceOriginalCommand(
      actorId: value['actorId'] as String,
      operation: value['operation'] as String,
      method: 'POST',
      path: apply
          ? '/finance/chart/import-apply'
          : '/finance/chart/imports/$source/repreview',
      identityField: apply ? 'importId' : 'requestId',
      opaqueIdentity: apply,
      body: Map<String, dynamic>.from(body),
    );
  }

  String _receiptPath(Map<String, dynamic> value) {
    final command = _command(value);
    return value['operation'] == 'CHART_IMPORT_APPLY'
        ? '/finance/chart/imports/${value['sourceId']}/operations/apply'
        : '/finance/chart/operations/${command.requestId}';
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_initialize()),
    );
  }

  Future<void> _initialize() async {
    if (!_canRead) {
      return;
    }
    await initializeFormDraft();
    if (!_current) {
      return;
    }
    setState(() => _ready = true);
    if (formDraftRestorationBlocked) {
      return;
    }
    if (_previewId != null) {
      await _loadPreview(_previewId!);
    } else if (_upload != null) {
      await _findUpload();
    } else {
      await _loadRecent();
      if (_current && _canWrite && widget.resumeDraftId == null) {
        await _pick();
      }
    }
  }

  Future<({AuthenticatedRequestScope scope, T result})?> _wait<T>(
    String title,
    Future<T> Function(ApiClient api, AuthenticatedRequestScope scope) action,
  ) => UtenBusyOverlay.run<({AuthenticatedRequestScope scope, T result})?>(
    context,
    title: title,
    action: () async {
      final scope = await captureFormDraftRequestScope();
      if (!_current || !scope.isCurrent) {
        return null;
      }
      final result = await scope.run(
        () => action(ref.read(apiClientProvider), scope),
      );
      if (!_current || !scope.isCurrent) {
        return null;
      }
      return (scope: scope, result: result);
    },
  );
  Future<void> _loadRecent() async {
    if (!_current || _busy) return;
    final generation = ++_recentRead, range = _recentScope;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await _wait(
        '正在读取原导入批次',
        (api, scope) => readCompleteFinanceSummaries(
          isCurrent: () =>
              _current &&
              scope.isCurrent &&
              generation == _recentRead &&
              range == _recentScope,
          idOf: (row) => row['importId'],
          loadPage: (page, size, revision) => api.get(
            '/finance/chart/imports/summaries',
            query: {
              'scope': range.name,
              'page': page,
              'size': size,
              'readSnapshotRevision': ?revision,
            },
          ),
        ),
      );
      if (value != null &&
          _current &&
          generation == _recentRead &&
          range == _recentScope) {
        setState(() => _recent = value.result);
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted && generation == _recentRead) setState(() => _busy = false);
    }
  }

  Future<void> _changeRecentScope(FinanceSummaryScope value) async {
    if (!_current ||
        _busy ||
        _financialPending ||
        _upload != null ||
        _previewId != null ||
        value == _recentScope) {
      return;
    }
    setState(() {
      _recentScope = value;
      _recent = [];
    });
    await _loadRecent();
  }

  Map<String, dynamic> _checkedPreview(Map<String, dynamic> value, String id) {
    if (value['importId'] != id ||
        value['sourceName'] is! String ||
        value['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sha256'] as String) ||
        value['rows'] is! List ||
        value['issues'] is! List ||
        value['applied'] is! bool ||
        value['cancelled'] is! bool ||
        !_importId(value['sourceImportId']) ||
        value['parentImportId'] != null &&
            !_importId(value['parentImportId'])) {
      throw const FormatException('原预览资料不完整，不按当前目录推定原结果');
    }
    return value;
  }

  Future<void> _loadPreview(String id) async {
    if (!_current ||
        _busy ||
        !_importId(id) ||
        _previewId != null && _previewId != id ||
        _pending != null && _pending!['sourceId'] != id) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await _wait(
        '正在读取原科目预览',
        (api, _) => api.get('/finance/chart/imports/$id'),
      );
      if (value == null || !_current) {
        return;
      }
      final preview = _checkedPreview(value.result, id);
      if (_upload != null && _upload!['sha256'] != preview['sha256']) {
        throw const FormatException('原文件校验与预览不一致');
      }
      setState(() {
        _previewId = id;
        _preview = preview;
      });
      await saveFormDraftNow();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _findUpload() async {
    if (!_current || _busy || _upload == null || _pending != null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? found;
    try {
      final value = await _wait(
        '正在核对原文件上传结果',
        (api, _) =>
            api.get('/finance/chart/imports/by-sha/${_upload!['sha256']}'),
      );
      if (value == null || !_current) {
        return;
      }
      final row = value.result;
      if (row['found'] != true) {
        setState(() => _error = '尚未找到原私有预览，不能据此认定未上传。可稍后核对，或重新选择同一文件核对。');
      } else {
        if (!_importId(row['importId']) ||
            row['sha256'] != _upload!['sha256'] ||
            row['sourceName'] is! String ||
            (row['sourceName'] as String).isEmpty ||
            row['storageSize'] != _upload!['storageSize']) {
          throw const FormatException('原上传的大小或字节校验不一致');
        }
        found = row['importId'] as String;
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (found != null && _current) {
      await _loadPreview(found);
    }
  }

  Future<void> _pick() async {
    if (!_ready ||
        !_current ||
        _busy ||
        _menuOpen ||
        !_canWrite ||
        _pending != null ||
        _previewId != null) {
      return;
    }
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await _wait('正在准备科目目录文件', (api, scope) async {
        final file = await UtenBusyOverlay.yieldWhile(
          () => ref.read(financeEntryFilePickerProvider)(),
        );
        if (!_current || !scope.isCurrent || epoch != _epoch || file == null) {
          return null;
        }
        final ext = file.extension?.toLowerCase(), bytes = file.bytes;
        if (ext != 'xls' && ext != 'xlsx' ||
            bytes == null ||
            bytes.isEmpty ||
            bytes.length > 15 * 1024 * 1024) {
          throw const FormatException('请选择完整且不超过15MB的XLS或XLSX科目目录');
        }
        final sha = await sha256HexResponsive(
          bytes,
          isCurrent: () => _current && scope.isCurrent && epoch == _epoch,
        );
        final identity = {
          'sha256': sha,
          'sourceName': file.name,
          'storageSize': bytes.length,
        };
        if (_upload != null &&
            (_upload!['sha256'] != sha ||
                _upload!['storageSize'] != bytes.length)) {
          throw const FormatException('请重新选择原文件，不能用另一份文件替换待核上传');
        }
        if (!_current || !scope.isCurrent) {
          return null;
        }
        _upload ??= identity;
        await saveFormDraftNow();
        if (!_current || !scope.isCurrent) {
          return null;
        }
        return api.postMultipartFile(
          '/finance/chart/import-preview',
          bytes,
          _upload!['sourceName'] as String,
          ext == 'xls'
              ? 'application/vnd.ms-excel'
              : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
      });
      if (value == null || value.result == null || !_current) {
        return;
      }
      final preview = value.result!;
      if (!_importId(preview['importId'])) {
        throw const FormatException('上传回执缺少原预览编号');
      }
      final checked = _checkedPreview(preview, preview['importId'] as String);
      if (checked['sha256'] != _upload!['sha256']) {
        throw const FormatException('上传回执与原文件字节校验不一致');
      }
      setState(() {
        _previewId = checked['importId'] as String;
        _preview = checked;
      });
      await saveFormDraftNow();
    } catch (error) {
      _showError(error, '上传结果仍待核对，原文件校验、名称和大小已保留');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _send({
    required bool repreview,
    String? viewedId,
    String? originalRequestId,
  }) async {
    if (!_ready ||
        !_current ||
        _busy ||
        _menuOpen ||
        !_canWrite ||
        _previewId == null) {
      return;
    }
    if (viewedId != null && viewedId != _previewId ||
        originalRequestId != null &&
            (_pending == null ||
                _command(_pending!).requestId != originalRequestId)) {
      return;
    }
    if (_pending != null &&
        (_pending!['operation'] == 'CHART_IMPORT_REPREVIEW') != repreview) {
      return;
    }
    if (_pending == null &&
        (_preview == null ||
            !repreview &&
                (_preview!['applied'] == true ||
                    _preview!['cancelled'] == true ||
                    _maps(_preview!['issues']).isNotEmpty ||
                    _retired != null))) {
      return;
    }
    final hadPending = _pending != null;
    final previousId = _previewId;
    bool dispatched = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _pending ??= {
        'operation': repreview
            ? 'CHART_IMPORT_REPREVIEW'
            : 'CHART_IMPORT_APPLY',
        'actorId': ref.read(authenticatedScopeProvider)!.userId,
        'sourceId': _previewId,
        'sourceSha': _preview!['sha256'],
        'sourceImportId': _preview!['sourceImportId'],
        'body': repreview
            ? {'requestId': const Uuid().v4()}
            : {'importId': _previewId},
      };
      final command = _command(_pending!);
      final value = await _wait(repreview ? '正在按当前版本重新预览' : '正在确认原科目目录导入', (
        api,
        scope,
      ) async {
        final receipt = await runFormDraftSubmission(() async {
          dispatched = true;
          return api.post(command.path, body: command.body);
        }, isDefiniteRejection: (_) => false);
        if (!_current || !scope.isCurrent) return false;
        return _accept(receipt);
      });
      if (value?.result == true && mounted && _current) {
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (!dispatched && !hadPending) {
        _pending = null;
        await releaseFormDraftBeforeDispatch();
      } else {
        try {
          await saveFormDraftNow();
        } catch (_) {}
      }
      _showError(error, '原操作结果待核对，请保留原请求');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (_current &&
        _pending == null &&
        _previewId != null &&
        _previewId != previousId) {
      await _loadPreview(_previewId!);
    }
  }

  Future<bool> _accept(Map<String, dynamic> receipt) async {
    final pending = _pending!, command = _command(pending);
    command.verify(receipt);
    if (receipt['outcome'] == 'CANCELLED_UNWRITTEN') {
      _retired = {'command': pending, 'receipt': receipt};
      _pending = null;
      await checkpointFormDraftAfterConfirmedMutation(
        originalReceiptAcknowledged: true,
      );
      if (_current) {
        setState(() {});
      }
      return false;
    }
    final result = receipt['result'];
    final apply = pending['operation'] == 'CHART_IMPORT_APPLY';
    if (result is! Map ||
        apply &&
            (result['importId'] != pending['sourceId'] ||
                result['status'] != 'APPLIED' ||
                result['imported'] is! int ||
                (result['imported'] as int) < 0) ||
        !apply &&
            (result['requestId'] != command.requestId ||
                result['parentImportId'] != pending['sourceId'] ||
                !_importId(result['importId']) ||
                result['importId'] == pending['sourceId'] ||
                !_importId(result['sourceImportId']) ||
                result['sha256'] != pending['sourceSha'] ||
                result['sourceImportId'] != pending['sourceImportId'] ||
                result['status'] != 'PREVIEWED')) {
      throw const FormatException('原导入回执与目标或文件依据不一致，继续保留原请求');
    }
    if (apply) {
      _changed = true;
      await completeFormDraft();
      return true;
    } else {
      _previewId = result['importId'] as String;
      _pending = null;
      _retired = null;
      _preview = null;
      await checkpointFormDraftAfterConfirmedMutation(
        originalReceiptAcknowledged: true,
      );
      if (_current) {
        setState(() {});
      }
      return false;
    }
  }

  Future<void> _recover(bool cancel) async {
    if (!_ready ||
        !_current ||
        _busy ||
        _pending == null ||
        cancel &&
            !financeOriginalIdentityCanMutate(
              ref.read(authenticatedScopeProvider),
            )) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final previousId = _previewId;
    try {
      final command = _command(_pending!);
      final value = await _wait(cancel ? '正在核实原导入是否写入' : '正在核对原导入回执', (
        api,
        scope,
      ) async {
        final receipt = await (cancel
            ? command.cancelUnwrittenResponsive(
                api,
                _receiptPath(_pending!),
                isCurrent: () => _current && scope.isCurrent,
              )
            : command.readReceiptResponsive(
                api,
                _receiptPath(_pending!),
                isCurrent: () => _current && scope.isCurrent,
              ));
        if (!_current || !scope.isCurrent || receipt['found'] != true) {
          return (found: receipt['found'] == true, close: false);
        }
        return (found: true, close: await _accept(receipt));
      });
      if (value == null || !_current) {
        return;
      }
      if (!value.result.found) {
        setState(() => _error = '尚未取得原操作回执，不能认定未写入，原请求继续保留。');
        return;
      }
      if (value.result.close && mounted && _current) {
        Navigator.pop(context, true);
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (_current &&
        _pending == null &&
        _previewId != previousId &&
        _previewId != null) {
      await _loadPreview(_previewId!);
    }
  }

  Future<void> _close() async {
    if (_busy || _menuOpen) {
      return;
    }
    if (_pending != null || _upload != null && _previewId == null) {
      setState(() => _busy = true);
      try {
        await UtenBusyOverlay.run(
          context,
          title: '正在保留原导入资料',
          action: saveFormDraftNow,
        );
        if (mounted) {
          Navigator.pop(context, _changed);
        }
      } catch (error) {
        _showError(error);
      } finally {
        if (mounted) {
          setState(() => _busy = false);
        }
      }
    } else if (await confirmFormDraftExit() && mounted) {
      Navigator.pop(context, _changed);
    }
  }

  void _showError(Object error, [String fallback = '原科目导入资料已保留，请核对后重试']) {
    if (_current) {
      setState(() => _error = describeSubmitError(error, fallback: fallback));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    if (!_current) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context, _changed),
        title: const Text('访问范围已变化'),
        content: const Text('原导入资料与未决请求已保留，请以具备原读取权限的账号重新打开。'),
      );
    }
    final rows = _maps(_preview?['rows']), issues = _maps(_preview?['issues']);
    final repreview = _pending?['operation'] == 'CHART_IMPORT_REPREVIEW';
    final viewedId = _previewId;
    final originalRequestId = _pending == null
        ? null
        : _command(_pending!).requestId;
    final stopped = _retired != null || _preview?['cancelled'] == true;
    final applied = _preview?['applied'] == true;
    final canApply = _preview != null && issues.isEmpty && !stopped && !applied;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) {
          unawaited(_close());
        }
      },
      child: withFormDraft(
        UtenAlertDialog(
          closeTooltip:
              _pending != null || _upload != null && _previewId == null
              ? '稍后核对'
              : '关闭',
          key: const ValueKey('finance-chart-import-workbench'),
          maxWidth: 1140,
          scrollable: false,
          showCloseButton: true,
          onClose: _close,
          closeEnabled: !(_busy || _menuOpen),
          title: UtenDialogTitleWithHint(
            title: const Text('科目目录导入'),
            info: _pending != null
                ? '原操作结果待核对。保留原账号、文件与预览，不换编号重复写入；稍后核对会保留原请求。'
                : '目录导入不带入余额或生成分录。原文件与字面行保持不变；重新预览是明确的新意图，只重新核对当前版本，不替代原操作回执。',
          ),
          content: SizedBox(
            width: 1100,
            height: MediaQuery.sizeOf(context).height * .68,
            child: !_ready
                ? const SizedBox(height: 80)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_upload != null || _preview != null)
                        UtenDialogField(
                          label: const Text('原文件'),
                          child: SelectableText(
                            (_preview?['sourceName'] ?? _upload?['sourceName'])
                                    ?.toString() ??
                                '',
                          ),
                        ),
                      if (_upload != null &&
                          _preview != null &&
                          _upload!['sourceName'] != _preview!['sourceName'])
                        UtenDialogField(
                          label: const Text('本次选择文件名'),
                          child: SelectableText(
                            _upload!['sourceName'] as String,
                          ),
                        ),
                      if (_preview != null)
                        UtenDialogField(
                          label: const Text('原预览状态'),
                          child: Text(
                            '${rows.length}条科目，${issues.length}项错误 · ${applied
                                ? '原批次已确认导入'
                                : stopped
                                ? '原批次已停止'
                                : '待核对预览'}',
                          ),
                        ),
                      if (_upload != null && _previewId == null)
                        const UtenDialogField(
                          label: Text('上传状态'),
                          child: Text('原私有预览待核对'),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if (_previewId == null && _upload == null)
                        FinanceSummaryScopeField(
                          key: const Key('finance-chart-import-record-scope'),
                          value: _recentScope,
                          enabled: !_busy && !_financialPending,
                          info:
                              '未确认且未停止的原预览保留在待办理；已确认和已停止批次在历史查看，原请求恢复仍按原ID或原文件校验核实。',
                          onChanged: _changeRecentScope,
                        ),
                      if (_previewId == null &&
                          _upload == null &&
                          _recent.isNotEmpty)
                        UtenDropdownField(
                          label: '恢复导入批次',
                          value: null,
                          enabled: !_busy,
                          items: [
                            for (final item in _recent)
                              UtenDropdownItem(
                                value: item['importId']?.toString(),
                                label:
                                    '${item['sourceName']} · ${item['cancelled'] == true
                                        ? '已停止'
                                        : item['appliedAt'] != null || item['applied'] == true
                                        ? '已确认导入'
                                        : '原预览'}',
                              ),
                          ],
                          onChanged: (id) {
                            if (id != null) {
                              unawaited(_loadPreview(id));
                            }
                          },
                        ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: _preview == null
                            ? Center(
                                child: _previewId != null
                                    ? UtenButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _loadPreview(_previewId!),
                                        child: const Text('读取原预览'),
                                      )
                                    : _upload == null
                                    ? UtenButton(
                                        onPressed: _busy || !_canWrite
                                            ? null
                                            : _pick,
                                        child: const Text('选择科目目录文件'),
                                      )
                                    : const SizedBox.shrink(),
                              )
                            : MasterDataTableView<Map<String, dynamic>>(
                                tableKey: issues.isEmpty
                                    ? 'finance.chart.import.preview'
                                    : 'finance.chart.import.issues',
                                virtualized: true,
                                expensiveRowMounts: false,
                                showPaginationControls: false,
                                showColumnChooser: false,
                                columns: issues.isEmpty
                                    ? [
                                        MasterColumnDef(
                                          key: 'code',
                                          label: '科目编码',
                                          width: 120,
                                          value: (row) =>
                                              row['code']?.toString(),
                                        ),
                                        MasterColumnDef(
                                          key: 'name',
                                          label: '科目名称',
                                          width: 230,
                                          value: (row) =>
                                              row['name']?.toString(),
                                        ),
                                        MasterColumnDef(
                                          key: 'currencyName',
                                          label: '外币名称',
                                          width: 100,
                                          value: (row) =>
                                              row['currencyName']?.toString(),
                                        ),
                                        for (final label in [
                                          '期初借方',
                                          '期初贷方',
                                          '本期发生借方',
                                          '本期发生贷方',
                                          '期末借方',
                                          '期末贷方',
                                        ])
                                          MasterColumnDef(
                                            key: label,
                                            label: label,
                                            width: 120,
                                            type: 'money',
                                            value: (_) => '',
                                          ),
                                      ]
                                    : [
                                        MasterColumnDef(
                                          key: 'sourceRow',
                                          label: '原行',
                                          width: 80,
                                          value: (row) =>
                                              row['sourceRow']?.toString(),
                                        ),
                                        MasterColumnDef(
                                          key: 'field',
                                          label: '字段',
                                          width: 130,
                                          value: (row) =>
                                              row['field']?.toString(),
                                        ),
                                        MasterColumnDef(
                                          key: 'message',
                                          label: '错误说明',
                                          width: 460,
                                          value: (row) =>
                                              row['message']?.toString(),
                                        ),
                                      ],
                                items: issues.isEmpty ? rows : issues,
                                facets: const {},
                                nullCounts: const {},
                                filters: const {},
                                onFilterChanged: (_, _) {},
                                toolbarActions: [
                                  if (canApply)
                                    UtenButton(
                                      type: UtenButtonType.secondary,
                                      onPressed:
                                          _busy ||
                                              _pending != null ||
                                              !_canWrite
                                          ? null
                                          : () => _send(
                                              repreview: true,
                                              viewedId: viewedId,
                                            ),
                                      child: const Text('按当前版本重新预览'),
                                    ),
                                ],
                              ),
                      ),
                    ],
                  ),
          ),
          actions: [
            if (_pending != null)
              ...financeOriginalRequestActions(
                context,
                busy: _busy,
                receiptLabel: '核对原导入结果',
                receipt: () => _recover(false),
                cancel: () => _recover(true),
                onMenuChanged: (value) {
                  if (mounted) {
                    setState(() => _menuOpen = value);
                  }
                },
              ),
            if (_pending != null)
              UtenButton(
                onPressed: _busy || !_canWrite
                    ? null
                    : () => _send(
                        repreview: repreview,
                        viewedId: viewedId,
                        originalRequestId: originalRequestId,
                      ),
                child: const Text('重试原导入请求'),
              )
            else if (_preview != null)
              UtenButton(
                onPressed: _busy || !_canWrite
                    ? null
                    : () => _send(repreview: !canApply, viewedId: viewedId),
                child: Text(canApply ? '确认导入科目目录' : '按当前版本重新预览'),
              )
            else if (_upload != null) ...[
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _busy || !_canWrite ? null : _pick,
                child: const Text('重新选择同一文件'),
              ),
              UtenButton(
                onPressed: _busy ? null : _findUpload,
                child: const Text('核对原上传'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

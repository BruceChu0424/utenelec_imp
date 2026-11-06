import '../shared/finance_complete_summary_read.dart';
import 'finance_summary_scope_field.dart';
import '../shared/finance_workbench_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import 'finance_source_table.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/business_submission_headers.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/performance/responsive_data_codec.dart';
import '../../../core/io/file_saver.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_entry_file_picker.dart';

Future<bool> showFinanceAuxiliaryImportDialog(
  BuildContext context, {
  required bool receivable,
  required String currencyId,
  required String dateFrom,
  required String dateTo,
  String? resumeDraftId,
}) async =>
    await showFinanceWorkbenchPanel<bool>(
      context: context,
      builder: (_) => _AuxiliaryImport(
        receivable: receivable,
        currencyId: currencyId,
        dateFrom: dateFrom,
        dateTo: dateTo,
        resumeDraftId: resumeDraftId,
      ),
    ) ??
    false;

class _AuxiliaryImport extends ConsumerStatefulWidget {
  const _AuxiliaryImport({
    required this.receivable,
    required this.currencyId,
    required this.dateFrom,
    required this.dateTo,
    this.resumeDraftId,
  });
  final String? resumeDraftId;
  final bool receivable;
  final String currencyId, dateFrom, dateTo;
  @override
  ConsumerState<_AuxiliaryImport> createState() => _AuxiliaryImportState();
}

class _AuxiliaryImportState extends ConsumerState<_AuxiliaryImport>
    with FormDraftMixin<_AuxiliaryImport> {
  late final ApiClient _api;
  late final int _epoch;
  final _book = TextEditingController();
  Map<String, dynamic>? _preview;
  List<Map<String, dynamic>> _recent = [], _comparisons = [];
  FinanceSummaryScope _recentScope = FinanceSummaryScope.active;
  int _recentRead = 0;
  bool _busy = false,
      _unknownUpload = false,
      _unknownApply = false,
      _changed = false;
  String? _error, _filename, _pendingBook;
  Map<String, dynamic> _uploadHeaders = const {};
  DraftByteValue? _ownedFile;
  String? _fileHash;
  Map<String, dynamic>? _pendingIntake, _pendingApply;
  bool _loading = true;
  Map<String, dynamic> get _scope => {
    'receivable': widget.receivable,
    'currencyId': widget.currencyId,
    'dateFrom': widget.dateFrom,
    'dateTo': widget.dateTo,
  };
  bool get _canMutate =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit);
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeAuxiliaryImport.spec(
        routeParameters: {
          'receivable': widget.receivable.toString(),
          'currencyId': widget.currencyId,
          'dateFrom': widget.dateFrom,
          'dateTo': widget.dateTo,
        },
      );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy || _loading;
  @override
  bool get formDraftCanReplaySubmission =>
      _pendingApply != null ||
      _pendingIntake != null &&
          (_pendingIntake!['kind'] == 'RECHECK' || _ownedFile != null);
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  Iterable<Listenable> get formDraftListenables => [_book];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'scope': _scope,
    'book': _book.text,
    'preview': _preview,
    'changed': _changed,
    'filename': _filename,
    'pendingBook': _pendingBook,
    'fileHash': _fileHash,
    'fileBytes': _ownedFile?.jsonValue,
    'uploadHeaders': businessSubmissionHeaders(_uploadHeaders),
    'pendingIntake': _pendingIntake == null
        ? null
        : {
            ..._pendingIntake!,
            'headers': businessSubmissionHeaders(_pendingIntake!['headers']),
          },
    'pendingApply': _pendingApply == null
        ? null
        : {
            ..._pendingApply!,
            'headers': businessSubmissionHeaders(_pendingApply!['headers']),
          },
    'unknownUpload': _unknownUpload,
    'unknownApply': _unknownApply,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> saved) async {
    if (!const DeepCollectionEquality().equals(saved['scope'], _scope)) {
      throw StateError('原辅助导入草稿类别、币别或期间不一致');
    }
    _book.text = saved['book']?.toString() ?? '';
    _preview = saved['preview'] is Map
        ? Map<String, dynamic>.from(saved['preview'] as Map)
        : null;
    _changed = saved['changed'] == true;
    _filename = saved['filename']?.toString();
    _pendingBook = saved['pendingBook']?.toString();
    _fileHash = saved['fileHash']?.toString();
    _uploadHeaders = businessSubmissionHeaders(saved['uploadHeaders']);
    _unknownUpload = saved['unknownUpload'] == true;
    _unknownApply = saved['unknownApply'] == true;
    _pendingIntake = saved['pendingIntake'] is Map
        ? Map<String, dynamic>.from(saved['pendingIntake'] as Map)
        : null;
    _pendingApply = saved['pendingApply'] is Map
        ? Map<String, dynamic>.from(saved['pendingApply'] as Map)
        : null;
    if (saved[formDraftUnknownSubmissionKey] == true) {
      if (_pendingIntake != null) _unknownUpload = true;
      if (_pendingApply != null) _unknownApply = true;
    }

    for (final pending in [_pendingIntake, _pendingApply]) {
      if (pending != null) {
        pending['headers'] = businessSubmissionHeaders(pending['headers']);
        if (pending['actorId'] !=
            ref.read(authenticatedScopeProvider)?.userId) {
          throw StateError('原辅助导入请求不属于当前操作人');
        }
      }
    }
    if (saved['fileBytes'] case final String encoded) {
      final bytes = await decodeBase64Responsive(
        encoded,
        isCurrent: () => mounted && formDraftIdentityIsCurrent,
      );
      if (bytes.length > 15 * 1024 * 1024 ||
          await sha256HexResponsive(
                bytes,
                isCurrent: () => mounted && formDraftIdentityIsCurrent,
              ) !=
              _fileHash) {
        throw StateError('原辅助明细文件字节或校验值不一致');
      }
      _ownedFile = DraftByteValue.decoded(bytes, encoded);
    }
    _comparisons = [];
  }

  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await initializeFormDraft();
        if (mounted && formDraftIdentityIsCurrent) await _loadRecent();
      } catch (e) {
        if (mounted && formDraftIdentityIsCurrent) _error = _message(e);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  void dispose() {
    _book.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    if (!_current || _busy) return;
    final generation = ++_recentRead, range = _recentScope;
    final kind = widget.receivable
        ? 'AUXILIARY_RECEIVABLE'
        : 'AUXILIARY_PAYABLE';
    final scope = await captureFormDraftRequestScope();
    bool current() =>
        _current &&
        scope.isCurrent &&
        generation == _recentRead &&
        range == _recentScope &&
        kind ==
            (widget.receivable ? 'AUXILIARY_RECEIVABLE' : 'AUXILIARY_PAYABLE');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await scope.run(
        () => readCompleteFinanceSummaries(
          isCurrent: current,
          idOf: (row) => row['importId'],
          loadPage: (page, size, revision) => _api.get(
            '/finance/auxiliary-imports/summaries',
            query: {
              'scope': range.name,
              'page': page,
              'size': size,
              'readSnapshotRevision': ?revision,
            },
          ),
        ),
      );
      if (current()) {
        setState(
          () => _recent = rows
              .where((row) => row['kind'] == kind)
              .toList(growable: false),
        );
      }
    } catch (error) {
      if (current()) setState(() => _error = _message(error));
    } finally {
      if (mounted && generation == _recentRead) setState(() => _busy = false);
    }
  }

  Future<void> _changeRecentScope(FinanceSummaryScope value) async {
    if (!_current ||
        _busy ||
        _loading ||
        _unknownUpload ||
        _unknownApply ||
        _preview != null ||
        value == _recentScope) {
      return;
    }
    setState(() {
      _recentScope = value;
      _recent = [];
    });
    await _loadRecent();
  }

  Future<void> _pick() async {
    if (!_current ||
        _busy ||
        _loading ||
        _unknownApply ||
        _unknownUpload ||
        formDraftHasUnknownSubmission ||
        !_canMutate) {
      return;
    }
    if (_book.text.trim().isEmpty) {
      setState(() => _error = '请填写财务原来源账套');
      return;
    }
    final file = await ref.read(financeEntryFilePickerProvider)();
    if (!_current || file == null) return;
    if (!{'xls', 'xlsx'}.contains(file.extension?.toLowerCase()) ||
        file.bytes == null ||
        file.bytes!.isEmpty ||
        file.bytes!.length > 15 * 1024 * 1024) {
      setState(() => _error = '请选择完整且不超过15MB的XLS或XLSX原明细');
      return;
    }
    setState(() => _busy = true);
    try {
      final owned = DraftByteValue(file.bytes!),
          hash = await sha256HexResponsive(
            owned.bytes,
            isCurrent: () => _current && formDraftIdentityIsCurrent,
          );
      if (!_current || !formDraftIdentityIsCurrent) return;
      setState(() {
        _filename = file.name;
        _ownedFile = owned;
        _fileHash = hash;
        _pendingBook = _book.text;
        _pendingIntake = null;
      });
      await saveFormDraftNow();
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _upload();
  }

  Map<String, dynamic> _newIntake() {
    if (_ownedFile == null ||
        _filename == null ||
        _pendingBook == null ||
        _pendingBook!.trim().isEmpty ||
        _fileHash == null) {
      throw StateError('原辅助文件、账套或校验资料不完整，未发送部分请求');
    }
    final request = const Uuid().v4();
    return {
      'kind': 'UPLOAD',
      'requestId': request,
      'path': Uri(
        path: '/finance/auxiliary-imports/preview',
        queryParameters: {
          'side': widget.receivable ? 'receivable' : 'payable',
          'sourceSystem': _pendingBook!,
          'currencyId': widget.currencyId,
          'dateFrom': widget.dateFrom,
          'dateTo': widget.dateTo,
          'requestId': request,
        },
      ).toString(),
      'scope': _scope,
      'sourceSystem': _pendingBook,
      'filename': _filename,
      'fileHash': _fileHash,
      'contentType': _filename!.toLowerCase().endsWith('.xls')
          ? 'application/vnd.ms-excel'
          : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'actorId': ref.read(authenticatedScopeProvider)?.userId,
      'headers': businessSubmissionHeaders(_uploadHeaders),
    };
  }

  bool _samePreview(Map<String, dynamic> result, Map<String, dynamic> pending) {
    final scope = Map<String, dynamic>.from(pending['scope'] as Map);
    return result['importId'] is String &&
        result['receivable'] == scope['receivable'] &&
        result['sourceSystem'] == pending['sourceSystem']?.toString().trim() &&
        result['currencyId'] == scope['currencyId'] &&
        result['dateFrom'] == scope['dateFrom'] &&
        result['dateTo'] == scope['dateTo'] &&
        result['sha256'] == pending['fileHash'];
  }

  Future<void> _acceptIntake(Map<String, dynamic> data) async {
    if (_pendingIntake == null || !_samePreview(data, _pendingIntake!)) {
      throw StateError('原请求的文件、账套或期间回执不一致，请保留原请求');
    }
    setState(() {
      _preview = data;
      _comparisons = [];
      _unknownUpload = false;
      _pendingIntake = null;
    });
    await checkpointFormDraftAfterConfirmedMutation();
  }

  Future<void> _upload() async {
    if (!_current ||
        _busy ||
        _loading ||
        !formDraftIdentityIsCurrent ||
        !_canMutate ||
        _unknownApply ||
        formDraftHasUnknownSubmission && _pendingIntake == null) {
      return;
    }
    final wasUnknown = _unknownUpload || formDraftHasUnknownSubmission;
    bool received = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _pendingIntake ??= _newIntake();
      final pending = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(_pendingIntake)) as Map,
      );
      if (pending['kind'] == 'UPLOAD' &&
          (_ownedFile == null ||
              pending['fileHash'] != _fileHash ||
              pending['filename'] != _filename)) {
        throw StateError('原辅助文件不完整或已变化，不能替换原文件重试');
      }
      final scope = await captureFormDraftRequestScope();
      final data = await runFormDraftSubmission(
        () => scope.run(
          () => pending['kind'] == 'RECHECK'
              ? _api.post(
                  pending['path'].toString(),
                  body: pending['body'],
                  headers: businessSubmissionHeaders(pending['headers']),
                )
              : _api.postMultipartFile(
                  pending['path'].toString(),
                  _ownedFile!.bytes,
                  pending['filename'].toString(),
                  pending['contentType'].toString(),
                  headers: businessSubmissionHeaders(pending['headers']),
                ),
        ),
        isDefiniteRejection: (e) => !wasUnknown && _rejected(e),
      );
      if (!_current || !scope.isCurrent) return;
      if (!_samePreview(data, pending)) {
        throw StateError('原文件、账套或期间回执不匹配，请保留原请求');
      }
      received = true;
      await _acceptIntake(data);
    } catch (e) {
      if (_current) {
        setState(() {
          if (!received) {
            _unknownUpload =
                wasUnknown || formDraftHasUnknownSubmission || !_rejected(e);
            if (!_unknownUpload) _pendingIntake = null;
          }
          _error = received
              ? '原文件批次已取得回执，恢复记录尚未写好，请保留窗口继续核对。${_message(e)}'
              : '${_message(e)}。原文件、原编号及账套已保留。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconcile() async {
    if (!_current || _busy || !formDraftIdentityIsCurrent) return;
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (_pendingIntake != null) {
        final pending = _pendingIntake!;
        final receipt = await scope.run(
          () => _api.get(
            '/finance/auxiliary-imports/operations/${pending['requestId']}',
          ),
        );
        if (!_current || !scope.isCurrent) return;
        if (receipt['requestId'] != pending['requestId']) {
          throw StateError('原导入编号回执不一致');
        }
        await _acceptIntake(
          Map<String, dynamic>.from(receipt['preview'] as Map),
        );
      } else if (_pendingApply != null) {
        final body = Map<String, dynamic>.from(_pendingApply!['body'] as Map);
        final data = await scope.run(
          () => _api.get('/finance/auxiliary-imports/${body['importId']}'),
        );
        if (!_current || !scope.isCurrent) return;
        if (data['importId'] != body['importId'] ||
            data['sha256'] != _preview?['sha256'] ||
            data['directoryApplied'] != true) {
          throw StateError('原批次目录结果尚未取得成功回执，请保留原请求');
        }
        setState(() {
          _preview = data;
          _unknownApply = false;
          _pendingApply = null;
          _changed = true;
        });
        await checkpointFormDraftAfterConfirmedMutation();
      } else if (_preview?['importId'] != null) {
        final previous = _preview!,
            data = await scope.run(
              () => _api.get(
                '/finance/auxiliary-imports/${previous['importId']}',
              ),
            );
        if (!_current || !scope.isCurrent) return;
        if (data['importId'] != previous['importId'] ||
            data['sha256'] != previous['sha256'] ||
            previous['directoryApplied'] == true &&
                data['directoryApplied'] != true) {
          throw StateError('原确认批次的成功回执不匹配');
        }
        setState(() {
          _preview = data;
          _unknownApply = false;
          _unknownUpload = false;
        });
        await checkpointFormDraftAfterConfirmedMutation();
      }
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(String id) async {
    if (!_current || _busy || _unknownUpload || _unknownApply) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _api.get('/finance/auxiliary-imports/$id');
      if (_current) {
        setState(() {
          _preview = data;
          _comparisons = [];
        });
      }
    } catch (error) {
      if (_current) setState(() => _error = _message(error));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    if (!_current ||
        _busy ||
        _preview == null ||
        _unknownUpload ||
        _loading ||
        !formDraftIdentityIsCurrent ||
        !_canMutate) {
      return;
    }
    final id = _preview!['importId'];
    final wasUnknown = _unknownApply;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _pendingApply ??= {
        'path': '/finance/auxiliary-imports/directory-apply',
        'body': {'importId': id},
        'headers': <String, dynamic>{},
        'actorId': ref.read(authenticatedScopeProvider)?.userId,
      };
      final pending = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(_pendingApply)) as Map,
          ),
          scope = await captureFormDraftRequestScope();
      await runFormDraftSubmission(
        () => scope.run(
          () => _api.post(
            pending['path'].toString(),
            body: pending['body'],
            headers: businessSubmissionHeaders(pending['headers']),
          ),
        ),
        isDefiniteRejection: (e) => !wasUnknown && _rejected(e),
      );
      if (!scope.isCurrent || !formDraftIdentityIsCurrent) return;
      if (_current) {
        setState(() {
          _unknownApply = false;
          _changed = true;
          _preview = {..._preview!, 'directoryApplied': true};
          _pendingApply = null;
        });
        await checkpointFormDraftAfterConfirmedMutation();
      }
    } catch (error) {
      if (_current) {
        setState(() {
          _unknownApply =
              wasUnknown || formDraftHasUnknownSubmission || !_rejected(error);
          if (!_unknownApply) _pendingApply = null;
          _error = _unknownApply
              ? '${_message(error)}。请保留原批次并重试核对，不会新增第二份辅助身份。'
              : _message(error);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _compare() async {
    if (!_current ||
        _busy ||
        _preview == null ||
        _unknownApply ||
        _unknownUpload) {
      return;
    }
    final id = _preview!['importId'];
    setState(() {
      _busy = true;
      _error = null;
      _comparisons = [];
    });
    try {
      final data = await _api.get('/finance/auxiliary-imports/$id/comparison');
      if (_current) setState(() => _comparisons = _maps(data['items']));
    } catch (error) {
      if (_current) setState(() => _error = _message(error));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _recheck() async {
    if (!_current ||
        _busy ||
        _preview == null ||
        _unknownApply ||
        _unknownUpload ||
        !_canMutate) {
      return;
    }
    final id = _preview!['importId'], request = const Uuid().v4();
    _pendingIntake = {
      'kind': 'RECHECK',
      'requestId': request,
      'path': '/finance/auxiliary-imports/$id/recheck?requestId=$request',
      'body': null,
      'scope': {
        'receivable': _preview!['receivable'],
        'currencyId': _preview!['currencyId'],
        'dateFrom': _preview!['dateFrom'],
        'dateTo': _preview!['dateTo'],
      },
      'sourceSystem': _preview!['sourceSystem'],
      'filename': _preview!['sourceName'],
      'fileHash': _preview!['sha256'],
      'actorId': ref.read(authenticatedScopeProvider)?.userId,
      'headers': <String, dynamic>{},
    };
    await _upload();
  }

  Future<void> _download() async {
    if (!_current || _busy || _preview == null) return;
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      final original = _preview!,
          bytes = await scope.run(
            () => _api.postForBytes(
              '/finance/auxiliary-imports/${original['importId']}/file',
            ),
          );
      if (!_current || !scope.isCurrent) return;
      if (await sha256HexResponsive(
            bytes,
            isCurrent: () => _current && scope.isCurrent,
          ) !=
          original['sha256']) {
        throw StateError('原明细文件校验不一致，未保存替代文件');
      }
      await saveBytes(
        bytes,
        original['sourceName']?.toString() ?? '原辅助明细.xlsx',
        stillCurrent: () => _current && scope.isCurrent,
      );
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (!_busy && await confirmFormDraftExit() && mounted) {
      Navigator.pop(context, _changed);
    }
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenButton(
    onPressed: _busy ? null : _reconcile,
    child: const Text('只读核对原结果'),
  );

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch ||
        !formDraftIdentityIsCurrent) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),

        title: const Text('访问范围已变化'),
      );
    }
    final frozen =
        _busy ||
        _loading ||
        _unknownUpload ||
        _unknownApply ||
        formDraftHasUnknownSubmission;
    final issues = _maps(_preview?['issues']);
    final sourceRows = _maps(_preview?['rows']);
    late List<Map<String, dynamic>> rows;
    late List<MasterColumnDef<Map<String, dynamic>>> columns;
    late String view;
    final actions = <Widget>[];
    if (_preview == null) {
      view = 'imports';
      rows = _recent;
      columns = [
        financeSourceColumn('sourceName', '原文件', width: 260),
        financeSourceColumn('sourceSystem', '来源账套', width: 160),
        financeSourceColumn('dateFrom', '开始日期', type: 'date'),
        financeSourceColumn('dateTo', '结束日期', type: 'date'),
      ];
      actions.add(
        UtenButton(
          onPressed: frozen || !_canMutate ? null : _pick,
          child: const Text('选择原明细文件'),
        ),
      );
      if (_unknownUpload) {
        actions.add(
          UtenButton(
            onPressed: _busy ? null : _upload,
            child: const Text('核对并重试原上传'),
          ),
        );
      }
    } else {
      if (issues.isNotEmpty) {
        view = 'issues';
        rows = issues;
        columns = [
          financeSourceColumn('sourceRow', '原行号', width: 100, type: 'number'),
          financeSourceColumn('field', '字段', width: 180),
          financeSourceColumn('message', '核对说明', width: 400),
        ];
      } else if (_comparisons.isNotEmpty) {
        view = 'comparison';
        rows = _comparisons;
        columns = [
          financeSourceColumn('accountCode', '科目编码'),
          financeSourceColumn(
            'partyCode',
            widget.receivable ? '客户编号' : '供应商编号',
          ),
          financeSourceColumn(
            'status',
            '核对结果',
            value: (row) => _status(row['status']),
          ),
          financeSourceColumn(
            'differences',
            '差异说明',
            width: 450,
            value: (row) => (row['differences'] as List? ?? []).join('；'),
          ),
        ];
      } else {
        view = 'source';
        rows = sourceRows;
        columns = [
          for (final column in _maps(_preview?['columns']))
            financeSourceColumn(
              '${column['key']}',
              '${column['label']}',
              width: (column['width'] as num?)?.toDouble() ?? 150,
              type: column['type']?.toString() ?? 'text',
            ),
        ];
      }
      if (issues.isEmpty && _preview!['directoryApplied'] != true) {
        actions.add(
          UtenButton(
            onPressed: _busy || _unknownUpload || !_canMutate ? null : _apply,
            child: Text(_unknownApply ? '核对并重试原批次' : '导入辅助目录草稿'),
          ),
        );
      }
      if (issues.isEmpty) {
        actions.add(
          UtenButton(
            onPressed: frozen ? null : _compare,
            child: const Text('与总账本币比对'),
          ),
        );
      }
      actions.add(
        UtenButton(
          onPressed: frozen || !_canMutate ? null : _recheck,
          child: const Text('重新核对原文件'),
        ),
      );
      actions.add(
        TextButton(
          onPressed: frozen
              ? null
              : () {
                  setState(() {
                    _preview = null;
                    _comparisons = [];
                  });
                  _loadRecent();
                },
          child: const Text('返回批次'),
        ),
      );
    }
    if (_preview == null) {
      actions.insert(
        0,
        FinanceSummaryScopeField(
          key: const Key('finance-aux-import-record-scope'),
          value: _recentScope,
          enabled: !_busy && !_loading && !_unknownUpload && !_unknownApply,
          info: '待办理保留未应用辅助目录的原件；已应用记录在历史保留查看，仍可作为账套接续的合法来源。',
          onChanged: _changeRecentScope,
        ),
      );
    }
    if (_preview != null) {
      actions.add(
        UtenButton(
          onPressed: _busy ? null : _download,
          child: const Text('下载原明细文件'),
        ),
      );
    }
    if ((_unknownUpload || _unknownApply) &&
        (_pendingIntake != null || _pendingApply != null)) {
      actions.add(formDraftSubmissionRecoveryAction!);
    }
    if (_preview != null && _unknownUpload) {
      actions.add(
        UtenButton(
          onPressed: _busy ? null : _upload,
          child: const Text('核对并重试原上传'),
        ),
      );
    }
    return withFormDraft(
      UtenDialogFrame(
        maxWidth: 1200,
        fillHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text('${widget.receivable ? '应收' : '应付'}账款明细表导入比对'),
                  ),
                  const UtenFieldHintIcon(
                    info:
                        '原文件金额按总账本币核对；各行币别属性按科目已确认对应冻结。目录导入保留未对应草稿；原文件与原请求可从本人草稿恢复。',
                  ),
                ],
              ),
              showCloseButton: true,
              onClose:
                  _busy ||
                      _loading ||
                      (_unknownUpload || _unknownApply) &&
                          formDraftRecoveryId == null
                  ? null
                  : _close,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_preview == null) ...[
                    UtenInput(
                      label: '来源账套',
                      controller: _book,
                      enabled: !frozen,
                      inputFormatters: [LengthLimitingTextInputFormatter(80)],
                    ),
                  ] else ...[
                    Tooltip(
                      message:
                          '${_preview!['sourceName']}  ${_preview!['sourceSystem']}',
                      child: Text(
                        '${_preview!['sourceName']}  ${_preview!['sourceSystem']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${_preview!['dateFrom']} 至 ${_preview!['dateTo']}：${sourceRows.length}条，${issues.length}项原表错误',
                    ),
                  ],
                  if (_error != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 100),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: financeSourceTable(
                tableKey: 'finance.auxiliary.import.$view.${widget.receivable}',
                columns: columns,
                rows: rows,
                idOf: (row) =>
                    '${row['importId'] ?? row['sourceRow']}:${row['field'] ?? ''}:${row['message'] ?? ''}',
                busy: _busy,
                actions: actions,
                scope: (_epoch, _preview?['importId'], view),
                showColumnChooser: view != 'source',
                canOpen: (_) => !frozen && _preview == null,
                onOpen: _preview == null
                    ? (row) => _restore('${row['importId']}')
                    : null,
              ),
            ),
            UtenDialogActions(
              children: [
                TextButton(
                  onPressed:
                      _busy ||
                          _loading ||
                          (_unknownUpload || _unknownApply) &&
                              formDraftRecoveryId == null
                      ? null
                      : _close,
                  child: const Text('关闭'),
                ),
              ],
            ),
            if (_busy)
              const UtenBusyOverlay(
                title: '正在核对辅助账来源',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    );
  }
}

List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map<String, dynamic>) row,
];
String _message(Object error) =>
    error is ApiException ? error.message : '操作未完成，请核对网络后重试';
bool _rejected(Object error) =>
    error is ApiException &&
    error.hasResponseCode &&
    (error.httpStatus ?? 0) >= 400 &&
    (error.httpStatus ?? 0) < 500 &&
    error.httpStatus != 408;
String _status(Object? value) => switch (value) {
  'MATCHED' => '一致',
  'DIFFERENT' => '有差异',
  'PENDING' => '待核对',
  'AUXILIARY_NOT_REGISTERED' => '辅助编号未维护',
  'LEDGER_EVIDENCE_MISSING' => '缺少总账依据',
  _ => '待核对',
};

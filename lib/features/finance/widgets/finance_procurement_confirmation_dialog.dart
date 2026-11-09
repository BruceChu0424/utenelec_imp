import '../shared/finance_workbench_panel.dart';
import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_progress_dialog.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../core/io/file_saver.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/business_submission_headers.dart';
import '../../../core/performance/responsive_data_codec.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import 'finance_entry_file_picker.dart';
import 'finance_source_table.dart';
import 'finance_durable_command_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';

const _path = '/finance/procurement-payable-recognitions';

bool _validProcurementPolicy(Map<String, dynamic> policy) {
  final revision = policy['revision'],
      reference = policy['sourceReference'],
      date = policy['effectiveFrom'];
  return revision is int &&
      revision >= 0 &&
      policy['enabled'] is bool &&
      policy.containsKey('sourceReference') &&
      (reference == null || reference is String) &&
      policy.containsKey('effectiveFrom') &&
      (date == null ||
          date is String &&
              RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) &&
              DateTime.tryParse(date) != null);
}

Future<Map<String, dynamic>?> showFinanceProcurementPolicyDialog(
  BuildContext context, {
  String? resumeDraftId,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final epoch = container.read(exportContextEpochProvider);
  Map<String, dynamic>? initial;
  if (resumeDraftId == null) {
    Map<String, dynamic> policy;
    try {
      policy = await UtenBusyOverlay.run(
        context,
        title: '正在读取首次应付设置',
        action: () => container.read(apiClientProvider).get('$_path/policy'),
      );
      if (!_validProcurementPolicy(policy)) {
        throw StateError('当前首次应付设置不完整，请重新读取后核对');
      }
    } catch (error) {
      if (context.mounted &&
          container.read(exportContextEpochProvider) == epoch) {
        context.appApiError(error, fallback: '首次应付设置读取失败，请重试');
      }
      return null;
    }
    if (!context.mounted ||
        container.read(exportContextEpochProvider) != epoch) {
      return null;
    }
    initial = {
      'expectedRevision': policy['revision'],
      'enabled': policy['enabled'] == true,
      'effectiveFrom': policy['effectiveFrom'],
      'sourceReference': policy['sourceReference'] ?? '',
    };
  }
  if (!context.mounted) return null;
  return showFinanceDurableCommandDialog(
    context,
    operation: FinanceDurableOperation.procurementPolicy,
    initialBody: initial,
    resumeDraftId: resumeDraftId,
    hint:
        '只影响生效日期后新审核的来源。历史正式应付不重开；已进入新路线的单据沿原路线完成。启用前维护暂估债务、待确认退货资产、正式应付及供应商辅助。',
    reviewLoader: (api, body, source, target) async {
      final policy = await api.get('$_path/policy');
      if (!_validProcurementPolicy(policy)) {
        throw StateError('当前首次应付设置缺少版本依据');
      }
      String route(Object? value) => value == true ? '先对账确认再立应付' : '保持原审核立应付';
      return FinanceCommandReview(
        versionPatch: {'expectedRevision': policy['revision']},
        rows: [
          ('新审核来源', route(body['enabled']), route(policy['enabled'])),
          (
            '生效日期',
            '${body['effectiveFrom'] ?? '未设置'}',
            '${policy['effectiveFrom'] ?? '未设置'}',
          ),
          (
            '启用或变更依据',
            '${body['sourceReference'] ?? ''}',
            '${policy['sourceReference'] ?? '未设置'}',
          ),
        ],
      );
    },
    editorBuilder: (context, editor) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        UtenDropdownField(
          label: '新审核来源',
          value: editor.body['enabled'] == true ? 'NEW' : 'LEGACY',
          enabled: editor.editable,
          allowClear: false,
          items: const [
            UtenDropdownItem(value: 'NEW', label: '先对账确认再立应付'),
            UtenDropdownItem(value: 'LEGACY', label: '保持原审核立应付'),
          ],
          onChanged: (value) {
            if (value != null) editor.set('enabled', value == 'NEW');
          },
        ),
        const SizedBox(height: 12),
        FormField<String>(
          validator: (_) {
            final value = editor.body['effectiveFrom'];
            if (editor.body['enabled'] == true &&
                (value is! String ||
                    value.compareTo(
                          ChinaDateTime.formatDate(ChinaDateTime.today()),
                        ) <
                        0)) {
              return '首次启用日期只能为今天或以后；历史正式来源保持原路线';
            }
            return null;
          },
          builder: (field) => UtenDateField(
            label: '生效日期',
            required: editor.body['enabled'] == true,
            info: '首次启用日期只能为今天或以后；历史正式来源保持原路线。',
            value: DateTime.tryParse('${editor.body['effectiveFrom'] ?? ''}'),
            enabled: editor.editable,
            errorMessage: field.errorText,
            onChanged: (date) {
              final value = _day(date);
              editor.set('effectiveFrom', value);
              field.didChange(value);
            },
          ),
        ),
        const SizedBox(height: 12),
        UtenInput(
          label: '启用或变更依据',
          controller: editor.controller('sourceReference'),
          enabled: editor.editable,
          required: true,
          validator: (value) =>
              (value ?? '').trim().length <
                  (editor.body['enabled'] == true ? 8 : 1)
              ? '请填写完整的启用或变更依据'
              : null,
        ),
      ],
    ),
  );
}

/// Mounted by the existing 委外对账单 / 供应商对账单 toolbar, with real typed selector UUIDs.
Future<void> showFinanceProcurementConfirmationDialog(
  BuildContext context, {
  required String supplierId,
  required String currencyId,
  String? resumeDraftId,
}) => showFinanceWorkbenchPanel<void>(
  context: context,
  builder: (_) => resumeDraftId != null
      ? _ConfirmationForm(
          supplierId: supplierId,
          currencyId: currencyId,
          selected: const [],
          resumeDraftId: resumeDraftId,
        )
      : _ConfirmationDirectory(supplierId: supplierId, currencyId: currencyId),
);

class _ConfirmationDirectory extends ConsumerStatefulWidget {
  const _ConfirmationDirectory({
    required this.supplierId,
    required this.currencyId,
  });
  final String supplierId, currencyId;
  @override
  ConsumerState<_ConfirmationDirectory> createState() =>
      _ConfirmationDirectoryState();
}

class _ConfirmationDirectoryState extends ConsumerState<_ConfirmationDirectory>
    with ScopedPagedReadViewMixin<_ConfirmationDirectory> {
  late final ApiClient _api;
  late final int _epoch;
  String _kind = 'PENDING';
  bool _busy = false;
  String? _error;
  int _generation = 0;
  @override
  Future<void> onReadViewResumed() => _load();
  List<Map<String, dynamic>> _rows = [];
  final Map<String, Map<String, dynamic>> _selected = {};
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _canWrite {
    final p = ref.read(currentPermissionsProvider);
    return p.contains(Perm.supplierSettlementConfirm) &&
        p.contains(Perm.financePostExecute);
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load();
  }

  Future<PagedResult<Map<String, dynamic>>> _fetchPage(
    int page,
    int size,
    String kind,
  ) async => PagedResult.fromJsonResponsive<Map<String, dynamic>>(
    await _api.get(
      kind == 'PENDING' ? '$_path/candidates' : _path,
      query: {
        'supplierId': widget.supplierId,
        'currencyId': widget.currencyId,
        'page': '$page',
        'size': '$size',
        if (kind == 'PENDING') 'status': 'PENDING',
      },
    ),
    (row) => Map<String, dynamic>.unmodifiable(row),
  );

  Future<void> _load() async {
    if (!_current) return;
    final generation = ++_generation, kind = _kind;
    bool current() => _current && generation == _generation && kind == _kind;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await readScopedPage<Map<String, dynamic>>(
        1,
        slot: 'procurement-recognitions',
        idOf: (row) => row['id'],
        query: [_api, widget.supplierId, widget.currencyId, kind],
        currentQuery: () => [_api, widget.supplierId, widget.currencyId, _kind],
        isCurrent: current,
        fetchPage: (page) async => _fetchPage(page, 100, kind),
        fetchPageSized: (page, size) async => _fetchPage(page, size, kind),
      );
      if (current()) setState(() => _rows = data.items);
    } catch (e) {
      if (!isRetiredViewRead(e) && current()) {
        setState(() {
          _error = _message(e);
          if (pagedReadAccessDenied(e)) {
            _rows = [];
            _selected.clear();
          }
        });
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_current || _busy || _selected.isEmpty) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ConfirmationForm(
        supplierId: widget.supplierId,
        currencyId: widget.currencyId,
        selected: _selected.values.toList(growable: false),
      ),
    );
    if (_current && saved == true) {
      setState(() {
        _selected.clear();
        _kind = 'HISTORY';
      });
      await _load();
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    if (!_current ||
        _busy ||
        _kind != 'HISTORY' ||
        !_rows.any((accepted) => identical(accepted, row))) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ConfirmationDetail(id: '${row['id']}'),
    );
    if (_current) await _load();
  }

  Future<void> _policy() async {
    if (!_current || _busy) return;
    await showFinanceProcurementPolicyDialog(context);
    if (_current) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) return _lost(context);
    final pending = _kind == 'PENDING';
    return UtenDialogFrame(
      maxWidth: 1200,
      fillHeight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenDialogHeader(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('对账确认'),
                UtenFieldHintIcon(
                  info: pending
                      ? '只选择已核对的原来源；确认件须由另一位财务审核后才形成正式应付。已选 ${_selected.length} 项。'
                      : '双击原记录查看原确认件、审核结果和反审；原正式应付保留历史路线。',
                ),
              ],
            ),
            showCloseButton: true,
            onClose: _busy ? null : () => Navigator.pop(context),
          ),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: UtenDropdownField(
              label: '查看',
              value: _kind,
              allowClear: false,
              enabled: !_busy,
              items: const [
                UtenDropdownItem(value: 'PENDING', label: '待确认来源'),
                UtenDropdownItem(value: 'HISTORY', label: '确认记录'),
              ],
              onChanged: (value) {
                if (value != null && !_busy) {
                  setState(() {
                    _kind = value;
                    _rows = [];
                  });
                  _load();
                }
              },
            ),
          ),
          Expanded(
            child: financeSourceTable(
              tableKey: 'finance.procurement-confirmation.$_kind',
              columns: pending
                  ? [
                      financeSourceColumn('billNo', '来源单号', width: 220),
                      financeSourceColumn(
                        'commercialDate',
                        '原单日期',
                        type: 'date',
                      ),
                      financeSourceColumn('accrualDate', '暂估日期', type: 'date'),
                      financeSourceColumn('supplierName', '供应商名称', width: 180),
                      financeSourceColumn('currencyName', '原币'),
                      financeSourceColumn(
                        'amountOriginal',
                        '原币金额',
                        type: 'money',
                      ),
                      financeSourceColumn('amountLocal', '账面本币', type: 'money'),
                    ]
                  : [
                      financeSourceColumn(
                        'effectiveDate',
                        '确认日期',
                        type: 'date',
                      ),
                      financeSourceColumn(
                        'status',
                        '状态',
                        value: (r) => _status(r['status']),
                      ),
                      financeSourceColumn('counterpartConfirmedBy', '对方确认人'),
                      financeSourceColumn(
                        'counterpartConfirmedDate',
                        '对方确认日期',
                        type: 'date',
                      ),
                      financeSourceColumn('fileName', '原确认件', width: 230),
                      financeSourceColumn(
                        'sourceReference',
                        '来源依据',
                        width: 260,
                      ),
                    ],
              rows: _rows,
              idOf: (r) => '${r['id']}',
              busy: _busy,
              error: _error,
              retry: () => _load(),
              onOpen: pending ? null : _open,
              selectable: pending,
              selectedIds: _selected.keys.toSet(),
              onSelectedIdsChanged: (ids) {
                if (_busy) return;
                setState(() {
                  _selected.removeWhere((key, _) => !ids.contains(key));
                  for (final row in _rows) {
                    final id = '${row['id']}';
                    if (ids.contains(id)) _selected[id] = Map.of(row);
                  }
                });
              },
              scope: (_epoch, widget.supplierId, widget.currencyId, _kind),
              actions: [
                if (pending && _canWrite)
                  UtenButton(
                    onPressed: _busy || _selected.isEmpty ? null : _submit,
                    child: const Text('提交对账确认'),
                  ),
                UtenButton(
                  onPressed: _busy ? null : () => _load(),
                  child: const Text('刷新'),
                ),
                if (_canWrite &&
                    ref
                        .watch(currentPermissionsProvider)
                        .contains(Perm.paymentStyleEdit))
                  UtenButton(
                    onPressed: _busy ? null : _policy,
                    child: const Text('首次应付设置'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmationForm extends ConsumerStatefulWidget {
  const _ConfirmationForm({
    required this.supplierId,
    required this.currencyId,
    required this.selected,
    this.resumeDraftId,
  });
  final String? resumeDraftId;
  final String supplierId, currencyId;
  final List<Map<String, dynamic>> selected;
  @override
  ConsumerState<_ConfirmationForm> createState() => _ConfirmationFormState();
}

class _ConfirmationFormState extends ConsumerState<_ConfirmationForm>
    with FormDraftMixin<_ConfirmationForm> {
  late final ApiClient _api;
  late final int _epoch;
  final _reference = TextEditingController(), _name = TextEditingController();
  DateTime _date = ChinaDateTime.today(), _signed = ChinaDateTime.today();
  Uint8List? _bytes;
  DraftByteValue? _ownedFile;
  String? _fileHash, _requestActor;
  List<Map<String, dynamic>> _selected = [];
  bool _loading = true;
  String? _filename, _type, _error;
  bool _busy = false, _unknown = false;
  Map<String, Object?>? _request;
  Map<String, dynamic> _requestHeaders = const {};
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _canWrite {
    final p = ref.read(currentPermissionsProvider);
    return p.contains(Perm.supplierSettlementConfirm) &&
        p.contains(Perm.financePostExecute);
  }

  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeProcurementConfirmation.spec(
        routeParameters: {
          'supplierId': widget.supplierId,
          'currencyId': widget.currencyId,
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
      _request != null && _ownedFile != null;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  Iterable<Listenable> get formDraftListenables => [_reference, _name];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'supplierId': widget.supplierId,
    'currencyId': widget.currencyId,
    'selected': _selected,
    'reference': _reference.text,
    'name': _name.text,
    'date': _day(_date),
    'signed': _day(_signed),
    'filename': _filename,
    'contentType': _type,
    'fileHash': _fileHash,
    'fileBytes': _ownedFile?.jsonValue,
    'request': _request,
    'requestHeaders': businessSubmissionHeaders(_requestHeaders),
    'requestActor': _requestActor,
    'unknown': _unknown,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> saved) async {
    if (saved['supplierId'] != widget.supplierId ||
        saved['currencyId'] != widget.currencyId) {
      throw StateError('原确认件草稿供应商或币别不一致');
    }
    _selected = _maps(saved['selected']);
    _reference.text = saved['reference']?.toString() ?? '';
    _name.text = saved['name']?.toString() ?? '';
    final day = DateTime.tryParse(saved['date']?.toString() ?? ''),
        signed = DateTime.tryParse(saved['signed']?.toString() ?? '');
    if (day == null || signed == null) throw StateError('原确认日期不完整');
    _date = day;
    _signed = signed;
    _filename = saved['filename']?.toString();
    _type = saved['contentType']?.toString();
    _fileHash = saved['fileHash']?.toString();
    _requestActor = saved['requestActor']?.toString();
    _request = saved['request'] is Map
        ? Map<String, Object?>.from(saved['request'] as Map)
        : null;
    _requestHeaders = businessSubmissionHeaders(saved['requestHeaders']);
    _unknown =
        saved['unknown'] == true ||
        saved[formDraftUnknownSubmissionKey] == true && _request != null;
    if (_request != null &&
        (_request!['supplierId'] != widget.supplierId ||
            _request!['currencyId'] != widget.currencyId ||
            _requestActor != ref.read(authenticatedScopeProvider)?.userId)) {
      throw StateError('原确认请求的对象或操作者不一致');
    }
    if (saved['fileBytes'] case final String encoded) {
      final bytes = await decodeBase64Responsive(
        encoded,
        isCurrent: () => formDraftIdentityIsCurrent && mounted,
      );
      if (bytes.length > 15 * 1024 * 1024 ||
          await sha256HexResponsive(
                bytes,
                isCurrent: () => formDraftIdentityIsCurrent && mounted,
              ) !=
              _fileHash) {
        throw StateError('原确认件字节与校验值不一致');
      }
      _ownedFile = DraftByteValue.decoded(bytes, encoded);
      _bytes = _ownedFile!.bytes;
    }
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _selected = [
      for (final row in widget.selected) Map<String, dynamic>.from(row),
    ];
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await initializeFormDraft();
      } catch (e) {
        if (mounted && formDraftIdentityIsCurrent) _error = _message(e);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  void dispose() {
    _reference.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (!_current || _busy || _unknown) return;
    final file = await ref.read(financeConfirmationFilePickerProvider)();
    if (!_current || file == null) return;
    final ext = file.extension?.toLowerCase();
    final type = switch (ext) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'csv' => 'text/csv',
      _ => null,
    };
    if (type == null ||
        file.bytes == null ||
        file.bytes!.isEmpty ||
        file.bytes!.length > 15 * 1024 * 1024) {
      setState(() => _error = '请选择完整且不超过15MB的实际对账确认件');
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
        _ownedFile = owned;
        _bytes = owned.bytes;
        _fileHash = hash;
        _filename = file.name;
        _type = type;
      });
      await saveFormDraftNow();
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_current ||
        _busy ||
        _loading ||
        !formDraftIdentityIsCurrent ||
        !_canWrite) {
      return;
    }
    if (!_unknown && _request == null) {
      if (_reference.text.trim().isEmpty ||
          _name.text.trim().isEmpty ||
          _bytes == null) {
        setState(() => _error = '请填写实际确认资料并选择原确认件');
        return;
      }
      if (_selected.isEmpty || _selected.length > 500) {
        setState(() => _error = '请选择1至500个明确原来源');
        return;
      }
      _requestActor = ref.read(authenticatedScopeProvider)?.userId;
      _requestHeaders = businessSubmissionHeaders(_requestHeaders);
      _request = {
        'requestId': const Uuid().v4(),
        'supplierId': widget.supplierId,
        'currencyId': widget.currencyId,
        'effectiveDate': _day(_date),
        'counterpartConfirmedDate': _day(_signed),
        'sourceReference': _reference.text,
        'counterpartConfirmedBy': _name.text,
        'candidates': [
          for (final row in _selected)
            {
              'candidateId': row['id'],
              'sourceFingerprint': row['sourceFingerprint'],
            },
        ],
      };
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_ownedFile == null ||
          _bytes == null ||
          _filename == null ||
          _type == null) {
        throw StateError('原确认件不完整，不能只发送部分请求');
      }
      final scope = await captureFormDraftRequestScope();
      await runFormDraftSubmission(
        () => scope.run(
          () => _api.postMultipartFile(
            _path,
            _ownedFile!.bytes,
            _filename!,
            _type!,
            jsonParts: {'command': _request},
            headers: businessSubmissionHeaders(_requestHeaders),
          ),
        ),
        isDefiniteRejection: (e) => !wasUnknown && _rejected(e),
      );
      if (!mounted || !_current || !scope.isCurrent) return;
      await completeFormDraft();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (_current) {
        setState(() {
          if (!wasUnknown && !formDraftHasUnknownSubmission && _rejected(e)) {
            _request = null;
            _requestActor = null;
          }
          _unknown =
              wasUnknown || formDraftHasUnknownSubmission || !_rejected(e);
          _error = _unknown
              ? '结果尚未确认。原文件和请求已保留，请核对并重试原请求。${_message(e)}'
              : _message(e);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _reconcile() async {
    if (!_current || _busy || _request == null || !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      final row = await scope.run(
        () => _api.get('$_path/operations/${_request!['requestId']}'),
      );
      if (!_current || !scope.isCurrent) return;
      if (row['request_id']?.toString() != _request!['requestId'] ||
          row['submitted_by']?.toString() != _requestActor ||
          row['file_sha256'] != _fileHash ||
          row['file_name'] != _filename ||
          row['supplier_id']?.toString() != widget.supplierId ||
          row['currency_id']?.toString() != widget.currencyId ||
          row['source_reference'] != _request!['sourceReference'] ||
          row['effective_date']?.toString() != _request!['effectiveDate'] ||
          row['counterpart_confirmed_by'] !=
              _request!['counterpartConfirmedBy'] ||
          row['counterpart_confirmed_date']?.toString() !=
              _request!['counterpartConfirmedDate']) {
        throw StateError('原请求、对象或附件回执不匹配，请保留原请求');
      }
      final expected = [
        for (final r in (_request!['candidates'] as List))
          '${(r as Map)['candidateId']}:${r['sourceFingerprint']}',
      ]..sort();
      final actual = [
        for (final r in _maps(row['lines']))
          '${r['candidate_id']}:${r['source_fingerprint']}',
      ]..sort();
      if (!const DeepCollectionEquality().equals(expected, actual)) {
        throw StateError('原确认来源行或原版本回执不一致，请保留原请求');
      }
      await completeFormDraft();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenButton(
    onPressed: _busy ? null : _reconcile,
    child: const Text('只读核对原回执'),
  );
  Future<void> _close() async {
    if (!_busy && await confirmFormDraftExit() && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch ||
        !formDraftIdentityIsCurrent) {
      return withFormDraft(_lost(context));
    }
    final enabled =
        !_busy && !_loading && !_unknown && !formDraftHasUnknownSubmission;
    return withFormDraft(
      UtenDialogFrame(
        maxWidth: 1000,
        fillHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              title: const Text('提交对账确认'),
              showCloseButton: true,
              onClose: _busy ? null : _close,
            ),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 220,
                    child: UtenDateField(
                      label: '确认日期',
                      value: _date,
                      enabled: enabled,
                      onChanged: (d) => setState(() {
                        _date = d;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: UtenDateField(
                      label: '对方确认日期',
                      value: _signed,
                      enabled: enabled,
                      onChanged: (d) => setState(() {
                        _signed = d;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: 230,
                    child: UtenInput(
                      label: '对方确认人',
                      controller: _name,
                      enabled: enabled,
                      onChanged: (_) => markFormDraftChanged(),
                    ),
                  ),
                  SizedBox(
                    width: 440,
                    child: UtenInput(
                      label: '来源依据',
                      controller: _reference,
                      enabled: enabled,
                      onChanged: (_) => markFormDraftChanged(),
                    ),
                  ),
                  UtenButton(
                    onPressed: enabled ? _pick : null,
                    child: const Text('选择原确认件'),
                  ),
                  if (_filename != null) Text(_filename!),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: financeSourceTable(
                tableKey: 'finance.procurement-confirmation.submit',
                columns: [
                  financeSourceColumn('billNo', '来源单号', width: 220),
                  financeSourceColumn('commercialDate', '原单日期', type: 'date'),
                  financeSourceColumn('amountOriginal', '原币金额', type: 'money'),
                  financeSourceColumn('amountLocal', '账面本币', type: 'money'),
                ],
                rows: _selected,
                idOf: (r) => '${r['id']}',
              ),
            ),
            UtenDialogActions(
              children: [
                TextButton(
                  onPressed: _busy ? null : _close,
                  child: const Text('取消'),
                ),
                if (_unknown && _request != null)
                  formDraftSubmissionRecoveryAction!,
                UtenButton(
                  onPressed: _busy || _loading || !_canWrite ? null : _save,
                  child: Text(_unknown ? '核对并重试原请求' : '提交对账确认'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmationDetail extends ConsumerStatefulWidget {
  const _ConfirmationDetail({required this.id});
  final String id;
  @override
  ConsumerState<_ConfirmationDetail> createState() =>
      _ConfirmationDetailState();
}

class _ConfirmationDetailState extends ConsumerState<_ConfirmationDetail> {
  late final ApiClient _api;
  late final int _epoch;
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false, _unknown = false;
  String? _pendingAction;
  String? _reason;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load();
  }

  Future<void> _load() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      final data = await _api.get('$_path/${widget.id}');
      if (_current) setState(() => _data = data);
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _act(String action) async {
    if (!_current || _busy) return;
    if (!_unknown) {
      final reason = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => UtenAlertDialog(
          title: Text(action == 'approve' ? '审核对账确认？' : '反审对账确认？'),
          content: action == 'approve'
              ? const Text('核对全部原来源和对方确认件后，生成唯一正式应付。提交人与审核人须为不同人员。')
              : UtenInput(label: '反审原因', controller: reason),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      final value = reason.text;
      reason.dispose();
      if (!_current || ok != true) return;
      _pendingAction = action;
      _reason = value;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final wasUnknown = _unknown;
    try {
      final data = await _api.post(
        '$_path/${widget.id}/$_pendingAction',
        body: _pendingAction == 'reverse' ? {'reason': _reason} : null,
      );
      if (_current) {
        setState(() {
          _data = data;
          _unknown = false;
        });
      }
    } catch (e) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(e);
          _error = _unknown ? '结果尚未确认，请核对并重试原操作。${_message(e)}' : _message(e);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _file() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      // 原确认件下载进统一进度弹窗: 字节进度、可立即取消; 取消则不落盘。
      final bytes = await showUtenProgress<Uint8List>(
        context,
        title: '下载确认文件',
        icon: Icons.download_outlined,
        initialStatus: '正在下载',
        initialDetail: _data?['file_name']?.toString(),
        action: (progress) => _api.postForBytes(
          '$_path/${widget.id}/file',
          onReceiveProgress: progress.receiving('正在下载'),
        ),
      );
      if (bytes != null && _current) {
        await saveBytes(
          bytes,
          '${_data?['file_name'] ?? 'confirmation.bin'}',
          stillCurrent: () => _current,
        );
      }
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) return _lost(context);
    final perms = ref.watch(currentPermissionsProvider);
    final can =
        perms.contains(Perm.supplierSettlementConfirm) &&
        perms.contains(Perm.financePostExecute);
    final lines = _maps(_data?['lines']);
    return PopScope(
      canPop: !_busy && !_unknown,
      child: UtenDialogFrame(
        maxWidth: 1100,
        fillHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              title: Text('对账确认 · ${_status(_data?['status'])}'),
              showCloseButton: true,
              onClose: _busy || _unknown ? null : () => Navigator.pop(context),
            ),
            if (_data != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  '确认日期：${_data!['effective_date']}　对方确认人：${_data!['counterpart_confirmed_by']}\n原确认件：${_data!['file_name']}\n来源依据：${_data!['source_reference']}',
                ),
              ),
            Expanded(
              child: financeSourceTable(
                tableKey: 'finance.procurement-confirmation.detail',
                columns: [
                  financeSourceColumn('bill_no', '来源单号', width: 220),
                  financeSourceColumn('commercial_date', '原单日期', type: 'date'),
                  financeSourceColumn(
                    'confirmed_original',
                    '原币金额',
                    type: 'money',
                  ),
                  financeSourceColumn('confirmed_local', '账面本币', type: 'money'),
                ],
                rows: lines,
                idOf: (r) => '${r['candidate_id']}',
                busy: _busy,
                error: _error,
                retry: _load,
                actions: [
                  UtenButton(
                    onPressed: _busy || _unknown ? null : _file,
                    child: const Text('下载原确认件'),
                  ),
                  if (can && _data?['status'] == 'DRAFT')
                    UtenButton(
                      onPressed: _busy || _unknown
                          ? null
                          : () => _act('approve'),
                      child: const Text('审核'),
                    ),
                  if (can && _data?['status'] == 'POSTED')
                    UtenButton(
                      onPressed: _busy || _unknown
                          ? null
                          : () => _act('reverse'),
                      child: const Text('反审'),
                    ),
                  if (_unknown)
                    UtenButton(
                      onPressed: _busy ? null : () => _act(_pendingAction!),
                      child: const Text('核对并重试原操作'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.map((row) => Map<String, dynamic>.from(row as Map)).toList()
    : [];
String _message(Object error) =>
    error is ApiException ? error.message : error.toString();
bool _rejected(Object error) =>
    error is ApiException &&
    error.hasResponseCode &&
    (error.httpStatus ?? 0) >= 400 &&
    (error.httpStatus ?? 0) < 500 &&
    error.httpStatus != 408;
String _day(DateTime date) => ChinaDateTime.formatDate(date);
String _status(Object? value) => switch (value) {
  'DRAFT' => '待审核',
  'POSTED' => '已确认',
  'REVERSED' => '已反审',
  _ => value?.toString() ?? '加载中',
};
Widget _lost(BuildContext context) => UtenAlertDialog(
  showCloseButton: true,
  onClose: () => Navigator.pop(context),

  title: const Text('财务身份已变化'),
  content: const Text('请重新打开当前入口，原身份的结果不会继续发布。'),
);

import 'dart:async';
import '../shared/finance_workbench_panel.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import '../../../core/print/print_bounds.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/io/file_saver.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/business_submission_headers.dart';
import '../../../core/performance/responsive_data_codec.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_column.dart';
import '../../report/shared/report_print_preview.dart';
import '../config/finance_requirement_names.dart';
import 'finance_auxiliary_dialog.dart';
import 'finance_entry_file_picker.dart';
import 'finance_source_table.dart';
import 'finance_statement_supplemental_cells.dart';
import 'finance_statement_compare_dialog.dart';
import 'finance_payable_statement_adjustment_dialog.dart';

const _base = '/finance/statement-documents';
const _profileKinds = {
  'OWN': '本方打印资料',
  'COUNTERPART': '对方打印资料',
  'CONTEXT': '账载余额及质保资料',
};
const _statuses = {
  'SUBMITTED': '待审核',
  'APPROVED': '已审核',
  'REJECTED': '已退回',
  'INTERNAL_CONFIRMED': '内部已确认',
  'BOTH_CONFIRMED': '双方已确认',
};
const _fields = {
  'organizationName': '组织名称',
  'address': '地址',
  'phone': '电话',
  'fax': '传真',
  'bankHolder': '收款户名',
  'bankName': '开户行',
  'bankAccount': '收款账户',
  'receiver': '收货方',
  'receiverPhone': '联系电话',
  'printRemark': '打印备注',
};
List<Map<String, dynamic>> _maps(Object? v) => [
  if (v is List)
    for (final row in v)
      if (row is Map) Map<String, dynamic>.from(row),
];
Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};
String _errorText(Object e) => humanErrorMessage(e) ?? '未处理完成，请保留原资料并重新核对';
String _title(String? key) => switch (key) {
  'supplierStatement' => FinanceRequirementNames.supplierStatement,
  'subcontractStatement' => FinanceRequirementNames.subcontractStatement,
  'clientStatement' => FinanceRequirementNames.clientStatement,
  'otherReceivableStatement' =>
    FinanceRequirementNames.otherReceivableStatement,
  _ => '对账原件',
};

/// Entry scope is the actual report identity, never inferred from its caption.
Future<bool> showFinanceStatementDocumentDialog(
  BuildContext context, {
  required String templateKey,
  required String partyRole,
  required String partyId,
  required String currencyId,
  required String dateFrom,
  required String dateTo,
  String? materialContextId,
  bool allMaterialContexts = true,
  String? resumeDraftId,
  String? draftMode,
  String? draftTargetId,
  String? draftProfileKind,
  Future<void> Function(String reviewId)? onOpenOriginal,
}) async =>
    await showFinanceWorkbenchPanel<bool>(
      context: context,
      builder: (_) => FinanceStatementDocumentDialog(
        scope: {
          'templateKey': templateKey,
          'partyRole': partyRole,
          'partyId': partyId,
          'currencyId': currencyId,
          'dateFrom': dateFrom,
          'dateTo': dateTo,
          if (materialContextId != null) ...{
            'materialContextId': materialContextId,
            'allMaterialContexts': allMaterialContexts,
          },
        },
        resumeDraftId: resumeDraftId,
        draftMode: draftMode,
        draftTargetId: draftTargetId,
        draftProfileKind: draftProfileKind,
        onOpenOriginal: onOpenOriginal,
      ),
    ) ??
    false;

class FinanceStatementDocumentDialog extends ConsumerStatefulWidget {
  const FinanceStatementDocumentDialog({
    super.key,
    required this.scope,
    this.resumeDraftId,
    this.draftMode,
    this.draftTargetId,
    this.draftProfileKind,
    this.onOpenOriginal,
  });
  final Map<String, dynamic> scope;
  final String? resumeDraftId, draftMode, draftTargetId, draftProfileKind;
  final Future<void> Function(String reviewId)? onOpenOriginal;
  @override
  ConsumerState<FinanceStatementDocumentDialog> createState() =>
      _DirectoryState();
}

class _DirectoryState extends ConsumerState<FinanceStatementDocumentDialog> {
  late final ApiClient _api;
  late final int _epoch;
  String _kind = 'REVIEWS';
  bool _busy = false, _changed = false;
  String? _error;
  List<Map<String, dynamic>> _rows = [];
  int _page = 1, _pages = 0;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool _can(String p) => ref.read(currentPermissionsProvider).contains(p);
  String get _write => widget.scope['partyRole'] == 'SUPPLIER'
      ? Perm.supplierSettlementConfirm
      : Perm.financeReceiptApprove;
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _load(1);
      if (_current && widget.resumeDraftId != null) {
        await _command(
          widget.draftMode ?? 'SUBMIT',
          id: widget.draftTargetId,
          profile: widget.draftProfileKind,
          resume: widget.resumeDraftId,
        );
      }
    });
  }

  Future<void> _load(int page) async {
    if (!_current || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = _kind == 'REVIEWS'
          ? await _api.post(
              '$_base/reviews/query',
              body: widget.scope,
              query: {'page': page, 'size': 50},
            )
          : await _api.get(
              '$_base/profiles',
              query: {
                'kind': _kind,
                'templateKey': _kind == 'CONTEXT'
                    ? widget.scope['templateKey']
                    : 'ALL',
                if (_kind != 'OWN') 'partyRole': widget.scope['partyRole'],
                if (_kind != 'OWN') 'partyId': widget.scope['partyId'],
                'currencyId': widget.scope['currencyId'],
                'page': page,
                'size': 50,
              },
            );
      if (_current) {
        setState(() {
          _rows = _maps(data['items']);
          _page = page;
          _pages = (data['totalPages'] as num?)?.toInt() ?? 0;
        });
      }
    } catch (e) {
      if (_current) {
        setState(() => _error = _errorText(e));
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _command(
    String mode, {
    String? id,
    String? profile,
    String? resume,
  }) async {
    if (!_current || _busy) {
      return;
    }
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FinanceStatementDocumentEditor(
        scope: widget.scope,
        mode: mode,
        targetId: id,
        profileKind: profile,
        resumeDraftId: resume,
      ),
    );
    if (_current) {
      if (changed == true) {
        _changed = true;
      }
      await _load(_page);
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    if (!_current || _busy) {
      return;
    }
    final id = row['id'].toString();
    if (_kind != 'REVIEWS') {
      await _command('PROFILE_VIEW', id: id, profile: _kind);
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _Original(
        scope: widget.scope,
        id: id,
        onCommand: (mode) => _command(mode, id: id),
        onOpenOriginal: widget.onOpenOriginal,
      ),
    );
    if (_current) {
      await _load(_page);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(exportContextEpochProvider);
    ref.watch(apiClientProvider);
    ref.watch(currentPermissionsProvider);
    if (!_current) return _retiredDocument(context);
    return _Frame(
      showCloseButton: true,
      onClose: _busy ? null : () => Navigator.pop(context, _changed),
      title: Text(
        '${_title(widget.scope['templateKey']?.toString())} · 原件与打印资料',
      ),
      width: 1180,
      busy: _busy,
      hint:
          '${widget.scope['dateFrom']} 至 ${widget.scope['dateTo']}。原件按实际对象、币别和期间分别保留。',
      content: SizedBox(
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDropdownField(
              label: '资料分类',
              value: _kind,
              items: [
                const UtenDropdownItem(value: 'REVIEWS', label: '对账原件'),
                for (final e in _profileKinds.entries)
                  UtenDropdownItem(value: e.key, label: e.value),
              ],
              enabled: !_busy,
              onChanged: (v) {
                if (v != null && v != _kind) {
                  setState(() {
                    _kind = v;
                    _rows = [];
                  });
                  _load(1);
                }
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: financeSourceTable(
                tableKey: 'finance-statement-documents-$_kind',
                columns: [
                  if (_kind != 'REVIEWS')
                    financeSourceColumn('revision', '版本', width: 90),
                  financeSourceColumn(
                    'status',
                    '状态',
                    value: (r) =>
                        _statuses[r['status']] ?? r['status']?.toString(),
                  ),
                  financeSourceColumn('submitted_name', '提交人'),
                  financeSourceColumn('submitted_at', '提交时间', width: 210),
                  financeSourceColumn(
                    _kind == 'REVIEWS' ? 'approved_name' : 'reviewed_name',
                    '审核人',
                  ),
                  financeSourceColumn(
                    _kind == 'REVIEWS' ? 'document_sha256' : 'source_reference',
                    _kind == 'REVIEWS' ? '原件SHA' : '来源依据',
                    width: 300,
                  ),
                ],
                rows: _current ? _rows : [],
                idOf: (r) => r['id'].toString(),
                busy: _busy,
                error: _current ? _error : '身份或权限已变化，请重新打开',
                retry: () => _load(_page),
                page: _page,
                pages: _pages,
                onPage: _load,
                onOpen: _open,
                scope: widget.scope,
                actions: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy ? null : () => _load(_page),
                    child: const Text('刷新'),
                  ),
                  if (_kind == 'REVIEWS')
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy ? null : () => _command('PREVIEW'),
                      child: const Text('核对当前原件'),
                    ),
                  if (_kind == 'REVIEWS' &&
                      const {
                        'supplierStatement',
                        'subcontractStatement',
                        'clientStatement',
                      }.contains(widget.scope['templateKey']))
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy
                          ? null
                          : () async {
                              if (!_current) return;
                              await showFinanceStatementCompareDialog(
                                context,
                                scope: widget.scope,
                              );
                            },
                      child: const Text('原表导入比对'),
                    ),
                  if (_kind == 'REVIEWS' && _can(_write))
                    UtenButton(
                      onPressed: _busy ? null : () => _command('SUBMIT'),
                      child: const Text('提交对账原件'),
                    ),
                  if (_kind != 'REVIEWS' && _can(Perm.paymentStyleEdit))
                    UtenButton(
                      onPressed: _busy
                          ? null
                          : () => _command('PROFILE_SAVE', profile: _kind),
                      child: const Text('新建资料版本'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: const [],
    );
  }
}

class _Original extends ConsumerStatefulWidget {
  const _Original({
    required this.scope,
    required this.id,
    required this.onCommand,
    this.onOpenOriginal,
  });
  final Map<String, dynamic> scope;
  final String id;
  final Future<void> Function(String) onCommand;
  final Future<void> Function(String)? onOpenOriginal;
  @override
  ConsumerState<_Original> createState() => _OriginalState();
}

class _OriginalState extends ConsumerState<_Original> {
  late final ApiClient _api;
  late final int _epoch;
  Map<String, dynamic>? _source;
  ReportData? _data;
  bool _busy = false;
  String? _error;
  int _page = 1;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool _can(String p) => ref.read(currentPermissionsProvider).contains(p);
  String get _endpoint => '$_base/reviews/${widget.id}/original-table';
  String get _report =>
      'statements/${switch (widget.scope['templateKey']) {
        'supplierStatement' => 'supplier',
        'subcontractStatement' => 'subcontract',
        'clientStatement' => 'client',
        _ => 'other-receivable',
      }}';
  Map<String, dynamic> get _export => {
    'statementReviewId': widget.id,
    'dateFrom': widget.scope['dateFrom'],
    'dateTo': widget.scope['dateTo'],
    'partyId': widget.scope['partyId'],
    'currencyId': widget.scope['currencyId'],
    if (widget.scope['materialContextId'] case final contextId?) ...{
      'materialContextId': contextId,
      'allMaterialContexts': widget.scope['allMaterialContexts'] ?? true,
    },
    'layout': 'template',
  };
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load(1);
  }

  Future<void> _load(int page) async {
    if (!_current || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.get('$_base/reviews/${widget.id}'),
        _api.get(_endpoint, query: {'page': page, 'size': 50}),
      ]);
      final parsed = await parseReportResponseResponsive(
        results[1],
        page,
        isCurrent: () => _current,
      );
      if (_current) {
        setState(() {
          _source = results[0];
          _data = parsed;
          _page = page;
        });
      }
    } catch (e) {
      if (_current) {
        setState(() => _error = _errorText(e));
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _command(String mode) async {
    await widget.onCommand(mode);
    if (_current) {
      await _load(_page);
    }
  }

  Future<void> _download() async {
    if (!_current || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await _api.postForBytes(
        '$_base/reviews/${widget.id}/counterpart-file',
      );
      if (_current) {
        await saveBytes(
          bytes,
          _source?['counterpart_file_name']?.toString() ??
              '对账确认件-${widget.id}.bin',
          stillCurrent: () => _current,
        );
      }
    } catch (e) {
      if (_current) {
        setState(() => _error = _errorText(e));
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(exportContextEpochProvider);
    ref.watch(apiClientProvider);
    ref.watch(currentPermissionsProvider);
    if (!_current) return _retiredDocument(context);
    final data = _data;
    final write = _can(
      widget.scope['partyRole'] == 'SUPPLIER'
          ? Perm.supplierSettlementConfirm
          : Perm.financeReceiptApprove,
    );
    return _Frame(
      showCloseButton: true,
      onClose: _busy ? null : () => Navigator.pop(context),
      title: const Text('对账原件'),
      width: 1240,
      busy: _busy,
      content: SizedBox(
        height: 650,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_source != null)
              SelectableText(
                '状态：${_statuses[_source!['status']] ?? _source!['status']}　提交：${_source!['submitted_name']}　内部审核：${_source!['approved_name'] ?? '待审核'}\n原件SHA：${_source!['document_sha256']}',
              ),
            if (data != null) ..._lines(data.documentMetadata, 'headerLines'),
            const SizedBox(height: 10),
            Expanded(
              child: financeSourceTable(
                tableKey:
                    'finance-statement-original-${widget.scope['templateKey']}',
                columns: [
                  if (data != null)
                    for (final c in data.columns)
                      financeSourceColumn(
                        c.key,
                        c.label,
                        width: c.width ?? 150,
                        type: c.type,
                        headerGroups: c.headerGroups,
                        value: (r) => formatReportCell(c, r),
                      ),
                ],
                rows: _current ? data?.rows ?? [] : [],
                idOf: (r) => '${r.hashCode}',
                showColumnChooser: false,
                busy: _busy,
                error: _error,
                retry: () => _load(_page),
                page: _page,
                pages: data?.totalPages ?? 0,
                onPage: _load,
                actions: [
                  UtenPrintPreviewButton(
                    title:
                        data?.documentMetadata['title']?.toString() ?? '对账原件',
                    subtitle: '原件共${data?.total ?? 0}行',
                    applyTableProjection: false,
                    showOutputScope: false,
                    enabled: !_busy && data != null,
                    loader: () => loadBoundedReportPrintPreview(
                      api: _api,
                      endpointOf: () => _endpoint,
                      queryOf: () => {},
                      isCurrent: () => _current,
                      repeatColumnHeaders: true,
                      rowLimit: maximumCompleteOriginalPrintRows,
                    ),
                    exportEndpoint: '/finance/reports/export',
                    exportReport: _report,
                    exportQuery: _export,
                    exportPermission: Perm.financeReportExport,
                  ),
                  UtenExportButton(
                    showOutputScope: false,
                    endpoint: '/finance/reports/export',
                    report: _report,
                    queryParams: _export,
                    requiredPermission: Perm.financeReportExport,
                    enabled: !_busy && data != null,
                    filename: '对账原件-${widget.id}',
                  ),
                  if (write &&
                      widget.scope['partyRole'] == 'SUPPLIER' &&
                      const {
                        'INTERNAL_CONFIRMED',
                        'BOTH_CONFIRMED',
                      }.contains(_source?['status']) &&
                      _source?['source_fingerprint'] != null)
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy
                          ? null
                          : () async {
                              if (!_current) return;
                              await showFinancePayableStatementAdjustmentDialog(
                                context,
                                statementReviewId:
                                    _map(
                                      data?.documentMetadata['settlementVersion'],
                                    )['rootReviewId']?.toString() ??
                                    widget.id,
                                expectedSourceFingerprint:
                                    _map(
                                      data?.documentMetadata['settlementVersion'],
                                    )['rootSourceFingerprint']?.toString() ??
                                    _source!['source_fingerprint'].toString(),
                              );
                              if (_current) await _load(_page);
                            },
                      child: const Text('手续费/尾数处理'),
                    ),
                  if (write &&
                      widget.scope['partyRole'] == 'SUPPLIER' &&
                      const {
                        'INTERNAL_CONFIRMED',
                        'BOTH_CONFIRMED',
                      }.contains(_source?['status']))
                    UtenButton(
                      onPressed: _busy ? null : () => _command('SETTLEMENT'),
                      child: const Text('生成结算原件'),
                    ),
                  if (write && _source?['status'] == 'SUBMITTED') ...[
                    UtenButton(
                      onPressed: _busy
                          ? null
                          : () => _command('REVIEW_APPROVE'),
                      child: const Text('确认原件'),
                    ),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy ? null : () => _command('REVIEW_REJECT'),
                      child: const Text('退回原件'),
                    ),
                  ],
                  if (write && _source?['status'] == 'INTERNAL_CONFIRMED')
                    UtenButton(
                      onPressed: _busy ? null : () => _command('COUNTERPART'),
                      child: const Text('保存对方确认件'),
                    ),
                  if (_source?['status'] == 'BOTH_CONFIRMED')
                    UtenButton(
                      onPressed: _busy ? null : _download,
                      child: const Text('下载对方确认件'),
                    ),
                  if (widget.onOpenOriginal != null)
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy
                          ? null
                          : () => widget.onOpenOriginal!(widget.id),
                      child: const Text('在原表打开'),
                    ),
                ],
              ),
            ),
            if (data != null)
              FinanceStatementSupplementalCells(
                metadata: data.documentMetadata,
              ),
            if (data != null) ..._lines(data.documentMetadata, 'footerLines'),
          ],
        ),
      ),
      actions: const [],
    );
  }
}

List<Widget> _lines(Map<String, dynamic> metadata, String group) => [
  for (final r in _maps(metadata[group]))
    Text(
      '${r['label'] ?? ''}${r['value'] ?? '待维护/签署'}${r['pending'] == true ? '（待核）' : ''}',
    ),
];

/// Shared editor for immutable source versions and their actual confirmations.
class FinanceStatementDocumentEditor extends ConsumerStatefulWidget {
  const FinanceStatementDocumentEditor({
    super.key,
    required this.scope,
    required this.mode,
    this.targetId,
    this.profileKind,
    this.resumeDraftId,
  });
  final Map<String, dynamic> scope;
  final String mode;
  final String? targetId, profileKind, resumeDraftId;
  @override
  ConsumerState<FinanceStatementDocumentEditor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<FinanceStatementDocumentEditor>
    with FormDraftMixin<FinanceStatementDocumentEditor> {
  late final ApiClient _api;
  late final int _readEpoch;
  final Map<String, TextEditingController> _text = {};
  Map<String, dynamic>? _source, _sent;
  Map<String, dynamic> _submissionHeaders = const {};
  Map<String, dynamic>? _settlementPreview, _settlementPreviewInput;
  bool _noDeductions = false;
  bool get _settlement => widget.mode == 'SETTLEMENT';
  List<Map<String, dynamic>> _balances = [], _retentions = [], _currencies = [];
  String _request = const Uuid().v4();
  int _revision = -1;
  bool _loading = true, _saving = false, _retentionKnown = false;
  String? _error, _filename, _fileHash;
  Uint8List? _bytes;
  DraftByteValue? _draftFile;
  bool _pickingFile = false;
  bool get _profile => widget.mode.startsWith('PROFILE');
  bool get _saveProfile => widget.mode == 'PROFILE_SAVE';
  bool get _view => widget.mode == 'PROFILE_VIEW' || widget.mode == 'PREVIEW';
  String get _kind =>
      widget.profileKind ?? _source?['kind']?.toString() ?? 'OWN';
  bool get _current =>
      mounted &&
      formDraftIdentityIsCurrent &&
      _readEpoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  TextEditingController _c(String k) =>
      _text.putIfAbsent(k, () => TextEditingController());
  @override
  FormDraftSpec get formDraftSpec =>
      (_profile
              ? (_saveProfile || _view
                    ? FormDraftCatalog.financeStatementProfile
                    : FormDraftCatalog.financeStatementProfileReview)
              : widget.scope['partyRole'] == 'SUPPLIER'
              ? FormDraftCatalog.financeStatementReview
              : FormDraftCatalog.financeStatementClientReview)
          .spec(
            title: _profile ? '对账打印资料' : '对账原件处理',
            routeParameters: {
              for (final e in widget.scope.entries)
                'statement.${e.key}': e.value.toString(),
              'statement.mode': widget.mode,
              if (widget.targetId != null)
                'statement.targetId': widget.targetId!,
              if (widget.profileKind != null)
                'statement.profileKind': widget.profileKind!,
            },
          );
  @override
  bool get formDraftEnabled => !_view;
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _saving;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftCanReplaySubmission => _sent != null;
  @override
  Iterable<Listenable> get formDraftListenables => _text.values;
  @override
  Map<String, dynamic> captureFormDraft() => {
    'scope': widget.scope,
    'mode': widget.mode,
    'targetId': widget.targetId,
    'kind': _kind,
    'text': {for (final e in _text.entries) e.key: e.value.text},
    'balances': _balances,
    'retentions': _retentions,
    'retentionKnown': _retentionKnown,
    'request': _request,
    'sent': _sent,
    'submissionHeaders': businessSubmissionHeaders(_submissionHeaders),
    'settlementPreview': _settlementPreview,
    'settlementPreviewInput': _settlementPreviewInput,
    'noDeductions': _noDeductions,
    'revision': _revision,
    'filename': _filename,
    'fileHash': _fileHash,
    'fileBytes': _draftFile?.jsonValue,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (!const DeepCollectionEquality().equals(data['scope'], widget.scope) ||
        data['mode'] != widget.mode ||
        data['targetId'] != widget.targetId ||
        data['kind'] != _kind) {
      throw StateError('原件草稿的对象、币别、期间或动作不一致');
    }
    final request = data['request'];
    if (request is! String || !Uuid.isValidUUID(fromString: request)) {
      throw StateError('原提交编号缺失');
    }
    _request = request;
    for (final e in _map(data['text']).entries) {
      _c(e.key).text = e.value?.toString() ?? '';
    }
    _balances = _maps(data['balances']);
    _retentions = _maps(data['retentions']);
    _retentionKnown = data['retentionKnown'] == true;
    _revision = (data['revision'] as num?)?.toInt() ?? -1;
    _sent = data['sent'] == null ? null : _map(data['sent']);
    _submissionHeaders = businessSubmissionHeaders(data['submissionHeaders']);
    _settlementPreview = data['settlementPreview'] == null
        ? null
        : _map(data['settlementPreview']);
    _settlementPreviewInput = data['settlementPreviewInput'] == null
        ? null
        : _map(data['settlementPreviewInput']);
    _noDeductions = data['noDeductions'] == true;
    _filename = data['filename']?.toString();
    _fileHash = data['fileHash']?.toString();
    if (data['fileBytes'] case final String encoded) {
      final bytes = await decodeBase64Responsive(
        encoded,
        isCurrent: () => _current,
      );
      if (bytes.length > 15 * 1024 * 1024 ||
          await sha256HexResponsive(bytes, isCurrent: () => _current) !=
              _fileHash) {
        throw StateError('原回传附件与原校验值不一致，请保留原请求');
      }
      _draftFile = DraftByteValue.decoded(bytes, encoded);
      _bytes = _draftFile!.bytes;
    }

    if (_sent != null && _saveProfile && _sent!['requestId'] != _request) {
      throw StateError('原打印资料提交编号不一致');
    }
    if (_sent != null &&
        _settlement &&
        (_sent!['requestId'] != _request ||
            _map(_sent!['source'])['basedReviewId'] != widget.targetId)) {
      throw StateError('结算原件的原提交编号或基础原件不一致');
    }
    if (_sent != null &&
        widget.mode == 'SUBMIT' &&
        (_sent!['requestId'] != _request ||
            !const DeepCollectionEquality().equals(
              _sent!['context'],
              widget.scope,
            ))) {
      throw StateError('原对账原件提交范围不一致');
    }
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _readEpoch = ref.read(exportContextEpochProvider);
    for (final k in [
      ..._fields.keys,
      'sourceReference',
      'reason',
      'signatoryName',
      'confirmedDate',
    ]) {
      _c(k);
    }
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final scope = await captureFormDraftRequestScope();
      if (_profile) {
        if (widget.targetId != null) {
          _source = await scope.run(
            () => _api.get('$_base/profiles/${widget.targetId}'),
          );
        } else {
          final list = await scope.run(
            () => _api.get(
              '$_base/profiles',
              query: {
                'kind': _kind,
                'templateKey': _kind == 'CONTEXT'
                    ? widget.scope['templateKey']
                    : 'ALL',
                if (_kind != 'OWN') 'partyRole': widget.scope['partyRole'],
                if (_kind != 'OWN') 'partyId': widget.scope['partyId'],
                'currencyId': widget.scope['currencyId'],
                'page': 1,
                'size': 1,
              },
            ),
          );
          final rows = _maps(list['items']);
          if (rows.isNotEmpty) {
            _revision = (rows.first['revision'] as num).toInt();
            _source = await scope.run(
              () => _api.get('$_base/profiles/${rows.first['id']}'),
            );
          }
        }
        if (!scope.isCurrent || !_current) {
          return;
        }
        final body = _map(_source?['body']);
        for (final k in _fields.keys) {
          _c(k).text = body[k]?.toString() ?? '';
        }
        _balances = [
          if (body['balance'] is Map) _map(body['balance']),
          ..._maps(body['additionalBalances']),
        ];
        _retentions = _maps(body['retentions']);
        _retentionKnown = body['retentions'] is List;
        if (_kind == 'CONTEXT' && _saveProfile) {
          final options = await scope.run(
            () => _api.get('/finance/chart/options'),
          );
          _currencies = _maps(options['currencies']);
        }
      } else if (widget.targetId != null) {
        _source = await scope.run(
          () => _api.get('$_base/reviews/${widget.targetId}'),
        );
      } else {
        _source = await scope.run(
          () => _api.post('$_base/preview', body: widget.scope),
        );
      }
      if (!scope.isCurrent || !_current) {
        return;
      }
      setState(() => _loading = false);
      if (!_view) {
        await initializeFormDraft();
      }
    } catch (e) {
      if (_current) {
        setState(() {
          _loading = false;
          _error = _errorText(e);
        });
      }
    }
  }

  Future<void> _balance() async {
    if (!_current || _saving || _sent != null || _balances.length >= 20) {
      return;
    }
    final code = TextEditingController();
    String? currency;
    Map<String, dynamic>? auxiliary;
    bool original =
        _balances.isEmpty || _balances.first['originalAmounts'] == true;
    final result = await UtenDialog.showAndWaitForExit<Map<String, dynamic>>(
      context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => _Frame(
          title: const Text('选择真实账载余额来源'),
          width: 620,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenInput(
                controller: code,
                label: '科目代码',
                onChanged: (_) => setLocal(() => auxiliary = null),
              ),
              UtenDropdownField(
                label: '科目会计币别',
                value: currency,
                items: [
                  for (final c in _currencies)
                    UtenDropdownItem(
                      value: c['id'].toString(),
                      label: '${c['code']} ${c['name']}',
                    ),
                ],
                onChanged: (v) => setLocal(() => currency = v),
              ),
              UtenDropdownField(
                label: '金额口径',
                value: original ? 'ORIGINAL' : 'LOCAL',
                enabled: _balances.isEmpty,
                items: const [
                  UtenDropdownItem(value: 'ORIGINAL', label: '原币金额'),
                  UtenDropdownItem(value: 'LOCAL', label: '本币账面金额'),
                ],
                onChanged: (v) => setLocal(() => original = v == 'ORIGINAL'),
              ),
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: code.text.trim().isEmpty
                    ? null
                    : () async {
                        final selected = await showFinanceAuxiliaryPicker(
                          context,
                          accountCode: code.text.trim(),
                          role: widget.scope['partyRole']?.toString(),
                        );
                        if (context.mounted && selected != null) {
                          setLocal(() => auxiliary = selected);
                        }
                      },
                child: Text(
                  auxiliary == null
                      ? '选择该科目的实际辅助项目'
                      : '${auxiliary!['sourceCode']} ${auxiliary!['sourceName']}',
                ),
              ),
            ],
          ),
          actions: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            UtenButton(
              onPressed:
                  code.text.trim().isEmpty ||
                      currency == null ||
                      auxiliary == null
                  ? null
                  : () => Navigator.pop(context, {
                      'accountCode': code.text.trim(),
                      'auxiliaryId': auxiliary!['id'],
                      'auxiliaryName':
                          '${auxiliary!['sourceCode']} ${auxiliary!['sourceName']}',
                      'accountingCurrencyId': currency,
                      'originalCurrencyId': original
                          ? widget.scope['currencyId']
                          : null,
                      'originalAmounts': original,
                      'normalDirection': widget.scope['partyRole'] == 'SUPPLIER'
                          ? -1
                          : 1,
                    }),
              child: const Text('使用此来源'),
            ),
          ],
        ),
      ),
    );
    code.dispose();
    if (_current && result != null) {
      setState(() => _balances.add(result));
      markFormDraftChanged();
    }
  }

  Future<void> _retention() async {
    if (!_current || _saving || _sent != null || _retentions.length >= 100) {
      return;
    }
    final date = TextEditingController(
          text: widget.scope['dateFrom']?.toString(),
        ),
        amount = TextEditingController(),
        reference = TextEditingController();
    final result = await UtenDialog.showAndWaitForExit<Map<String, dynamic>>(
      context,
      barrierDismissible: false,
      builder: (context) => _Frame(
        title: const Text('质保组成'),
        width: 600,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenInput(controller: date, label: '实际起点日期 YYYY-MM-DD'),
            UtenInput(controller: amount, label: '原金额（不另加到余额）'),
            UtenInput(controller: reference, label: '协议/来源依据'),
          ],
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          UtenButton(
            onPressed: () => Navigator.pop(context, {
              'effectiveFrom': date.text.trim(),
              'amount': amount.text.trim(),
              'sourceReference': reference.text,
            }),
            child: const Text('保留此组成'),
          ),
        ],
      ),
    );
    date.dispose();
    amount.dispose();
    reference.dispose();
    if (_current && result != null) {
      setState(() => _retentions.add(result));
      markFormDraftChanged();
    }
  }

  Map<String, dynamic> get _settlementInput => {
    'basedReviewId': widget.targetId,
    'expectedBasedFingerprint': _source?['source_fingerprint'],
    'explicitlyNoDeductions': _noDeductions,
    'sourceReference': _c('sourceReference').text,
  };

  Future<void> _previewSettlement() async {
    if (!_current || _saving || _sent != null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final input = _map(jsonDecode(jsonEncode(_settlementInput)));
      final scope = await captureFormDraftRequestScope();
      final preview = await scope.run(
        () => _api.post('$_base/settlement-preview', body: input),
      );
      if (!_current || !scope.isCurrent) return;
      setState(() {
        _settlementPreview = preview;
        _settlementPreviewInput = input;
      });
      markFormDraftChanged();
    } catch (error) {
      if (_current) setState(() => _error = _errorText(error));
    } finally {
      if (_current) setState(() => _saving = false);
    }
  }

  Map<String, dynamic> _payload() {
    if (_settlement) {
      if (_settlementPreview == null ||
          !const DeepCollectionEquality().equals(
            _settlementInput,
            _settlementPreviewInput,
          )) {
        throw StateError('请先核对当前结算原件，修改来源或无扣款选择后需要重新核对');
      }
      return {
        'requestId': _request,
        'source': _settlementPreviewInput,
        'expectedSourceFingerprint': _settlementPreview!['sourceFingerprint'],
      };
    }
    if (_saveProfile) {
      Map<String, dynamic> clean(Map<String, dynamic> r) =>
          {...r}..remove('auxiliaryName');
      return {
        'requestId': _request,
        'expectedRevision': _revision,
        'kind': _kind,
        'templateKey': _kind == 'CONTEXT' ? widget.scope['templateKey'] : 'ALL',
        'partyRole': _kind == 'OWN' ? null : widget.scope['partyRole'],
        'partyId': _kind == 'OWN' ? null : widget.scope['partyId'],
        'currencyId': widget.scope['currencyId'],
        'organization': _kind == 'CONTEXT'
            ? null
            : {for (final k in _fields.keys) k: _c(k).text},
        'settings': _kind == 'CONTEXT'
            ? {
                'balance': _balances.isEmpty ? null : clean(_balances.first),
                'additionalBalances': [
                  for (final b in _balances.skip(1)) clean(b),
                ],
                'retentions': _retentionKnown ? _retentions : null,
                'printRemark': _c('printRemark').text,
              }
            : null,
        'sourceReference': _c('sourceReference').text,
      };
    }
    if (widget.mode == 'SUBMIT') {
      return {
        'requestId': _request,
        'context': widget.scope,
        'expectedSourceFingerprint': _source?['sourceFingerprint'],
      };
    }
    if (widget.mode == 'COUNTERPART') {
      return {
        'documentSha256': _source?['document_sha256'],
        'signatoryName': _c('signatoryName').text,
        'confirmedDate': _c('confirmedDate').text.trim(),
        'sourceReference': _c('sourceReference').text,
      };
    }
    return {
      'approve': widget.mode.endsWith('APPROVE'),
      'reason': _c('reason').text,
    };
  }

  Future<void> _file() async {
    if (!_current || _saving || _pickingFile) return;
    _pickingFile = true;
    try {
      final file = await ref.read(financeConfirmationFilePickerProvider)();
      if (!_current || file == null) return;
      if (file.bytes == null ||
          file.bytes!.isEmpty ||
          file.bytes!.length > 15 * 1024 * 1024) {
        throw StateError('请选择完整且不超过15MB的实际回传文件');
      }
      setState(() => _saving = true);
      final owned = DraftByteValue(file.bytes!),
          hash = await sha256HexResponsive(
            owned.bytes,
            isCurrent: () => _current,
          );
      if (!_current) return;
      if (_sent != null && (_fileHash != hash || _filename != file.name)) {
        throw StateError('上次结果待确认，原回传文件不能替换');
      }
      setState(() {
        _filename = file.name;
        _fileHash = hash;
        _draftFile = owned;
        _bytes = owned.bytes;
      });
      await saveFormDraftNow();
    } catch (e) {
      if (_current) setState(() => _error = _errorText(e));
    } finally {
      _pickingFile = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<Map<String, dynamic>> _send() async {
    if (_settlement) {
      return _api.post(
        '$_base/settlement-reviews',
        body: _sent,
        headers: businessSubmissionHeaders(_submissionHeaders),
      );
    }
    if (_saveProfile) {
      return _api.post('$_base/profiles', body: _sent);
    }
    if (widget.mode == 'SUBMIT') {
      return _api.post('$_base/reviews', body: _sent);
    }
    if (widget.mode == 'COUNTERPART') {
      final prior = await _api.get('$_base/reviews/${widget.targetId}');
      if (prior['status'] == 'BOTH_CONFIRMED' &&
          prior['counterpart_file_sha256'] == _fileHash &&
          prior['counterpart_file_name'] == _filename) {
        return prior;
      }
      if (_bytes == null) {
        throw StateError('请选择与原草稿相同的回传文件，原件和输入均已保留');
      }
      final lower = _filename!.toLowerCase();
      final type = lower.endsWith('.pdf')
          ? 'application/pdf'
          : lower.endsWith('.png')
          ? 'image/png'
          : lower.endsWith('.jpg') || lower.endsWith('.jpeg')
          ? 'image/jpeg'
          : 'application/octet-stream';
      return _api.postMultipartFile(
        '$_base/reviews/${widget.targetId}/counterpart',
        _bytes!,
        _filename!,
        type,
        jsonParts: {'input': _sent},
        headers: businessSubmissionHeaders(_submissionHeaders),
      );
    }
    final endpoint = _profile
        ? '$_base/profiles/${widget.targetId}'
        : '$_base/reviews/${widget.targetId}';
    final prior = await _api.get(endpoint);
    final status = _sent!['approve'] == true
        ? (_profile ? 'APPROVED' : 'INTERNAL_CONFIRMED')
        : 'REJECTED';
    if (prior['status'] == status &&
        prior['review_reason'] == _sent!['reason']) {
      return prior;
    }
    return _api.post(
      '$endpoint/${_profile ? 'review' : 'decision'}',
      body: _sent,
    );
  }

  Future<void> _save() async {
    if (!_current || _loading || _saving || _view) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.mode == 'COUNTERPART' && _sent == null && _bytes == null) {
        throw StateError('请选择实际回传确认文件');
      }
      _sent ??= _map(jsonDecode(jsonEncode(_payload())));
      final scope = await captureFormDraftRequestScope();
      final wasUnknown = formDraftHasUnknownSubmission;
      await runFormDraftSubmission(
        () => scope.run(_send),
        isDefiniteRejection: (e) =>
            !wasUnknown &&
            (e.details?['notWritten'] == true ||
                e.hasResponseCode &&
                    const {
                      'VALIDATION_FAILED',
                      'CONFLICT',
                      'FORBIDDEN',
                      'NOT_FOUND',
                    }.contains(e.code)),
      );
      if (!_current || !scope.isCurrent) {
        return;
      }
      await completeFormDraft();
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!formDraftHasUnknownSubmission) {
        _sent = null;
      }
      if (_current) {
        setState(() => _error = '${_errorText(e)}。原输入已保留。');
      }
    } finally {
      if (_current) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _close() async {
    if (await confirmFormDraftExit() && mounted) {
      Navigator.pop(context, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(exportContextEpochProvider);
    ref.watch(apiClientProvider);
    ref.watch(currentPermissionsProvider);
    if (!_current) {
      return withFormDraft(_retiredDocument(context, close: _close));
    }
    final locked = _saving || _sent != null || _view || !_current;
    return withFormDraft(
      _Frame(
        showCloseButton: true,
        onClose: _saving ? null : _close,
        title: Text(
          _profile
              ? (_profileKinds[_kind] ?? '打印资料')
              : {
                      'PREVIEW': '核对当前原件',
                      'SUBMIT': '提交对账原件',
                      'COUNTERPART': '保存对方确认件',
                      'SETTLEMENT': '生成结算原件',
                    }[widget.mode] ??
                    '审核原资料',
        ),
        width: 1050,
        busy: _saving,
        hint:
            _kind == 'CONTEXT' &&
                (_saveProfile || widget.mode == 'PROFILE_VIEW')
            ? '余额仅合并明确选择的同一对象、同一金额口径来源；质保属于现有余额组成。点击已选草稿行可移除。'
            : widget.mode == 'PREVIEW' || widget.mode == 'SUBMIT'
            ? '此处展示前100行；冻结与下载保留完整原件的全部行。'
            : null,
        content: SizedBox(
          height: 600,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : !_current
              ? const Text('身份或权限已变化，请关闭后重新打开，原输入已保留。')
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null)
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if ((_saveProfile || widget.mode == 'PROFILE_VIEW') &&
                          _kind != 'CONTEXT')
                        for (final e in _fields.entries)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: UtenInput(
                              controller: _c(e.key),
                              label: e.value,
                              enabled: !locked,
                            ),
                          ),
                      if ((_saveProfile || widget.mode == 'PROFILE_VIEW') &&
                          _kind == 'CONTEXT') ...[
                        SizedBox(
                          height: 220,
                          child: financeSourceTable(
                            tableKey: 'finance-statement-balance-selection',
                            columns: [
                              financeSourceColumn('accountCode', '科目代码'),
                              financeSourceColumn(
                                'auxiliaryName',
                                '辅助项目',
                                value: (r) =>
                                    r['auxiliaryName']?.toString() ?? '已保存辅助项目',
                              ),
                              financeSourceColumn(
                                'originalAmounts',
                                '金额口径',
                                value: (r) => r['originalAmounts'] == true
                                    ? '原币金额'
                                    : '本币账面金额',
                              ),
                            ],
                            rows: _balances,
                            idOf: (r) =>
                                '${r['accountCode']}:${r['auxiliaryId']}',
                            onOpen: locked
                                ? null
                                : (r) {
                                    setState(() => _balances.remove(r));
                                    markFormDraftChanged();
                                  },
                            actions: [
                              UtenButton(
                                onPressed: locked ? null : _balance,
                                child: const Text('加入余额来源'),
                              ),
                            ],
                          ),
                        ),
                        UtenDropdownField(
                          label: '质保组成核对',
                          value: _retentionKnown ? 'KNOWN' : 'UNKNOWN',
                          enabled: !locked,
                          items: const [
                            UtenDropdownItem(value: 'UNKNOWN', label: '尚未核对'),
                            UtenDropdownItem(
                              value: 'KNOWN',
                              label: '已核对（空清单表示确认为0）',
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _retentionKnown = v == 'KNOWN');
                            markFormDraftChanged();
                          },
                        ),
                        SizedBox(
                          height: 190,
                          child: financeSourceTable(
                            tableKey: 'finance-statement-retention-selection',
                            columns: [
                              financeSourceColumn('effectiveFrom', '实际起点'),
                              financeSourceColumn(
                                'amount',
                                '组成金额',
                                type: 'money',
                              ),
                              financeSourceColumn(
                                'sourceReference',
                                '来源依据',
                                width: 320,
                              ),
                            ],
                            rows: _retentions,
                            idOf: (r) => '${r.hashCode}',
                            onOpen: locked
                                ? null
                                : (r) {
                                    setState(() => _retentions.remove(r));
                                    markFormDraftChanged();
                                  },
                            actions: [
                              UtenButton(
                                onPressed: locked ? null : _retention,
                                child: const Text('加入质保组成'),
                              ),
                            ],
                          ),
                        ),
                        UtenInput(
                          controller: _c('printRemark'),
                          label: '打印备注',
                          enabled: !locked,
                        ),
                      ],
                      if (_settlement) ...[
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('本次没有手续费及尾数扣款'),
                          value: _noDeductions,
                          onChanged: locked
                              ? null
                              : (value) {
                                  setState(() => _noDeductions = value == true);
                                  markFormDraftChanged();
                                },
                        ),
                        UtenButton(
                          onPressed: locked ? null : _previewSettlement,
                          child: const Text('核对结算原件'),
                        ),
                        if (_settlementPreview != null)
                          ..._lines(
                            _map(_settlementPreview!['documentMetadata']),
                            'footerLines',
                          ),
                      ],
                      if (widget.mode == 'PREVIEW' ||
                          widget.mode == 'SUBMIT') ...[
                        ..._lines(
                          _map(_source?['documentMetadata']),
                          'headerLines',
                        ),
                        ..._lines(
                          _map(_source?['documentMetadata']),
                          'footerLines',
                        ),
                        SelectableText(
                          '源指纹：${_source?['sourceFingerprint'] ?? ''}',
                        ),
                        SizedBox(
                          height: 300,
                          child: financeSourceTable(
                            tableKey: 'finance-statement-live-preview',
                            columns: _maps(_source?['columns']).map((raw) {
                              final column = ReportColumn.fromJson(raw);
                              return financeSourceColumn(
                                column.key,
                                column.label,
                                width: column.width ?? 150,
                                type: column.type,
                                headerGroups: column.headerGroups,
                                value: (row) => formatReportCell(column, row),
                              );
                            }).toList(),
                            rows: [
                              if (_source?['rows'] case final List<Object?> raw)
                                for (final row in raw.take(100))
                                  if (row is Map)
                                    Map<String, dynamic>.from(row),
                            ],
                            idOf: (r) => '${r.hashCode}',
                            showColumnChooser: false,
                          ),
                        ),
                        FinanceStatementSupplementalCells(
                          metadata: _map(_source?['documentMetadata']),
                        ),
                        Text(
                          '完整原件共${(_source?['rows'] as List<Object?>?)?.length ?? 0}行',
                        ),
                      ],
                      if (widget.mode == 'COUNTERPART') ...[
                        SelectableText(
                          '绑定原件SHA：${_source?['document_sha256']}',
                        ),
                        UtenInput(
                          controller: _c('signatoryName'),
                          label: '对方实际签署姓名',
                          enabled: !locked,
                        ),
                        UtenInput(
                          controller: _c('confirmedDate'),
                          label: '实际确认日期 YYYY-MM-DD',
                          enabled: !locked,
                        ),
                        UtenButton(
                          type: UtenButtonType.secondary,
                          onPressed: _saving ? null : _file,
                          child: Text(_filename ?? '选择实际签名/盖章回传件'),
                        ),
                        const Text('系统只保存实际回传文件，不生成手写签名或印章。'),
                      ],
                      if (_saveProfile ||
                          widget.mode == 'COUNTERPART' ||
                          _settlement)
                        UtenInput(
                          controller: _c('sourceReference'),
                          label: '实际来源依据',
                          enabled: !locked,
                        ),
                      if (widget.mode.contains('APPROVE') ||
                          widget.mode.contains('REJECT'))
                        UtenInput(
                          controller: _c('reason'),
                          label: '审核依据/退回原因',
                          enabled: !locked,
                        ),
                      if (widget.mode == 'PROFILE_VIEW') ...[
                        Text(
                          '版本：${_source?['revision']}　状态：${_statuses[_source?['status']] ?? _source?['status']}　提交：${_source?['submitted_name']}　审核：${_source?['reviewed_name'] ?? '待审核'}',
                        ),
                        Text('来源依据：${_source?['source_reference'] ?? ''}'),
                        if (_source?['status'] == 'SUBMITTED' &&
                            ref
                                .read(currentPermissionsProvider)
                                .contains(Perm.financePostExecute))
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final approve in [true, false])
                                UtenButton(
                                  type: approve
                                      ? UtenButtonType.primary
                                      : UtenButtonType.secondary,
                                  onPressed: () async {
                                    final changed = await showDialog<bool>(
                                      context: context,
                                      barrierDismissible: false,
                                      builder: (_) =>
                                          FinanceStatementDocumentEditor(
                                            scope: widget.scope,
                                            mode: approve
                                                ? 'PROFILE_APPROVE'
                                                : 'PROFILE_REJECT',
                                            targetId: widget.targetId,
                                            profileKind: _kind,
                                          ),
                                    );
                                    if (changed == true && context.mounted) {
                                      Navigator.pop(context, true);
                                    }
                                  },
                                  child: Text(approve ? '审核此版本' : '退回此版本'),
                                ),
                            ],
                          ),
                      ],
                    ],
                  ),
                ),
        ),
        actions: [
          if (!_view)
            UtenButton(
              onPressed: _saving || _loading || !_current ? null : _save,
              child: Text(
                _sent != null
                    ? '核对原提交并继续'
                    : _saveProfile || _settlement
                    ? '保存新版本'
                    : '确认本次处理',
              ),
            ),
        ],
      ),
    );
  }
}

Widget _retiredDocument(
  BuildContext context, {
  FutureOr<void> Function()? close,
}) => _Frame(
  showCloseButton: true,
  onClose: close ?? () => Navigator.pop(context, false),
  title: const Text('对账原件'),
  width: 620,
  content: const Text('身份或权限已变化，请从原入口重新打开；原件和原账号草稿仍保留。'),
  actions: const [],
);

class _Frame extends StatelessWidget {
  const _Frame({
    required this.title,
    required this.width,
    required this.content,
    required this.actions,
    this.onClose,
    this.showCloseButton = false,
    this.busy = false,
    this.hint,
  });
  final Widget title, content;
  final double width;
  final List<Widget> actions;
  final FutureOr<void> Function()? onClose;
  final bool showCloseButton;
  final bool busy;
  final String? hint;
  @override
  Widget build(BuildContext context) => UtenDialogFrame(
    maxWidth: width,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenDialogHeader(
          title: UtenDialogTitleWithHint(title: title, info: hint),
          showCloseButton: showCloseButton,
          onClose: busy ? null : onClose,
        ),
        Flexible(
          fit:
              context
                      .dependOnInheritedWidgetOfExactType<
                        UtenEmbeddedDialogScope
                      >() ==
                  null
              ? FlexFit.loose
              : FlexFit.tight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: content,
          ),
        ),
        UtenDialogActions(children: actions),
        if (busy)
          const UtenBusyOverlay(title: '正在处理对账原件', showDoNotLeaveHint: false),
      ],
    ),
  );
}

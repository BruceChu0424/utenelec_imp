import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_action_overflow.dart';
import '../../../core/formatters/exact_number_text.dart';
import '../../../core/io/file_saver.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/business_submission_headers.dart';
import '../../../core/performance/responsive_data_codec.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import 'finance_entry_file_picker.dart';
import 'finance_source_table.dart';

const _base = '/finance/subcontract-quantity-evidence';
const _purposes = {
  'ROW_CORRESPONDENCE': '原表数量对应',
  'PERIOD_OPENING': '期初实盘核对',
  'PERIOD_ENDING': '尾料实盘核对',
};
const _types = {
  'BILATERAL_SETTLEMENT_EQUIVALENCE': '双方确认结算当量',
  'RECEIPT_USAGE_DOCUMENT': '实际回厂耗用凭据',
  'PHYSICAL_COUNT': '期初或尾料实盘',
};
const _sources = {
  'MATERIAL_ISSUE': '原材料发料行',
  'MATERIAL_RETURN': '原材料退回行',
  'RECEIPT': '原回厂行',
  'PRODUCT_RETURN': '原成品退货行',
};
Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};
List<Map<String, dynamic>> _maps(Object? v) => [
  if (v is List)
    for (final row in v)
      if (row is Map) _map(row),
];
String _problem(Object e) => humanErrorMessage(e) ?? '读取或提交失败，原输入、附件及请求已保留';
String _status(Object? v) => switch (v) {
  'SUBMITTED' => '待审核',
  'APPROVED' => '已审核',
  'REJECTED' => '退回核对',
  _ => v?.toString() ?? '',
};
String _sourceLabel(Map<String, dynamic>? value) {
  final source = _map(value?['source'] ?? value);
  return [
    source['billNo'],
    source['goodsCode'],
    source['goodsName'],
    source['unitCode'] ?? source['unitName'],
  ].where((x) => x != null).join('  ');
}

Future<void> showFinanceSubcontractQuantityEvidenceDialog(
  BuildContext context, {
  required Map<String, dynamic> scope,
  String purpose = 'ROW_CORRESPONDENCE',
  Map<String, dynamic>? sourceRow,
  String? evidenceId,
  String? resumeDraftId,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      resumeDraftId != null || evidenceId != null || sourceRow != null
      ? _EvidenceEditor(
          scope: Map.unmodifiable(scope),
          initialPurpose: purpose,
          seed: sourceRow,
          evidenceId: evidenceId,
          resumeDraftId: resumeDraftId,
        )
      : _EvidenceDirectory(
          scope: Map.unmodifiable(scope),
          initialPurpose: purpose,
        ),
);

class _EvidenceDirectory extends ConsumerStatefulWidget {
  const _EvidenceDirectory({required this.scope, required this.initialPurpose});
  final Map<String, dynamic> scope;
  final String initialPurpose;
  @override
  ConsumerState<_EvidenceDirectory> createState() => _EvidenceDirectoryState();
}

class _EvidenceDirectoryState extends ConsumerState<_EvidenceDirectory> {
  late final bool Function() _owner;
  bool _retired = false, _busy = false, _opening = false;
  String? _error;
  int _page = 1, _pages = 0;
  List<Map<String, dynamic>> _rows = [];
  bool get _current => mounted && !_retired && _owner();
  @override
  void initState() {
    super.initState();
    _owner = captureReadOwner(ref);
    listenReadOwner(ref, () {
      if (mounted) {
        setState(() {
          _retired = true;
          _rows = [];
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider),
          guard = await api.captureRequestScope(isCurrent: () => _current);
      final result = await guard.run(
        () =>
            api.get(_base, query: {...widget.scope, 'page': page, 'size': 50}),
      );
      if (_current && guard.isCurrent) {
        setState(() {
          _rows = _maps(result['items']);
          _page = page;
          _pages = (result['totalPages'] as num?)?.toInt() ?? 0;
        });
      }
    } catch (e) {
      if (_current) setState(() => _error = _problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open({Map<String, dynamic>? row, String? purpose}) async {
    if (!_current || _busy || _opening) return;
    _opening = true;
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _EvidenceEditor(
          scope: row == null ? widget.scope : _map(_map(row['input'])['scope']),
          initialPurpose: purpose ?? widget.initialPurpose,
          evidenceId: row?['id']?.toString(),
        ),
      );
    } finally {
      _opening = false;
    }
    if (_current) await _load(_page);
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return UtenAlertDialog(
        title: const Text('原表数量资料'),
        content: const Text('身份或权限已变化，请重新打开。'),
        actions: [
          UtenButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    final canEdit = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.paymentStyleEdit);
    return UtenDialogFrame(
      maxWidth: 1250,
      fillHeight: true,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenDialogHeader(
                title: const Text('原表数量对应/期初与尾料核对'),
                showCloseButton: true,
                onClose: _busy ? null : () => Navigator.pop(context),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: UtenResponsiveActionWrap(
                  children: [
                    UtenButton(
                      onPressed: _busy ? null : () => _load(1),
                      child: const Text('刷新'),
                    ),
                    if (canEdit) ...[
                      UtenButton(
                        onPressed: _busy
                            ? null
                            : () => _open(purpose: 'ROW_CORRESPONDENCE'),
                        child: const Text('新增原表数量对应'),
                      ),
                      UtenButton(
                        onPressed: _busy
                            ? null
                            : () => _open(purpose: 'PERIOD_OPENING'),
                        child: const Text('新增期初与尾料核对'),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: financeSourceTable(
                  tableKey: 'finance.subcontract.quantity.evidence',
                  columns: [
                    financeSourceColumn(
                      'purpose',
                      '用途',
                      value: (r) => _purposes[_map(r['input'])['purpose']],
                    ),
                    financeSourceColumn(
                      'type',
                      '证据类型',
                      value: (r) => _types[_map(r['input'])['evidenceType']],
                      width: 210,
                    ),
                    financeSourceColumn(
                      'source',
                      '原业务行/材料',
                      value: (r) => r['source'] != null
                          ? _sourceLabel(_map(r['source']))
                          : [
                              _map(r['stockGroupReference'])['goodsCode'],
                              _map(r['stockGroupReference'])['goodsName'],
                              _map(r['stockGroupReference'])['colorName'],
                            ].where((v) => v != null).join(' '),
                      width: 260,
                    ),
                    financeSourceColumn(
                      'original',
                      '原PCS输入',
                      type: 'number',
                      value: (r) => _map(r['input'])['quantityPcs']?.toString(),
                    ),
                    financeSourceColumn(
                      'appliedQuantityPcs',
                      '实际采用PCS',
                      type: 'number',
                    ),
                    financeSourceColumn(
                      'bookEstimatedPcs',
                      '账载估计PCS',
                      type: 'number',
                    ),
                    financeSourceColumn(
                      'apply',
                      '原表采用',
                      value: (r) => _map(r['input'])['applyToStatement'] == true
                          ? '用于原表数量'
                          : '仅作差异对比',
                    ),
                    financeSourceColumn(
                      'status',
                      '审核状态',
                      value: (r) => _status(r['status']),
                    ),
                    financeSourceColumn(
                      'enabled',
                      '启用',
                      value: (r) =>
                          _map(r['input'])['enabled'] == true ? '启用' : '停用',
                    ),
                  ],
                  rows: _rows,
                  idOf: (r) => '${r['id']}',
                  busy: _busy,
                  error: _error,
                  retry: () => _load(_page),
                  page: _page,
                  pages: _pages,
                  onPage: _load,
                  onOpen: (r) => _open(row: r),
                  canOpen: (_) => !_busy,
                  scope: widget.scope,
                ),
              ),
            ],
          ),
          if (_busy)
            const UtenBusyOverlay(
              title: '正在读取原表数量资料',
              showDoNotLeaveHint: false,
            ),
        ],
      ),
    );
  }
}

class _EvidenceEditor extends ConsumerStatefulWidget {
  const _EvidenceEditor({
    required this.scope,
    required this.initialPurpose,
    this.seed,
    this.evidenceId,
    this.resumeDraftId,
  });
  final Map<String, dynamic> scope;
  final String initialPurpose;
  final Map<String, dynamic>? seed;
  final String? evidenceId, resumeDraftId;
  @override
  ConsumerState<_EvidenceEditor> createState() => _EvidenceEditorState();
}

class _EvidenceEditorState extends ConsumerState<_EvidenceEditor>
    with FormDraftMixin<_EvidenceEditor> {
  final _form = GlobalKey<FormState>();
  final _qty = TextEditingController(),
      _date = TextEditingController(),
      _reference = TextEditingController(),
      _reason = TextEditingController();
  Map<String, dynamic>? _source, _material, _record, _pending;
  Map<String, dynamic> _group = {};
  List<Map<String, dynamic>> _pcs = [];
  String _purpose = 'ROW_CORRESPONDENCE',
      _type = 'BILATERAL_SETTLEMENT_EQUIVALENCE',
      _sourceKind = 'RECEIPT';
  String? _apply, _pcsId, _filename, _contentType, _fileHash, _error;
  DraftByteValue? _file;
  bool _busy = false,
      _loading = true,
      _editing = true,
      _enabled = true,
      _picking = false;
  bool get _current => mounted && formDraftIdentityIsCurrent;
  bool get _frozen => _pending != null || formDraftHasUnknownSubmission;
  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit);
  bool get _canReview =>
      _canEdit &&
      ref.read(currentPermissionsProvider).contains(Perm.financePostExecute) &&
      _record?['submitted_by']?.toString() !=
          ref.read(authenticatedScopeProvider)?.userId;
  bool get _row => _purpose == 'ROW_CORRESPONDENCE';
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeSubcontractQuantityEvidence.spec(
        routeParameters: {
          for (final e in widget.scope.entries) e.key: e.value.toString(),
          'quantityPurpose': widget.initialPurpose,
          if (widget.evidenceId != null) 'evidenceId': widget.evidenceId!,
        },
      );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy || _loading;
  @override
  bool get formDraftCanReplaySubmission => _pending != null;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _qty,
    _date,
    _reference,
    _reason,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'scope': widget.scope,
    'purpose': _purpose,
    'evidenceType': _type,
    'sourceKind': _sourceKind,
    'source': _source,
    'material': _material,
    'stockGroup': _group,
    'pcsId': _pcsId,
    'apply': _apply,
    'enabled': _enabled,
    'record': _record,
    'editing': _editing,
    'quantity': _qty.text,
    'date': _date.text,
    'reference': _reference.text,
    'reason': _reason.text,
    'filename': _filename,
    'contentType': _contentType,
    'fileHash': _fileHash,
    'fileBytes': _file?.jsonValue,
    'pending': _pending == null
        ? null
        : {
            ..._pending!,
            'headers': businessSubmissionHeaders(_pending!['headers']),
          },
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (!const DeepCollectionEquality().equals(data['scope'], widget.scope)) {
      throw StateError('原数量草稿的供应商或期间不一致');
    }
    _purpose = data['purpose']?.toString() ?? '';
    _type = data['evidenceType']?.toString() ?? '';
    _sourceKind = data['sourceKind']?.toString() ?? '';
    if (!_purposes.containsKey(_purpose) ||
        !_types.containsKey(_type) ||
        !_sources.containsKey(_sourceKind)) {
      throw StateError('原数量草稿的用途或来源类型不完整');
    }
    _source = data['source'] is Map ? _map(data['source']) : null;
    _material = data['material'] is Map ? _map(data['material']) : null;
    _group = _map(data['stockGroup']);
    _pcsId = data['pcsId']?.toString();
    _apply = data['apply']?.toString();
    _enabled = data['enabled'] == true;
    _record = data['record'] is Map ? _map(data['record']) : null;
    _editing = data['editing'] == true;
    _pending = data['pending'] is Map ? _map(data['pending']) : null;
    if (_pending != null) {
      _pending!['headers'] = businessSubmissionHeaders(_pending!['headers']);
    }
    if (widget.evidenceId != null && _record?['id'] != widget.evidenceId) {
      throw StateError('原数量版本与草稿不一致');
    }
    _qty.text = data['quantity']?.toString() ?? '';
    _date.text = data['date']?.toString() ?? '';
    _reference.text = data['reference']?.toString() ?? '';
    _reason.text = data['reason']?.toString() ?? '';
    _filename = data['filename']?.toString();
    _contentType = data['contentType']?.toString();
    _fileHash = data['fileHash']?.toString();
    if (data['fileBytes'] case final String encoded) {
      final bytes = await decodeBase64Responsive(
        encoded,
        isCurrent: () => _current,
      );
      if (bytes.length > 15 * 1024 * 1024 ||
          await sha256HexResponsive(bytes, isCurrent: () => _current) !=
              _fileHash) {
        throw StateError('原附件字节与原校验值不一致，原请求不能替换文件');
      }
      _file = DraftByteValue.decoded(bytes, encoded);
    }
    if (_pending != null &&
        _pending!['actorId'] != ref.read(authenticatedScopeProvider)?.userId) {
      throw StateError('原数量请求不属于当前操作人');
    }
  }

  @override
  void initState() {
    super.initState();
    _purpose = widget.initialPurpose;
    if (!_row) _type = 'PHYSICAL_COUNT';
    if (widget.seed != null) {
      _group = {
        'goodsId': widget.seed!['__goodsId'],
        'colorId': widget.seed!['__colorId'],
        'goodsCode': widget.seed!['goodsCode'],
        'goodsName': widget.seed!['goodsName'],
      };
    }
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initial());
  }

  @override
  void dispose() {
    for (final c in [_qty, _date, _reference, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _initial() async {
    try {
      final api = ref.read(apiClientProvider),
          guard = await captureFormDraftRequestScope();
      _pcs = await guard.run(() => api.getList('$_base/pcs-units'));
      if (!_current || !guard.isCurrent) return;
      if (_pcs.length == 1) _pcsId = _pcs.single['id']?.toString();
      if (widget.resumeDraftId == null && widget.evidenceId != null) {
        final row = await guard.run(
          () => api.get('$_base/${widget.evidenceId}'),
        );
        if (!_current || !guard.isCurrent) return;
        _record = row;
        _editing = false;
        final input = _map(row['input']);
        if (!const DeepCollectionEquality().equals(
          input['scope'],
          widget.scope,
        )) {
          throw StateError('原数量版本不属于本供应商或期间');
        }
        _purpose = input['purpose'].toString();
        _type = input['evidenceType'].toString();
        _sourceKind = _map(input['source'])['kind']?.toString() ?? 'RECEIPT';
        _source = row['source'] is Map ? {'source': _map(row['source'])} : null;
        _material = row['materialSource'] is Map
            ? {'source': _map(row['materialSource'])}
            : null;
        _group = {
          ..._map(input['stockGroup']),
          ..._map(row['stockGroupReference']),
        };
        _pcsId = _group['pcsUnitId']?.toString();
        _apply = input['applyToStatement'] == true ? 'USE' : 'COMPARE';
        _enabled = input['enabled'] == true;
        _qty.text = input['quantityPcs']?.toString() ?? '';
        _date.text = input['evidenceDate']?.toString() ?? '';
        _reference.text = input['sourceReference']?.toString() ?? '';
      }
      if (_current) await initializeFormDraft();
    } catch (e) {
      if (_current) _error = _problem(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectSource({
    bool material = false,
    bool group = false,
  }) async {
    if (!_current ||
        _busy ||
        _frozen ||
        _picking ||
        !_editing ||
        _record != null) {
      return;
    }
    _picking = true;
    try {
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _EvidencePicker(
          scope: widget.scope,
          kind: group
              ? 'GROUP'
              : material
              ? 'MATERIAL_ISSUE'
              : _sourceKind,
          orderItemId: material ? (_source?['orderItemId']?.toString()) : null,
        ),
      );
      if (!_current || picked == null) return;
      if (group) {
        setState(
          () => _group = {
            'goodsId': picked['goodsId'],
            'colorId': picked['colorId'],
            'goodsCode': picked['goodsCode'],
            'goodsName': picked['goodsName'],
            'colorName': picked['colorName'],
          },
        );
      } else if (material) {
        _setMaterial(picked);
      } else {
        setState(() {
          _source = picked;
          _material = null;
        });
        if (_sourceKind == 'MATERIAL_ISSUE') {
          _setMaterial(picked);
        } else if (_sourceKind == 'MATERIAL_RETURN' &&
            picked['materialIssueItemId'] != null) {
          setState(() => _busy = true);
          try {
            final guard = await captureFormDraftRequestScope();
            final real = await guard.run(
              () => ref
                  .read(apiClientProvider)
                  .get(
                    '$_base/sources/MATERIAL_ISSUE/${picked['materialIssueItemId']}',
                    query: {'supplierId': widget.scope['supplierId']},
                  ),
            );
            if (_current && guard.isCurrent) _setMaterial(real);
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        }
      }
      markFormDraftChanged();
    } catch (e) {
      if (_current) setState(() => _error = _problem(e));
    } finally {
      _picking = false;
    }
  }

  void _setMaterial(Map<String, dynamic> row) {
    final source = _map(row['source']);
    setState(() {
      _material = row;
      _group = {
        'goodsId': source['goodsId'],
        'colorId': source['colorId'],
        'goodsCode': source['goodsCode'],
        'goodsName': source['goodsName'],
      };
    });
  }

  Future<void> _pickFile() async {
    if (!_current || _busy || _frozen || !_editing || _picking) return;
    _picking = true;
    try {
      final file = await ref.read(financeConfirmationFilePickerProvider)();
      if (!_current || file == null) return;
      final type = switch (file.extension?.toLowerCase()) {
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
        throw StateError('请选择完整且不超过15MB的真实凭据');
      }
      setState(() => _busy = true);
      final owned = DraftByteValue(file.bytes!),
          hash = await sha256HexResponsive(
            owned.bytes,
            isCurrent: () => _current,
          );
      if (_current) {
        setState(() {
          _file = owned;
          _filename = file.name;
          _contentType = type;
          _fileHash = hash;
        });
        await saveFormDraftNow();
      }
    } catch (e) {
      if (_current) setState(() => _error = _problem(e));
    } finally {
      _picking = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _input() {
    final source = _map(_source?['source']),
        material = _map(_material?['source']);
    return {
      'scope': widget.scope,
      'purpose': _purpose,
      'evidenceType': _type,
      'source': _row ? source['source'] : null,
      'materialIssueItemId': _row ? _map(material['source'])['itemId'] : null,
      'stockGroup': {
        'goodsId': _group['goodsId'],
        'colorId': _group['colorId'],
        'pcsUnitId': _pcsId,
      },
      'quantityPcs': _qty.text,
      'evidenceDate': _date.text,
      'enabled': _enabled,
      'applyToStatement': _apply == 'USE',
      'sourceReference': _reference.text,
    };
  }

  Map<String, dynamic> _command({bool? approve}) => approve != null
      ? {
          'path': '$_base/${_record!['id']}/decision',
          'body': {'approve': approve, 'reason': _reason.text.trim()},
          'hasFile': false,
        }
      : {
          'path': _base,
          'body': {
            'requestId': const Uuid().v4(),
            'expectedRevision': _record == null ? -1 : _record!['revision'],
            'input': _input(),
            'attachmentEvidenceId': _file == null ? (_record?['id']) : null,
          },
          'hasFile': _file != null,
          'filename': _filename,
          'contentType': _contentType,
          'fileHash': _fileHash ?? _map(_record?['attachment'])['sha256'],
        };
  Future<void> _send({bool? approve, bool retry = false}) async {
    if (!_current ||
        _busy ||
        _loading ||
        !(approve != null ? _canReview : _canEdit) ||
        _frozen && !retry) {
      return;
    }
    if (!retry) {
      if (!(_form.currentState?.validate() ?? false)) return;
      if (approve == null &&
          (_group['goodsId'] == null ||
              _pcsId == null ||
              _apply == null ||
              _row && (_source == null || _material == null) ||
              _enabled && _file == null && _record?['attachment'] == null)) {
        setState(() => _error = '请选择完整真实来源、材料、PCS、采用用途和凭据；原输入已保留');
        return;
      }
    }
    final unknown = formDraftHasUnknownSubmission;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final guard = await captureFormDraftRequestScope();
      _pending ??= {
        ..._command(approve: approve),
        'actorId': ref.read(authenticatedScopeProvider)?.userId,
        'headers': <String, dynamic>{},
      };
      final command = _map(jsonDecode(jsonEncode(_pending)));
      if (command['hasFile'] == true &&
          (_file == null ||
              command['fileHash'] != _fileHash ||
              command['filename'] != _filename ||
              command['contentType'] != _contentType)) {
        throw StateError('原文件或原请求不匹配，不能替换后重试');
      }
      await runFormDraftSubmission(
        () => guard.run(
          () => command['hasFile'] == true
              ? ref
                    .read(apiClientProvider)
                    .postMultipartFile(
                      command['path'].toString(),
                      _file!.bytes,
                      command['filename'].toString(),
                      command['contentType'].toString(),
                      jsonParts: {'input': command['body']},
                      headers: businessSubmissionHeaders(command['headers']),
                    )
              : ref
                    .read(apiClientProvider)
                    .post(
                      command['path'].toString(),
                      body: command['body'],
                      headers: businessSubmissionHeaders(command['headers']),
                    ),
        ),
        isDefiniteRejection: (e) =>
            !unknown &&
            (e.details?['notWritten'] == true ||
                e.hasResponseCode &&
                    const {
                      'VALIDATION_FAILED',
                      'CONFLICT',
                      'FORBIDDEN',
                      'NOT_FOUND',
                    }.contains(e.code)),
      );
      if (!_current || !guard.isCurrent) return;
      await completeFormDraft();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!formDraftHasUnknownSubmission) _pending = null;
      if (_current) setState(() => _error = _problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receipt() async {
    if (!_current || _busy || _pending == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final guard = await captureFormDraftRequestScope(),
          body = _map(_pending!['body']);
      final decision = _pending!['path'].toString().endsWith('/decision');
      final row = await guard.run(
        () => ref
            .read(apiClientProvider)
            .get(
              decision
                  ? '$_base/${_record!['id']}'
                  : '$_base/operations/${body['requestId']}',
            ),
      );
      if (!_current || !guard.isCurrent) return;
      if (decision) {
        if (row['reviewed_by']?.toString() != _pending!['actorId'] ||
            row['review_reason'] != body['reason'] ||
            row['status'] !=
                (body['approve'] == true ? 'APPROVED' : 'REJECTED')) {
          throw StateError('尚未取得本人原审核成功回执');
        }
      } else {
        final expected = _map(body['input']), actual = _map(row['input']);
        expected['quantityPcs'] = exactNumberDisplay(expected['quantityPcs']);
        actual['quantityPcs'] = exactNumberDisplay(actual['quantityPcs']);
        if (row['requestId']?.toString() != body['requestId'] ||
            row['submitted_by']?.toString() != _pending!['actorId'] ||
            row['revision']?.toString() !=
                ((body['expectedRevision'] as num).toInt() + 1).toString() ||
            !const DeepCollectionEquality().equals(expected, actual) ||
            _pending!['fileHash'] != null &&
                _map(row['attachment'])['sha256'] != _pending!['fileHash']) {
          throw StateError('原数量、来源或附件回执不匹配，请保留原请求');
        }
      }
      await completeFormDraft();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (_current) setState(() => _error = _problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    if (!_current || _busy || _record == null) return;
    setState(() => _busy = true);
    try {
      final guard = await captureFormDraftRequestScope();
      final bytes = await guard.run(
        () => ref
            .read(apiClientProvider)
            .getBytes('$_base/${_record!['id']}/attachment'),
      );
      if (_current && guard.isCurrent) {
        await saveBytes(
          bytes,
          _map(_record?['attachment'])['filename']?.toString() ?? '原数量凭据.bin',
          stillCurrent: () => _current && guard.isCurrent,
        );
      }
    } catch (e) {
      if (_current) setState(() => _error = _problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (!_busy && await confirmFormDraftExit() && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenResponsiveActionWrap(
    children: [
      UtenButton(
        onPressed: _busy ? null : _receipt,
        child: const Text('核对原请求回执'),
      ),
      UtenButton(
        onPressed: _busy
            ? null
            : () => _send(
                approve:
                    _pending?['path'].toString().endsWith('/decision') == true
                    ? _map(_pending?['body'])['approve'] as bool
                    : null,
                retry: true,
              ),
        child: const Text('重试原请求'),
      ),
    ],
  );
  String? _required(String? v) =>
      (v?.trim().isEmpty ?? true) ? '请填写实际来源值' : null;
  String? _validDate(String? v) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v ?? '') &&
          DateTime.tryParse(v ?? '') != null
      ? null
      : '请填写YYYY-MM-DD真实日期';
  @override
  Widget build(BuildContext context) {
    if (!formDraftIdentityIsCurrent) {
      return withFormDraft(
        UtenAlertDialog(
          title: const Text('原表数量资料'),
          content: const Text('身份或权限已变化，原草稿、附件和请求已保留。'),
          actions: [
            UtenButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
    final editable = _editing && !_busy && !_frozen && _canEdit,
        original = _map(_source?['source']);
    return withFormDraft(
      UtenDialogFrame(
        maxWidth: 1000,
        fillHeight: true,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_row ? '原表数量对应' : '期初与尾料核对'),
                      const UtenFieldHintIcon(
                        info:
                            '数量资料只用于本供应商、本期间的财务原表。保留账载估算与财务确认差异，不改仓库、旧BOM核销、成本或加工原价原额。',
                      ),
                    ],
                  ),
                  showCloseButton: true,
                  onClose: _close,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          UtenDropdownField(
                            label: '原表用途',
                            enabled: editable && _record == null,
                            value: _purpose,
                            items: [
                              for (final e in _purposes.entries)
                                UtenDropdownItem(value: e.key, label: e.value),
                            ],
                            onChanged: editable && _record == null
                                ? (v) {
                                    if (v == null) return;
                                    setState(() {
                                      _purpose = v;
                                      _type = _row
                                          ? 'BILATERAL_SETTLEMENT_EQUIVALENCE'
                                          : 'PHYSICAL_COUNT';
                                      _source = null;
                                      _material = null;
                                    });
                                    markFormDraftChanged();
                                  }
                                : (_) {},
                          ),
                          const SizedBox(height: 12),
                          UtenDropdownField(
                            label: '证据类型',
                            enabled: editable && _record == null,
                            value: _type,
                            info: '双方结算当量和实际回厂耗用分别留证，不能把二者或冻结BOM估算默认为一致。',
                            items: [
                              for (final e in _types.entries)
                                if (_row
                                    ? e.key != 'PHYSICAL_COUNT'
                                    : e.key == 'PHYSICAL_COUNT')
                                  UtenDropdownItem(
                                    value: e.key,
                                    label: e.value,
                                  ),
                            ],
                            onChanged: editable && _record == null
                                ? (v) {
                                    if (v != null) {
                                      setState(() => _type = v);
                                      markFormDraftChanged();
                                    }
                                  }
                                : (_) {},
                          ),
                          if (_row) ...[
                            const SizedBox(height: 12),
                            UtenDropdownField(
                              label: '原业务来源',
                              enabled: editable && _record == null,
                              value: _sourceKind,
                              items: [
                                for (final e in _sources.entries)
                                  UtenDropdownItem(
                                    value: e.key,
                                    label: e.value,
                                  ),
                              ],
                              onChanged: editable && _record == null
                                  ? (v) {
                                      if (v != null) {
                                        setState(() {
                                          _sourceKind = v;
                                          _source = null;
                                          _material = null;
                                        });
                                        markFormDraftChanged();
                                      }
                                    }
                                  : (_) {},
                            ),
                            UtenResponsiveActionWrap(
                              children: [
                                Text(_sourceLabel(_source)),
                                UtenButton(
                                  onPressed: editable && _record == null
                                      ? () => _selectSource()
                                      : null,
                                  child: const Text('选择原业务行'),
                                ),
                              ],
                            ),
                            UtenResponsiveActionWrap(
                              children: [
                                Text(_sourceLabel(_material)),
                                UtenButton(
                                  onPressed:
                                      editable &&
                                          _record == null &&
                                          _source != null
                                      ? () => _selectSource(material: true)
                                      : null,
                                  child: const Text('选择实际原发料行'),
                                ),
                              ],
                            ),
                            if (_source != null)
                              UtenResponsiveActionWrap(
                                children: [
                                  UtenSummaryField(
                                    label: '原数量',
                                    value: original['quantityOriginal']
                                        ?.toString(),
                                    inline: true,
                                    selectable: true,
                                  ),
                                  UtenSummaryField(
                                    label: '原单价',
                                    value: original['priceOriginal']
                                        ?.toString(),
                                    inline: true,
                                    selectable: true,
                                  ),
                                  UtenSummaryField(
                                    label: '原金额',
                                    value: original['amountOriginal']
                                        ?.toString(),
                                    inline: true,
                                    selectable: true,
                                  ),
                                ],
                              ),
                          ],
                          const SizedBox(height: 12),
                          UtenResponsiveActionWrap(
                            children: [
                              Text(
                                [
                                  _group['goodsCode'],
                                  _group['goodsName'],
                                  _group['colorName'],
                                ].where((x) => x != null).join('  '),
                              ),
                              if (!_row)
                                UtenButton(
                                  onPressed: editable && _record == null
                                      ? () => _selectSource(group: true)
                                      : null,
                                  child: const Text('选择真实材料和颜色'),
                                ),
                            ],
                          ),
                          UtenDropdownField(
                            label: '实际PCS单位',
                            enabled: editable && _record == null,
                            value: _pcsId,
                            items: [
                              for (final unit in _pcs)
                                UtenDropdownItem(
                                  value: unit['id']?.toString(),
                                  label: '${unit['code']} ${unit['name']}',
                                ),
                            ],
                            onChanged: editable && _record == null
                                ? (v) {
                                    setState(() => _pcsId = v);
                                    markFormDraftChanged();
                                  }
                                : (_) {},
                            info: '选择真实PCS单位；原来源的原数量、原单位保留，不按名字猜折算。',
                          ),
                          const SizedBox(height: 12),
                          UtenInput(
                            label: '原PCS输入',
                            controller: _qty,
                            enabled: editable,
                            info: '按实际凭据填写，不预填BOM估计；原小数保留，超支持精度时由本次用户明确选择采用值。',
                            validator: (v) => !_editing
                                ? null
                                : _required(v) ??
                                      (RegExp(
                                            r'^\d+(?:\.\d+)?$',
                                          ).hasMatch(v ?? '')
                                          ? null
                                          : '请填写非负原数量'),
                          ),
                          if (_record != null)
                            UtenResponsiveActionWrap(
                              children: [
                                UtenSummaryField(
                                  label: '实际采用PCS',
                                  value:
                                      (_record!['appliedQuantityPcsExact'] ??
                                              _record!['appliedQuantityPcs'])
                                          ?.toString(),
                                  inline: true,
                                  selectable: true,
                                ),
                                UtenSummaryField(
                                  label: '账载估计PCS',
                                  value:
                                      (_record!['bookEstimatedPcsExact'] ??
                                              _record!['bookEstimatedPcs'])
                                          ?.toString() ??
                                      '待核',
                                  info: _record!['bookEstimateBasis']
                                      ?.toString(),
                                  inline: true,
                                  selectable: true,
                                ),
                                UtenSummaryField(
                                  label: '确认与估计差异PCS',
                                  value:
                                      (_record!['differencePcsExact'] ??
                                              _record!['differencePcs'])
                                          ?.toString() ??
                                      '待核',
                                  inline: true,
                                  selectable: true,
                                  info: '实际采用PCS减账载估计；无估计来源时保留待核，不默判为0或一致。',
                                ),
                              ],
                            ),
                          const SizedBox(height: 12),
                          UtenInput(
                            label: '真实凭据/实盘日期',
                            controller: _date,
                            enabled: editable,
                            validator: (v) => _editing ? _validDate(v) : null,
                          ),
                          const SizedBox(height: 12),
                          UtenDropdownField(
                            label: '采用用途',
                            enabled: editable,
                            value: _apply,
                            items: const [
                              UtenDropdownItem(value: 'USE', label: '用于原表数量'),
                              UtenDropdownItem(
                                value: 'COMPARE',
                                label: '仅作差异对比',
                              ),
                            ],
                            onChanged: editable
                                ? (v) {
                                    setState(() => _apply = v);
                                    markFormDraftChanged();
                                  }
                                : (_) {},
                            info: '必须明确选择。一个原业务行和材料组只能采用一份受审来源，其他证据保留作差异核对。',
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('启用'),
                            value: _enabled,
                            onChanged: editable
                                ? (v) {
                                    setState(() => _enabled = v);
                                    markFormDraftChanged();
                                  }
                                : null,
                          ),
                          UtenInput(
                            label: '真实依据',
                            controller: _reference,
                            enabled: editable,
                            maxLines: 3,
                            validator: (v) => _editing ? _required(v) : null,
                          ),
                          const SizedBox(height: 12),
                          UtenResponsiveActionWrap(
                            children: [
                              Text(
                                _filename ??
                                    _map(
                                      _record?['attachment'],
                                    )['filename']?.toString() ??
                                    '尚未选择原凭据',
                              ),
                              if (_editing)
                                UtenButton(
                                  onPressed: editable ? _pickFile : null,
                                  child: const Text('选择真实凭据'),
                                ),
                              if (_record?['attachment'] != null)
                                UtenButton(
                                  onPressed: _busy ? null : _download,
                                  child: const Text('下载原凭据'),
                                ),
                            ],
                          ),
                          if (!_editing && _record?['status'] == 'SUBMITTED')
                            UtenInput(
                              label: '审核依据',
                              controller: _reason,
                              enabled: !_busy && !_frozen && _canReview,
                              maxLines: 3,
                              validator: _required,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                UtenDialogActions(
                  children: [
                    if (_frozen)
                      formDraftSubmissionRecoveryAction!
                    else ...[
                      if (_editing && _canEdit)
                        UtenButton(
                          onPressed: _busy || _loading ? null : () => _send(),
                          child: const Text('提交审核'),
                        ),
                      if (!_editing &&
                          _record?['status'] == 'SUBMITTED' &&
                          _canReview) ...[
                        UtenButton(
                          onPressed: _busy ? null : () => _send(approve: true),
                          child: const Text('审核通过'),
                        ),
                        UtenButton(
                          onPressed: _busy ? null : () => _send(approve: false),
                          child: const Text('退回核对'),
                        ),
                      ],
                      if (!_editing && _canEdit)
                        UtenButton(
                          onPressed: _busy
                              ? null
                              : () {
                                  setState(() => _editing = true);
                                  markFormDraftChanged();
                                },
                          child: const Text('更正或停用'),
                        ),
                    ],
                    UtenButton(
                      onPressed: _busy ? null : _close,
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ],
            ),
            if (_busy || _loading)
              const UtenBusyOverlay(
                title: '正在核对原数量与凭据',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    );
  }
}

class _EvidencePicker extends ConsumerStatefulWidget {
  const _EvidencePicker({
    required this.scope,
    required this.kind,
    this.orderItemId,
  });
  final Map<String, dynamic> scope;
  final String kind;
  final String? orderItemId;
  @override
  ConsumerState<_EvidencePicker> createState() => _EvidencePickerState();
}

class _EvidencePickerState extends ConsumerState<_EvidencePicker> {
  late final bool Function() _owner;
  bool _retired = false, _busy = false;
  final _q = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  int _page = 1, _pages = 0;
  String? _error;
  bool get _current => mounted && !_retired && _owner();
  @override
  void initState() {
    super.initState();
    _owner = captureReadOwner(ref);
    listenReadOwner(ref, () {
      if (mounted) {
        setState(() {
          _retired = true;
          _rows = [];
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load(int page) async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider),
          guard = await api.captureRequestScope(isCurrent: () => _current);
      final group = widget.kind == 'GROUP';
      final result = await guard.run(
        () => api.get(
          group
              ? '/finance/subcontract-loss-policies/source-choices'
              : '$_base/sources',
          query: {
            if (group)
              'supplierId': widget.scope['supplierId']
            else
              ...widget.scope,
            if (!group) 'kind': widget.kind,
            if (widget.orderItemId != null) 'orderItemId': widget.orderItemId,
            'keyword': _q.text,
            'page': page,
            'size': 50,
          },
        ),
      );
      if (_current && guard.isCurrent) {
        setState(() {
          _rows = _maps(result['items']);
          _page = page;
          _pages = (result['totalPages'] as num?)?.toInt() ?? 0;
        });
      }
    } catch (e) {
      if (_current) setState(() => _error = _problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return UtenAlertDialog(
        title: const Text('选择真实来源'),
        content: const Text('身份或权限已变化，请重新打开。'),
        actions: [
          UtenButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    final group = widget.kind == 'GROUP';
    return UtenDialogFrame(
      maxWidth: 1050,
      fillHeight: true,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenDialogHeader(
                title: Text(
                  group ? '选择真实材料和颜色' : _sources[widget.kind] ?? '选择真实来源',
                ),
                showCloseButton: true,
                onClose: _busy ? null : () => Navigator.pop(context),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: UtenInput(
                  label: '搜索真实单号或商品',
                  controller: _q,
                  enabled: !_busy,
                  onFieldSubmitted: (_) => _load(1),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: UtenButton(
                  onPressed: _busy ? null : () => _load(1),
                  child: const Text('查询'),
                ),
              ),
              Expanded(
                child: financeSourceTable(
                  tableKey:
                      'finance.subcontract.quantity.picker.${widget.kind}',
                  columns: group
                      ? [
                          financeSourceColumn('goodsCode', '物料编码'),
                          financeSourceColumn('goodsName', '品名及规格', width: 220),
                          financeSourceColumn('colorName', '颜色'),
                          financeSourceColumn('unitName', '来源原单位'),
                        ]
                      : [
                          financeSourceColumn(
                            'billNo',
                            '原单号',
                            value: (r) =>
                                _map(r['source'])['billNo']?.toString(),
                          ),
                          financeSourceColumn(
                            'date',
                            '原日期',
                            value: (r) =>
                                _map(r['source'])['businessDate']?.toString(),
                          ),
                          financeSourceColumn(
                            'goodsCode',
                            '物料编码',
                            value: (r) =>
                                _map(r['source'])['goodsCode']?.toString(),
                          ),
                          financeSourceColumn(
                            'goodsName',
                            '品名及规格',
                            value: (r) =>
                                _map(r['source'])['goodsName']?.toString(),
                            width: 240,
                          ),
                          financeSourceColumn(
                            'quantityOriginal',
                            '原数量',
                            type: 'number',
                            value: (r) => _map(
                              r['source'],
                            )['quantityOriginal']?.toString(),
                          ),
                          financeSourceColumn(
                            'unit',
                            '原单位',
                            value: (r) =>
                                _map(r['source'])['unitCode']?.toString(),
                          ),
                        ],
                  rows: _rows,
                  idOf: (r) => group
                      ? '${r['goodsId']}:${r['colorId']}:${r['unitId']}'
                      : '${_map(_map(r['source'])['source'])['itemId']}',
                  busy: _busy,
                  error: _error,
                  retry: () => _load(_page),
                  page: _page,
                  pages: _pages,
                  onPage: _load,
                  onOpen: (r) {
                    if (_current && !_busy) Navigator.pop(context, r);
                  },
                  canOpen: (_) => !_busy,
                  scope: (widget.scope, widget.kind, widget.orderItemId),
                ),
              ),
            ],
          ),
          if (_busy)
            const UtenBusyOverlay(title: '正在读取真实来源', showDoNotLeaveHint: false),
        ],
      ),
    );
  }
}

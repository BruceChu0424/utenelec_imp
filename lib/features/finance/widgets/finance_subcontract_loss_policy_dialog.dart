import '../../../components/inputs/uten_selected_value_theme.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../core/formatters/exact_number_text.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_action_overflow.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_source_table.dart';

const _base = '/finance/subcontract-loss-policies';
Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
String _status(Object? value) => switch (value) {
  'SUBMITTED' => '待审核',
  'APPROVED' => '已审核',
  'REJECTED' => '退回核对',
  _ => value?.toString() ?? '',
};
String _problem(Object error) =>
    humanErrorMessage(error) ?? '读取或提交失败，原输入和请求已保留';
String _dimensionId(Map<String, dynamic> row) =>
    '${row['goodsId']}:${row['colorId']}:${row['unitId']}';
Map<String, dynamic> _source(Map<String, dynamic> row) => {
  'goodsId': row['goodsId'] ?? row['goods_id'] ?? row['__goodsId'],
  'colorId': row['colorId'] ?? row['color_id'] ?? row['__colorId'],
  'unitId': row['unitId'] ?? row['unit_id'] ?? row['__unitId'],
  'goodsCode': row['goodsCode'] ?? row['goods_code'],
  'goodsName': row['goodsName'] ?? row['goods_name'],
  'colorName': row['colorName'] ?? row['color'],
  'unitCode': row['unitCode'] ?? row['unit_code'],
  'unitName': row['unitName'] ?? row['unit_name'],
};

/// Currency is deliberately absent: the same physical SKU has one reviewed rate.
Future<void> showFinanceSubcontractLossPolicyDialog(
  BuildContext context, {
  required String supplierId,
  Map<String, dynamic>? sourceRow,
  String? resumeDraftId,
  String? policyId,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => resumeDraftId != null || sourceRow != null || policyId != null
      ? _PolicyEditor(
          supplierId: supplierId,
          seed: sourceRow,
          policyId: policyId,
          resumeDraftId: resumeDraftId,
        )
      : _PolicyDirectory(supplierId: supplierId),
);

class _PolicyDirectory extends ConsumerStatefulWidget {
  const _PolicyDirectory({required this.supplierId, this.chooseSource = false});
  final String supplierId;
  final bool chooseSource;
  @override
  ConsumerState<_PolicyDirectory> createState() => _PolicyDirectoryState();
}

class _PolicyDirectoryState extends ConsumerState<_PolicyDirectory>
    with ScopedPagedReadViewMixin<_PolicyDirectory> {
  @override
  Future<void> onReadViewResumed() => _load();
  late final ApiClient _api;
  late final int _epoch;
  final _keyword = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  bool _busy = false, _opening = false;
  String? _error;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<PagedResult<Map<String, dynamic>>> _fetchPage(
    int page,
    int size,
    String keyword,
  ) async => PagedResult.fromJsonResponsive<Map<String, dynamic>>(
    await _api.get(
      widget.chooseSource ? '$_base/source-choices' : _base,
      query: {
        'supplierId': widget.supplierId,
        'keyword': keyword,
        'page': page,
        'size': size,
      },
    ),
    (row) => row,
  );

  Future<void> _load() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final keyword = _keyword.text;
      final result = await readScopedPage<Map<String, dynamic>>(
        1,
        slot: 'subcontract-loss-policies',
        idOf: (row) => widget.chooseSource
            ? row['goodsId'] == null || row['unitId'] == null
                  ? null
                  : _dimensionId(row)
            : row['id'],
        query: [_api, widget.supplierId, widget.chooseSource, keyword],
        currentQuery: () => [
          _api,
          widget.supplierId,
          widget.chooseSource,
          _keyword.text,
        ],
        isCurrent: () => _current,
        fetchPage: (page) async => _fetchPage(page, 100, keyword),
        fetchPageSized: (page, size) async => _fetchPage(page, size, keyword),
        onProgressiveBatch: (partial) => setState(() => _rows = partial.items),
      );
      if (_current) {
        setState(() {
          _rows = result.items;
        });
      }
    } catch (error) {
      if (isRetiredViewRead(error)) return;
      if (_current) {
        setState(() {
          _rows = [];
          _error = _problem(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(Map<String, dynamic>? row) async {
    if (!_current || _busy || _opening) return;
    if (widget.chooseSource) {
      Navigator.pop(context, row);
      return;
    }
    _opening = true;
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PolicyEditor(
          supplierId: widget.supplierId,
          policyId: row?['id']?.toString(),
        ),
      );
    } finally {
      _opening = false;
    }
    if (_current) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),

        title: const Text('允许损耗率'),
        content: const Text('登录身份、权限或服务器已变化，请重新打开。'),
      );
    }
    final canEdit = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.paymentStyleEdit);
    return UtenDialogFrame(
      maxWidth: 1120,
      fillHeight: true,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenDialogHeader(
                title: Text(widget.chooseSource ? '选择真实商品、颜色和单位' : '允许损耗率'),
                showCloseButton: true,
                onClose: _busy ? null : () => Navigator.pop(context),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: UtenInput(
                  label: '搜索商品、颜色、单位',
                  controller: _keyword,
                  onFieldSubmitted: (_) => _load(),
                  enabled: !_busy,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: UtenResponsiveActionWrap(
                  children: [
                    UtenButton(
                      onPressed: _busy ? null : _load,
                      child: const Text('查询'),
                    ),
                    if (!widget.chooseSource && canEdit)
                      UtenButton(
                        onPressed: _busy ? null : () => _open(null),
                        child: const Text('新增规则'),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: financeSourceTable(
                  tableKey: widget.chooseSource
                      ? 'finance.subcontract.loss.sourceChoices'
                      : 'finance.subcontract.loss.policies',
                  columns: [
                    // 2026-11-11 口径：编码列可排序 + 按值筛选；颜色/单位/来源/
                    //状态类别列按值筛选；数值/日期列可排序（全量策略快照就地收集桶）。
                    financeSourceColumn(
                      'goodsCode',
                      '物料编码',
                      sortable: true,
                      filterByValue: true,
                    ),
                    financeSourceColumn('goodsName', '品名及规格', width: 220),
                    financeSourceColumn(
                      'colorName',
                      '颜色',
                      filterByValue: true,
                      value: (r) => r['colorName']?.toString() ?? '全部颜色',
                    ),
                    financeSourceColumn(
                      'unitName',
                      '单位',
                      filterByValue: true,
                      value: (r) => [
                        r['unitCode'],
                        r['unitName'],
                      ].where((v) => v != null).join(' '),
                    ),
                    if (widget.chooseSource)
                      financeSourceColumn(
                        'actualSource',
                        '来源',
                        filterByValue: true,
                        value: (r) =>
                            r['actualSource'] == true ? '原发料行' : '商品主档基本单位',
                      )
                    else ...[
                      financeSourceColumn(
                        'rate_percent_original',
                        '原输入（%）',
                        type: 'number',
                        sortable: true,
                      ),
                      financeSourceColumn(
                        'ratePercent',
                        '实际采用值（%）',
                        type: 'number',
                        sortable: true,
                      ),
                      financeSourceColumn(
                        'effective_from',
                        '生效日期',
                        sortable: true,
                      ),
                      financeSourceColumn(
                        'effective_to',
                        '截止日期',
                        sortable: true,
                      ),
                      financeSourceColumn(
                        'status',
                        '审核状态',
                        filterByValue: true,
                        value: (r) => _status(r['status']),
                      ),
                      financeSourceColumn(
                        'enabled',
                        '启用状态',
                        filterByValue: true,
                        value: (r) => r['enabled'] == true ? '启用' : '停用',
                      ),
                      financeSourceColumn(
                        'revision',
                        '版本',
                        type: 'int',
                        sortable: true,
                      ),
                    ],
                  ],
                  rows: _rows,
                  idOf: (r) =>
                      widget.chooseSource ? _dimensionId(r) : '${r['id']}',
                  busy: _busy,
                  error: _error,
                  retry: _load,
                  onOpen: _open,
                  canOpen: (_) => !_busy,
                  scope: (widget.supplierId, _epoch),
                ),
              ),
            ],
          ),
          if (_busy)
            const UtenBusyOverlay(
              title: '正在读取允许损耗率',
              showDoNotLeaveHint: false,
            ),
        ],
      ),
    );
  }
}

class _PolicyEditor extends ConsumerStatefulWidget {
  const _PolicyEditor({
    required this.supplierId,
    this.seed,
    this.policyId,
    this.resumeDraftId,
  });
  final String supplierId;
  final Map<String, dynamic>? seed;
  final String? policyId, resumeDraftId;
  @override
  ConsumerState<_PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends ConsumerState<_PolicyEditor>
    with FormDraftMixin<_PolicyEditor> {
  final _form = GlobalKey<FormState>();
  final _rate = TextEditingController(),
      _from = TextEditingController(),
      _to = TextEditingController(),
      _reference = TextEditingController(),
      _reason = TextEditingController();
  Map<String, dynamic> _selection = {};
  Map<String, dynamic>? _record, _pending;
  String? _error;
  bool _busy = false, _loading = true, _enabled = true, _editing = true;
  bool get _current => mounted && formDraftIdentityIsCurrent;
  bool get _frozen => _pending != null || formDraftHasUnknownSubmission;
  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit);
  bool get _canReview =>
      _canEdit &&
      ref.read(currentPermissionsProvider).contains(Perm.financePostExecute);
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeSubcontractLossPolicy.spec(
        routeParameters: {
          'supplierId': widget.supplierId,
          if (widget.policyId != null) 'policyId': widget.policyId!,
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
    _rate,
    _from,
    _to,
    _reference,
    _reason,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'supplierId': widget.supplierId,
    'selection': _selection,
    'record': _record,
    'editing': _editing,
    'enabled': _enabled,
    'rate': _rate.text,
    'from': _from.text,
    'to': _to.text,
    'reference': _reference.text,
    'reason': _reason.text,
    'pending': _pending,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['supplierId'] != widget.supplierId) {
      throw StateError('损耗率草稿不属于当前真实供应商');
    }
    _selection = _map(data['selection']);
    _record = data['record'] is Map ? _map(data['record']) : null;
    _pending = data['pending'] is Map ? _map(data['pending']) : null;
    if (widget.policyId != null && _record?['id'] != widget.policyId) {
      throw StateError('损耗率原版本与草稿不一致');
    }
    _editing = data['editing'] == true;
    _enabled = data['enabled'] == true;
    _rate.text = data['rate']?.toString() ?? '';
    _from.text = data['from']?.toString() ?? '';
    _to.text = data['to']?.toString() ?? '';
    _reference.text = data['reference']?.toString() ?? '';
    _reason.text = data['reason']?.toString() ?? '';
    if (_pending != null &&
        _pending!['actorId'] != ref.read(authenticatedScopeProvider)?.userId) {
      throw StateError('原请求不属于当前操作人，请保留本人草稿');
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.seed != null) _selection = _source(widget.seed!);
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initial());
  }

  @override
  void dispose() {
    for (final c in [_rate, _from, _to, _reference, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _initial() async {
    try {
      if (widget.resumeDraftId == null && widget.policyId != null) {
        final scope = await captureFormDraftRequestScope();
        final row = await scope.run(
          () => ref.read(apiClientProvider).get('$_base/${widget.policyId}'),
        );
        if (!_current || !scope.isCurrent) return;
        if (row['supplier_id']?.toString() != widget.supplierId) {
          throw StateError('原损耗率版本不属于当前供应商');
        }
        _record = row;
        _selection = _source(row);
        _editing = false;
        _enabled = row['enabled'] == true;
        _rate.text =
            (row['rate_percent_originalExact'] ??
                    row['rate_percent_original'] ??
                    row['ratePercentExact'] ??
                    row['ratePercent'])
                ?.toString() ??
            '';
        _from.text = row['effective_from']?.toString() ?? '';
        _to.text = row['effective_to']?.toString() ?? '';
        _reference.text = row['source_reference']?.toString() ?? '';
      }
      if (_current) await initializeFormDraft();
    } catch (error) {
      if (_current) _error = _problem(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choose() async {
    if (_busy || _frozen || !_editing || _record != null) return;
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _PolicyDirectory(supplierId: widget.supplierId, chooseSource: true),
    );
    if (_current && selected != null) {
      setState(() => _selection = _source(selected));
      markFormDraftChanged();
    }
  }

  Map<String, dynamic> _command({bool? approve}) {
    if (approve != null) {
      return {
        'path': '$_base/${_record!['id']}/decision',
        'body': {'approve': approve, 'reason': _reason.text.trim()},
        'headers': <String, dynamic>{},
      };
    }
    if (_selection['goodsId'] == null || _selection['unitId'] == null) {
      throw StateError('请选择同一真实商品、颜色与单位');
    }
    return {
      'path': _base,
      'body': {
        'requestId': const Uuid().v4(),
        'expectedRevision': _record == null ? -1 : _record!['revision'],
        'supplierId': widget.supplierId,
        'goodsId': _selection['goodsId'],
        'colorId': _selection['colorId'],
        'unitId': _selection['unitId'],
        'effectiveFrom': _from.text.trim(),
        'effectiveTo': _to.text.trim().isEmpty ? null : _to.text.trim(),
        'ratePercent': _rate.text,
        'enabled': _enabled,
        'sourceReference': _reference.text.trim(),
      },
      'headers': <String, dynamic>{},
    };
  }

  Future<void> _send({bool? approve, bool retry = false}) async {
    if (!_current ||
        _busy ||
        _loading ||
        !(approve != null ? _canReview : _canEdit)) {
      return;
    }
    if (_frozen && !retry) return;
    if (!retry && !(_form.currentState?.validate() ?? false)) return;
    final wasUnknown = formDraftHasUnknownSubmission;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      _pending ??= {
        ..._command(approve: approve),
        'actorId': ref.read(authenticatedScopeProvider)?.userId,
      };
      final command = _map(jsonDecode(jsonEncode(_pending)));
      await runFormDraftSubmission(
        () => scope.run(
          () => ref
              .read(apiClientProvider)
              .post(
                command['path'].toString(),
                body: command['body'],
                headers: _map(command['headers']),
              ),
        ),
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
      if (!_current || !scope.isCurrent) return;
      await completeFormDraft();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!formDraftHasUnknownSubmission) _pending = null;
      if (_current) setState(() => _error = _problem(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _matchesReceipt(
    Map<String, dynamic> response,
    Map<String, dynamic> body,
  ) {
    if (response['request_id']?.toString() != body['requestId'] ||
        response['submitted_by']?.toString() != _pending!['actorId']) {
      return false;
    }
    for (final entry in const {
      'supplierId': 'supplier_id',
      'goodsId': 'goods_id',
      'colorId': 'color_id',
      'unitId': 'unit_id',
      'effectiveFrom': 'effective_from',
      'effectiveTo': 'effective_to',
      'enabled': 'enabled',
      'sourceReference': 'source_reference',
    }.entries) {
      if (response[entry.value]?.toString() != body[entry.key]?.toString()) {
        return false;
      }
    }
    final revision = body['expectedRevision'];
    if (revision is! num ||
        response['revision']?.toString() != (revision.toInt() + 1).toString()) {
      return false;
    }
    return exactNumberDisplay(
          response['rate_percent_originalExact'] ??
              response['rate_percent_original'],
        ) ==
        exactNumberDisplay(body['ratePercent']);
  }

  Future<void> _receipt() async {
    if (!_current || _busy || _pending == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope(),
          body = _map(_pending!['body']);
      final decision = _pending!['path'].toString().endsWith('/decision');
      final path = decision
          ? '$_base/${_record!['id']}'
          : '$_base/operations/${body['requestId']}';
      final response = await scope.run(
        () => ref.read(apiClientProvider).get(path),
      );
      if (!_current || !scope.isCurrent) return;
      if (decision &&
          (response['reviewed_by']?.toString() != _pending!['actorId'] ||
              response['review_reason'] != body['reason'] ||
              response['status'] !=
                  (body['approve'] == true ? 'APPROVED' : 'REJECTED'))) {
        throw StateError('尚未取得本人原审核请求的成功回执，请保留原请求');
      }
      if (!decision && !_matchesReceipt(response, body)) {
        throw StateError('原请求回执不匹配，请保留原请求');
      }
      await completeFormDraft();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (_current) setState(() => _error = _problem(error));
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
  String? _required(String? value) =>
      (value?.trim().isEmpty ?? true) ? '请填写实际来源值' : null;
  String? _date(String? value, {bool optional = false}) {
    if (optional && (value?.isEmpty ?? true)) return null;
    return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value ?? '') &&
            DateTime.tryParse(value ?? '') != null
        ? null
        : '请填写YYYY-MM-DD日期';
  }

  @override
  Widget build(BuildContext context) {
    if (!formDraftIdentityIsCurrent) {
      return withFormDraft(
        UtenAlertDialog(
          showCloseButton: true,
          onClose: () => Navigator.pop(context),

          title: const Text('允许损耗率'),
          content: const Text('登录身份、权限或服务器已变化，原草稿已保留。'),
        ),
      ).withSelectedValueHighlights();
    }
    final editable = _editing && !_busy && !_frozen && _canEdit;
    return withFormDraft(
      UtenDialogFrame(
        maxWidth: 760,
        fillHeight: true,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  title: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('允许损耗率'),
                      UtenFieldHintIcon(
                        info:
                            '按真实供应商、商品、颜色、单位和原发料日期采用已审核规则；加工币别不改变实物损耗。原表“允许生产损耗3%”列名保留。',
                      ),
                    ],
                  ),
                  showCloseButton: true,
                  onClose: _busy ? null : _close,
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
                          UtenResponsiveActionWrap(
                            children: [
                              Text(
                                [
                                  _selection['goodsCode'],
                                  _selection['goodsName'],
                                  _selection['colorName'] ?? '全部颜色',
                                  _selection['unitCode'] ??
                                      _selection['unitName'],
                                ].where((v) => v != null).join('  '),
                              ),
                              if (_record == null)
                                UtenButton(
                                  onPressed: editable ? _choose : null,
                                  child: const Text('选择实际商品'),
                                ),
                            ],
                          ),
                          if (_record != null)
                            Text(
                              '版本 ${_record!['revision']}  ${_status(_record!['status'])}',
                            ),
                          const SizedBox(height: 12),
                          UtenInput(
                            label: '允许损耗率（%）',
                            info: '3表示3%，5表示5%。小数按原值保留；超出支持精度时由本次用户明确选择。',
                            controller: _rate,
                            enabled: editable,
                            validator: (v) => !_editing
                                ? null
                                : _required(v) ??
                                      (RegExp(
                                            r'^\d+(?:\.\d+)?$',
                                          ).hasMatch(v ?? '')
                                          ? null
                                          : '请填写0至100之间的百分数'),
                          ),
                          if (_record != null) ...[
                            const SizedBox(height: 12),
                            UtenSummaryField(
                              label: '实际采用损耗率（%）',
                              value:
                                  (_record!['ratePercentExact'] ??
                                          _record!['ratePercent'])
                                      ?.toString(),
                              selectable: true,
                              inline: true,
                              info: '原输入与采用值分别保留；超支持精度仅按本次用户明确选择。',
                            ),
                          ],
                          const SizedBox(height: 12),
                          UtenInput(
                            label: '生效日期',
                            controller: _from,
                            enabled: editable && _record == null,
                            validator: (v) => _editing ? _date(v) : null,
                          ),
                          const SizedBox(height: 12),
                          UtenInput(
                            label: '截止日期',
                            info: '留空表示没有截止日期。后续版本必须保留原生效日；新增期间须明确避免重叠。',
                            controller: _to,
                            enabled: editable,
                            validator: (v) =>
                                _editing ? _date(v, optional: true) : null,
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
                            label: '实际来源依据',
                            controller: _reference,
                            enabled: editable,
                            maxLines: 3,
                            validator: (v) => _editing ? _required(v) : null,
                          ),
                          if (!_editing &&
                              _record?['status'] == 'SUBMITTED') ...[
                            const SizedBox(height: 12),
                            UtenInput(
                              label: '审核依据',
                              controller: _reason,
                              enabled: !_busy && !_frozen && _canReview,
                              maxLines: 3,
                              validator: (v) => _required(v),
                            ),
                          ],
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
                          onPressed: _busy || _loading
                              ? null
                              : () => _send(approve: true),
                          child: const Text('审核通过'),
                        ),
                        UtenButton(
                          onPressed: _busy || _loading
                              ? null
                              : () => _send(approve: false),
                          child: const Text('退回核对'),
                        ),
                      ],
                      if (!_editing && _canEdit)
                        UtenButton(
                          onPressed: _busy || _loading
                              ? null
                              : () {
                                  setState(() => _editing = true);
                                  markFormDraftChanged();
                                },
                          child: const Text('更正或停用'),
                        ),
                    ],
                  ],
                ),
              ],
            ),
            if (_busy || _loading)
              const UtenBusyOverlay(
                title: '正在核对允许损耗率',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    ).withSelectedValueHighlights();
  }
}

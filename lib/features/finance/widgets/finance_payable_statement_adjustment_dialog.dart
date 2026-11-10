import '../../../components/inputs/uten_selected_value_theme.dart';
import '../shared/finance_workbench_panel.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/paging/versioned_summary_read.dart';
import '../../../shared/paging/read_view_activity.dart';
import '../../../shared/paging/scoped_paged_read.dart'
    show pagedReadAccessDenied;
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_auxiliary_dialog.dart';
import 'finance_source_table.dart';

const _path = '/finance/payable-statement-adjustments';
Future<void> showFinancePayableStatementAdjustmentDialog(
  BuildContext context, {
  required String statementReviewId,
  required String expectedSourceFingerprint,
  String? resumeDraftId,
}) => showFinanceWorkbenchPanel<void>(
  context: context,
  builder: (_) => _Adjustment(
    statementReviewId: statementReviewId,
    fingerprint: expectedSourceFingerprint,
    resumeDraftId: resumeDraftId,
  ),
);

class _Adjustment extends ConsumerStatefulWidget {
  const _Adjustment({
    required this.statementReviewId,
    required this.fingerprint,
    this.resumeDraftId,
  });
  final String statementReviewId, fingerprint;
  final String? resumeDraftId;
  @override
  ConsumerState<_Adjustment> createState() => _AdjustmentState();
}

class _Line extends EditableGridRow {
  _Line(this.target, {String? rowId}) : rowId = rowId ?? const Uuid().v4();
  final Map<String, dynamic> target;
  final String rowId;
  String? decision, kind, category, styleId;
  Map<String, dynamic>? auxiliary;
  final amount = TextEditingController(),
      attribution = TextEditingController(),
      source = TextEditingController();
  Map<String, dynamic> snapshot() => {
    'rowId': rowId,
    'target': target,
    'decision': decision,
    'kind': kind,
    'category': category,
    'styleId': styleId,
    'auxiliary': auxiliary,
    'amount': amount.text,
    'attribution': attribution.text,
    'source': source.text,
  };
  Map<String, dynamic> payload() => {
    'targetLedgerId': target['ledgerId'],
    'expectedTargetFingerprint': target['fingerprint'],
    'decision': decision,
    'feeKind': kind,
    'category': category,
    'amountOriginal': amount.text,
    'counterpartStyleId': styleId,
    'counterpartAuxiliaryId': auxiliary?['id'],
    'attributionReference': attribution.text,
    'sourceReference': source.text,
  };
  @override
  void dispose() {
    amount.dispose();
    attribution.dispose();
    source.dispose();
    super.dispose();
  }
}

class _AdjustmentState extends ConsumerState<_Adjustment>
    with FormDraftMixin<_Adjustment>, ReadViewActivityMixin<_Adjustment> {
  @override
  Future<void> onReadViewResumed() => _load();
  late final ApiClient _api;
  late final int _epoch;
  final _grid = UtenEditableGridController<_Line>();
  final _reference = TextEditingController();
  Map<String, dynamic> _data = {};
  Map<String, dynamic>? _preview, _sent;
  String? _error;
  int _generation = 0;
  bool _busy = false,
      _initialized = false,
      _unknown = false,
      _readDenied = false;
  Map<String, dynamic> get _scope => {
    'statementReviewId': widget.statementReviewId,
    'expectedSourceFingerprint': widget.fingerprint,
  };
  bool get _current =>
      mounted &&
      formDraftIdentityIsCurrent &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _write => ref.read(currentPermissionsProvider).containsAll({
    'supplier_settlement:confirm',
    'finance_payment:approve',
    'finance_post:execute',
  });
  bool get _editable =>
      _current && !_readDenied && !_busy && _sent == null && _write;
  List<Map<String, dynamic>> get _targets => _maps(_data['targets']);
  List<Map<String, dynamic>> get _accounts => _maps(_data['accounts']);
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financePayableStatementAdjustment.spec(
        title: '手续费/尾数',
        routeParameters: {
          'statementReviewId': widget.statementReviewId,
          'expectedSourceFingerprint': widget.fingerprint,
        },
      );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftCanReplaySubmission => _sent != null;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _reference,
    _grid,
    for (final row in _grid.rows) ...[row.amount, row.attribution, row.source],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'scope': _scope,
    'rows': [for (final row in _grid.rows) row.snapshot()],
    'reference': _reference.text,
    'preview': _preview,
    'sent': _sent,
    'unknown': _unknown,
    if (_unknown) formDraftUnknownSubmissionKey: true,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (jsonEncode(data['scope']) != jsonEncode(_scope)) {
      throw StateError('原件编号或来源指纹与草稿不一致');
    }
    final rows = <_Line>[];
    for (final item in _maps(data['rows'])) {
      final target = _map(item['target']);
      if (target['ledgerId'] is! String ||
          target['fingerprint'] is! String ||
          !Uuid.isValidUUID(fromString: item['rowId']?.toString() ?? '')) {
        throw StateError('原应付身份或草稿行编号缺失');
      }
      final row = _Line(target, rowId: item['rowId'] as String)
        ..decision = item['decision']?.toString()
        ..kind = item['kind']?.toString()
        ..category = item['category']?.toString()
        ..styleId = item['styleId']?.toString()
        ..auxiliary = item['auxiliary'] == null
            ? null
            : _map(item['auxiliary']);
      row.amount.text = item['amount']?.toString() ?? '';
      row.attribution.text = item['attribution']?.toString() ?? '';
      row.source.text = item['source']?.toString() ?? '';
      rows.add(row);
    }
    _grid.replaceAll(rows);
    _reference.text = data['reference']?.toString() ?? '';
    _preview = data['preview'] == null ? null : _map(data['preview']);
    _sent = data['sent'] == null ? null : _map(data['sent']);
    _unknown = data['unknown'] == true;
    if (_sent != null) {
      final path = _sent!['path']?.toString() ?? '';
      if (path != _path &&
          !RegExp(
            r'^/finance/payable-statement-adjustments/[0-9a-f-]{36}/(approve|reverse)$',
          ).hasMatch(path)) {
        throw StateError('原操作路径无法确认');
      }
      if (path == _path) {
        final body = _map(_sent!['body']);
        if (!Uuid.isValidUUID(
              fromString: body['requestId']?.toString() ?? '',
            ) ||
            jsonEncode(body['context']) != jsonEncode(_scope)) {
          throw StateError('原提交编号或原件范围不一致');
        }
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    startFormDraftIdentityGuard();
    _grid.rowsListenable.addListener(_rowsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _grid.rowsListenable.removeListener(_rowsChanged);
    _reference.dispose();
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _busy) return;
    final generation = ++_generation;
    bool current() => _current && generation == _generation;
    final query = Map<String, dynamic>.unmodifiable(_scope);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await readViewActivity.runRead(current, () async {
        Map<String, dynamic> first = {};

        final targets =
            await readVersionedSummarySnapshot<Map<String, dynamic>>(
              isCurrent: current,
              idOf: (row) => row['ledgerId'],
              decode: Map<String, dynamic>.unmodifiable,
              loadPage: (batch, size, revision) async {
                final value = await _api.get(
                  _path,
                  query: {
                    ...query,
                    'part': 'targets',
                    'page': batch,
                    'size': size,
                    'readSnapshotRevision': ?revision,
                  },
                );
                if (batch == 1) first = value;
                return {...value, 'items': value['targets']};
              },
            );
        // Records have their own count, fixed internal batch and query token.
        // They must never inherit the independent target count or token.
        final records =
            await readVersionedSummarySnapshot<Map<String, dynamic>>(
              isCurrent: current,
              batchSize: 50,
              idOf: (row) => row['id'],
              decode: Map<String, dynamic>.unmodifiable,
              loadPage: (batch, size, revision) async {
                final value = await _api.get(
                  _path,
                  query: {
                    ...query,
                    'part': 'adjustments',
                    'adjustmentPage': batch,
                    'readSnapshotRevision': ?revision,
                  },
                );
                return {
                  ...value,
                  'items': value['adjustments'],
                  'page': value['adjustmentPage'],
                  'size': value['adjustmentSize'],
                  'total': value['adjustmentTotal'],
                  'totalPages': value['adjustmentPages'],
                };
              },
            );
        // Part-specific tokens are intentionally different. The shared domain
        // and authority proofs must agree before publishing either collection.
        if (targets.dataVersion == null || records.dataVersion == null) {
          throw ApiException(
            'INCOMPLETE_READ_PROTOCOL',
            '服务端未提供完整调整范围凭据，请更新后重试',
          );
        }
        if (targets.dataVersion != records.dataVersion ||
            targets.readScopeVersion != records.readScopeVersion) {
          throw ApiException('SNAPSHOT_CHANGED', '调整范围已变化，请重新读取');
        }
        return <String, dynamic>{
          ...first,
          'targets': targets.items,
          'page': 1,
          'total': targets.page.total,
          'totalPages': targets.page.totalPages,
          'adjustments': records.items,
          'adjustmentPage': 1,
          'adjustmentPages': records.page.totalPages,
          'adjustmentTotal': records.page.total,
        };
      });
      if (!_current || generation != _generation) return;
      setState(() {
        _data = data;
        _readDenied = false;
      });
      if (!_initialized) {
        await initializeFormDraft();
        if (!_current) return;
        _initialized = true;
      }
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _generation) {
        setState(() {
          _error = _message(e);
          if (pagedReadAccessDenied(e)) {
            _readDenied = _data.isNotEmpty || _grid.rows.isNotEmpty;
            _data = {};
          }
        });
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  void _changed() {
    _preview = null;
    markFormDraftChanged();
  }

  void _rowsChanged() {
    if (mounted) {
      _preview = null;
      markFormDraftChanged();
    }
  }

  void _select(Set<String> ids) {
    if (!_editable) return;
    final old = List<_Line>.of(_grid.rows);
    final next = [
      for (final row in old)
        if (ids.contains(row.target['ledgerId'])) row,
    ];
    for (final id in ids) {
      if (next.any((row) => row.target['ledgerId'] == id)) continue;
      final source = _targets.where((row) => row['ledgerId'] == id).firstOrNull;
      if (source != null) next.add(_Line(source));
    }
    _grid.clearSelection();
    _grid.swapRows(next);
    for (final row in old) {
      if (!next.contains(row)) row.dispose();
    }
    setState(_changed);
  }

  Future<void> _pickAuxiliary(_Line row) async {
    if (!_editable || row.styleId == null) return;
    final account = _accounts.where((a) => a['id'] == row.styleId).firstOrNull;
    if (account == null) return;
    final selected = await showFinanceAuxiliaryPicker(
      context,
      accountCode: account['code']?.toString(),
    );
    if (!_current || selected == null) return;
    setState(() {
      row.auxiliary = selected;
      _changed();
    });
  }

  List<Map<String, dynamic>> _payload() {
    if (_grid.rows.isEmpty) throw StateError('请选择原件完整覆盖的实际应付');
    return [for (final row in _grid.rows) row.payload()];
  }

  Future<void> _calculate() async {
    if (!_editable) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _api.postCancellable(
        '$_path/preview',
        body: {'context': _scope, 'lines': _payload()},
      );
      if (_current) {
        setState(() => _preview = result);
        markFormDraftChanged();
      }
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_current || (_readDenied && _sent == null) || _busy || !_write) return;
    if (_sent == null) {
      if (_preview == null || _reference.text.trim().isEmpty) {
        setState(() => _error = '请填写处理依据并预览本次原币和本币金额');
        return;
      }
      _sent = {
        'path': _path,
        'body': {
          'requestId': const Uuid().v4(),
          'context': _scope,
          'lines': _payload(),
          'expectedPlanHash': _preview!['planHash'],
          'sourceReference': _reference.text,
          'precisionChoicesJson': _preview!['precisionChoicesJson'],
        },
      };
    }
    await _send();
  }

  Future<void> _send() async {
    if (!_current || _busy || _sent == null) return;
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      final sent = _sent!;
      await runFormDraftSubmission(
        () => scope.run(() async {
          final path = sent['path'] as String;
          if (path == _path) {
            await _api.post(path, body: sent['body']);
          } else {
            await _api.postList(path, body: sent['body']);
          }
        }),
      );
      if (!_current || !scope.isCurrent) return;
      await completeFormDraft();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _unknown = wasUnknown || !_rejected(e);
      if (!_unknown && !formDraftHasUnknownSubmission) _sent = null;
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _act(Map<String, dynamic> record) async {
    if (!_editable) return;
    if (_grid.rows.isNotEmpty || _reference.text.isNotEmpty) {
      setState(() => _error = '请先保存当前填写内容，再处理原审核记录');
      return;
    }
    final id = record['id']?.toString();
    if (id == null) return;
    Map<String, dynamic> detail;
    setState(() => _busy = true);
    try {
      detail = await _api.get('$_path/$id');
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
      return;
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (!mounted || !_current) return;
    final reverse = detail['status'] == 'APPROVED';
    if (!reverse && detail['status'] != 'DRAFT') return;
    final reason = TextEditingController();
    final label = reverse ? '反审处理' : '审核处理';
    final plan = _map(detail['plan']);
    final effects = _maps(detail['effects']);
    final rows = [
      for (final (index, row) in _maps(plan['items']).indexed)
        {
          ..._map(row['preview']),
          ..._map(_map(row['preview'])['input']),
          'counterpart': row['counterpart'],
          'effectiveParts': index < effects.length
              ? effects[index]['effectiveParts']
              : null,
        },
    ];
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
        maxWidth: 1000,
        title: Text(label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 300,
              width: 950,
              child: financeSourceTable(
                tableKey: 'finance.payable-statement-adjustments.confirm',
                columns: [
                  financeSourceColumn('targetBillNo', '原应付单号', width: 220),
                  financeSourceColumn('targetSourceDocNo', '原业务单号', width: 220),
                  financeSourceColumn(
                    'decision',
                    '决定',
                    value: (r) => _label(r['decision']),
                  ),
                  financeSourceColumn(
                    'feeKind',
                    '手续费/尾数',
                    value: (r) => _label(r['feeKind']),
                  ),
                  financeSourceColumn(
                    'category',
                    '原审批归属',
                    value: (r) => _label(r['category']),
                  ),
                  financeSourceColumn(
                    'effectiveParts',
                    '当前有效归属',
                    width: 380,
                    value: (r) => _maps(r['effectiveParts'])
                        .map(
                          (p) =>
                              '${_label(p['category'])} 原币${p['amountOriginal']} / 账面${p['amountLocal']}',
                        )
                        .join('；'),
                  ),
                  financeSourceColumn(
                    'effectiveCorrection',
                    '更正编号',
                    width: 290,
                    value: (r) => _maps(r['effectiveParts'])
                        .map((p) => p['correctionId']?.toString())
                        .whereType<String>()
                        .toSet()
                        .join('；'),
                  ),
                  financeSourceColumn(
                    'amountOriginal',
                    '明确原币金额',
                    type: 'money',
                  ),
                  financeSourceColumn('amountLocal', '减少账面本币', type: 'money'),
                  financeSourceColumn('counterpartAccountCode', '对方财务科目'),
                  financeSourceColumn(
                    'debtAccount',
                    '原应付财务科目',
                    value: (r) =>
                        _map(r['debtAccount'])['accountCode']?.toString(),
                  ),
                  financeSourceColumn(
                    'counterpartAuxiliary',
                    '对方真实辅助',
                    value: (r) => _map(
                      _map(r['counterpart'])['auxiliary'],
                    )['sourceName']?.toString(),
                  ),
                  financeSourceColumn(
                    'attributionReference',
                    '归属依据',
                    width: 300,
                  ),
                  financeSourceColumn('sourceReference', '原来源依据', width: 300),
                ],
                rows: rows,
                idOf: (r) => '${r['targetLedgerId']}|${r['feeKind']}',
                scope: (_epoch, id),
              ),
            ),
            if (reverse) UtenInput(label: '反审依据', controller: reason),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          UtenButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(label),
          ),
        ],
      ),
    );
    final reasonText = reason.text;
    reason.dispose();
    if (accepted != true || !_current) return;
    if (reverse && reasonText.trim().isEmpty) {
      setState(() => _error = '请填写反审依据');
      return;
    }
    _sent = {
      'path': '$_path/$id/${reverse ? 'reverse' : 'approve'}',
      'body': reverse ? {'reason': reasonText} : null,
    };
    await _send();
  }

  Future<void> _close() async {
    if (_busy) return;
    if (await confirmFormDraftExit() && mounted) Navigator.pop(context);
  }

  Widget _dropdown(
    _Line row,
    String? value,
    Map<String, String> choices,
    void Function(String?) assign,
  ) => UtenDropdownField(
    value: value,
    enabled: _editable,
    dense: true,
    items: [
      for (final item in choices.entries)
        UtenDropdownItem(value: item.key, label: item.value),
    ],
    onChanged: (v) => setState(() {
      assign(v);
      _changed();
    }),
  );
  @override
  Widget build(BuildContext context) {
    ref.watch(apiClientProvider);
    ref.watch(exportContextEpochProvider);
    ref.watch(currentPermissionsProvider);
    if (!_current || _readDenied) {
      return withFormDraft(
        UtenAlertDialog(
          showCloseButton: true,
          onClose: () => Navigator.pop(context),

          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('手续费/尾数'),
              UtenFieldHintIcon(
                info: '身份、权限或原件范围已变化。原私有草稿保留，请重新进入。',
                errorMessage: _error,
              ),
            ],
          ),
        ),
      );
    }
    final columns = <EditableGridColumn<_Line>>[
      EditableGridColumn(
        key: 'target',
        label: '原应付单号',
        width: 230,
        textOf: (r) => '${r.target['billNo']}',
        cellBuilder: (_, r) => Text('${r.target['billNo']}'),
      ),
      EditableGridColumn(
        key: 'kind',
        label: '手续费/尾数',
        width: 150,
        cellBuilder: (_, r) => _dropdown(r, r.kind, {
          'HANDLING_FEE': '手续费',
          'ROUNDING': '尾数',
        }, (v) => r.kind = v),
      ),
      EditableGridColumn(
        key: 'decision',
        label: '仍欠/不欠',
        width: 160,
        headerInfo: '由财务逐笔选择，不设全局默认；真实银行手续费仍沿原银行费用链。',
        cellBuilder: (_, r) => _dropdown(
          r,
          r.decision,
          {'STILL_OWED': '仍欠', 'RELEASED': '不欠'},
          (v) {
            r.decision = v;
            if (v == 'STILL_OWED') {
              r.styleId = null;
              r.auxiliary = null;
            }
          },
        ),
      ),
      EditableGridColumn(
        key: 'category',
        label: '货款/模具归属',
        width: 160,
        cellBuilder: (_, r) => _dropdown(r, r.category, {
          'GOODS': '货款',
          'MOULD': '模具款',
        }, (v) => r.category = v),
      ),
      EditableGridColumn(
        key: 'amount',
        label: '明确原币金额',
        width: 240,
        numeric: true,
        textOf: (r) => r.amount.text,
        exactValueOf: (r) => r.amount.text,
        listenableOf: (r) => r.amount,
        cellBuilder: (_, r) => UtenInput(
          key: ValueKey('fee-amount-${r.rowId}'),
          controller: r.amount,
          enabled: _editable,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(_changed),
        ),
      ),
      EditableGridColumn(
        key: 'style',
        label: '不欠对方科目',
        width: 260,
        cellBuilder: (_, r) => UtenDropdownField(
          value: r.styleId,
          enabled: _editable && r.decision == 'RELEASED',
          dense: true,
          items: [
            for (final a in _accounts)
              UtenDropdownItem(
                value: a['id']?.toString(),
                label: '${a['code']} ${a['name']}',
              ),
          ],
          onChanged: (v) => setState(() {
            r.styleId = v;
            r.auxiliary = null;
            _changed();
          }),
        ),
      ),
      EditableGridColumn(
        key: 'auxiliary',
        label: '对方真实辅助',
        width: 200,
        cellBuilder: (_, r) => UtenButton(
          type: r.auxiliary == null
              ? UtenButtonType.secondary
              : UtenButtonType.tonal,
          onPressed: _editable && r.decision == 'RELEASED' && r.styleId != null
              ? () => _pickAuxiliary(r)
              : null,
          child: Text(r.auxiliary?['sourceName']?.toString() ?? '选择辅助项目'),
        ),
      ),
      for (final key in ['attribution', 'source'])
        EditableGridColumn(
          key: key,
          label: key == 'attribution' ? '归属依据' : '原来源依据',
          width: 300,
          textOf: (r) => (key == 'attribution' ? r.attribution : r.source).text,
          listenableOf: (r) => key == 'attribution' ? r.attribution : r.source,
          cellBuilder: (_, r) => UtenInput(
            key: ValueKey('fee-$key-${r.rowId}'),
            controller: key == 'attribution' ? r.attribution : r.source,
            enabled: _editable,
            inputFormatters: [LengthLimitingTextInputFormatter(2000)],
            onChanged: (_) => setState(_changed),
          ),
        ),
      EditableGridColumn(
        key: 'more',
        label: '同单另一项',
        width: 160,
        cellBuilder: (_, r) => UtenButton(
          onPressed: _editable
              ? () {
                  _grid.addRow(_Line(r.target));
                  setState(_changed);
                }
              : null,
          child: const Text('添加同单项'),
        ),
      ),
    ];
    return withFormDraft(
      Stack(
        children: [
          UtenDialogFrame(
            maxWidth: 1300,
            fillHeight: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('手续费/尾数'),
                      UtenFieldHintIcon(
                        errorMessage: _error,
                        info:
                            '仍欠保留原应付；不欠经独立审核后按原应付科目减少债务。原件本期净额与已付款后的待汇余额分别核对。',
                      ),
                    ],
                  ),
                  showCloseButton: true,
                  onClose: _busy ? null : _close,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 175,
                          child: financeSourceTable(
                            tableKey:
                                'finance.payable-statement-adjustments.original',
                            columns: [
                              financeSourceColumn(
                                'periodAmountOriginal',
                                '原件本期金额',
                                type: 'money',
                                value: (r) =>
                                    r['periodAmountOriginal']?.toString() ??
                                    '待核',
                              ),
                              financeSourceColumn(
                                'releasedOriginal',
                                '本次不欠原币',
                                type: 'money',
                                value: (r) =>
                                    r['releasedOriginal']?.toString() ?? '待核',
                              ),
                              financeSourceColumn(
                                'currency',
                                '原币单位',
                                width: 250,
                              ),
                            ],
                            rows: [
                              {
                                'periodAmountOriginal': _map(
                                  _data['original'],
                                )['periodAmountOriginal'],
                                'releasedOriginal':
                                    _preview?['releasedOriginal'],
                                'currency': _data['currency'] == null
                                    ? '待核'
                                    : '${_map(_data['currency'])['code']} ${_map(_data['currency'])['name']}',
                              },
                            ],
                            idOf: (_) => widget.statementReviewId,
                            scope: (_epoch, widget.statementReviewId),
                          ),
                        ),
                        SizedBox(
                          height: 240,
                          child: financeSourceTable(
                            tableKey:
                                'finance.payable-statement-adjustments.targets',
                            columns: [
                              financeSourceColumn(
                                'billNo',
                                '原应付单号',
                                width: 220,
                              ),
                              financeSourceColumn(
                                'sourceDocNo',
                                '原业务单号',
                                width: 220,
                              ),
                              financeSourceColumn(
                                'balanceOriginal',
                                '当前未结原币',
                                type: 'money',
                              ),
                              financeSourceColumn(
                                'balanceLocal',
                                '当前未结本币',
                                type: 'money',
                              ),
                            ],
                            rows: _targets,
                            idOf: (r) => '${r['ledgerId']}',
                            busy: _busy,
                            error: _targets.isEmpty ? _error : null,
                            retry: () => _load(),
                            scope: (_epoch, widget.statementReviewId),
                            selectable: _editable,
                            selectedIds: _grid.rows
                                .map((r) => '${r.target['ledgerId']}')
                                .toSet(),
                            onSelectedIdsChanged: _select,
                          ),
                        ),
                        UtenEditableGrid<_Line>(
                          emptyMessage: '请在上表选择本次处理的应付行',
                          tableKey:
                              'finance.payable-statement-adjustments.lines',
                          controller: _grid,
                          columns: columns,
                          showAddRow: false,
                          showColumnSettings: false,
                          stickyHeader: false,
                          selectionEnabled: _editable,
                          showRowDelete: _editable,
                          showRemoveRowsAction: _editable,
                          onDeleteRow: (_, index) {
                            if (!_editable) return;
                            _grid.removeAt(index);
                            setState(_changed);
                          },
                        ).withSelectedValueHighlights(),
                        UtenInput(
                          label: '本次处理依据',
                          controller: _reference,
                          enabled: _editable,
                          maxLines: 2,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(2000),
                          ],
                          onChanged: (_) => markFormDraftChanged(),
                        ),
                        if (_preview != null)
                          SizedBox(
                            height: 220,
                            child: financeSourceTable(
                              tableKey:
                                  'finance.payable-statement-adjustments.preview',
                              columns: [
                                financeSourceColumn(
                                  'targetBeforeOriginal',
                                  '处理前未结原币',
                                  type: 'money',
                                ),
                                financeSourceColumn(
                                  'amountLocal',
                                  '本次减少账面本币',
                                  type: 'money',
                                ),
                                financeSourceColumn(
                                  'targetAfterOriginal',
                                  '处理后未结原币',
                                  type: 'money',
                                ),
                                financeSourceColumn(
                                  'targetAfterLocal',
                                  '处理后未结本币',
                                  type: 'money',
                                ),
                              ],
                              rows: [
                                for (final r in _maps(_preview!['lines']))
                                  {
                                    ...r,
                                    'key':
                                        '${_map(r['input'])['targetLedgerId']}|${_map(r['input'])['feeKind']}',
                                  },
                              ],
                              idOf: (r) => '${r['key']}',
                              scope: (
                                _epoch,
                                widget.statementReviewId,
                                _preview!['planHash'],
                              ),
                            ),
                          ),
                        if (_maps(_data['adjustments']).isNotEmpty)
                          SizedBox(
                            height: 220,
                            child: financeSourceTable(
                              tableKey:
                                  'finance.payable-statement-adjustments.records',
                              columns: [
                                financeSourceColumn(
                                  'status',
                                  '状态',
                                  value: (r) => _label(r['status']),
                                ),
                                financeSourceColumn(
                                  'effective_date',
                                  '处理日期',
                                  type: 'date',
                                ),
                                financeSourceColumn(
                                  'released_original',
                                  '不欠原币',
                                  type: 'money',
                                ),
                                financeSourceColumn(
                                  'released_local',
                                  '不欠本币',
                                  type: 'money',
                                ),
                                financeSourceColumn(
                                  'source_reference',
                                  '处理依据',
                                  width: 300,
                                ),
                              ],
                              rows: _maps(_data['adjustments']),
                              idOf: (r) => '${r['id']}',
                              onOpen: _write ? _act : null,
                              scope: (_epoch, widget.statementReviewId),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                UtenDialogActions(
                  children: [
                    UtenButton(
                      onPressed: _busy || _sent != null ? null : () => _load(),
                      child: const Text('刷新核对'),
                    ),
                    UtenButton(
                      onPressed: _editable ? _calculate : null,
                      child: const Text('预览逐笔金额'),
                    ),

                    if (_write)
                      UtenButton(
                        onPressed: _busy ? null : _submit,
                        child: Text(_sent != null ? '核对并重试原操作' : '保存待审核处理'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (_busy)
            const UtenBusyOverlay(
              title: '正在处理手续费/尾数',
              showDoNotLeaveHint: false,
            ),
        ],
      ),
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? [
        for (final row in value)
          if (row is Map) Map<String, dynamic>.from(row),
      ]
    : [];
String _message(Object e) => e is ApiException
    ? e.message
    : e is StateError
    ? e.message
    : '操作未完成，原输入已保留';
bool _rejected(Object error) =>
    error is ApiException &&
    error.hasResponseCode &&
    (error.httpStatus ?? 0) >= 400 &&
    (error.httpStatus ?? 0) < 500;
String _label(Object? value) =>
    const {
      'STILL_OWED': '仍欠',
      'RELEASED': '不欠',
      'HANDLING_FEE': '手续费',
      'ROUNDING': '尾数',
      'GOODS': '货款',
      'MOULD': '模具款',
      'DRAFT': '待审核',
      'APPROVED': '已审核',
      'REVERSED': '已反审',
    }[value] ??
    '待核';

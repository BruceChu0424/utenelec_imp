import '../../../components/inputs/uten_selected_value_theme.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../core/utils/currency_display.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../config/finance_requirement_names.dart';
import 'finance_applications_page.dart';

/// Original source identifiers and decimal text survive interruptions; no money is moved here.
class FinanceApplicationEditPage extends ConsumerStatefulWidget {
  const FinanceApplicationEditPage({
    super.key,
    required this.kind,
    this.resumeDraftId,
    this.applicationId,
  });
  final String kind;
  final String? resumeDraftId, applicationId;
  @override
  ConsumerState<FinanceApplicationEditPage> createState() =>
      _ApplicationEditState();
}

class _ApplicationEditState extends ConsumerState<FinanceApplicationEditPage>
    with FormDraftMixin<FinanceApplicationEditPage> {
  final _text = <String, TextEditingController>{};
  final _grid = UtenEditableGridController<_RequestRow>();
  Map<String, dynamic> _catalog = {},
      _references = {},
      _source = {},
      _travel = {},
      _supplier = {};
  Map<String, dynamic>? _sent;
  String _id = const Uuid().v4(), _nature = 'GENERAL_EXPENSE';
  String? _currency, _error;
  bool _loading = true, _saving = false;
  int _version = -1;
  TextEditingController _c(String key) =>
      _text.putIfAbsent(key, () => TextEditingController());
  String get _kind => widget.kind;
  bool get _expense =>
      {'REIMBURSEMENT', 'TRAVEL_REIMBURSEMENT'}.contains(_kind);
  bool get _payment =>
      {'PAYMENT_APPLICATION', 'PREPAYMENT_APPLICATION'}.contains(_kind);
  String get _label =>
      financeApplicationRows(
        _catalog['types'],
      ).where((r) => r['key'] == _kind).firstOrNull?['label']?.toString() ??
      FinanceRequirementNames.financeApplications;
  FormDraftDescriptor get _descriptor {
    final expense =
        _expense ||
        (_kind == 'TRAVEL_APPLICATION' &&
            ref.read(currentPermissionsProvider).contains(Perm.expenseApply));
    if (widget.applicationId != null) {
      return _kind == 'PAYROLL_PAYMENT'
          ? FormDraftCatalog.financeApplicationPayrollEditing
          : expense
          ? FormDraftCatalog.financeApplicationExpenseEditing
          : FormDraftCatalog.financeApplicationEditing;
    }
    return _kind == 'PAYROLL_PAYMENT'
        ? FormDraftCatalog.financeApplicationPayroll
        : expense
        ? FormDraftCatalog.financeApplicationExpense
        : FormDraftCatalog.financeApplication;
  }

  @override
  FormDraftSpec get formDraftSpec => _descriptor.spec(
    route: widget.applicationId == null
        ? '/finance/applications/new'
        : '/finance/applications/${widget.applicationId}/edit',
    routeParameters: {'kind': _kind},
    title: _label,
  );
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _saving;
  @override
  bool get formDraftCanReplaySubmission => _sent != null;
  @override
  Iterable<Listenable> get formDraftListenables => [
    ..._text.values,
    for (final row in _grid.rows) ...[row.label, row.amount],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'kind': _kind,
    'id': _id,
    'version': _version,
    'text': {for (final e in _text.entries) e.key: e.value.text},
    'source': _source,
    'travel': _travel,
    'supplier': _supplier,
    'nature': _nature,
    'currency': _currency,
    'lines': [for (final r in _grid.rows) r.capture()],
    'sent': _sent,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['kind'] != _kind) throw const FormatException('申请类型已变化，原草稿保持原类型');
    _id = data['id'].toString();
    _version = (data['version'] as num?)?.toInt() ?? -1;
    for (final e in financeApplicationMap(data['text']).entries) {
      _c(e.key).text = e.value?.toString() ?? '';
    }
    _source = financeApplicationMap(data['source']);
    _travel = financeApplicationMap(data['travel']);
    _supplier = financeApplicationMap(data['supplier']);
    _nature = data['nature']?.toString() ?? _nature;
    _currency = data['currency']?.toString();
    _grid.replaceAll(
      financeApplicationRows(
        data['lines'],
      ).map((r) => _RequestRow(r, markFormDraftChanged)),
    );
    _sent = data['sent'] is Map ? financeApplicationMap(data['sent']) : null;
  }

  @override
  void initState() {
    super.initState();
    for (final key in [
      'title',
      'remark',
      'requestedDate',
      'destination',
      'travelStart',
      'travelEnd',
      'travelPurpose',
    ]) {
      _c(key);
    }
    final today = ChinaDateTime.today().toIso8601String().substring(0, 10);
    for (final key in ['requestedDate', 'travelStart', 'travelEnd']) {
      _c(key).text = today;
    }
    if (_kind == 'PREPAYMENT_APPLICATION') _nature = 'SUPPLIER_PREPAYMENT';
    if (_payment) _grid.addRow(_RequestRow({}, markFormDraftChanged));
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final scope = await captureFormDraftRequestScope();
      final api = ref.read(apiClientProvider);
      final result = await scope.run(
        () => Future.wait([
          api.get('$financeApplicationsApi/catalog'),
          api.get('$financeApplicationsApi/references'),
          if (widget.applicationId != null)
            api.get('$financeApplicationsApi/${widget.applicationId}'),
        ]),
      );
      if (!mounted || !scope.isCurrent) return;
      _catalog = result[0];
      _references = result[1];
      if (!financeApplicationRows(
        _catalog['types'],
      ).any((r) => r['key'] == _kind)) {
        throw const FormatException('原申请类型不存在');
      }
      _currency = financeApplicationRows(
        _references['currencies'],
      ).where((r) => r['baseCurrency'] == true).firstOrNull?['id']?.toString();
      if (widget.applicationId != null) {
        final app = result[2];
        if (app['kind'] != _kind ||
            !{'DRAFT', 'REJECTED', 'REVERSED'}.contains(app['status'])) {
          throw const FormatException('原申请类型或可编辑状态已变化，请返回原申请核对');
        }
        final payload = financeApplicationMap(app['requested_payload']);
        _id = app['id'].toString();
        _version = (app['row_version'] as num).toInt();
        for (final k in _text.keys) {
          _c(k).text =
              (switch (k) {
                'title' => app['title'],
                'remark' => app['remark'],
                'requestedDate' => app['requested_date'],
                _ => payload[k],
              })?.toString() ??
              '';
        }
        _currency = payload['currencyId']?.toString() ?? _currency;
        _nature = payload['paymentNature']?.toString() ?? _nature;
        _supplier = financeApplicationMap(app['supplierReference']);
        _travel = financeApplicationMap(app['travelReference']);
        final source = financeApplicationMap(app['currentDraftSource']);
        _source = {
          'id': app['source_id'],
          'code': source['claim_no'] ?? source['period'] ?? '已关联原始来源',
          'name': source['title'] ?? app['title'],
        };
        _grid.replaceAll(
          financeApplicationRows(payload['lines']).map(
            (r) => _RequestRow({
              ...r,
              'source': r['appliedLedgerId'] == null
                  ? null
                  : {'id': r['appliedLedgerId'], 'code': r['label']},
            }, markFormDraftChanged),
          ),
        );
      }
      setState(() => _loading = false);
      await initializeFormDraft();
    } catch (e) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() {
          _error = humanErrorMessage(e) ?? '原申请资料未读取完成';
          _loading = false;
        });
      }
    }
  }

  Future<void> _pick(String key, String kind, {_RequestRow? row}) async {
    if (_saving || _sent != null) return;
    final result = await pickFinanceApplicationSource(
      context,
      kind: kind,
      supplierId: _supplier['id']?.toString(),
      currencyId: _currency,
    );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        result == null ||
        _sent != null) {
      return;
    }
    setState(() {
      if (row != null) {
        if (!_grid.rows.contains(row)) return;
        row.source = Map.from(result);
        row.amount.text = result['amount']?.toString() ?? row.amount.text;
        row.label.text = result['code']?.toString() ?? '';
      } else if (key == 'travel') {
        _travel = result;
      } else if (key == 'supplier') {
        _supplier = result;
        for (final r in _grid.rows) {
          r.source = {};
        }
      } else {
        _source = result;
      }
    });
    markFormDraftChanged();
  }

  Map<String, dynamic> _payload() => {
    'requestId': const Uuid().v4(),
    'id': _id,
    'expectedVersion': _version,
    'kind': _kind,
    'title': _c('title').text,
    'remark': _c('remark').text,
    'requestedDate': _c('requestedDate').text.trim(),
    'sourceId': _source['id'],
    'travelApplicationId': _travel['id'],
    'paymentNature': _nature,
    'supplierId': _supplier['id'],
    'currencyId': _currency,
    'lines': [
      for (final r in _grid.rows)
        {
          'id': r.id,
          'label': r.label.text,
          'amountOriginal': r.amount.text.trim(),
          'appliedLedgerId': _nature == 'SUPPLIER_AP' ? r.source['id'] : null,
        },
    ],
    'destination': _c('destination').text,
    'travelStart': _c('travelStart').text.trim(),
    'travelEnd': _c('travelEnd').text.trim(),
    'travelPurpose': _c('travelPurpose').text,
  };
  Future<void> _reviewOriginal() async {
    if (_saving || !formDraftIdentityIsCurrent) return;
    final original = _sent ?? _payload();
    await context.push(
      '/finance/applications/$_id/continue?kind=$_kind',
      extra: {'originalCommand': jsonEncode(original)},
    );
  }

  Future<void> _save() async {
    if (_saving || !formDraftIdentityIsCurrent) return;
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    setState(() => _saving = true);
    try {
      _sent ??= _payload();
      final result = await runFormDraftSubmission(
        () => scope.run(
          () => ref
              .read(apiClientProvider)
              .post(financeApplicationsApi, body: _sent),
        ),
      );
      if (!mounted || !scope.isCurrent) return;
      await completeFormDraft();
      if (mounted) context.go('/finance/applications/${result['id']}');
    } catch (e) {
      if (mounted && scope.isCurrent) {
        if (e is ApiException &&
            e.hasResponseCode &&
            (e.httpStatus ?? 0) >= 400 &&
            (e.httpStatus ?? 0) < 500 &&
            e.httpStatus != 408) {
          setState(() => _sent = null);
        }
        context.appApiError(e, fallback: '结果待确认，原申请和请求编号已保留，请重试原请求');
      }
    } finally {
      if (mounted && scope.isCurrent) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    _grid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editable = !_saving && _sent == null && formDraftIdentityIsCurrent;
    final currencies = financeApplicationRows(_references['currencies']);
    final selectedCurrency = currencies
        .where((row) => row['id']?.toString() == _currency)
        .firstOrNull;
    final currencyLabel = financeCurrencyDisplayLabel(
      name: selectedCurrency?['name']?.toString(),
      code: selectedCurrency?['code']?.toString(),
    );
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: _label,
          info: [
            if (_kind == 'PAYROLL_PAYMENT' && _catalog['enabled'] != true)
              '流程尚未启用，可先保留草稿；提交前由财务明确岗位人员并启用。',
            if (_expense || _kind == 'PAYROLL_PAYMENT')
              '金额沿原始来源读取；原报销票据和工资项目保留在原单中。',
            if (_payment) '合计以服务端保存后的原申请为准',
          ].join('\n'),
          showBackButton: true,
          actions: [
            if (_kind != 'PAYROLL_PAYMENT' &&
                (widget.applicationId != null || _sent != null))
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _saving || _loading ? null : _reviewOriginal,
                child: const Text('审阅后按当前流程继续'),
              ),
            UtenButton(
              onPressed: _saving || _loading
                  ? null
                  : (widget.applicationId == null &&
                            _kind != 'PAYROLL_PAYMENT' &&
                            _sent == null
                        ? _reviewOriginal
                        : _save),
              child: Text(
                _sent != null
                    ? '重试原请求'
                    : widget.applicationId == null && _kind != 'PAYROLL_PAYMENT'
                    ? '审阅后按当前流程继续'
                    : '保存申请草稿',
              ),
            ),
          ],
        ),
        body: UtenContentContainer(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    if (_error != null) Text(_error!),

                    UtenInput(
                      label: '申请事由',
                      controller: _c('title'),
                      enabled: editable,
                      required: true,
                    ),
                    const SizedBox(height: 12),
                    UtenInput(
                      label: '申请日期',
                      info: '按中国业务日期填写 YYYY-MM-DD',
                      controller: _c('requestedDate'),
                      enabled: editable,
                      required: true,
                    ),
                    const SizedBox(height: 12),
                    if (_kind == 'TRAVEL_APPLICATION') ...[
                      for (final entry in const {
                        'destination': '出差地点',
                        'travelStart': '出差开始日期',
                        'travelEnd': '出差结束日期',
                        'travelPurpose': '出差事由',
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: UtenInput(
                            label: entry.value,
                            controller: _c(entry.key),
                            enabled: editable,
                            required: true,
                          ),
                        ),
                    ],
                    if (_kind == 'TRAVEL_REIMBURSEMENT')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: UtenButton(
                          type: _travel.isEmpty
                              ? UtenButtonType.secondary
                              : UtenButtonType.tonal,
                          onPressed: editable
                              ? () => _pick('travel', 'TRAVEL_APPLICATION')
                              : null,
                          child: Text(
                            _travel.isEmpty
                                ? '选择已批准并由财务保管的出差申请'
                                : '出差申请：${_travel['code']} ${_travel['name']}',
                          ),
                        ),
                      ),
                    if (_expense || _kind == 'PAYROLL_PAYMENT') ...[
                      UtenButton(
                        type: _source.isEmpty
                            ? UtenButtonType.secondary
                            : UtenButtonType.tonal,
                        onPressed: editable
                            ? () => _pick(
                                'source',
                                _expense ? 'EXPENSE_CLAIM' : 'PAYROLL_BATCH',
                              )
                            : null,
                        child: Text(
                          _source.isEmpty
                              ? (_expense ? '选择原报销草稿/退回单' : '选择已审核原工资批次')
                              : '${_source['code']} ${_source['name']}',
                        ),
                      ),
                      if (_expense)
                        UtenButton(
                          type: UtenButtonType.secondary,
                          onPressed: editable
                              ? () => context.push(
                                  Uri(
                                    path: '/expense/new',
                                    queryParameters: {
                                      'applicationKind': _kind,
                                      'travelApplicationId': ?_travel['id']
                                          ?.toString(),
                                    },
                                  ).toString(),
                                )
                              : null,
                          child: const Text('填写原报销单及发票凭证'),
                        ),
                      const SizedBox(height: 12),
                    ],
                    if (_payment) ...[
                      if (_kind != 'PREPAYMENT_APPLICATION')
                        UtenDropdownField(
                          label: '付款来源',
                          value: _nature,
                          items: const [
                            UtenDropdownItem(
                              value: 'GENERAL_EXPENSE',
                              label: '一般费用',
                            ),
                            UtenDropdownItem(
                              value: 'SUPPLIER_AP',
                              label: '供应商应付付款',
                            ),
                          ],
                          onChanged: editable
                              ? (v) {
                                  if (v != null) {
                                    setState(() {
                                      _nature = v;
                                      for (final r in _grid.rows) {
                                        r.source = {};
                                      }
                                      markFormDraftChanged();
                                    });
                                  }
                                }
                              : (_) {},
                          enabled: editable,
                          allowClear: false,
                        ),
                      const SizedBox(height: 12),
                      UtenDropdownField(
                        label: '原币',
                        value: _currency,
                        items: [
                          for (final r in currencies)
                            UtenDropdownItem(
                              value: r['id'].toString(),
                              label: '${r['code']} ${r['name']}',
                            ),
                        ],
                        onChanged: editable
                            ? (v) => setState(() {
                                _currency = v;
                                for (final r in _grid.rows) {
                                  r.source = {};
                                }
                                markFormDraftChanged();
                              })
                            : (_) {},
                        enabled: editable,
                      ),
                      const SizedBox(height: 12),
                      if (_nature.startsWith('SUPPLIER'))
                        UtenButton(
                          type: _supplier.isEmpty
                              ? UtenButtonType.secondary
                              : UtenButtonType.tonal,
                          onPressed: editable
                              ? () => _pick('supplier', 'SUPPLIER')
                              : null,
                          child: Text(
                            _supplier.isEmpty
                                ? '选择供应商'
                                : '供应商：${_supplier['code']} ${_supplier['name']}',
                          ),
                        ),
                      IgnorePointer(
                        ignoring: !editable,
                        child: UtenEditableGrid<_RequestRow>(
                          controller: _grid,
                          defaultColumnOrderAnchors: const {
                            'currency': 'amount',
                          },
                          createBlankRow: () =>
                              _RequestRow({}, markFormDraftChanged),
                          showAddRow: editable,
                          showRowDelete: editable,
                          columns: [
                            if (_nature == 'SUPPLIER_AP')
                              EditableGridColumn(
                                key: 'source',
                                label: '原应付单号',
                                width: 210,
                                textOf: (r) =>
                                    r.source['code']?.toString() ?? '',
                                cellBuilder: (_, r) => UtenButton(
                                  type: r.source.isEmpty
                                      ? UtenButtonType.secondary
                                      : UtenButtonType.tonal,
                                  onPressed: editable
                                      ? () => _pick(
                                          'source',
                                          'SUPPLIER_AP',
                                          row: r,
                                        )
                                      : null,
                                  child: Text(
                                    r.source['code']?.toString() ?? '选择原应付项',
                                  ),
                                ),
                              ),
                            EditableGridColumn(
                              key: 'label',
                              label: '款项说明',
                              width: 280,
                              textOf: (r) => r.label.text,
                              listenableOf: (r) => r.label,
                              cellBuilder: (_, r) => UtenInput(
                                controller: r.label,
                                enabled: editable,
                              ),
                            ),
                            EditableGridColumn(
                              key: 'amount',
                              label: '申请原币金额',
                              width: 190,
                              textOf: (r) => r.amount.text,
                              listenableOf: (r) => r.amount,
                              exactValueOf: (r) => r.amount.text,
                              exactListenableOf: (r) => r.amount,
                              cellBuilder: (_, r) => UtenInput(
                                controller: r.amount,
                                enabled: editable,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                              ),
                            ),
                            EditableGridColumn(
                              key: 'currency',
                              label: '币种',
                              width: 80,
                              textOf: (_) => currencyLabel ?? '',
                              cellBuilder: (_, _) => Text(currencyLabel ?? '—'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    UtenInput(
                      label: '备注',
                      controller: _c('remark'),
                      maxLines: 3,
                      enabled: editable,
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
        ),
      ),
    ).withSelectedValueHighlights();
  }
}

class _RequestRow extends EditableGridRow {
  _RequestRow(Map<String, dynamic> raw, this.changed)
    : id = raw['id']?.toString() ?? const Uuid().v4(),
      label = TextEditingController(text: raw['label']?.toString() ?? ''),
      amount = TextEditingController(
        text: raw['amountOriginal']?.toString() ?? '',
      ),
      source = financeApplicationMap(raw['source']) {
    label.addListener(changed);
    amount.addListener(changed);
  }
  final String id;
  final TextEditingController label, amount;
  Map<String, dynamic> source;
  final VoidCallback changed;
  Map<String, dynamic> capture() => {
    'id': id,
    'label': label.text,
    'amountOriginal': amount.text,
    'source': source,
  };
  @override
  void dispose() {
    label.removeListener(changed);
    amount.removeListener(changed);
    label.dispose();
    amount.dispose();
    super.dispose();
  }
}

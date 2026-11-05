import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_auxiliary_dialog.dart';
import 'finance_source_table.dart';

const _path = '/finance/native-posting-accounts';

/// Mount on an existing original AR/AP row; identity is the real ledger UUID, never its caption.
Future<void> showFinanceNativeDebtCorrespondenceDialog(
  BuildContext context, {
  required String ledgerId,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _Correspondence(ledgerId: ledgerId),
);

class _Correspondence extends ConsumerStatefulWidget {
  const _Correspondence({required this.ledgerId});
  final String ledgerId;
  @override
  ConsumerState<_Correspondence> createState() => _CorrespondenceState();
}

class _CorrespondenceState extends ConsumerState<_Correspondence> {
  late final ApiClient _api;
  late final int _epoch;
  final _reference = TextEditingController();
  Map<String, dynamic> _source = {};
  List<Map<String, dynamic>> _accounts = [];
  String? _entry, _code, _error, _pendingApprove;
  Map<String, dynamic>? _auxiliary, _pending;
  bool _busy = false, _unknown = false, _dirty = false;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _editable =>
      _current && !_busy && !_unknown && _pendingApprove == null;
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load();
  }

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _api.get('$_path/debts/${widget.ledgerId}');
      final rows = await _api.getList(
        '$_path/accounts',
        query: {
          'role': result['partyRole'] == 'CUSTOMER'
              ? 'AR_CONTROL'
              : 'AP_CONTROL',
        },
      );
      if (_current) {
        setState(() {
          _source = result;
          _accounts = rows;
          if (_reviews.any(
            (r) => r['id'] == _pendingApprove && r['status'] == 'APPROVED',
          )) {
            _pendingApprove = null;
          }
        });
      }
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> get _entries => _maps(_source['entries']);
  List<Map<String, dynamic>> get _reviews => _maps(_source['reviews']);
  List<Map<String, dynamic>> get _eligible {
    final selected = _entries.where((r) => r['entryId'] == _entry).firstOrNull;
    return selected == null
        ? []
        : _accounts.where((r) => r['style_id'] == selected['styleId']).toList();
  }

  Future<void> _pick() async {
    if (!_editable || _code == null) return;
    final item = await showFinanceAuxiliaryPicker(
      context,
      accountCode: _code,
      role: _source['partyRole']?.toString(),
    );
    if (!_current || item == null) return;
    if (item['partyId'] != _source['partyId']) {
      setState(() => _error = '该辅助项目未对应原单的真实往来对象，请先维护正确关系。');
      return;
    }
    setState(() {
      _auxiliary = item;
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (!_current || _busy || _pendingApprove != null) return;
    if (!_unknown && !_dirty && _reviews.isNotEmpty) return;
    if (!_unknown) {
      if (_entry == null ||
          _code == null ||
          _auxiliary == null ||
          _reference.text.trim().isEmpty) {
        setState(() => _error = '请选择原分录、财务科目和实际辅助对象，填写核对依据。');
        return;
      }
      _pending = {
        'requestId': const Uuid().v4(),
        'ledgerId': widget.ledgerId,
        'entryId': _entry,
        'accountCode': _code,
        'auxiliaryId': _auxiliary!['id'],
        'sourceReference': _reference.text.trim(),
      };
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.post('$_path/debt-reviews', body: _pending);
      if (_current) {
        setState(() {
          _unknown = false;
          _dirty = false;
        });
      }
    } catch (e) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(e);
          _error = '${_message(e)}${_unknown ? '；原请求已保留，请核对并重试原提交。' : ''}';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (_current && !_unknown) await _load();
  }

  Future<void> _approve(Map<String, dynamic> row) async {
    if (!_current || _busy || _unknown) return;
    final id = '${row['id']}';
    if (_pendingApprove != null && _pendingApprove != id) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
        title: const Text('审核原往来补对应'),
        content: Text(
          '原单：${_source['sourceDocNo']}\n依据：${row['source_reference']}\n本次只补充原分录科目及辅助证据，不新增或修改金额。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          UtenButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('审核'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_current) return;
    setState(() {
      _busy = true;
      _pendingApprove = id;
      _error = null;
    });
    try {
      await _api.post('$_path/debt-reviews/$id/approve');
      if (_current) setState(() => _pendingApprove = null);
    } catch (e) {
      if (_current) {
        setState(() {
          if (_rejected(e)) _pendingApprove = null;
          _error =
              '${_message(e)}${_pendingApprove == null ? '' : '；请刷新核对或重试同一审核。'}';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (_current && _pendingApprove == null) await _load();
  }

  Future<void> _close() async {
    if (!_editable) return;
    if (_dirty) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => UtenAlertDialog(
          title: const Text('放弃未保存的核对？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续填写'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (yes != true) return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),

        title: const Text('访问范围已变化'),
        content: const Text('请重新打开原往来核对提交结果。'),
      );
    }
    final approved = _reviews.any((r) => r['status'] == 'APPROVED');
    return PopScope(
      canPop: false,
      child: UtenDialogFrame(
        maxWidth: 760,
        fillHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              title: const Text('核对原科目与辅助'),
              showCloseButton: true,
              onClose: _editable ? _close : null,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    Text('原单：${_source['sourceDocNo'] ?? ''}'),
                    Text(
                      '原币：${(_source['originalCurrency'] as Map?)?['code'] ?? ''} ${(_source['originalCurrency'] as Map?)?['name'] ?? ''}',
                    ),
                    Text(
                      '原币金额：${_source['amountOriginalText'] ?? '待核'}；账面本币：${_source['amountLocalText'] ?? '待核'}',
                    ),
                    if (approved) const Text('原科目及辅助已独立审核。原真实分录及金额保留，不能在这里改写。'),
                    if (!approved) ...[
                      UtenDropdownField(
                        label: '原已记账分录',
                        value: _entry,
                        enabled: _editable,
                        items: [
                          for (final e in _entries)
                            UtenDropdownItem(
                              value: '${e['entryId']}',
                              label: '${e['voucherNo']} ${e['styleName']}',
                            ),
                        ],
                        onChanged: (v) => setState(() {
                          _entry = v;
                          _code = null;
                          _auxiliary = null;
                          _dirty = true;
                        }),
                      ),
                      UtenDropdownField(
                        label: '对应财务科目',
                        value: _code,
                        enabled: _editable && _entry != null,
                        items: [
                          for (final a in _eligible)
                            UtenDropdownItem(
                              value: '${a['code']}',
                              label: '${a['code']} ${a['name']}',
                            ),
                        ],
                        onChanged: (v) => setState(() {
                          _code = v;
                          _auxiliary = null;
                          _dirty = true;
                        }),
                      ),
                      UtenButton(
                        onPressed: _editable && _code != null ? _pick : null,
                        child: Text(
                          _auxiliary == null
                              ? '选择原单的实际辅助对象'
                              : '${_auxiliary!['sourceCode']} ${_auxiliary!['sourceName']}',
                        ),
                      ),
                      UtenInput(
                        label: '原分录及辅助核对依据',
                        controller: _reference,
                        enabled: _editable,
                        maxLines: 3,
                        onChanged: (_) => _dirty = true,
                      ),
                      const Text(
                        '只选原分录的真实科目 UUID 与原单实际往来对象，不按当前会计用途、名称或金额相似程度关联。需要另一名财务审核人审核，不再生成债务或资金。',
                      ),
                    ],
                    if (_reviews.isNotEmpty)
                      SizedBox(
                        height: 240,
                        child: financeSourceTable(
                          tableKey:
                              'finance.native-debt-correspondence.history',
                          columns: [
                            financeSourceColumn(
                              'status',
                              '状态',
                              value: (r) =>
                                  r['status'] == 'APPROVED' ? '已审核' : '待审核',
                            ),
                            financeSourceColumn(
                              'source_reference',
                              '原分录及辅助核对依据',
                              width: 400,
                            ),
                          ],
                          rows: _reviews,
                          idOf: (r) => '${r['id']}',
                          onOpen: approved || _busy || _unknown
                              ? null
                              : (r) {
                                  if (r['status'] == 'DRAFT') {
                                    _approve(r);
                                  }
                                },
                          scope: (_epoch, widget.ledgerId),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            UtenDialogActions(
              children: [
                UtenButton(
                  onPressed: _busy || _unknown ? null : _load,
                  child: const Text('刷新核对'),
                ),

                if (!approved)
                  UtenButton(
                    onPressed:
                        _busy ||
                            _pendingApprove != null ||
                            (!_dirty && !_unknown && _reviews.isNotEmpty)
                        ? null
                        : _save,
                    isLoading: _busy,
                    child: Text(_unknown ? '核对并重试原提交' : '保存待审核核对'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

List<Map<String, dynamic>> _maps(dynamic rows) => [
  for (final r in rows as List? ?? [])
    if (r is Map<String, dynamic>) r,
];
String _message(Object e) => e is ApiException ? e.message : '操作未完成，请核对网络后重试';
bool _rejected(Object e) =>
    e is ApiException &&
    e.hasResponseCode &&
    (e.httpStatus ?? 0) >= 400 &&
    (e.httpStatus ?? 0) < 500 &&
    e.httpStatus != 408;

import '../shared/finance_workbench_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/paging/read_view_activity.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_auxiliary_dialog.dart';
import 'finance_source_table.dart';

const _path = '/finance/native-posting-accounts';

Future<void> showFinanceNativePostingAccountsDialog(BuildContext context) =>
    showFinanceWorkbenchPanel<void>(
      context: context,
      builder: (_) => const _Directory(),
    );

class _Directory extends ConsumerStatefulWidget {
  const _Directory();
  @override
  ConsumerState<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends ConsumerState<_Directory>
    with ScopedPagedReadViewMixin<_Directory> {
  @override
  Future<void> onReadViewResumed() => _load();
  late final ApiClient _api;
  late final int _epoch;
  List<Map<String, dynamic>> _rows = [];
  int _generation = 0;
  bool _busy = false;
  String? _error, _pendingApproval;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _write =>
      ref.read(currentPermissionsProvider).contains('payment_style:edit');
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load();
  }

  Future<PagedResult<Map<String, dynamic>>> _fetchPage(int page, int size) async =>
      PagedResult.fromJsonResponsive<Map<String, dynamic>>(
        await _api.get(_path, query: {'page': page, 'size': size}),
        (row) => row,
      );

  Future<void> _load() async {
    if (!_current || _busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await readScopedPage<Map<String, dynamic>>(
        1,
        slot: 'native-posting-accounts',
        idOf: (row) => row['id'],
        query: const [_path],
        currentQuery: () => const [_path],
        isCurrent: () => _current && generation == _generation,
        fetchPage: (page) async => _fetchPage(page, 100),
        fetchPageSized: _fetchPage,
      );
      if (!_current || generation != _generation) return;
      setState(() {
        _rows = result.items;
        if (_rows.any(
          (r) => r['id'] == _pendingApproval && r['status'] == 'APPROVED',
        )) {
          _pendingApproval = null;
        }
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _generation) {
        setState(() {
          if (pagedReadAccessDenied(e)) _rows = [];
          _error = _message(e);
        });
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (!_current || _busy || _pendingApproval != null) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _Editor(epoch: _epoch),
    );
    if (_current && saved == true) await _load();
  }

  Future<void> _approve(Map<String, dynamic> row) async {
    if (!_current ||
        _busy ||
        row['status'] != 'DRAFT' ||
        !_write ||
        !ref
            .read(currentPermissionsProvider)
            .contains('finance_post:execute')) {
      return;
    }
    final id = row['id']?.toString();
    if (id == null) return;
    if (_pendingApproval != null && _pendingApproval != id) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
        title: const Text('审核业务单据科目对应'),
        content: Text(
          '用途：${row['role_key']}\n财务科目：${row['account_code']}\n生效日期：${row['effective_from']}\n依据：${row['source_reference']}\n\n审核后用于新业务，已发生债务保留原对应。',
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
    if (ok != true || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
      _pendingApproval = id;
    });
    try {
      await _api.post('$_path/$id/approve');
      if (_current) setState(() => _pendingApproval = null);
    } catch (e) {
      if (_current) {
        setState(() {
          if (_rejected(e)) _pendingApproval = null;
          _error =
              '${_message(e)}${_pendingApproval == null ? '' : '；保留本次审核，可刷新核对或重试同一记录。'}';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (_current && _pendingApproval == null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final changed = ref.watch(exportContextEpochProvider) != _epoch;
    return PopScope(
      canPop: !_busy && _pendingApproval == null,
      child: UtenDialogFrame(
        maxWidth: 1100,
        fillHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              title: const Text('业务单据科目对应'),
              showCloseButton: true,
              onClose: _busy || _pendingApproval != null
                  ? null
                  : () => Navigator.pop(context),
            ),
            if (changed)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('访问范围已变化，请关闭后重新打开。'),
              ),
            Expanded(
              child: financeSourceTable(
                tableKey: 'finance.native-posting-accounts',
                columns: [
                  financeSourceColumn('role_key', '会计用途', width: 220),
                  financeSourceColumn('account_code', '财务科目代码'),
                  financeSourceColumn('effective_from', '生效日期', type: 'date'),
                  financeSourceColumn('configuration_version', '对应版本'),
                  financeSourceColumn(
                    'status',
                    '状态',
                    value: (r) => r['status'] == 'APPROVED' ? '已审核' : '待审核',
                  ),
                  financeSourceColumn(
                    'enabled',
                    '使用对应',
                    value: (r) => r['enabled'] == true ? '是' : '恢复原用途',
                  ),
                  financeSourceColumn('source_reference', '依据', width: 300),
                ],
                rows: changed ? [] : _rows,
                idOf: (r) => '${r['id']}',
                busy: _busy,
                error: _error,
                retry: _load,
                onOpen: changed ? null : _approve,
                scope: _epoch,
                actions: [
                  if (_write)
                    UtenButton(
                      onPressed: _busy || changed || _pendingApproval != null
                          ? null
                          : _create,
                      child: const Text('新增对应版本'),
                    ),
                  UtenButton(
                    onPressed: _busy || changed ? null : _load,
                    child: const Text('刷新'),
                  ),
                ],
              ),
            ),
            if (_busy)
              const UtenBusyOverlay(
                title: '正在读取业务科目对应',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    );
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({required this.epoch});
  final int epoch;
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final ApiClient _api;
  final _reference = TextEditingController();
  List<Map<String, dynamic>> _roles = [], _currencies = [], _accounts = [];
  String? _role, _currency, _accountCode, _error;
  Map<String, dynamic>? _auxiliary, _pending;
  DateTime _date = ChinaDateTime.today();
  bool _busy = false, _unknown = false, _dirty = false, _enabled = true;
  int _accountGeneration = 0;
  bool get _current =>
      mounted &&
      widget.epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _editable => _current && !_busy && !_unknown;
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _choices();
  }

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  Future<void> _choices() async {
    setState(() => _busy = true);
    try {
      final r = await _api.get('$_path/choices');
      if (_current) {
        setState(() {
          _roles = _maps(r['roles']);
          _currencies = _maps(r['currencies']);
        });
      }
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _accountChoices(String role) async {
    final generation = ++_accountGeneration;
    setState(() {
      _role = role;
      _accountCode = null;
      _auxiliary = null;
      _accounts = [];
      _dirty = true;
      _busy = true;
    });
    try {
      final rows = await _api.getList('$_path/accounts', query: {'role': role});
      if (_current && generation == _accountGeneration) {
        setState(() => _accounts = rows);
      }
    } catch (e) {
      if (_current && generation == _accountGeneration) {
        setState(() => _error = _message(e));
      }
    } finally {
      if (_current && generation == _accountGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _pickAuxiliary() async {
    if (!_editable || _accountCode == null) return;
    final r = await showFinanceAuxiliaryPicker(
      context,
      accountCode: _accountCode,
    );
    if (!_current || r == null) return;
    if (r['partyId'] == null) {
      setState(() => _error = '该辅助项目尚未对应真实业务对象，请先维护辅助核算目录。');
      return;
    }
    setState(() {
      _auxiliary = r;
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (!_current || _busy) return;
    if (!_unknown) {
      final matches = _accounts
          .where((r) => r['code'] == _accountCode)
          .toList();
      if (_role == null ||
          matches.length != 1 ||
          matches.single['accounting_currency_id'] == null ||
          _reference.text.trim().isEmpty) {
        setState(() => _error = '请选择用途及已核验币别的财务科目，并填写依据。');
        return;
      }
      final account = matches.single;
      _pending = {
        'requestId': const Uuid().v4(),
        'role': _role,
        'originalCurrencyId': _currency,
        'effectiveFrom': _date.toIso8601String().substring(0, 10),
        'enabled': _enabled,
        'styleId': account['style_id'],
        'accountCode': _accountCode,
        'accountingCurrencyId': account['accounting_currency_id'],
        'sourceReference': _reference.text.trim(),
        if (_auxiliary != null)
          'party': {'role': _auxiliary!['role'], 'id': _auxiliary!['partyId']},
        if (_auxiliary != null) 'auxiliaryId': _auxiliary!['id'],
      };
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.post(_path, body: _pending);
      if (mounted && _current) Navigator.pop(context, true);
    } catch (e) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(e);
          _error = '${_message(e)}${_unknown ? '；原输入和提交编号已保留，请核对并重试原提交。' : ''}';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (!_editable) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => UtenAlertDialog(
          title: const Text('放弃未保存的对应？'),
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
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != widget.epoch) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),

        title: const Text('访问范围已变化'),
        content: const Text('请重新打开对应目录核对原提交。'),
      );
    }
    final editable = _editable;
    return PopScope(
      canPop: false,
      child: UtenDialogFrame(
        maxWidth: 720,
        fillHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              title: const UtenDialogTitleWithHint(
                title: Text('新增业务单据科目对应'),
                info: '保存为待审核版本，由另一名具备权限的财务审核。已发生债务和已记账分录保留原对应，付款、收款按原债务科目清偿。',
              ),
              showCloseButton: true,
              onClose: editable ? _close : null,
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
                    UtenDropdownField(
                      label: '会计用途',
                      value: _role,
                      enabled: editable,
                      items: [
                        for (final r in _roles)
                          UtenDropdownItem(
                            value: r['id']?.toString() ?? '',
                            label: '${r['name']} (${r['id']})',
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) _accountChoices(v);
                      },
                    ),
                    UtenDropdownField(
                      label: '真实交易币别范围',
                      value: _currency ?? '',
                      enabled: editable,
                      allowClear: false,
                      items: [
                        const UtenDropdownItem(value: '', label: '该用途所有交易币别'),
                        for (final c in _currencies)
                          UtenDropdownItem(
                            value: '${c['id']}',
                            label: '${c['code']} ${c['name']}',
                          ),
                      ],
                      onChanged: (v) => setState(() {
                        _currency = v == null || v.isEmpty ? null : v;
                        _dirty = true;
                      }),
                    ),
                    UtenDropdownField(
                      label: '财务科目代码',
                      value: _accountCode,
                      enabled: editable,
                      items: [
                        for (final a in _accounts)
                          UtenDropdownItem(
                            value: '${a['code']}',
                            label: '${a['code']} ${a['name']}',
                          ),
                      ],
                      onChanged: (v) => setState(() {
                        _accountCode = v;
                        _auxiliary = null;
                        _dirty = true;
                      }),
                    ),
                    UtenDateField(
                      label: '生效日期',
                      value: _date,
                      enabled: editable,
                      onChanged: (v) => setState(() {
                        _date = v;
                        _dirty = true;
                      }),
                    ),
                    Text(
                      _auxiliary == null
                          ? '往来范围：该用途的所有往来对象，过账时按真实关系选辅助项目'
                          : '往来范围：${_auxiliary!['sourceCode']} ${_auxiliary!['sourceName']}',
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        UtenButton(
                          onPressed: editable && _accountCode != null
                              ? _pickAuxiliary
                              : null,
                          child: const Text('指定真实辅助对象'),
                        ),
                        if (_auxiliary != null)
                          UtenButton(
                            onPressed: editable
                                ? () => setState(() {
                                    _auxiliary = null;
                                    _dirty = true;
                                  })
                                : null,
                            child: const Text('适用所有往来对象'),
                          ),
                      ],
                    ),
                    UtenDropdownField(
                      label: '使用对应',
                      value: _enabled ? 'YES' : 'NO',
                      enabled: editable,
                      allowClear: false,
                      items: const [
                        UtenDropdownItem(value: 'YES', label: '使用本次对应'),
                        UtenDropdownItem(value: 'NO', label: '恢复原有全局用途'),
                      ],
                      onChanged: (v) => setState(() {
                        _enabled = v == 'YES';
                        _dirty = true;
                      }),
                    ),
                    UtenInput(
                      label: '来源及变更依据',
                      controller: _reference,
                      enabled: editable,
                      maxLines: 3,
                      onChanged: (_) => _dirty = true,
                    ),
                  ],
                ),
              ),
            ),
            UtenDialogActions(
              children: [
                TextButton(
                  onPressed: editable ? _close : null,
                  child: const Text('取消'),
                ),
                UtenButton(
                  onPressed: _busy ? null : _save,
                  isLoading: _busy,
                  child: Text(_unknown ? '核对并重试原提交' : '保存待审核版本'),
                ),
              ],
            ),
            if (_busy)
              const UtenBusyOverlay(
                title: '正在核对业务科目对应',
                showDoNotLeaveHint: false,
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

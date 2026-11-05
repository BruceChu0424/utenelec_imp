import '../shared/finance_workbench_panel.dart';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_segment_row.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_action_overflow.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/financial_amount_validation.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/finance_requirement_names.dart';
import 'finance_auxiliary_dialog.dart';
import 'finance_auxiliary_import_dialog.dart';
import 'finance_chart_dialog.dart';
import 'finance_entry_file_picker.dart';

List<Map<String, dynamic>> _accountingMaps(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map) Map<String, dynamic>.from(item),
];
Map<String, dynamic> _accountingMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
String _accountingId(Map<String, dynamic>? value) =>
    (value?['importId'] ?? value?['id'] ?? '').toString();
const _accountingPurposes = {
  'OPERATING': '日常业务',
  'PNL_CLOSE': '损益结转',
  'PRIOR_YEAR_ADJUSTMENT': '以前年度调整',
  'RECLASSIFICATION': '重分类',
};
const _accountingStates = {
  'PREVIEW': '待核对',
  'SUBMITTED': '待另一人复核',
  'POSTED': '已接续',
  'REJECTED': '已退回',
  'CANCELLED': '已撤回',
};

class _AccountingAllocationRow extends EditableGridRow {
  _AccountingAllocationRow(this.identity, this.source);
  final String identity;
  final Map<String, dynamic> source;
  final changed = ValueNotifier<int>(0);
  @override
  void dispose() {
    changed.dispose();
    super.dispose();
  }
}

class _AccountingOpeningRow extends EditableGridRow {
  _AccountingOpeningRow({Map<String, dynamic>? data})
    : identity = data?['_rowId']?.toString() ?? const Uuid().v4() {
    accountCode = data?['accountCode']?.toString();
    auxiliaryId = data?['auxiliaryId']?.toString();
    currencyId = data?['currencyId']?.toString();
    originalCurrencyId = data?['originalCurrencyId']?.toString();
    auxiliaryLabel = data?['_auxiliaryLabel']?.toString();
    for (final key in [
      'openingDebit',
      'openingCredit',
      'originalNet',
      'exchangeRate',
      'sourceReference',
      'accountPathName',
    ]) {
      text[key] = TextEditingController(text: data?[key]?.toString() ?? '');
    }
  }
  final String identity;
  String? accountCode,
      auxiliaryId,
      currencyId,
      originalCurrencyId,
      auxiliaryLabel;
  final text = <String, TextEditingController>{};
  final changed = ValueNotifier<int>(0);
  Map<String, dynamic> capture() => {
    '_rowId': identity,
    '_auxiliaryLabel': auxiliaryLabel,
    'accountCode': accountCode,
    'auxiliaryId': auxiliaryId,
    'currencyId': currencyId,
    'originalCurrencyId': originalCurrencyId,
    for (final e in text.entries) e.key: e.value.text,
  };
  Map<String, dynamic> command() {
    final result = capture()
      ..remove('_rowId')
      ..remove('_auxiliaryLabel');
    for (final key in ['openingDebit', 'openingCredit']) {
      final value = text[key]!.text.trim();
      final error = validateNonNegativeFinanceBookAmount(
        value,
        label: key == 'openingDebit' ? '期初借方' : '期初贷方',
      );
      if (error != null) {
        throw StateError(error);
      }
      result[key] = value;
    }
    for (final key in ['originalNet', 'exchangeRate']) {
      final value = text[key]!.text.trim();
      final error = value.isEmpty
          ? null
          : key == 'originalNet'
          ? validateSignedFinanceAmount(value, label: '原币净额')
          : validateFinanceAmount(value, label: '原记账汇率');
      if (error != null) {
        throw StateError(error);
      }
      result[key] = value.isEmpty ? null : value;
    }
    if (text['originalNet']!.text.trim().isNotEmpty &&
        originalCurrencyId == null) {
      throw StateError('请明确本行原币净额实际使用的币别，不按名称推定');
    }
    if (accountCode == null ||
        currencyId == null ||
        auxiliaryId == null ||
        text['sourceReference']!.text.trim().isEmpty) {
      throw StateError('期初分配须明确科目、辅助项目及来源依据');
    }
    return result;
  }

  @override
  void dispose() {
    for (final c in text.values) {
      c.dispose();
    }
    changed.dispose();
    super.dispose();
  }
}

Future<bool> showFinanceAccountingImportDialog(
  BuildContext context, {
  String? initialImportId,
  String? resumeDraftId,
}) async =>
    await showFinanceWorkbenchPanel<bool>(
      context: context,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1380,
          height: MediaQuery.sizeOf(context).height * .92,
          child: FinanceAccountingImportSurface(
            initialImportId: initialImportId,
            resumeDraftId: resumeDraftId,
          ),
        ),
      ),
    ) ??
    false;

/// The original worksheets stay on the server. Local drafts contain identities,
/// explicit choices and one frozen command, never the 83-column source body.
class FinanceAccountingImportSurface extends ConsumerStatefulWidget {
  const FinanceAccountingImportSurface({
    super.key,
    this.initialImportId,
    this.resumeDraftId,
  });
  final String? initialImportId, resumeDraftId;
  @override
  ConsumerState<FinanceAccountingImportSurface> createState() =>
      _FinanceAccountingImportSurfaceState();
}

class _FinanceAccountingImportSurfaceState
    extends ConsumerState<FinanceAccountingImportSurface>
    with FormDraftMixin<FinanceAccountingImportSurface> {
  final _book = TextEditingController(),
      _reason = TextEditingController(),
      _search = TextEditingController();
  Map<String, dynamic>? _vouchers, _balances, _pending;
  String? _retainedVoucherId, _retainedBalanceId;
  int? _acceptedVoucherVersion;
  bool _needsReconfirm = false;
  List<Map<String, dynamic>> _recent = [],
      _chart = [],
      _currencies = [],
      _auxSources = [],
      _comparison = [];
  final Map<String, Map<String, dynamic>> _accounts = {};
  final Map<String, String> _purposes = {},
      _entryAux = {},
      _entryAuxLabels = {},
      _sourceCurrencyMappings = {};
  final Set<String> _sourceIds = {}, _zeroCodes = {};
  final _accountGrid = UtenEditableGridController<_AccountingAllocationRow>(),
      _purposeGrid = UtenEditableGridController<_AccountingAllocationRow>(),
      _auxiliaryGrid = UtenEditableGridController<_AccountingAllocationRow>(),
      _sourceCurrencyGrid =
          UtenEditableGridController<_AccountingAllocationRow>();
  final _openingGrid = UtenEditableGridController<_AccountingOpeningRow>();
  bool _loading = true, _busy = false, _complete = false, _append = false;
  String? _error, _auxCurrency;
  int _tab = 0;
  int _optionsRead = 0, _pairRead = 0;
  String _appliedSearch = '';
  Object? _cachedVoucherSource, _cachedBalanceSource;
  List<Map<String, dynamic>> _cachedVouchers = [],
      _cachedBalances = [],
      _cachedEntries = [],
      _cachedRawRows = [],
      _cachedMissing = [];
  bool get _canMutate =>
      ref.read(authenticatedScopeProvider)?.readOnly == false &&
      ref.read(currentPermissionsProvider).contains(Perm.financePostExecute);
  bool get _canEditDirectory =>
      _canMutate &&
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit);
  String get _state => _vouchers?['status']?.toString() ?? 'PREVIEW';
  bool get _editable =>
      _state == 'PREVIEW' &&
      _pending == null &&
      !_busy &&
      !_loading &&
      _canMutate;
  bool get _owner =>
      _vouchers?['submittedBy'] == ref.read(authenticatedScopeProvider)?.userId;
  void _cacheSources() {
    final vouchers = _vouchers?['source'], balances = _balances?['source'];
    if (identical(vouchers, _cachedVoucherSource) &&
        identical(balances, _cachedBalanceSource)) {
      return;
    }
    if (vouchers != null || balances != null) throw StateError('原表显示准备尚未完成');
    _cachedVoucherSource = null;
    _cachedBalanceSource = null;
    _cachedVouchers = [];
    _cachedBalances = [];
    _cachedEntries = [];
    _cachedRawRows = [];
    _cachedMissing = [];
  }

  Future<bool> _publishSources(
    Map<String, dynamic>? vouchers,
    Map<String, dynamic>? balances,
    bool Function() current,
  ) async {
    bool allowed() => mounted && formDraftIdentityIsCurrent && current();
    final work = UiWorkBudget(
      maxItems: 32,
      isCurrent: allowed,
      debugLabel: 'finance.accounting.original-projection',
    );
    try {
      final v = _accountingMaps(
            _accountingMap(vouchers?['source'])['vouchers'],
          ),
          b = _accountingMaps(_accountingMap(balances?['source'])['balances']);
      final entries = <Map<String, dynamic>>[],
          raw = <Map<String, dynamic>>[],
          missing = <Map<String, dynamic>>[];
      final present = b.map((row) => row['accountCode']).toSet(),
          seen = <String>{};
      for (final voucher in v) {
        for (final entry in _accountingMaps(voucher['entries'])) {
          entries.add(entry);
          final cells = _accountingMap(entry['source']);
          raw.add({
            'sourceRow': entry['sourceRow'],
            '__sourceEntryId': entry['sourceEntryId'],
            '__search': cells.values.join('\t').toLowerCase(),
            for (final cell in cells.entries) cell.key.substring(1): cell.value,
          });
          if (!present.contains(entry['accountCode']) &&
              seen.add(entry['accountCode'].toString())) {
            missing.add({
              'accountCode': entry['accountCode'],
              'accountName': entry['accountName'],
              'currencyName': entry['currencyName'],
            });
          }
          await work.checkpoint();
        }
      }
      raw.sort(
        (a, b) => (a['sourceRow'] as num).compareTo(b['sourceRow'] as num),
      );
      work.ensureCurrent();
      setState(() {
        _vouchers = vouchers;
        _balances = balances;
        _cachedVoucherSource = vouchers?['source'];
        _cachedBalanceSource = balances?['source'];
        _cachedVouchers = v;
        _cachedBalances = b;
        _cachedEntries = entries;
        _cachedRawRows = raw;
        _cachedMissing = missing;
        _syncAllocationRows();
      });
      return true;
    } on UiWorkCancelled {
      return false;
    }
  }

  List<Map<String, dynamic>> get _voucherRows {
    _cacheSources();
    return _cachedVouchers;
  }

  List<Map<String, dynamic>> get _balanceRows {
    _cacheSources();
    return _cachedBalances;
  }

  List<Map<String, dynamic>> get _entries {
    _cacheSources();
    return _cachedEntries;
  }

  Map<String, dynamic> _chartCode(String code) =>
      _chart.where((item) => item['code'] == code).firstOrNull ?? {};
  List<Map<String, dynamic>> get _missingCodes {
    _cacheSources();
    return _cachedMissing;
  }

  List<Map<String, dynamic>> get _accountRows => [
    ..._balanceRows,
    for (final row in _missingCodes)
      if (_zeroCodes.contains(row['accountCode'])) row,
  ];
  void _syncAccountRows() {
    _accountGrid.replaceAll([
      for (final row in _accountRows)
        _AccountingAllocationRow(row['accountCode'].toString(), row),
    ]);
  }

  void _syncAllocationRows() {
    final labels = <String>{};
    _sourceCurrencyGrid.replaceAll([
      for (final entry in _entries)
        if (entry['currencyName'] is String &&
            (entry['currencyName'] as String).isNotEmpty &&
            labels.add(entry['currencyName'].toString()))
          _AccountingAllocationRow(entry['currencyName'].toString(), {
            'sourceCurrencyLabel': entry['currencyName'],
            'sourceRow': entry['sourceRow'],
          }),
    ]);
    _syncAccountRows();
    _purposeGrid.replaceAll([
      for (final row in _voucherRows)
        _AccountingAllocationRow(row['key'].toString(), row),
    ]);
    _auxiliaryGrid.replaceAll([
      for (final row in _entries)
        _AccountingAllocationRow(row['sourceEntryId'].toString(), row),
    ]);
  }

  void _allocationChanged(String kind, String id) {
    final grid = kind == 'account'
        ? _accountGrid
        : kind == 'sourceCurrency'
        ? _sourceCurrencyGrid
        : kind == 'purpose'
        ? _purposeGrid
        : _auxiliaryGrid;
    final row = grid.rows.where((row) => row.identity == id).firstOrNull;
    if (row == null) return;
    row.changed.value++;
    markFormDraftChanged();
  }

  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeAccountingImport.spec();
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftCanReplaySubmission => _pending != null;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _book,
    _reason,
    _openingGrid,
    for (final row in _openingGrid.rows) ...row.text.values,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'schema': 3,
    'voucherId': _vouchers == null
        ? _retainedVoucherId ?? ''
        : _accountingId(_vouchers),
    'balanceId': _balances == null
        ? _retainedBalanceId ?? ''
        : _accountingId(_balances),
    'book': _book.text,
    'reason': _reason.text,
    'accounts': _accounts,
    'purposes': _purposes,
    'entryAuxiliaries': _entryAux,
    'entryAuxiliaryLabels': _entryAuxLabels,
    'sourceCurrencyMappings': _sourceCurrencyMappings,
    'auxiliarySourceIds': _sourceIds.toList(),
    'omittedZeroBalanceProfitCodes': _zeroCodes.toList(),
    'completeOriginalPeriod': _complete,
    'appendPeriod': _append,
    'pending': _pending,
    'voucherVersion': _vouchers?['version'] ?? _acceptedVoucherVersion,
    'openingAllocations': [for (final row in _openingGrid.rows) row.capture()],
    'tab': _tab,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (!const {1, 2, 3}.contains(data['schema'])) {
      throw StateError('原账套接续草稿格式不匹配');
    }
    final id = data['voucherId']?.toString() ?? '';
    _retainedVoucherId = id.isEmpty ? null : id;
    _retainedBalanceId = data['balanceId']?.toString();
    _acceptedVoucherVersion = (data['voucherVersion'] as num?)?.toInt();
    if (widget.initialImportId != null &&
        id.isNotEmpty &&
        id != widget.initialImportId) {
      throw StateError('草稿与本次原账套批次不一致');
    }
    _book.text = data['book']?.toString() ?? '';
    _reason.text = data['reason']?.toString() ?? '';
    _accounts
      ..clear()
      ..addAll({
        for (final e in _accountingMap(data['accounts']).entries)
          e.key: _accountingMap(e.value),
      });
    void restoreStrings(Map<String, String> target, Object? value) {
      target
        ..clear()
        ..addAll({
          for (final e in _accountingMap(value).entries)
            e.key: e.value.toString(),
        });
    }

    restoreStrings(_purposes, data['purposes']);
    restoreStrings(_entryAux, data['entryAuxiliaries']);
    restoreStrings(_entryAuxLabels, data['entryAuxiliaryLabels']);
    restoreStrings(_sourceCurrencyMappings, data['sourceCurrencyMappings']);
    _sourceIds
      ..clear()
      ..addAll(
        (data['auxiliarySourceIds'] as List? ?? const []).map(
          (v) => v.toString(),
        ),
      );
    _zeroCodes
      ..clear()
      ..addAll(
        (data['omittedZeroBalanceProfitCodes'] as List? ?? const []).map(
          (v) => v.toString(),
        ),
      );
    _complete = data['completeOriginalPeriod'] == true;
    _openingGrid.replaceAll([
      for (final row in _accountingMaps(data['openingAllocations']))
        _AccountingOpeningRow(data: row),
    ]);
    _append = data['appendPeriod'] == true;
    _pending = data['pending'] is Map ? _accountingMap(data['pending']) : null;
    if (_pending != null &&
        (_pending!['importId'] != id ||
            !const {
              'submit',
              'approve',
              'reject',
              'withdraw',
            }.contains(_pending!['action']))) {
      throw StateError('原提交的批次或动作身份不一致');
    }
    if (id.isNotEmpty) {
      try {
        await _readPair(
          id,
          balanceId: data['balanceId']?.toString(),
          hydrate: false,
        );
      } catch (error) {
        if (mounted && formDraftIdentityIsCurrent) {
          setState(
            () => _error =
                '原选择及请求已恢复，原件暂未读到：${humanErrorMessage(error) ?? '请核对网络后恢复原批次'}',
          );
        }
      }
    }
    _tab = ((data['tab'] as num?)?.toInt() ?? 0).clamp(0, 6);
    if (data['schema'] == 1 && _tab == 4) _tab = 5;
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _book.dispose();
    _reason.dispose();
    _search.dispose();
    _accountGrid.dispose();
    _purposeGrid.dispose();
    _auxiliaryGrid.dispose();
    _sourceCurrencyGrid.dispose();
    _openingGrid.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _loadOptions();
      if (widget.initialImportId != null) {
        await _readPair(widget.initialImportId!);
      }
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() {
          _loading = false;
          _error = humanErrorMessage(error) ?? '原账套资料加载失败';
        });
      }
    } finally {
      if (mounted && formDraftIdentityIsCurrent) {
        await initializeFormDraft();
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadOptions() async {
    final generation = ++_optionsRead;
    final scope = await captureFormDraftRequestScope(),
        api = ref.read(apiClientProvider);
    final values = await scope.run(
      () => Future.wait([
        api.get('/finance/accounting-imports'),
        api.get('/finance/chart'),
        api.get('/finance/accounting-imports/options'),
        _canEditDirectory
            ? api.get('/finance/auxiliary-imports')
            : Future.value(<String, dynamic>{}),
      ]),
    );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _optionsRead) {
      return;
    }
    setState(() {
      _recent = _accountingMaps(values[0]['items']);
      _chart = _accountingMaps(values[1]['items']);
      _currencies = _accountingMaps(values[2]['currencies']);
      _auxSources = _accountingMaps(values[3]['items']);
    });
  }

  Future<void> _refresh() async {
    if (_busy || _loading) return;
    setState(() => _busy = true);
    try {
      await _loadOptions();
      if (_vouchers == null && _retainedVoucherId != null) {
        await _readPair(
          _retainedVoucherId!,
          balanceId: _retainedBalanceId,
          hydrate: false,
        );
      }
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '选项未刷新，原选择已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readPair(
    String id, {
    String? balanceId,
    bool hydrate = true,
  }) async {
    final generation = ++_pairRead;
    final scope = await captureFormDraftRequestScope(),
        api = ref.read(apiClientProvider);
    final primary = await scope.run(
      () => api.get('/finance/accounting-imports/$id'),
    );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _pairRead) {
      return;
    }
    if (primary['kind'] != 'VOUCHERS') {
      throw StateError('请从原凭证批次开始，科目余额在右侧成对选择');
    }
    final review = _accountingMap(primary['review']),
        request = _accountingMap(review['request']);
    final pairId =
        primary['status'] != 'PREVIEW' && request['balanceImportId'] != null
        ? request['balanceImportId'].toString()
        : balanceId?.isNotEmpty == true
        ? balanceId
        : request['balanceImportId']?.toString();
    final pair = pairId == null || pairId.isEmpty
        ? null
        : await scope.run(() => api.get('/finance/accounting-imports/$pairId'));
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _pairRead) {
      return;
    }
    if (!await _publishSources(
      primary,
      pair,
      () => scope.isCurrent && generation == _pairRead,
    )) {
      return;
    }
    _retainedVoucherId = _accountingId(primary);
    _retainedBalanceId = pair == null ? null : _accountingId(pair);
    _needsReconfirm =
        !hydrate &&
        _acceptedVoucherVersion != null &&
        primary['version'] != _acceptedVoucherVersion;
    if (hydrate) {
      _acceptedVoucherVersion = (primary['version'] as num?)?.toInt();
    }
    setState(() {
      _book.text = primary['sourceSystem']?.toString() ?? _book.text;
      _comparison = [];
    });
    if (hydrate && request.isNotEmpty) {
      _accounts
        ..clear()
        ..addAll({
          for (final row in _accountingMaps(request['accounts']))
            row['accountCode'].toString(): row,
        });
      _purposes
        ..clear()
        ..addAll({
          for (final e in _accountingMap(request['voucherPurposes']).entries)
            e.key: e.value.toString(),
        });
      _entryAux
        ..clear()
        ..addAll({
          for (final e in _accountingMap(request['entryAuxiliaries']).entries)
            e.key: e.value.toString(),
        });
      _sourceCurrencyMappings
        ..clear()
        ..addAll({
          for (final e in _accountingMap(
            request['sourceCurrencyMappings'],
          ).entries)
            e.key: e.value.toString(),
        });
      _sourceIds
        ..clear()
        ..addAll(
          (request['auxiliarySourceIds'] as List? ?? const []).map(
            (v) => v.toString(),
          ),
        );
      _zeroCodes
        ..clear()
        ..addAll(
          (request['omittedZeroBalanceProfitCodes'] as List? ?? const []).map(
            (v) => v.toString(),
          ),
        );
      _complete = request['completeOriginalPeriod'] == true;
      _openingGrid.replaceAll([
        for (final row in _accountingMaps(request['openingAllocations']))
          _AccountingOpeningRow(data: row),
      ]);
      _append = request['appendPeriod'] == true;
      _reason.text = primary['status'] == 'PREVIEW'
          ? request['reason']?.toString() ?? ''
          : '';
      _syncAccountRows();
    }
  }

  Future<void> _pick(String kind) async {
    if (_busy ||
        _loading ||
        !_canMutate ||
        _pending != null ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    if (_book.text.trim().isEmpty) {
      context.appWarning('请先填写原账套标识');
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      await saveFormDraftNow();
      final file = await ref.read(financeEntryFilePickerProvider)();
      if (file == null || !mounted || !scope.isCurrent) return;
      final bytes = file.bytes;
      if (!const {'xls', 'xlsx'}.contains(file.extension?.toLowerCase()) ||
          bytes == null ||
          bytes.isEmpty ||
          bytes.length > 15 * 1024 * 1024) {
        throw StateError('请选择完整XLS/XLSX原件，最大15MB');
      }
      final preview = await scope.run(
        () => ref
            .read(apiClientProvider)
            .postMultipartFile(
              Uri(
                path: '/finance/accounting-imports/preview',
                queryParameters: {
                  'kind': kind,
                  'sourceSystem': _book.text.trim(),
                },
              ).toString(),
              bytes,
              file.name,
              file.extension?.toLowerCase() == 'xls'
                  ? 'application/vnd.ms-excel'
                  : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            ),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      final replacing = kind == 'VOUCHERS'
          ? _vouchers != null &&
                _accountingId(_vouchers) != _accountingId(preview)
          : _balances != null &&
                _accountingId(_balances) != _accountingId(preview);
      Future<void> publish() async {
        if (kind == 'VOUCHERS' && replacing) {
          _clearChoices();
        }
        if (!await _publishSources(
          kind == 'VOUCHERS' ? preview : _vouchers,
          kind == 'BALANCE' ? preview : _balances,
          () => scope.isCurrent,
        )) {
          return;
        }
        setState(() {
          if (replacing) {
            _accounts.clear();
            _zeroCodes.clear();
            _complete = false;
            _syncAccountRows();
          }
          _comparison = [];
        });
      }

      if (replacing) {
        await resetFormDraftAfterSubmission(
          preserveCurrentDraft: true,
          prepare: publish,
        );
      } else {
        await publish();
      }
      markFormDraftChanged();
      await _loadOptions();
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '原件未读取完成，可从最近批次恢复或重选同一文件');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseVoucher(String? id) async {
    if (id == null ||
        _busy ||
        _pending != null ||
        !await confirmFormDraftExit() ||
        !mounted) {
      return;
    }
    await resetFormDraftAfterSubmission(
      preserveCurrentDraft: true,
      prepare: () async {
        setState(() => _busy = true);
        try {
          _clearChoices();
          await _readPair(id);
        } catch (error) {
          if (mounted) context.appApiError(error, fallback: '批次未恢复');
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      },
    );
  }

  Future<void> _chooseBalance(String? id) async {
    if (id == null || !_editable) return;
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      final value = await scope.run(
        () =>
            ref.read(apiClientProvider).get('/finance/accounting-imports/$id'),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      if (value['kind'] != 'BALANCE' ||
          value['sourceSystem'] != _vouchers?['sourceSystem']) {
        throw StateError('请选择相同原账套的科目余额');
      }
      if (!await _publishSources(_vouchers, value, () => scope.isCurrent)) {
        return;
      }
      setState(() {
        _accounts.clear();
        _zeroCodes.clear();
        _syncAccountRows();
        _comparison = [];
        _complete = false;
      });
      markFormDraftChanged();
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '余额批次未恢复');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _clearChoices() {
    _vouchers = null;
    _balances = null;
    _accounts.clear();
    _purposes.clear();
    _entryAux.clear();
    _entryAuxLabels.clear();
    _sourceCurrencyMappings.clear();
    _sourceIds.clear();
    _zeroCodes.clear();
    _complete = false;
    _append = false;
    _comparison = [];
    _reason.clear();
    _pending = null;
    _auxCurrency = null;
    _retainedVoucherId = null;
    _retainedBalanceId = null;
    _acceptedVoucherVersion = null;
    _needsReconfirm = false;
    _accountGrid.clear();
    _purposeGrid.clear();
    _auxiliaryGrid.clear();
    _sourceCurrencyGrid.clear();
    _openingGrid.clear();
  }

  Future<void> _new() async {
    if (_busy ||
        _pending != null ||
        !await confirmFormDraftExit() ||
        !mounted) {
      return;
    }
    await resetFormDraftAfterSubmission(
      preserveCurrentDraft: true,
      prepare: () async {
        setState(() {
          _clearChoices();
          _book.clear();
          _tab = 0;
        });
      },
    );
  }

  Future<void> _compare() async {
    if (_vouchers == null || _balances == null || _busy) return;
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      final result = await scope.run(
        () => ref
            .read(apiClientProvider)
            .get(
              '/finance/accounting-imports/${_accountingId(_vouchers)}/compare',
              query: {'balanceImportId': _accountingId(_balances)},
            ),
      );
      if (mounted && formDraftIdentityIsCurrent && scope.isCurrent) {
        setState(() => _comparison = _accountingMaps(result['issues']));
      }
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '成对核对未完成');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _submission() {
    if (_vouchers == null || _balances == null || !_complete) {
      throw StateError('请成对选择原凭证/科目余额，并确认原期间完整');
    }
    for (final source in [_vouchers, _balances]) {
      if (_accountingMaps(
        _accountingMap(source?['source'])['issues'],
      ).isNotEmpty) {
        throw StateError('原文件仍有读取错误，请先核对原表');
      }
    }
    if (_voucherRows.any((v) => !_purposes.containsKey(v['key']))) {
      throw StateError('请明确每张凭证的业务性质，候选标志不能代替复核');
    }
    for (final row in _sourceCurrencyGrid.rows) {
      final chosen = _sourceCurrencyMappings[row.identity];
      if (chosen == null ||
          !_currencies.any((currency) => currency['id'] == chosen)) {
        throw StateError('请在原凭证币别页明确F10标签“${row.identity}”对应的真实币别');
      }
    }
    final selected = <Map<String, dynamic>>[];
    for (final row in _accountRows) {
      final code = row['accountCode'].toString(),
          choice = _accounts[row['accountCode']],
          chart = _chartCode(code);
      if (choice == null ||
          choice['styleId'] == null ||
          choice['currencyId'] == null ||
          choice['chartVersion'] != chart['version'] ||
          !_accountingMaps(
            chart['targets'],
          ).any((target) => target['id'] == choice['styleId'])) {
        throw StateError('请重新核对科目$code的对应、币别及版本');
      }
      selected.add({'accountCode': code, ...choice});
    }
    return {
      'expectedVersion': _vouchers!['version'],
      'balanceImportId': _accountingId(_balances),
      'balanceVersion': _balances!['version'],
      'accounts': selected,
      'voucherPurposes': Map.of(_purposes),
      'entryAuxiliaries': Map.of(_entryAux),
      'auxiliarySourceIds': _sourceIds.toList(),
      'omittedZeroBalanceProfitCodes': _zeroCodes.toList(),
      'completeOriginalPeriod': true,
      'appendPeriod': _append,
      'reason': _reason.text.trim(),
      'sourceCurrencyMappings': Map<String, String>.from(
        _sourceCurrencyMappings,
      ),
      'openingAllocations': [
        for (final row in _openingGrid.rows) row.command(),
      ],
    };
  }

  bool _definite(ApiException error) =>
      error.hasResponseCode &&
      (error.code == 'VALIDATION_FAILED' || error.code == 'CONFLICT');
  Future<void> _act(String action) async {
    if (_busy || _loading || !_canMutate || !formDraftIdentityIsCurrent) return;
    if (_pending == null && _reason.text.trim().isEmpty) {
      context.appWarning('请填写核对依据或退回/撤回原因');
      return;
    }
    if (_pending == null && _needsReconfirm) {
      context.appWarning('批次版本已变化，本机草稿已保留，请重新核对当前批次后再操作');
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      _pending ??= {
        'importId': _accountingId(_vouchers),
        'action': action,
        'body': action == 'submit'
            ? _submission()
            : {
                'requestId': const Uuid().v4(),
                'expectedVersion': _vouchers!['version'],
                'reason': _reason.text.trim(),
              },
      };
      final command = _accountingMap(jsonDecode(jsonEncode(_pending)));
      await runFormDraftSubmission(
        () => scope.run(
          () => ref
              .read(apiClientProvider)
              .post(
                '/finance/accounting-imports/${command['importId']}/${command['action']}',
                body: command['body'],
              ),
        ),
        isDefiniteRejection: _definite,
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      await completeFormDraft();
      if (mounted) {
        context.appSuccess(
          command['action'] == 'submit' ? '已提交，请由另一人复核' : '原账套操作已完成',
        );
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!formDraftHasUnknownSubmission) _pending = null;
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '操作未确认，原批次及请求参数已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receipt() async {
    if (_pending == null || _busy) return;
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      final id = _pending!['importId'].toString();
      final value = await scope.run(
        () =>
            ref.read(apiClientProvider).get('/finance/accounting-imports/$id'),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      final action = _pending!['action'];
      bool proved =
          value['status'] == 'POSTED' &&
          (action == 'approve' || action == 'submit');
      if (action == 'submit' && value['status'] == 'SUBMITTED') {
        proved = _sameSubmitBody(
          _accountingMap(_accountingMap(value['review'])['request']),
          _accountingMap(_pending!['body']),
        );
      }
      if (proved) {
        await completeFormDraft();
        if (mounted) {
          context.appSuccess('原批次操作已确认');
          Navigator.of(context).pop(true);
        }
      } else {
        context.appWarning('尚未取得相同原操作的成功证据，请保留原请求核对或重试');
      }
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '未取得原操作成功证据');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _sameSubmitBody(Map<String, dynamic> a, Map<String, dynamic> b) {
    Map<String, dynamic> normalized(Map<String, dynamic> v) => {
      ...v,
      'omittedZeroBalanceProfitCodes':
          (v['omittedZeroBalanceProfitCodes'] as List? ?? const [])
              .map((e) => e.toString())
              .toList()
            ..sort(),
    };
    return const DeepCollectionEquality().equals(normalized(a), normalized(b));
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenResponsiveActionWrap(
    children: [
      TextButton(
        onPressed: _busy ? null : _receipt,
        child: const Text('核对原批次结果'),
      ),
      if (_pending != null)
        TextButton(
          onPressed: _busy || !_canMutate
              ? null
              : () => _act(_pending!['action'].toString()),
          child: const Text('使用原请求核对并重试'),
        ),
    ],
  );
  Future<void> _close() async {
    if (!_busy && await confirmFormDraftExit() && mounted) {
      Navigator.of(context).pop(false);
    }
  }

  void _changed() {
    markFormDraftChanged();
    setState(() {});
  }

  Widget _grid(
    List<MasterColumnDef<Map<String, dynamic>>> columns,
    List<Map<String, dynamic>> rows, {
    String? key,
  }) {
    final query = _appliedSearch.trim().toLowerCase();
    final filtered = query.isEmpty
        ? rows
        : rows
              .where(
                (row) => row['__search'] != null
                    ? row['__search'].toString().contains(query)
                    : row.values.any(
                        (v) => v.toString().toLowerCase().contains(query),
                      ),
              )
              .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      key: ValueKey('${key ?? _tab}:$query'),
      tableKey: 'finance.accounting.${key ?? _tab}',
      columns: columns,
      items: filtered,
      rowKeyOf: (row) {
        final id =
            row['__sourceEntryId'] ??
            row['sourceEntryId'] ??
            row['key'] ??
            row['accountCode'] ??
            row['2'];
        return id == null
            ? null
            : '${_accountingId(_vouchers)}|${key ?? _tab}|$id';
      },
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      showPaginationControls: false,
      virtualized: true,
      showColumnChooser: false,
      expensiveRowMounts: false,
    );
  }

  Widget _allocationGrid(
    List<MasterColumnDef<Map<String, dynamic>>> columns,
    UtenEditableGridController<_AccountingAllocationRow> controller,
    String key,
  ) => SingleChildScrollView(
    child: UtenEditableGrid<_AccountingAllocationRow>(
      controller: controller,
      tableKey: 'finance.accounting.$key',
      showAddRow: false,
      showRowDelete: false,
      showRemoveRowsAction: false,
      showColumnSettings: false,
      selectionEnabled: _editable,
      emptyMessage: '请先选择原文件批次',
      columns: [
        for (final column in columns)
          EditableGridColumn(
            key: column.key,
            label: column.label,
            width: column.width,
            required: true,
            aiSensitive: column.aiSensitive,
            textOf: (row) => column.value(row.source) ?? '',
            listenableOf: (row) => row.changed,
            cellBuilder: (context, row) => ValueListenableBuilder<int>(
              valueListenable: row.changed,
              builder: (context, revision, child) =>
                  column.cellBuilder?.call(context, row.source) ??
                  Text(column.value(row.source) ?? ''),
            ),
          ),
      ],
    ),
  );

  MasterColumnDef<Map<String, dynamic>> _column(
    String key,
    String label, {
    double width = 150,
  }) => MasterColumnDef(
    key: key,
    label: label,
    width: width,
    aiSensitive: true,
    filterFromRows: true,
    facetSearchEnabled: true,
    columnSearchEnabled: true,
    value: (row) => row[key]?.toString() ?? '',
  );
  Widget _originals() {
    _cacheSources();
    final balance = _sourceView == 'BALANCE',
        source = _accountingMap((balance ? _balances : _vouchers)?['source']);
    final headers = (source['headers'] as List? ?? const [])
        .map((v) => v.toString())
        .toList();
    final rows = balance
        ? [
            for (final row in _balanceRows)
              {
                '0': row['year'],
                '1': row['month'],
                '2': row['accountCode'],
                '3': row['accountName'],
                '4': row['currencyName'],
                '5': row['openingDebit'],
                '6': row['openingCredit'],
                '7': row['debit'],
                '8': row['credit'],
                '9': row['closingDebit'],
                '10': row['closingCredit'],
              },
          ]
        : _cachedRawRows;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenSegmentRow<String>(
            segments: const [
              ButtonSegment(value: 'VOUCHERS', label: Text('原凭证83列')),
              ButtonSegment(value: 'BALANCE', label: Text('原科目余额11列')),
            ],
            selected: {_sourceView},
            onSelectionChanged: (v) => setState(() {
              _sourceView = v.single;
            }),
          ),
        ),
        Expanded(
          child: headers.isEmpty
              ? const Center(child: Text('请先选择原文件批次'))
              : _grid(
                  [
                    for (int i = 0; i < headers.length; i++)
                      _column(
                        balance ? '$i' : '${i + 1}',
                        headers[i],
                        width: 190,
                      ),
                  ],
                  rows,
                  key: 'original-$_sourceView',
                ),
        ),
      ],
    );
  }

  String _sourceView = 'VOUCHERS';
  Widget _accountTable() => _allocationGrid(
    [
      _column('accountCode', '科目编码', width: 105),
      _column('accountName', '科目名称', width: 200),
      _column('currencyName', '外币名称', width: 120),
      MasterColumnDef(
        key: 'target',
        label: '对应核算科目',
        width: 310,
        value: (row) =>
            _accounts[row['accountCode']]?['styleId']?.toString() ?? '',
        cellBuilder: (_, row) {
          final code = row['accountCode'].toString(),
              chart = _chartCode(code),
              choice = _accounts[code] ?? {},
              targets = _accountingMaps(chart['targets']);
          return UtenDropdownField(
            key: ValueKey('accounting-style-$code'),
            value: choice['styleId']?.toString(),
            enabled: _editable,
            items: [
              for (final target in targets)
                UtenDropdownItem(
                  value: target['id'].toString(),
                  label: '${target['code']} ${target['name']}',
                ),
            ],
            onChanged: (v) {
              _accounts[code] = {
                ...choice,
                'styleId': v,
                'chartVersion': chart['version'],
              };
              _allocationChanged('account', code);
            },
          );
        },
      ),
      MasterColumnDef(
        key: 'currency',
        label: '科目会计币别',
        width: 210,
        value: (row) =>
            _accounts[row['accountCode']]?['currencyId']?.toString() ?? '',
        cellBuilder: (_, row) {
          final code = row['accountCode'].toString(),
              choice = _accounts[code] ?? {},
              chart = _chartCode(code);
          return UtenDropdownField(
            key: ValueKey('accounting-currency-$code'),
            value: choice['currencyId']?.toString(),
            enabled: _editable,
            items: [
              for (final c in _currencies)
                UtenDropdownItem(
                  value: c['id'].toString(),
                  label: '${c['code']} ${c['name']}',
                ),
            ],
            onChanged: (v) {
              _accounts[code] = {
                ...choice,
                'currencyId': v,
                'chartVersion': chart['version'],
              };
              _allocationChanged('account', code);
            },
          );
        },
      ),
      MasterColumnDef(
        key: 'checked',
        label: '对应状态',
        width: 220,
        value: (row) {
          final code = row['accountCode'].toString(),
              choice = _accounts[code],
              chart = _chartCode(code);
          return choice == null
              ? '待核对'
              : choice['chartVersion'] != chart['version']
              ? '科目关系已变化，请重新选择确认'
              : choice['styleId'] == null ||
                    choice['currencyId'] == null ||
                    !_accountingMaps(
                      chart['targets'],
                    ).any((target) => target['id'] == choice['styleId'])
              ? '未选完整'
              : '已明确选择';
        },
      ),
    ],
    _accountGrid,
    'accounts',
  );
  Widget _sourceCurrencyTable() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.all(UtenSpacing.s12),
        child: Text(
          '原凭证F10币别标签对应本凭证原币金额的实际单位。请财务明确选择真实币别；此选择独立于科目会计币别，不按同名自动对应。空白原标签保留未知，不补外币单位。',
        ),
      ),
      Expanded(
        child: _allocationGrid(
          [
            _column('sourceCurrencyLabel', '原凭证F10币别标签', width: 240),
            _column('sourceRow', '首次原行', width: 120),
            MasterColumnDef<Map<String, dynamic>>(
              key: 'actualCurrency',
              label: '实际原币单位',
              width: 300,
              value: (row) =>
                  _sourceCurrencyMappings[row['sourceCurrencyLabel']] ?? '',
              cellBuilder: (_, row) {
                final label = row['sourceCurrencyLabel'].toString();
                return UtenDropdownField(
                  key: ValueKey('accounting-source-currency-$label'),
                  value: _sourceCurrencyMappings[label],
                  enabled: _editable,
                  items: [
                    for (final currency in _currencies)
                      UtenDropdownItem(
                        value: currency['id'].toString(),
                        label: '${currency['code']} ${currency['name']}',
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      _sourceCurrencyMappings.remove(label);
                    } else {
                      _sourceCurrencyMappings[label] = value;
                    }
                    _allocationChanged('sourceCurrency', label);
                  },
                );
              },
            ),
          ],
          _sourceCurrencyGrid,
          'source-currencies',
        ),
      ),
    ],
  );
  Widget _purposeTable() => _allocationGrid(
    [
      _column('date', '日期', width: 120),
      _column('type', '凭证类别', width: 100),
      _column('number', '凭证号', width: 120),
      _column('debit', '借方合计'),
      _column('credit', '贷方合计'),
      MasterColumnDef(
        key: 'candidate',
        label: '原结构提示',
        width: 180,
        value: (row) =>
            row['closingCandidate'] == true ? '损益结转候选，仍需复核' : '需复核业务性质',
      ),
      MasterColumnDef(
        key: 'purpose',
        label: '本次明确性质',
        width: 210,
        value: (row) => _accountingPurposes[_purposes[row['key']]] ?? '',
        cellBuilder: (_, row) => UtenDropdownField(
          key: ValueKey('accounting-purpose-${row['key']}'),
          value: _purposes[row['key']],
          enabled: _editable,
          items: [
            for (final e in _accountingPurposes.entries)
              UtenDropdownItem(value: e.key, label: e.value),
          ],
          onChanged: (v) {
            if (v == null) {
              _purposes.remove(row['key']);
            } else {
              _purposes[row['key'].toString()] = v;
            }
            _allocationChanged('purpose', row['key'].toString());
          },
        ),
      ),
    ],
    _purposeGrid,
    'purposes',
  );
  Future<void> _selectAuxiliary(Map<String, dynamic> entry) async {
    if (!_editable) return;
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    final role =
        entry['customerCode']?.toString().isNotEmpty == true &&
            entry['supplierCode']?.toString().isEmpty == true
        ? 'CUSTOMER'
        : entry['supplierCode']?.toString().isNotEmpty == true &&
              entry['customerCode']?.toString().isEmpty == true
        ? 'SUPPLIER'
        : null;
    final chosen = await showFinanceAuxiliaryPicker(
      context,
      accountCode: entry['accountCode'].toString(),
      role: role,
      canEdit: _canEditDirectory,
    );
    if (chosen == null ||
        !mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent) {
      return;
    }
    final id = entry['sourceEntryId'].toString();
    _entryAux[id] = chosen['id'].toString();
    _entryAuxLabels[id] = '${chosen['sourceCode']} ${chosen['sourceName']}';
    _allocationChanged('auxiliary', id);
  }

  Widget _auxiliaryTable() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final source in _auxSources)
              FilterChip(
                label: Text(
                  '${source['sourceName']} / ${source['sourceSystem']}',
                ),
                selected: _sourceIds.contains(_accountingId(source)),
                onSelected: !_editable
                    ? null
                    : (v) {
                        if (v) {
                          _sourceIds.add(_accountingId(source));
                        } else {
                          _sourceIds.remove(_accountingId(source));
                        }
                        _changed();
                      },
              ),
            if (_canEditDirectory)
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: !_editable ? null : () => _importAuxiliary(),
                child: const Text('导入原辅助明细'),
              ),
          ],
        ),
      ),
      Expanded(
        child: _allocationGrid(
          [
            _column('number', '凭证号', width: 100),
            _column('accountCode', '科目代码', width: 110),
            _column('accountName', '原科目名称', width: 180),
            _column('customerCode', '原客户编号', width: 130),
            _column('supplierCode', '原供应商编号', width: 140),
            _column('employeeCode', '原人员编号', width: 130),
            _column('projectCode', '原项目编号', width: 130),
            MasterColumnDef(
              key: 'aux',
              label: '明确辅助项目',
              width: 260,
              value: (e) => _entryAuxLabels[e['sourceEntryId']] ?? '按原编号核对',
              cellBuilder: (_, e) => TextButton(
                onPressed: !_editable ? null : () => _selectAuxiliary(e),
                child: Text(
                  _entryAuxLabels[e['sourceEntryId']] ?? '按原编号核对／明确选择',
                ),
              ),
            ),
          ],
          _auxiliaryGrid,
          'auxiliary',
        ),
      ),
    ],
  );
  Future<void> _importAuxiliary() async {
    if (_balances == null || _busy) return;
    final first = _balanceRows.firstOrNull;
    if (first == null) return;
    final year = (first['year'] as num).toInt(),
        month = (first['month'] as num).toInt();
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => UtenAlertDialog(
          title: const Text('原辅助明细'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              UtenDropdownField(
                label: '原币别属性',
                value: _auxCurrency,
                items: [
                  for (final c in _currencies)
                    UtenDropdownItem(
                      value: c['id'].toString(),
                      label: '${c['code']} ${c['name']}',
                    ),
                ],
                onChanged: (v) {
                  update(() => _auxCurrency = v);
                },
              ),
              TextButton(
                onPressed: _auxCurrency == null
                    ? null
                    : () => Navigator.pop(context, 'receivable'),
                child: const Text('应收账款明细表'),
              ),
              TextButton(
                onPressed: _auxCurrency == null
                    ? null
                    : () => Navigator.pop(context, 'payable'),
                child: const Text('应付账款明细表'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || _auxCurrency == null || !mounted) return;
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    await showFinanceAuxiliaryImportDialog(
      context,
      receivable: choice == 'receivable',
      currencyId: _auxCurrency!,
      dateFrom: DateTime(year, month).toIso8601String().substring(0, 10),
      dateTo: DateTime(year, month + 1, 0).toIso8601String().substring(0, 10),
    );
    if (mounted && formDraftIdentityIsCurrent && scope.isCurrent) {
      await _loadOptions();
    }
  }

  Future<void> _selectOpeningAux(_AccountingOpeningRow row) async {
    if (!_editable || row.accountCode == null) {
      context.appWarning('请先明确本行原科目');
      return;
    }
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    final chosen = await showFinanceAuxiliaryPicker(
      context,
      accountCode: row.accountCode,
      canEdit: _canEditDirectory,
    );
    if (chosen == null ||
        !mounted ||
        !scope.isCurrent ||
        !_openingGrid.rows.contains(row)) {
      return;
    }
    row.auxiliaryId = chosen['id'].toString();
    row.auxiliaryLabel = '${chosen['sourceCode']} ${chosen['sourceName']}';
    row.changed.value++;
    markFormDraftChanged();
  }

  Widget _openingAllocations() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(UtenSpacing.s12),
          child: Text(
            '可使用原辅助明细，也可在此按明确原始依据分配期初。每个原科目借贷总额必须与原余额完全一致；原币与本位币分开，未知不补0。',
          ),
        ),
        UtenEditableGrid<_AccountingOpeningRow>(
          controller: _openingGrid,
          tableKey: 'finance.accounting.opening-allocations',
          showAddRow: _editable,
          showRowDelete: _editable,
          selectionEnabled: _editable,
          showColumnSettings: false,
          showRemoveRowsAction: false,
          createBlankRow: () => _AccountingOpeningRow(),
          emptyMessage: '无手工期初分配；可从原辅助明细取数',
          columns: [
            EditableGridColumn(
              key: 'accountCode',
              label: '科目编码',
              width: 220,
              required: true,
              textOf: (r) => r.accountCode ?? '',
              listenableOf: (r) => r.changed,
              cellBuilder: (_, r) => ValueListenableBuilder<int>(
                valueListenable: r.changed,
                builder: (context, revision, child) => UtenDropdownField(
                  key: ValueKey('accounting-opening-accountCode-${r.identity}'),
                  value: r.accountCode,
                  enabled: _editable,
                  items: [
                    for (final source in _accountRows)
                      UtenDropdownItem(
                        value: source['accountCode'].toString(),
                        label:
                            '${source['accountCode']} ${source['accountName']}',
                      ),
                  ],
                  onChanged: (v) {
                    r.accountCode = v;
                    r.auxiliaryId = null;
                    r.auxiliaryLabel = null;
                    r.currencyId = null;
                    r.originalCurrencyId = null;
                    r.changed.value++;
                    markFormDraftChanged();
                  },
                ),
              ),
            ),
            EditableGridColumn(
              key: 'auxiliary',
              label: '辅助项目',
              width: 280,
              required: true,
              textOf: (r) => r.auxiliaryLabel ?? '',
              listenableOf: (r) => r.changed,
              cellBuilder: (_, r) => ValueListenableBuilder<int>(
                valueListenable: r.changed,
                builder: (context, revision, child) => TextButton(
                  onPressed: _editable ? () => _selectOpeningAux(r) : null,
                  child: Text(r.auxiliaryLabel ?? '明确选择原辅助项目'),
                ),
              ),
            ),
            EditableGridColumn(
              key: 'currencyId',
              label: '科目会计币别',
              width: 220,
              textOf: (r) => r.currencyId ?? '',
              listenableOf: (r) => r.changed,
              cellBuilder: (_, r) => ValueListenableBuilder<int>(
                valueListenable: r.changed,
                builder: (context, revision, child) => UtenDropdownField(
                  key: ValueKey('accounting-opening-currencyId-${r.identity}'),
                  value: r.currencyId,
                  enabled: _editable,
                  hintText: '按科目已确认币别',
                  items: [
                    for (final c in _currencies)
                      UtenDropdownItem(
                        value: c['id'].toString(),
                        label: '${c['code']} ${c['name']}',
                      ),
                  ],
                  onChanged: (v) {
                    r.currencyId = v;
                    r.changed.value++;
                    markFormDraftChanged();
                  },
                ),
              ),
            ),
            EditableGridColumn(
              key: 'originalCurrencyId',
              label: '原币金额单位',
              width: 230,
              textOf: (row) => row.originalCurrencyId ?? '',
              listenableOf: (row) => row.changed,
              cellBuilder: (_, row) => ValueListenableBuilder<int>(
                valueListenable: row.changed,
                builder: (_, _, _) => UtenDropdownField(
                  key: ValueKey(
                    'accounting-opening-originalCurrencyId-${row.identity}',
                  ),
                  value: row.originalCurrencyId,
                  enabled: _editable,
                  hintText: '实际原币单位，独立于会计币别',
                  items: [
                    for (final currency in _currencies)
                      UtenDropdownItem(
                        value: currency['id'].toString(),
                        label: '${currency['code']} ${currency['name']}',
                      ),
                  ],
                  onChanged: (value) {
                    row.originalCurrencyId = value;
                    row.changed.value++;
                    markFormDraftChanged();
                  },
                ),
              ),
            ),
            for (final field in const {
              'openingDebit': '期初借方（本币）',
              'openingCredit': '期初贷方（本币）',
              'originalNet': '原币净额',
              'exchangeRate': '原记账汇率',
              'sourceReference': '原始依据',
              'accountPathName': '原用途科目全称',
            }.entries)
              EditableGridColumn(
                key: field.key,
                label: field.value,
                width:
                    field.key == 'sourceReference' ||
                        field.key == 'accountPathName'
                    ? 280
                    : 180,
                required:
                    field.key == 'openingDebit' ||
                    field.key == 'openingCredit' ||
                    field.key == 'sourceReference',
                textOf: (r) => r.text[field.key]!.text,
                listenableOf: (r) => r.text[field.key]!,
                aiSensitive: true,
                cellBuilder: (_, r) => UtenInput(
                  key: ValueKey(
                    'accounting-opening-${field.key}-${r.identity}',
                  ),
                  controller: r.text[field.key],
                  enabled: _editable,
                ),
              ),
          ],
        ),
      ],
    ),
  );
  Widget _review() => SingleChildScrollView(
    padding: const EdgeInsets.all(UtenSpacing.s16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '原凭证：${_vouchers?['sourceName'] ?? '未选择'}；原科目余额：${_balances?['sourceName'] ?? '未选择'}',
        ),
        const SizedBox(height: UtenSpacing.s12),
        const Text('金额按原账套本币保留，原币与币别属性分开核对。原文件审核/记账标志仅作来源信息，不代替本系统另一人复核。'),
        Text(
          _append ? '本次模式：继续月份，只追加当期凭证，不重复期初。' : '本次模式：首次接续，核对并写入一次期初及当期原凭证。',
        ),
        if (_accountingMap(
              _accountingMap(_vouchers?['review'])['plan'],
            )['effectiveFrom'] !=
            null)
          Text(
            '服务端核定接续起点：${_accountingMap(_accountingMap(_vouchers?['review'])['plan'])['effectiveFrom']}',
          ),
        if (_state != 'PREVIEW')
          Text(
            '原提交核对依据：${_accountingMap(_accountingMap(_vouchers?['review'])['request'])['reason'] ?? ''}',
          ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _append,
          title: const Text('继续导入后续完整月份（核对上期期末，本次不重复期初）'),
          onChanged: !_editable
              ? null
              : (v) {
                  _append = v == true;
                  _changed();
                },
        ),
        if (_missingCodes.isNotEmpty) ...[
          const Text('原余额表省略的凭证科目：仅明确收入/费用科目且整期借贷结平时，才可复核为期初期末均为零。'),
          for (final row in _missingCodes)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _zeroCodes.contains(row['accountCode']),
              title: Text('${row['accountCode']} ${row['accountName']}'),
              onChanged: !_editable
                  ? null
                  : (v) {
                      if (v == true) {
                        _zeroCodes.add(row['accountCode'].toString());
                      } else {
                        _zeroCodes.remove(row['accountCode']);
                      }
                      _syncAccountRows();
                      _changed();
                    },
            ),
        ],
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _complete,
          title: const Text('已核对本期原始凭证完整、原余额与辅助明细完整，并逐张确认凭证性质'),
          onChanged: !_editable
              ? null
              : (v) {
                  _complete = v == true;
                  _changed();
                },
        ),
        UtenInput(
          label: '核对依据／退回或撤回原因',
          controller: _reason,
          maxLines: 3,
          enabled: !_busy && _pending == null,
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _busy || _vouchers == null || _balances == null
              ? null
              : _compare,
          child: const Text('核对两份原表'),
        ),
        for (final source in [_vouchers, _balances])
          for (final issue in _accountingMaps(
            _accountingMap(source?['source'])['issues'],
          ))
            Text(
              '第${issue['sourceRow']}行 ${issue['field']}：${issue['message']}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        for (final issue in _comparison)
          Text(
            '原表核对：第${issue['sourceRow']}行 ${issue['field']} ${issue['message']}',
          ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => withFormDraft(
    Stack(
      children: [
        Material(
          child: Column(
            children: [
              UtenDialogSurface(
                child: UtenDialogHeader(
                  icon: Icons.account_balance_outlined,
                  title: const Text(
                    FinanceRequirementNames.accountingContinuation,
                  ),
                  showCloseButton: true,
                  onClose: _close,
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, limits) => Column(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: limits.maxHeight * .28,
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(UtenSpacing.s12),
                                child: Column(
                                  children: [
                                    UtenFormGrid(
                                      maxColumns: 3,
                                      children: [
                                        UtenInput(
                                          label: '原账套标识',
                                          controller: _book,
                                          enabled:
                                              _canMutate &&
                                              !_loading &&
                                              !_busy &&
                                              _vouchers == null &&
                                              _balances == null,
                                          info: '与原辅助明细使用相同原账套标识，不能按名称合并其他账套。',
                                        ),
                                        UtenDropdownField(
                                          label: '原凭证批次',
                                          value:
                                              _accountingId(_vouchers).isEmpty
                                              ? null
                                              : _accountingId(_vouchers),
                                          selectedLabel:
                                              _vouchers?['sourceName']
                                                  ?.toString(),
                                          enabled: !_busy && _pending == null,
                                          items: [
                                            for (final row in _recent)
                                              if (row['kind'] == 'VOUCHERS')
                                                UtenDropdownItem(
                                                  value: _accountingId(row),
                                                  label:
                                                      '${row['sourceName']} · ${_accountingStates[row['status']] ?? row['status']}',
                                                ),
                                          ],
                                          onChanged: _chooseVoucher,
                                        ),
                                        UtenDropdownField(
                                          label: '成对原科目余额',
                                          value:
                                              _accountingId(_balances).isEmpty
                                              ? null
                                              : _accountingId(_balances),
                                          selectedLabel:
                                              _balances?['sourceName']
                                                  ?.toString(),
                                          enabled:
                                              _editable && _vouchers != null,
                                          items: [
                                            for (final row in _recent)
                                              if (row['kind'] == 'BALANCE' &&
                                                  row['sourceSystem'] ==
                                                      _vouchers?['sourceSystem'])
                                                UtenDropdownItem(
                                                  value: _accountingId(row),
                                                  label: row['sourceName']
                                                      .toString(),
                                                ),
                                          ],
                                          onChanged: _chooseBalance,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: UtenSpacing.s8),
                                    UtenResponsiveActionWrap(
                                      children: [
                                        UtenImportButton(
                                          onPressed: _editable
                                              ? () => _pick('VOUCHERS')
                                              : null,
                                          label: '导入原凭证83列',
                                        ),
                                        UtenImportButton(
                                          onPressed: _editable
                                              ? () => _pick('BALANCE')
                                              : null,
                                          label: '导入原科目余额11列',
                                        ),
                                        UtenRefreshButton(
                                          onRefresh: _refresh,
                                          busy: _busy || _loading,
                                          tooltip: '刷新可选批次／科目',
                                        ),
                                        if (_vouchers != null)
                                          UtenButton(
                                            type: UtenButtonType.secondary,
                                            onPressed: _busy || _pending != null
                                                ? null
                                                : () => _chooseVoucher(
                                                    _accountingId(_vouchers),
                                                  ),
                                            child: const Text('重新核对当前批次'),
                                          ),
                                        if (_canEditDirectory)
                                          UtenButton(
                                            type: UtenButtonType.secondary,
                                            onPressed: _busy || _pending != null
                                                ? null
                                                : () async {
                                                    final scope =
                                                        await captureFormDraftRequestScope();
                                                    if (!mounted ||
                                                        !scope.isCurrent) {
                                                      return;
                                                    }
                                                    await showFinanceChartDialog(
                                                      this.context,
                                                      canEdit: true,
                                                    );
                                                    if (mounted &&
                                                        scope.isCurrent) {
                                                      await _loadOptions();
                                                    }
                                                  },
                                            child: const Text('科目代码及新增对应'),
                                          ),
                                        UtenButton(
                                          type: UtenButtonType.secondary,
                                          onPressed:
                                              _busy ||
                                                  _loading ||
                                                  !_canMutate ||
                                                  _pending != null
                                              ? null
                                              : _new,
                                          child: const Text('新建接续'),
                                        ),
                                        Text(
                                          _accountingStates[_state] ?? _state,
                                        ),
                                        if (_needsReconfirm)
                                          const UtenFieldHintIcon(
                                            info:
                                                '批次版本已变化，本机草稿保留。请用“重新核对当前批次”读取当前冻结内容。',
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.all(
                                    UtenSpacing.s12,
                                  ),
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s12,
                        ),
                        child: UtenSegmentRow<int>(
                          segments: const [
                            ButtonSegment(value: 0, label: Text('原文预览')),
                            ButtonSegment(value: 1, label: Text('科目对应')),
                            ButtonSegment(value: 2, label: Text('凭证性质')),
                            ButtonSegment(value: 3, label: Text('辅助复核')),
                            ButtonSegment(value: 4, label: Text('期初分配')),
                            ButtonSegment(value: 5, label: Text('核对与提交')),
                            ButtonSegment(value: 6, label: Text('原凭证币别')),
                          ],
                          selected: {_tab},
                          onSelectionChanged: (v) => setState(() {
                            _tab = v.single;
                            _search.clear();
                            _appliedSearch = '';
                          }),
                        ),
                      ),
                      if (_tab == 0)
                        Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: UtenSearchBar(
                            hint: '查找当前原表',
                            controller: _search,
                            onChanged: (value) => setState(() {
                              _appliedSearch = value;
                            }),
                          ),
                        ),
                      Expanded(
                        child: _loading
                            ? const Center(child: CircularProgressIndicator())
                            : switch (_tab) {
                                0 => _originals(),
                                1 => _accountTable(),
                                2 => _purposeTable(),
                                3 => _auxiliaryTable(),
                                4 => _openingAllocations(),
                                6 => _sourceCurrencyTable(),
                                _ => _review(),
                              },
                      ),
                    ],
                  ),
                ),
              ),
              UtenDialogActions(
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy ? null : _close,
                    child: const Text('关闭'),
                  ),
                  if (_pending != null)
                    UtenButton(
                      onPressed: _busy || !_canMutate
                          ? null
                          : () => _act(_pending!['action'].toString()),
                      child: const Text('使用原请求核对并重试'),
                    )
                  else if (_state == 'PREVIEW')
                    UtenButton(
                      onPressed:
                          _busy ||
                              !_canMutate ||
                              _vouchers == null ||
                              _balances == null
                          ? null
                          : () => _act('submit'),
                      child: const Text('提交另一人复核'),
                    ),
                  if (_pending == null && _state == 'SUBMITTED' && _owner)
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy || !_canMutate
                          ? null
                          : () => _act('withdraw'),
                      child: const Text('撤回本次提交'),
                    ),
                  if (_pending == null && _state == 'SUBMITTED' && !_owner) ...[
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy || !_canMutate
                          ? null
                          : () => _act('reject'),
                      child: const Text('退回核对'),
                    ),
                    UtenButton(
                      onPressed: _busy || !_canMutate
                          ? null
                          : () => _act('approve'),
                      child: const Text('复核通过并接续'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        if (_busy)
          const UtenBusyOverlay(
            title: '正在处理原账套接续',
            description: '原批次和请求参数保持不变，结果未确认时请核对原操作。',
          ),
      ],
    ),
  );
}

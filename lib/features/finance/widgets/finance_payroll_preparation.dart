import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import 'finance_payroll_deduction_allocations.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/repositories/task_claim_repository.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../pages/finance_applications_page.dart';

/// Mappings and source references only: original payroll remains the sole amount authority.
class FinancePayrollPreparation extends ConsumerStatefulWidget {
  const FinancePayrollPreparation({
    super.key,
    required this.application,
    this.resumeDraftId,
  });
  final Map<String, dynamic> application;
  final String? resumeDraftId;
  @override
  ConsumerState<FinancePayrollPreparation> createState() =>
      _PayrollPreparationState();
}

class _PayrollPreparationState extends ConsumerState<FinancePayrollPreparation>
    with FormDraftMixin<FinancePayrollPreparation> {
  final _asOf = TextEditingController(), _reference = TextEditingController();
  late final ApiClient _ownerApi = ref.read(apiClientProvider);
  bool get _current =>
      mounted &&
      formDraftIdentityIsCurrent &&
      identical(_ownerApi, ref.read(apiClientProvider));
  final _departments = UtenEditableGridController<_StyleRow>();
  final _allocations =
      <String, UtenEditableGridController<PayrollDeductionAllocationRow>>{};
  final _existing = UtenEditableGridController<_LiabilityRow>();
  Map<String, dynamic> _refs = {},
      _source = {},
      _existingVoucher = {},
      _frozenInstruction = {};
  List<Map<String, dynamic>> _items = [];
  late int _version = (widget.application['row_version'] as num).toInt();
  List<Map<String, dynamic>> _issues = [];
  final Set<String> _evidence = {};
  String _mode = 'NATIVE_APPROVED_PAYROLL';
  String? _wage, _basis, _error;
  bool _loading = true, _saving = false;
  Map<String, dynamic>? _sent;
  TaskClaimSession? _claim;
  String get _id => widget.application['id'].toString();
  bool get _netAlready =>
      _mode == 'EXISTING_CONFIRMED_LIABILITY' &&
      _basis == 'NET_AFTER_DEDUCTIONS';
  bool get _reusedAccrual => _refs['reusedAccrual'] == true;
  bool get _noEvent =>
      ['grossIncome', 'totalDeduction', 'netIncome'].every(
        (key) => financeAmountUnits(_source[key]?.toString()) == BigInt.zero,
      ) &&
      _slips.every(
        (slip) => ['grossIncome', 'totalDeduction', 'netIncome'].every(
          (key) => financeAmountUnits(slip[key]?.toString()) == BigInt.zero,
        ),
      ) &&
      _items.every(
        (item) => financeAmountUnits(item['amount']?.toString()) == BigInt.zero,
      );
  String _issueSource(Object? raw) {
    final source = raw?.toString() ?? '';
    final item = _items.where((item) => item['id'] == source).firstOrNull;
    return item == null
        ? source
        : '${item['employeeCode']} ${item['employeeName']} ${item['code']} ${item['name']}';
  }

  bool get _recognitionOnly =>
      _netAlready &&
      financeAmountUnits(_source['netIncome']?.toString()) == BigInt.zero &&
      (financeAmountUnits(_source['grossIncome']?.toString()) ?? BigInt.zero) >
          BigInt.zero;
  List<Map<String, dynamic>> get _styles =>
      financeApplicationRows(_refs['styles']);
  List<Map<String, dynamic>> get _slips =>
      financeApplicationRows(_source['slips']);
  void _allocationChanged() {
    markFormDraftChanged();
    if (mounted) {
      setState(() {});
    }
  }

  void _seedItems(Map<String, dynamic> instruction) {
    _items = [
      for (final slip in _slips)
        for (final item in financeApplicationRows(slip['items']))
          if (item['type'] == 'DEDUCTION')
            {
              ...item,
              'employeeId': slip['employeeId'],
              'employeeCode': slip['employeeCode'],
              'employeeName': slip['employeeName'],
              'departmentId': slip['departmentId'],
              'departmentName': slip['departmentName'],
            },
    ];
    for (final grid in _allocations.values) {
      grid.dispose();
    }
    _allocations.clear();
    final old = financeApplicationMap(instruction['deductionAllocations']);
    for (final item in _items) {
      final id = item['id'].toString();
      final rows = financeApplicationRows(old[id]);
      _allocations[id] =
          UtenEditableGridController<PayrollDeductionAllocationRow>()
            ..replaceAll(
              rows.isNotEmpty
                  ? [
                      for (final value in rows)
                        PayrollDeductionAllocationRow(
                          item,
                          value,
                          _allocationChanged,
                        ),
                    ]
                  : financeAmountUnits(item['amount']?.toString()) ==
                        BigInt.zero
                  ? []
                  : [
                      PayrollDeductionAllocationRow(item, {
                        'amount': item['amount']?.toString(),
                      }, _allocationChanged),
                    ],
            );
    }
  }

  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeApplicationReview.spec(
        route: '/finance/applications/$_id',
        routeParameters: {'action': 'payroll-preparation'},
        title: '工资付款申请 · 核对工资会计准备',
      );
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
  Iterable<Listenable> get formDraftListenables => [
    _asOf,
    _reference,
    for (final r in _departments.rows) r.style,
    for (final grid in _allocations.values)
      for (final r in grid.rows) ...[r.purpose, r.style, r.amount, r.reference],
    for (final r in _existing.rows) ...[r.local, r.original],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'id': _id,
    'sourceFingerprint': widget.application['source_fingerprint'],
    'version': _version,
    'mode': _mode,
    'wage': _wage,
    'basis': _basis,
    'asOf': _asOf.text,
    'reference': _reference.text,
    'departments': [for (final r in _departments.rows) r.capture()],
    'deductionAllocations': {
      for (final e in _allocations.entries)
        e.key: [for (final row in e.value.rows) row.capture()],
    },
    'originalSource': _source,
    'originalReferences': _refs,
    'frozenInstruction': _frozenInstruction,
    'existing': [for (final r in _existing.rows) r.capture()],
    'existingVoucher': _existingVoucher,
    'evidence': _evidence.toList(),
    'sent': _sent,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['id'] != _id) throw const FormatException('工资草稿对应另一原申请');
    _sent = data['sent'] is Map ? financeApplicationMap(data['sent']) : null;
    _frozenInstruction = financeApplicationMap(data['frozenInstruction']);
    if (_sent == null &&
        (data['sourceFingerprint'] !=
                widget.application['source_fingerprint'] ||
            data['version'] != widget.application['row_version'])) {
      throw const FormatException('原工资或审核版本已变化，原映射保留，请先核对当前事实');
    }
    _mode = data['mode']?.toString() ?? _mode;
    _wage = data['wage']?.toString();
    _basis = data['basis']?.toString();
    _asOf.text = data['asOf']?.toString() ?? '';
    _reference.text = data['reference']?.toString() ?? '';
    for (final r in _departments.rows) {
      final old = financeApplicationRows(
        data['departments'],
      ).where((x) => x['key'] == r.key).firstOrNull;
      r.style.value = old?['styleId']?.toString();
    }
    if (_items.isEmpty && _sent != null) {
      _source = financeApplicationMap(data['originalSource']);
      _refs = financeApplicationMap(data['originalReferences']);
      _seedItems({});
    }
    final allocationData = financeApplicationMap(data['deductionAllocations']);
    for (final e in allocationData.entries) {
      final grid = _allocations[e.key];
      final item = _items.where((r) => r['id'] == e.key).firstOrNull;
      if (grid == null || item == null) {
        throw const FormatException('原工资扣款项目已变化，不能套用到另一项');
      }
      grid.replaceAll([
        for (final value in financeApplicationRows(e.value))
          PayrollDeductionAllocationRow(item, value, _allocationChanged),
      ]);
    }
    _version = (data['version'] as num?)?.toInt() ?? _version;
    _existing.replaceAll(
      financeApplicationRows(
        data['existing'],
      ).map((r) => _LiabilityRow(r, markFormDraftChanged)),
    );
    _existingVoucher = financeApplicationMap(data['existingVoucher']);
    _evidence
      ..clear()
      ..addAll((data['evidence'] as List? ?? []).map((e) => e.toString()));
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    final requested = DateTime.tryParse(
      widget.application['requested_date']?.toString() ?? '',
    );
    if (requested != null && !requested.isAfter(ChinaDateTime.today())) {
      _asOf.text = widget.application['requested_date'].toString();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _claimChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final scope = await captureFormDraftRequestScope();
      _claim = TaskClaimSession(
        ref.read(taskClaimRepositoryProvider),
        strict: true,
        isCurrentSession: () => _current,
      )..addListener(_claimChanged);
      await _claim!.claimAll('FINANCE_APPLICATION_REVIEW', [_id]);
      if (!_claim!.isReady) {
        throw StateError(_claim!.failureMessage ?? '当前工资复核未取得本人有效认领');
      }
      final data = await scope.run(
        () => ref
            .read(apiClientProvider)
            .get(
              '$financeApplicationsApi/$_id/payroll-references',
              query: {
                'sourceFingerprint': widget.application['source_fingerprint'],
                'expectedClaimId': _claim!.claimIdFor(
                  'FINANCE_APPLICATION_REVIEW',
                  _id,
                ),
              },
            ),
      );
      if (!mounted || !scope.isCurrent) return;
      _refs = data;
      _source = financeApplicationMap(data['source']);
      final old = financeApplicationMap(
        _reusedAccrual
            ? financeApplicationMap(data['accrual'])['instruction']
            : widget.application['payroll_instruction'],
      );
      _frozenInstruction = old;
      _seedItems(old);
      _mode = old['mode']?.toString() ?? _mode;
      _wage = old['wagePayableStyleId']?.toString();
      _basis = old['existingLiabilityBasis']?.toString();
      if (old['existingAccrualVoucherId'] != null && _recognitionOnly) {
        _existingVoucher = {
          'voucherId': old['existingAccrualVoucherId'],
          'voucherNo': '已明确原非现金凭证',
        };
      }
      _asOf.text = old['accountingAsOf']?.toString() ?? _asOf.text;
      _reference.text = old['sourceReference']?.toString() ?? '';
      final cost = financeApplicationMap(old['expenseStyleByDepartment']);
      _departments.replaceAll([]);
      final seen = <String>{};
      for (final slip in _slips) {
        final id = slip['departmentId']?.toString();
        if (id != null && seen.add(id)) {
          final label =
              slip['departmentName']?.toString() ??
              financeApplicationRows(
                _refs['departments'],
              ).where((r) => r['id'] == id).firstOrNull?['name']?.toString() ??
              '原部门未记录';
          _departments.addRow(
            _StyleRow(id, label, cost[id]?.toString(), markFormDraftChanged),
          );
        }
      }
      _existing.replaceAll(
        financeApplicationRows(old['existingLiabilityLines']).map(
          (r) => _LiabilityRow({
            'source': r,
            'amountLocal': r['amountLocal'],
            'amountOriginal': r['amountOriginal'],
          }, markFormDraftChanged),
        ),
      );
      _evidence.addAll(
        (old['originalEvidenceIds'] as List? ?? []).map((e) => e.toString()),
      );
      setState(() => _loading = false);
      await initializeFormDraft();
    } catch (e) {
      if (_current) {
        setState(() {
          _loading = false;
          _error = humanErrorMessage(e) ?? '工资会计资料未读取完成';
        });
        if (widget.resumeDraftId != null) {
          try {
            await initializeFormDraft();
          } catch (_) {
            /* The draft guard retains the original checkpoint. */
          }
        }
      }
    }
  }

  Future<Map<String, dynamic>?> _pick({
    required String styleId,
    required String kind,
    String? employeeId,
  }) async {
    if (_saving ||
        _sent != null ||
        !await (_claim?.validateForDecision() ?? Future.value(false))) {
      return null;
    }
    if (!mounted || !_current) return null;
    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1000,
          height: MediaQuery.sizeOf(context).height * .82,
          child: _PayrollGlPicker(
            application: widget.application,
            references: _refs,
            styleId: styleId,
            kind: kind,
            accountingAsOf: _asOf.text,
            claimId: _claim!.claimIdFor('FINANCE_APPLICATION_REVIEW', _id)!,
            employeeId: employeeId,
          ),
        ),
      ),
    );
  }

  Future<void> _addLiability() async {
    if (_wage == null) {
      context.appInfo('请先明确应付工资科目。');
      return;
    }
    final value = await _pick(styleId: _wage!, kind: 'WAGE_LIABILITY');
    if (!mounted || !_current || value == null) return;
    if (_existing.rows.any(
      (r) =>
          r.source['entryId'] == value['entryId'] &&
          r.source['allocationNo'] == value['allocationNo'],
    )) {
      context.appInfo('这份原GL分配已在所选来源中。');
      return;
    }
    _existing.addRow(
      _LiabilityRow({
        'source': value,
        'amountLocal': value['amountLocal'],
        'amountOriginal': value['amountOriginal'],
      }, markFormDraftChanged),
    );
    setState(() {});
    markFormDraftChanged();
  }

  Future<void> _pickExistingVoucher() async {
    if (_wage == null) {
      context.appInfo('请先明确应付工资科目。');
      return;
    }
    final value = await _pick(
      styleId: _wage!,
      kind: 'EXISTING_NON_CASH_VOUCHER',
    );
    if (_current && value != null) {
      setState(() => _existingVoucher = value);
      markFormDraftChanged();
    }
  }

  Future<Map<String, dynamic>?> _deductionSource(
    PayrollDeductionAllocationRow row,
  ) async {
    final style = row.style.value;
    if (style == null || row.purpose.value != 'EMPLOYEE_SETTLEMENT') {
      return null;
    }
    final value = await _pick(
      styleId: style,
      kind: 'DEDUCTION',
      employeeId: row.item['employeeId']?.toString(),
    );
    if (!mounted || !_current || value == null) {
      return null;
    }
    return {
      'auxiliaryId': value['auxiliaryId'],
      'original': {
        'kind': value['kind'] ?? 'GL_ALLOCATION',
        'sourceId': value['kind'] == 'GL_AUXILIARY_BALANCE_POOL'
            ? value['auxiliaryId']
            : value['entryId'],
        'allocationNo': value['allocationNo'],
        'sourceFingerprint': value['sourceFingerprint'],
      },
      'caption': value['voucherNo'] ?? '该员工实际余额池',
      'accountingAsOf': _asOf.text,
    };
  }

  Map<String, dynamic> _payload() => {
    'requestId': const Uuid().v4(),
    'expectedVersion': _version,
    'sourceFingerprint': widget.application['source_fingerprint'],
    'expectedClaimId': _claim?.claimIdFor('FINANCE_APPLICATION_REVIEW', _id),
    'instruction': {
      'mode': _mode,
      'wagePayableStyleId': _wage,
      'expenseStyleByDepartment': _netAlready
          ? <String, dynamic>{}
          : {for (final r in _departments.rows) r.key: r.style.value},
      'deductionStyleByCode': _reusedAccrual && !_netAlready
          ? financeApplicationMap(_frozenInstruction['deductionStyleByCode'])
          : <String, dynamic>{},
      'deductionAllocations': _netAlready
          ? <String, dynamic>{}
          : {
              for (final e in _allocations.entries)
                e.key: [for (final row in e.value.rows) row.instruction()],
            },
      'existingAccrualVoucherId': _recognitionOnly
          ? _existingVoucher['voucherId']
          : _existing.rows.firstOrNull?.source['voucherId'],
      'sourceReference': _reference.text,
      'existingLiabilityBasis': _basis,
      'existingLiabilityLines': [
        for (final r in _existing.rows)
          if (!_recognitionOnly)
            {
              'entryId': r.source['entryId'],
              'allocationNo': r.source['allocationNo'],
              'sourceFingerprint': r.source['sourceFingerprint'],
              'amountLocal': r.local.text.trim(),
              'amountOriginal': r.original.text.trim(),
            },
      ],
      'deductionSettlements': _reusedAccrual && !_netAlready
          ? financeApplicationRows(_frozenInstruction['deductionSettlements'])
          : <Object?>[],
      'originalEvidenceIds': _evidence.toList(),
      'accountingAsOf': _asOf.text.trim(),
    },
  };
  Future<void> _handlePreparation(Map<String, dynamic> value) async {
    if (value['row_version'] is! num) {
      throw const FormatException('原会计准备回执缺少版本，请保留原请求并读取回执');
    }
    final prepared = financeApplicationMap(value['preparation']);
    if (prepared['issues'] is! List) {
      throw const FormatException('原会计准备回执未完整读取，请保留原请求');
    }
    final version = (value['row_version'] as num).toInt();
    if (version > _version) {
      _version = version;
    }
    final issues = financeApplicationRows(prepared['issues']);
    if (issues.isNotEmpty) {
      await resetFormDraftAfterSubmission(
        prepare: () async {
          _sent = null;
          _issues = issues;
        },
      );
      if (mounted) {
        setState(() {});
      }
      await saveFormDraftNow();
      return;
    }
    if (prepared['instructionFingerprint'] is! String) {
      throw const FormatException('原准备凭据尚未核对完成');
    }
    await completeFormDraft();
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _save() async {
    if (_saving || !_current) {
      return;
    }
    setState(() => _saving = true);
    var mayPublish = () => _current;
    try {
      if (_sent == null &&
          !await (_claim?.validateForDecision() ?? Future.value(false))) {
        return;
      }
      final scope = await captureFormDraftRequestScope();
      mayPublish = () => _current && scope.isCurrent;
      if (!mayPublish()) {
        return;
      }
      _sent ??= _payload();
      final value = await runFormDraftSubmission(
        () => scope.run(
          () => ref
              .read(apiClientProvider)
              .post(
                '$financeApplicationsApi/$_id/payroll-preparation',
                body: _sent,
              ),
        ),
      );
      if (!mayPublish()) {
        return;
      }
      await _handlePreparation(value);
    } catch (error) {
      if (mounted && mayPublish()) {
        if (!formDraftHasUnknownSubmission) {
          _sent = null;
        }
        context.appApiError(error, fallback: '工资核对结果待确认，原工资、份额和请求编号已保留');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _receipt() async {
    if (_saving || _sent == null || !_current) {
      return;
    }
    setState(() => _saving = true);
    try {
      final scope = await captureFormDraftRequestScope();
      final result = await scope.run(
        () => ref
            .read(apiClientProvider)
            .get(
              '$financeApplicationsApi/$_id/operations/${_sent!['requestId']}',
            ),
      );
      if (!mounted || !scope.isCurrent) {
        return;
      }
      if (result['found'] == true) {
        await _handlePreparation(financeApplicationMap(result['result']));
      } else {
        context.appInfo('尚未取得已完成回执，继续保留原请求，可原样重试。');
      }
    } catch (error) {
      if (mounted && _current) {
        context.appApiError(error, fallback: '原请求仍待核对，原输入已保留');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  List<UtenDropdownItem> _choices(bool cost) => [
    for (final r in _styles)
      if (cost
          ? r['costAllowed'] == true
          : {'LIABILITY', 'INCOME', 'ACCOUNT'}.contains(r['category']))
        UtenDropdownItem(
          value: r['id'].toString(),
          label: '${r['code']} ${r['name']}',
        ),
  ];
  Widget _mappingGrid(
    UtenEditableGridController<_StyleRow> grid, {
    required bool cost,
    required bool enabled,
  }) => UtenEditableGrid<_StyleRow>(
    controller: grid,
    stickyHeader: false,
    showAddRow: false,
    showRowDelete: false,
    columns: [
      EditableGridColumn(
        key: 'source',
        label: cost ? '原工资部门' : '原扣款项目',
        width: 280,
        textOf: (r) => r.name,
        cellBuilder: (_, r) => Text(r.name),
      ),
      EditableGridColumn(
        key: 'style',
        label: cost ? '费用/制造费用科目' : '扣款科目',
        width: 360,
        listenableOf: (r) => r.style,
        textOf: (r) =>
            _styles
                .where((s) => s['id'] == r.style.value)
                .firstOrNull?['name']
                ?.toString() ??
            '',
        cellBuilder: (_, r) => ValueListenableBuilder(
          valueListenable: r.style,
          builder: (_, value, _) => UtenDropdownField(
            value: value,
            items: _choices(cost),
            enabled: enabled,
            onChanged: enabled
                ? (v) {
                    r.style.value = v;
                    markFormDraftChanged();
                    setState(() {});
                  }
                : (_) {},
          ),
        ),
      ),
    ],
  );
  @override
  void dispose() {
    _claim?.removeListener(_claimChanged);
    unawaited(_claim?.releaseAll() ?? Future.value());
    _claim?.dispose();
    _asOf.dispose();
    _reference.dispose();
    _departments.dispose();
    for (final grid in _allocations.values) {
      grid.dispose();
    }
    _existing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!identical(_ownerApi, ref.watch(apiClientProvider))) {
      return const Center(child: Text('身份或服务器已变化，原草稿保留，请重新进入。'));
    }
    final editable = !_saving && _sent == null && _current;
    final mappingEditable = editable && !_reusedAccrual;
    return withFormDraft(
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              padding: EdgeInsets.zero,
              title: Text(
                '核对工资会计准备',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              showCloseButton: true,
              onClose: _saving ? null : () => Navigator.pop(context),
            ),
            Text('${widget.application['application_no']}　原工资金额不在本页修改'),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        if (_error != null) Text(_error!),
                        if (_claim?.isReady != true)
                          Text(_claim?.failureMessage ?? '当前财务复核未取得本人有效认领'),
                        for (final issue in _issues)
                          Text(
                            '${_issueSource(issue['sourceRow'])} ${issue['message'] ?? ''}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        UtenInput(
                          label: '会计核对截至日期',
                          controller: _asOf,
                          enabled: editable,
                          info: '选择真实已到日期 YYYY-MM-DD；原GL候选与准备使用同一日期',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '原应发：${financeMoneyText(_source['grossIncome']?.toString())}　原扣款：${financeMoneyText(_source['totalDeduction']?.toString())}　原实发：${financeMoneyText(_source['netIncome']?.toString())}',
                        ),
                        if (_noEvent)
                          const Text(
                            '原工资应发、扣款及实发均为0，核对原事实后按无资金事件办理，不生成0元银行流水或凭证。',
                          ),
                        UtenDropdownField(
                          label: '原工资计提方式',
                          value: _mode,
                          items: const [
                            UtenDropdownItem(
                              value: 'NATIVE_APPROVED_PAYROLL',
                              label: '原工资事实计提并清偿',
                            ),
                            UtenDropdownItem(
                              value: 'EXISTING_CONFIRMED_LIABILITY',
                              label: '明确认领既有应付工资分录',
                            ),
                          ],
                          allowClear: false,
                          enabled: mappingEditable,
                          onChanged: mappingEditable
                              ? (v) => setState(() {
                                  if (v != null) _mode = v;
                                  markFormDraftChanged();
                                })
                              : (_) {},
                        ),
                        const SizedBox(height: 12),
                        if (!_noEvent)
                          UtenDropdownField(
                            label: '应付工资科目',
                            value: _wage,
                            items: [
                              for (final r in _styles)
                                if (r['wageAllowed'] == true)
                                  UtenDropdownItem(
                                    value: r['id'].toString(),
                                    label: '${r['code']} ${r['name']}',
                                  ),
                            ],
                            enabled: mappingEditable,
                            onChanged: mappingEditable
                                ? (v) => setState(() {
                                    _wage = v;
                                    markFormDraftChanged();
                                  })
                                : (_) {},
                          ),
                        const SizedBox(height: 12),
                        if (_mode == 'NATIVE_APPROVED_PAYROLL' && !_noEvent)
                          _mappingGrid(
                            _departments,
                            cost: true,
                            enabled: mappingEditable,
                          ),
                        FinancePayrollDeductionSection(
                          items: _items,
                          grids: _allocations,
                          styles: _styles,
                          enabled: mappingEditable,
                          netAlready: _netAlready,
                          reusedAccrual: _reusedAccrual,
                          onChanged: _allocationChanged,
                          onPickSource: _deductionSource,
                        ),
                        if (_mode == 'EXISTING_CONFIRMED_LIABILITY' &&
                            !_noEvent) ...[
                          UtenDropdownField(
                            label: '既有应付工资原始口径',
                            value: _basis,
                            items: const [
                              UtenDropdownItem(
                                value: 'GROSS_BEFORE_DEDUCTIONS',
                                label: '应发总额（扣款前）',
                              ),
                              UtenDropdownItem(
                                value: 'NET_AFTER_DEDUCTIONS',
                                label: '已明确拆分扣款后的实发净额',
                              ),
                            ],
                            enabled: mappingEditable,
                            onChanged: mappingEditable
                                ? (v) => setState(() {
                                    _basis = v;
                                    markFormDraftChanged();
                                  })
                                : (_) {},
                          ),
                          UtenButton(
                            type: UtenButtonType.secondary,
                            onPressed: mappingEditable
                                ? (_recognitionOnly
                                      ? _pickExistingVoucher
                                      : _addLiability)
                                : null,
                            child: Text(
                              _recognitionOnly ? '选择既有非现金原凭证' : '选择明确原应付工资GL来源',
                            ),
                          ),
                          if (_recognitionOnly)
                            Text(
                              '${_existingVoucher['voucherNo'] ?? '尚未选择原凭证'}\n本支线只认领已存在的非现金清偿，核对整张原凭证、扣款科目和员工辅助；原凭证保留，不再预留旧借款或重复清偿。',
                            ),
                          if (!_recognitionOnly)
                            UtenEditableGrid<_LiabilityRow>(
                              controller: _existing,
                              stickyHeader: false,
                              showAddRow: false,
                              showRowDelete: mappingEditable,
                              columns: [
                                EditableGridColumn(
                                  key: 'voucher',
                                  label: '原凭证',
                                  width: 200,
                                  textOf: (r) =>
                                      r.source['voucherNo']?.toString() ??
                                      '已关联原GL',
                                  cellBuilder: (_, r) => Text(
                                    r.source['voucherNo']?.toString() ??
                                        '已关联原GL',
                                  ),
                                ),
                                EditableGridColumn(
                                  key: 'allocation',
                                  label: '原分配编号',
                                  width: 120,
                                  textOf: (r) =>
                                      r.source['allocationNo']?.toString() ??
                                      '',
                                  cellBuilder: (_, r) => Text(
                                    r.source['allocationNo']?.toString() ?? '',
                                  ),
                                ),
                                EditableGridColumn(
                                  key: 'local',
                                  label: '认领账载本币份额',
                                  width: 220,
                                  textOf: (r) => r.local.text,
                                  listenableOf: (r) => r.local,
                                  cellBuilder: (_, r) => UtenInput(
                                    controller: r.local,
                                    enabled: mappingEditable,
                                  ),
                                ),
                                EditableGridColumn(
                                  key: 'original',
                                  label: '认领原币份额',
                                  width: 220,
                                  textOf: (r) => r.original.text,
                                  listenableOf: (r) => r.original,
                                  cellBuilder: (_, r) => UtenInput(
                                    controller: r.original,
                                    enabled: mappingEditable,
                                  ),
                                ),
                              ],
                            ),
                        ],
                        const SizedBox(height: 12),
                        UtenInput(
                          label: '会计准备与原始依据',
                          controller: _reference,
                          enabled: editable,
                          maxLines: 3,
                          required: true,
                        ),
                        for (final evidence in financeApplicationRows(
                          _refs['evidence'],
                        ))
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(evidence['name']?.toString() ?? '原始依据'),
                            value: _evidence.contains(evidence['id']),
                            onChanged: editable
                                ? (value) => setState(() {
                                    value == true
                                        ? _evidence.add(
                                            evidence['id'].toString(),
                                          )
                                        : _evidence.remove(evidence['id']);
                                    markFormDraftChanged();
                                  })
                                : (_) {},
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                if (_sent != null)
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _saving ? null : _receipt,
                    child: const Text('读取原请求回执'),
                  ),
                UtenButton(
                  onPressed:
                      _loading ||
                          _saving ||
                          (_sent == null && _claim?.isReady != true)
                      ? null
                      : _save,
                  child: Text(_sent == null ? '核对并保存原会计准备' : '重试原请求'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StyleRow extends EditableGridRow {
  _StyleRow(this.key, this.name, String? initial, this.changed)
    : style = ValueNotifier(initial) {
    style.addListener(changed);
  }
  final String key, name;
  final ValueNotifier<String?> style;
  final VoidCallback changed;
  Map<String, dynamic> capture() => {'key': key, 'styleId': style.value};
  @override
  void dispose() {
    style.removeListener(changed);
    style.dispose();
    super.dispose();
  }
}

class _LiabilityRow extends EditableGridRow {
  _LiabilityRow(Map<String, dynamic> raw, this.changed)
    : source = financeApplicationMap(raw['source']),
      local = TextEditingController(text: raw['amountLocal']?.toString() ?? ''),
      original = TextEditingController(
        text: raw['amountOriginal']?.toString() ?? '',
      ) {
    local.addListener(changed);
    original.addListener(changed);
  }
  final Map<String, dynamic> source;
  final TextEditingController local, original;
  final VoidCallback changed;
  Map<String, dynamic> capture() => {
    'source': source,
    'amountLocal': local.text,
    'amountOriginal': original.text,
  };
  @override
  void dispose() {
    local.removeListener(changed);
    original.removeListener(changed);
    local.dispose();
    original.dispose();
    super.dispose();
  }
}

class _PayrollGlPicker extends ConsumerStatefulWidget {
  const _PayrollGlPicker({
    required this.application,
    required this.references,
    required this.styleId,
    required this.kind,
    required this.accountingAsOf,
    required this.claimId,
    this.employeeId,
  });
  final Map<String, dynamic> application, references;
  final String styleId, kind, accountingAsOf, claimId;
  final String? employeeId;
  @override
  ConsumerState<_PayrollGlPicker> createState() => _GlPickerState();
}

class _GlPickerState extends ConsumerState<_PayrollGlPicker> {
  String? _employee, _auxiliary, _error;
  String _search = '';
  List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic> _pool = {};
  bool _loading = false, _more = false;
  int _read = 0;
  late final ApiClient _api = ref.read(apiClientProvider);
  late final int _epoch = ref.read(exportContextEpochProvider);
  bool get _current =>
      mounted &&
      ref.read(exportContextEpochProvider) == _epoch &&
      identical(_api, ref.read(apiClientProvider));
  Map<String, dynamic> get _query => {
    'sourceFingerprint': widget.application['source_fingerprint'],
    'expectedClaimId': widget.claimId,
    'styleId': widget.styleId,
    'kind': widget.kind,
    'accountingAsOf': widget.accountingAsOf,
    'auxiliaryId': ?_auxiliary,
    'employeeId': ?_employee,
    'search': _search,
  };
  @override
  void initState() {
    super.initState();
    _employee = widget.employeeId;
    if (_employee != null) {
      final choices = financeApplicationRows(
        widget.references['auxiliaries'],
      ).where((a) => a['employeeId'] == _employee).toList();
      if (choices.length == 1) _auxiliary = choices.single['id']?.toString();
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!_current) return;
    final read = ++_read;
    setState(() {
      _loading = true;
      _rows = [];
      _pool = {};
    });
    try {
      final value = await _api.get(
        '$financeApplicationsApi/${widget.application['id']}/payroll-gl-sources',
        query: _query,
      );
      if (mounted && read == _read && _current) {
        setState(() {
          _rows = financeApplicationRows(value['items']);
          _pool = financeApplicationMap(value['balancePool']);
          _more = value['more'] == true;
          _error = null;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && read == _read && _current) {
        setState(() {
          _error = humanErrorMessage(e) ?? '原GL来源未读取完成';
          _loading = false;
        });
      }
    }
  }

  Future<void> _select(Map<String, dynamic> row) async {
    if (widget.kind == 'EXISTING_NON_CASH_VOUCHER') {
      if (_current && row['ready'] == true) Navigator.pop(context, row);
      return;
    }
    if (_loading || !_current) return;
    final read = ++_read;
    setState(() => _loading = true);
    try {
      final result = await _api.get(
        '$financeApplicationsApi/${widget.application['id']}/payroll-gl-sources',
        query: {
          ..._query,
          'entryId': row['entryId'],
          'allocationNo': row['allocationNo'],
        },
      );
      if (!_current || read != _read) return;
      final selected = financeApplicationRows(result['items'])
          .where(
            (x) =>
                x['entryId'] == row['entryId'] &&
                x['allocationNo'] == row['allocationNo'],
          )
          .firstOrNull;
      if (selected == null) throw const FormatException('原GL来源已变化，请重新核对');
      if (selected['ready'] != true) {
        setState(
          () => _error = financeApplicationRows(
            selected['issues'],
          ).map((x) => x['message']).join('；'),
        );
        return;
      }
      if (mounted) {
        Navigator.pop(context, {
          ...selected,
          'auxiliaryId': _auxiliary,
          'kind': 'GL_ALLOCATION',
        });
      }
    } catch (e) {
      if (_current && read == _read) {
        setState(() => _error = humanErrorMessage(e) ?? '所选原GL来源未核对完成');
      }
    } finally {
      if (_current && read == _read) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenDialogHeader(
              padding: EdgeInsets.zero,
              title: const Text('身份或权限已变化，请关闭后从原申请重新进入。'),
              showCloseButton: true,
              onClose: () => Navigator.pop(context),
            ),
          ],
        ),
      );
    }
    final employees = financeApplicationRows(
      financeApplicationMap(widget.references['source'])['slips'],
    );
    final auxiliaries = financeApplicationRows(
      widget.references['auxiliaries'],
    ).where((a) => a['employeeId'] == _employee).toList();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenDialogHeader(
            padding: EdgeInsets.zero,
            title: Text(
              widget.kind == 'WAGE_LIABILITY'
                  ? '选择明确原工资负债来源'
                  : '选择本工资条员工的真实未结来源',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            showCloseButton: true,
            onClose: () => Navigator.pop(context),
          ),
          const SizedBox(height: 12),
          if (widget.employeeId == null && widget.kind == 'WAGE_LIABILITY')
            UtenDropdownField(
              label: '工资负债归属',
              value: _employee,
              items: [
                const UtenDropdownItem(label: '明确原汇总负债（无员工辅助）'),
                for (final e in employees)
                  UtenDropdownItem(
                    value: e['employeeId'].toString(),
                    label: '${e['employeeCode']} ${e['employeeName']}',
                  ),
              ],
              onChanged: (v) {
                setState(() {
                  _employee = v;
                  _auxiliary = null;
                });
                unawaited(_load());
              },
            ),
          if (_employee != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: UtenDropdownField(
                label: '该员工明确辅助项目',
                value: _auxiliary,
                items: [
                  for (final a in auxiliaries)
                    UtenDropdownItem(
                      value: a['id'].toString(),
                      label: '${a['sourceSystem']} ${a['code']} ${a['name']}',
                    ),
                ],
                onChanged: (v) {
                  setState(() => _auxiliary = v);
                  unawaited(_load());
                },
              ),
            ),
          Row(
            children: [
              Expanded(
                child: UtenInput(
                  label: '原凭证号',
                  onChanged: (v) => _search = v,
                  onFieldSubmitted: (_) => _load(),
                ),
              ),
              const SizedBox(width: 8),
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _loading ? null : _load,
                child: const Text('查询'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          if (_error != null) Text(_error!),
          if (_more) const Text('候选超过100行，请按原凭证号缩小范围。'),
          if (widget.kind == 'DEDUCTION' &&
              _pool['issues'] is List &&
              (_pool['issues'] as List).isEmpty &&
              _pool['fingerprint'] != null)
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => Navigator.pop(context, {
                'auxiliaryId': _auxiliary,
                'kind': 'GL_AUXILIARY_BALANCE_POOL',
                'sourceFingerprint': _pool['fingerprint'],
                'voucherNo': '该员工实际余额池',
              }),
              child: const Text('明确按该员工同币已记账余额池清偿（不认定某张旧单结清）'),
            ),
          Expanded(
            child: MasterDataTableView<Map<String, dynamic>>(
              columns: [
                financeApplicationColumn(
                  'voucherNo',
                  '原凭证号',
                  200,
                  filters: false,
                ),
                financeApplicationColumn(
                  'allocationNo',
                  '辅助分配编号',
                  130,
                  filters: false,
                ),
                financeApplicationColumn('date', '原分录日期', 130, filters: false),
                financeApplicationColumn(
                  'sourceAmountLocal',
                  '原账载本币金额',
                  190,
                  filters: false,
                ),
                financeApplicationColumn(
                  'amountLocal',
                  '现可认领本币上限',
                  210,
                  filters: false,
                ),
                financeApplicationColumn(
                  'amountOriginal',
                  '现可认领原币上限',
                  210,
                  filters: false,
                ),
                MasterColumnDef(
                  key: 'issues',
                  label: '核对提示',
                  width: 360,
                  value: (r) => financeApplicationRows(
                    r['issues'],
                  ).map((x) => x['message']).join('；'),
                  columnSearchEnabled: false,
                ),
              ],
              items: _rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              isLoading: _loading,
              onRowTap: _select,
              showPaginationControls: false,
              showFullscreenToggle: false,
              rowKeyOf: (r) => '${r['entryId']}:${r['allocationNo']}',
            ),
          ),
        ],
      ),
    );
  }
}

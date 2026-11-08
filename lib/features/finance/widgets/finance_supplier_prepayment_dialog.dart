import '../shared/finance_workbench_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/paged_read_intent.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../providers/finance_name_provider.dart';
import 'ar_ap_picker_dialog.dart';
import 'finance_account_picker_panel.dart';
import 'finance_open_item_classification_dialog.dart';
import 'finance_source_table.dart';

/// Original supplier advances use the existing finance table and native selectors.
Future<void> showFinanceSupplierPrepaymentDialog(
  BuildContext context, {
  String? supplierId,
  String? currencyId,
}) => showFinanceWorkbenchPanel<void>(
  context: context,
  builder: (_) =>
      _AdvanceDirectory(supplierId: supplierId, currencyId: currencyId),
);

class _AdvanceDirectory extends ConsumerStatefulWidget {
  const _AdvanceDirectory({this.supplierId, this.currencyId, this.paymentId});
  final String? supplierId, currencyId, paymentId;
  @override
  ConsumerState<_AdvanceDirectory> createState() => _AdvanceDirectoryState();
}

class _AdvanceDirectoryState extends ConsumerState<_AdvanceDirectory>
    with ScopedPagedReadViewMixin<_AdvanceDirectory> {
  @override
  Future<void> onReadViewResumed() => _load();
  late final ApiClient _api;
  late final int _epoch;
  bool _busy = false;
  String? _error;
  String _kind = 'APPLICATION';
  List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic>? _source;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool _can(String permission) =>
      ref.read(currentPermissionsProvider).contains(permission);
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load();
  }

  Future<PagedResult<Map<String, dynamic>>> _fetchSettlements(
    int page,
    int size,
    String? id,
    String kind,
  ) async => PagedResult.fromJsonResponsive<Map<String, dynamic>>(
    await _api.get(
      id == null
          ? '/finance/supplier-prepayments'
          : '/finance/supplier-prepayments/$id/settlements',
      query: {
        'page': page,
        'size': size,
        if (id == null && widget.supplierId != null)
          'supplierId': widget.supplierId,
        if (id == null && widget.currencyId != null)
          'currencyId': widget.currencyId,
        if (id != null) 'kind': kind,
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
      final id = widget.paymentId;
      final kind = _kind;
      final result = await readViewActivity.runRead(() => _current, () async {
        final source = id == null
            ? null
            : await _api.get('/finance/supplier-prepayments/$id');
        if (PagedReadIntent.currentActivity?.call() == false) {
          throw const UiWorkCancelled();
        }
        final complete = await readScopedPage<Map<String, dynamic>>(
          1,
          slot: 'supplier-prepayments',
          idOf: (row) => row[id == null ? 'paymentId' : 'id'],
          query: [_api, id, widget.supplierId, widget.currencyId, kind],
          currentQuery: () => [_api, id, widget.supplierId, widget.currencyId, _kind],
          isCurrent: () => _current,
          fetchPage: (page) async => _fetchSettlements(page, 100, id, kind),
          fetchPageSized: (page, size) async =>
              _fetchSettlements(page, size, id, kind),
        );
        return (source: source, complete: complete);
      });
      if (_current) {
        setState(() {
          _source = result.source;
          _rows = result.complete.items;
        });
      }
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current) {
        setState(() {
          if (pagedReadAccessDenied(e)) {
            _rows = [];
            _source = null;
          }
          _error = _message(e);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    if (!_current || _busy) return;
    if (widget.paymentId == null) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _AdvanceDirectory(paymentId: '${row['paymentId']}'),
      );
    } else {
      final refund = _kind == 'REFUND';
      final status = row['status'];
      if ((!refund && status != 'APPLIED') ||
          (refund && status == 'REVERSED')) {
        await showDialog<void>(
          context: context,
          builder: (_) => UtenAlertDialog(
            showCloseButton: true,
            onClose: () => Navigator.pop(context),

            title: const Text('原处理记录'),
            content: SelectableText(
              '状态：$status\n原币：${_exact(row, 'amount_original')}\n账面本币：${_exact(row, 'source_local')}\n来源依据：${row['source_reference'] ?? ''}',
            ),
          ),
        );
      } else {
        final mode = refund
            ? (status == 'DRAFT' ? 'REFUND_APPROVE' : 'REFUND_REVERSE')
            : 'APPLICATION_REVERSE';
        await _command(mode, selected: row);
      }
    }
    if (_current) await _load();
  }

  Future<void> _classify() async {
    if (!_current || _busy || widget.paymentId == null) return;
    await showFinancePrepaymentClassificationDialog(
      context,
      paymentId: widget.paymentId!,
    );
    if (_current) await _load();
  }

  Future<void> _command(String mode, {Map<String, dynamic>? selected}) async {
    if (!_current || _busy || _source == null) return;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _AdvanceCommand(source: _source!, mode: mode, selected: selected),
    );
    if (_current) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) return _lost(context);
    final detail = widget.paymentId != null;
    final permissions = ref.watch(currentPermissionsProvider);
    final canApply =
        permissions.contains(Perm.supplierSettlementConfirm) &&
        permissions.contains(Perm.financePaymentApprove);
    return Stack(
      children: [
        UtenDialogFrame(
          maxWidth: 1150,
          fillHeight: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenDialogHeader(
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        detail
                            ? '供应商预付款 ${_source?['billNo'] ?? ''}'
                            : '供应商预付款',
                      ),
                    ),
                    UtenFieldHintIcon(
                      info:
                          _error ?? '原预付资产与正式应付分别记账；应用不重复付款，目标当前归属另存，资产来源只计一次。',
                    ),
                  ],
                ),
                showCloseButton: true,
                onClose: _busy ? null : () => Navigator.pop(context),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_source != null)
                      SelectableText(
                        '原币：${_source!['currencyName'] ?? ''}  未应用原币：${_source!['remainingOriginal']}  未应用账面本币：${_source!['remainingLocal']}',
                      ),
                    if (detail)
                      UtenDropdownField(
                        label: '处理记录',
                        value: _kind,
                        allowClear: false,
                        enabled: !_busy,
                        items: const [
                          UtenDropdownItem(value: 'APPLICATION', label: '预付应用'),
                          UtenDropdownItem(value: 'REFUND', label: '预付退款'),
                        ],
                        onChanged: (v) {
                          if (!_busy && v != null) {
                            setState(() => _kind = v);
                            _load();
                          }
                        },
                      ),
                  ],
                ),
              ),
              Expanded(
                child: financeSourceTable(
                  tableKey: detail
                      ? 'finance.supplier-prepayment.$_kind'
                      : 'finance.supplier-prepayment.sources',
                  columns: detail
                      ? [
                          financeSourceColumn(
                            'created_at',
                            '登记时间',
                            type: 'date',
                            width: 190,
                          ),
                          financeSourceColumn(
                            'status',
                            '状态',
                            value: (r) => switch (r['status']) {
                              'DRAFT' => '待审核',
                              'APPROVED' || 'APPLIED' => '已生效',
                              'REVERSED' => '已反审',
                              _ => '${r['status'] ?? ''}',
                            },
                          ),
                          financeSourceColumn(
                            'source_category',
                            '原预付类别',
                            value: (r) =>
                                r['source_category'] == 'GOODS' ? '货款' : '模具款',
                          ),
                          financeSourceColumn(
                            'amount_original',
                            '原币金额',
                            type: 'money',
                          ),
                          financeSourceColumn(
                            'source_local',
                            '原预付账面本币',
                            type: 'money',
                            width: 180,
                          ),
                          if (_kind == 'APPLICATION')
                            financeSourceColumn(
                              'target_category',
                              '原目标归属',
                              value: (r) => r['target_category'] == 'GOODS'
                                  ? '货款'
                                  : '模具款',
                            ),
                          if (_kind == 'APPLICATION')
                            financeSourceColumn(
                              'effectiveTargetParts',
                              '当前目标归属',
                              width: 380,
                              value: (r) => _maps(r['effectiveTargetParts'])
                                  .map(
                                    (p) =>
                                        '${const {'GOODS': '货款', 'MOULD': '模具款'}[p['category']] ?? '待核对'} 原币${p['amountOriginalExact'] ?? p['amountOriginal']} / 账面${p['targetLocalExact'] ?? p['targetLocal']}',
                                  )
                                  .join('；'),
                            ),
                          if (_kind == 'APPLICATION')
                            financeSourceColumn(
                              'target_local',
                              '应付账面本币',
                              type: 'money',
                            ),
                          financeSourceColumn(
                            'source_reference',
                            '来源依据',
                            width: 280,
                          ),
                        ]
                      : [
                          financeSourceColumn('billNo', '付款单号', width: 220),
                          financeSourceColumn('billDate', '日期', type: 'date'),
                          financeSourceColumn('supplierCode', '供应商编号'),
                          financeSourceColumn(
                            'supplierName',
                            '供应商名称',
                            width: 220,
                          ),
                          financeSourceColumn('currencyCode', '原币'),
                          financeSourceColumn(
                            'amountOriginal',
                            '原币金额',
                            type: 'money',
                          ),
                          financeSourceColumn(
                            'amountLocal',
                            '账面本币',
                            type: 'money',
                          ),
                          financeSourceColumn(
                            'status',
                            '状态',
                            value: (r) => r['status'] == 'OPEN' ? '有效' : '已反审',
                          ),
                        ],
                  rows: _rows,
                  idOf: (r) => '${r[detail ? 'id' : 'paymentId']}',
                  busy: _busy,
                  error: _error,
                  retry: _load,
                  scope: (
                    _epoch,
                    widget.paymentId,
                    widget.supplierId,
                    widget.currencyId,
                    _kind,
                  ),
                  onOpen: _open,
                  canOpen: (_) => !_busy,
                  actions: [
                    if (detail && canApply)
                      UtenButton(
                        onPressed: _busy || _source?['status'] != 'OPEN'
                            ? null
                            : _classify,
                        child: const Text('货款/模具款分类'),
                      ),
                    if (detail && canApply)
                      UtenButton(
                        onPressed: _busy || _source?['status'] != 'OPEN'
                            ? null
                            : () => _command('APPLICATION'),
                        child: const Text('应用到应付'),
                      ),
                    if (detail && _can(Perm.financeReceiptCreate))
                      UtenButton(
                        onPressed: _busy || _source?['status'] != 'OPEN'
                            ? null
                            : () => _command('REFUND_DRAFT'),
                        child: const Text('登记实际退款'),
                      ),
                    UtenButton(
                      onPressed: _busy ? null : _load,
                      child: const Text('刷新'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_busy)
          const UtenBusyOverlay(title: '正在核对实际预付处理', showDoNotLeaveHint: false),
      ],
    );
  }
}

class _AdvanceCommand extends ConsumerStatefulWidget {
  const _AdvanceCommand({
    required this.source,
    required this.mode,
    this.selected,
  });
  final Map<String, dynamic> source;
  final String mode;
  final Map<String, dynamic>? selected;
  @override
  ConsumerState<_AdvanceCommand> createState() => _AdvanceCommandState();
}

class _AdvanceCommandState extends ConsumerState<_AdvanceCommand> {
  late final ApiClient _api;
  late final int _epoch;
  final _id = const Uuid().v4();
  final _amount = TextEditingController(),
      _reason = TextEditingController(),
      _bankAmount = TextEditingController(),
      _bankRate = TextEditingController(),
      _bankFee = TextEditingController(text: '0'),
      _bankReference = TextEditingController(),
      _bankDate = TextEditingController();
  String? _sourceCategory, _targetCategory, _error, _pendingPath;
  AppliedArAp? _target;
  FinanceAccountReference? _account;
  Map<String, dynamic>? _pending;
  bool _busy = false, _unknown = false, _dirty = false;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _application => widget.mode == 'APPLICATION';
  bool get _refundDraft => widget.mode == 'REFUND_DRAFT';
  bool get _reverse => widget.mode.endsWith('_REVERSE');
  String get _title => switch (widget.mode) {
    'APPLICATION' => '预付应用到应付',
    'REFUND_DRAFT' => '登记实际退款',
    'REFUND_APPROVE' => '审核实际退款',
    'REFUND_REVERSE' => '反审实际退款',
    _ => '反审预付应用',
  };
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
  }

  @override
  void dispose() {
    for (final c in [
      _amount,
      _reason,
      _bankAmount,
      _bankRate,
      _bankFee,
      _bankReference,
      _bankDate,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickTarget() async {
    if (_busy || _unknown) return;
    final selected = await showArApPickerDialog(
      context,
      ref,
      direction: 'AP',
      partyId: '${widget.source['supplierId']}',
      lockedCurrencyId: '${widget.source['currencyId']}',
    );
    if (!_current || selected == null) return;
    if (selected.length != 1) {
      setState(() => _error = '每次请选择一笔明确的正式应付；多笔可分次应用');
      return;
    }
    setState(() {
      _target = selected.single;
      _amount.text = selected.single.receiptAmountText;
      _dirty = true;
    });
  }

  Future<void> _pickAccount() async {
    if (_busy || _unknown) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final names = ref.read(financeNameServiceProvider);
      await names.ensureLoaded(
        refreshAccounts: true,
        includeCounterparties: false,
      );
      if (!mounted || !_current) return;
      final id = await showFinanceAccountPickerPanel(
        context: context,
        accounts: names.accountReferences.values.toList(),
        selectedId: _account?.id,
        title: '选择退款实际到账账户',
      );
      if (_current && id != null) {
        setState(() {
          _account = names.accountReference(id);
          _dirty = true;
        });
      }
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_current || _busy) return;
    if (!_unknown) {
      final id = '${widget.source['payment_id']}';
      if ((_application || _refundDraft || _reverse) &&
          _reason.text.trim().isEmpty) {
        setState(() => _error = '请填写明确来源或反审依据');
        return;
      }
      if ((_application || _refundDraft) &&
          (_sourceCategory == null || !_decimal(_amount.text))) {
        setState(() => _error = '请选择原预付类别并填写准确原币金额');
        return;
      }
      if (_application) {
        if (_target == null || _targetCategory == null) {
          setState(() => _error = '请选择真实正式应付和明确目标类别');
          return;
        }
        _pendingPath = '/finance/supplier-prepayments/$id/applications';
        _pending = {
          'requestId': _id,
          'payableId': _target!.ledgerId,
          'sourceCategory': _sourceCategory,
          'targetCategory': _targetCategory,
          'amountOriginal': _amount.text.trim(),
          'sourceReference': _reason.text,
        };
      } else if (_refundDraft) {
        if (_account == null ||
            !_decimal(_bankAmount.text) ||
            !_decimal(_bankRate.text) ||
            !_decimal(_bankFee.text) ||
            DateTime.tryParse(_bankDate.text.trim()) == null ||
            !RegExp(r'(?:Z|[+-]\d\d:\d\d)$').hasMatch(_bankDate.text.trim()) ||
            _bankReference.text.trim().isEmpty) {
          setState(() => _error = '请按实际回单填写账户、到账、手续费、汇率、流水号和含时区的入账时间');
          return;
        }
        _pendingPath = '/finance/supplier-prepayments/$id/refunds';
        _pending = {
          'requestId': _id,
          'sourceCategory': _sourceCategory,
          'amountOriginal': _amount.text.trim(),
          'accountId': _account!.id,
          'accountCurrencyId': _account!.currencyId,
          'bankAmount': _bankAmount.text.trim(),
          'bankRate': _bankRate.text.trim(),
          'bankFeeAmount': _bankFee.text.trim(),
          'bankReference': _bankReference.text,
          'bankBookedAt': _bankDate.text.trim(),
          'sourceReference': _reason.text,
        };
      } else {
        final selected = '${widget.selected!['id']}';
        _pendingPath = widget.mode == 'APPLICATION_REVERSE'
            ? '/finance/supplier-prepayments/applications/$selected/reverse'
            : '/finance/supplier-prepayments/refunds/$selected/${_reverse ? 'reverse' : 'approve'}';
        _pending = _reverse ? {'reason': _reason.text} : {};
      }
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.post(_pendingPath!, body: _pending);
      if (mounted && _current) Navigator.pop(context, true);
    } catch (e) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(e);
          _error = _unknown
              ? '${_message(e)}。原提交和金额已保留，请核对并重试原请求。'
              : _message(e);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_busy || _unknown) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialog) => UtenAlertDialog(
          title: const Text('放弃未保存内容？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('继续填写'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) return _lost(context);
    final enabled = !_busy && !_unknown;
    final permission = _refundDraft
        ? Perm.financeReceiptCreate
        : widget.mode == 'REFUND_APPROVE'
        ? Perm.financeReceiptApprove
        : widget.mode == 'REFUND_REVERSE'
        ? Perm.financeReceiptReverse
        : Perm.supplierSettlementConfirm;
    final canWrite =
        ref.watch(currentPermissionsProvider).contains(permission) &&
        ((!_application && widget.mode != 'APPLICATION_REVERSE') ||
            ref
                .watch(currentPermissionsProvider)
                .contains(Perm.financePaymentApprove));
    return Stack(
      children: [
        UtenDialogFrame(
          maxWidth: 720,
          fillHeight: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenDialogHeader(
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(_title)),
                    UtenFieldHintIcon(
                      info: _error ?? '按原付款的真实原币、资产和应付账面分别核对，当前汇率不覆盖原事实。',
                    ),
                  ],
                ),
                showCloseButton: true,
                onClose: enabled ? _close : null,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SelectableText(
                        '原付款：${widget.source['billNo']}\n原币单位：${widget.source['currencyName']}',
                      ),
                      if (_application || _refundDraft) ...[
                        UtenDropdownField(
                          label: '原预付类别',
                          value: _sourceCategory,
                          allowClear: false,
                          enabled: enabled,
                          items: const [
                            UtenDropdownItem(value: 'GOODS', label: '货款'),
                            UtenDropdownItem(value: 'MOULD', label: '模具款'),
                          ],
                          onChanged: (v) {
                            if (enabled) {
                              setState(() {
                                _sourceCategory = v;
                                _dirty = true;
                              });
                            }
                          },
                        ),
                        if (_application) ...[
                          UtenButton(
                            onPressed: enabled ? _pickTarget : null,
                            child: Text(
                              _target == null
                                  ? '选择正式应付'
                                  : '${_target!.appliedBillNo}',
                            ),
                          ),
                          if (_target != null)
                            TextButton(
                              onPressed: enabled
                                  ? () =>
                                        showFinanceOpenItemClassificationDialog(
                                          context,
                                          ledgerId: _target!.ledgerId,
                                        )
                                  : null,
                              child: const Text('核对目标应付货款/模具款分类'),
                            ),
                          UtenDropdownField(
                            label: '目标应付类别',
                            value: _targetCategory,
                            allowClear: false,
                            enabled: enabled,
                            items: const [
                              UtenDropdownItem(value: 'GOODS', label: '货款'),
                              UtenDropdownItem(value: 'MOULD', label: '模具款'),
                            ],
                            onChanged: (v) {
                              if (enabled) {
                                setState(() {
                                  _targetCategory = v;
                                  _dirty = true;
                                });
                              }
                            },
                          ),
                        ],
                        UtenInput(
                          label: _application ? '本次应用原币' : '实际退回原币总额',
                          controller: _amount,
                          enabled: enabled,
                          aiSensitive: true,
                          onChanged: (_) => _dirty = true,
                        ),
                      ],
                      if (_refundDraft) ...[
                        UtenButton(
                          onPressed: enabled ? _pickAccount : null,
                          child: Text(
                            _account == null
                                ? '选择退款实际到账账户'
                                : '${_account!.code ?? ''} ${_account!.name ?? ''} ${_account!.currencyName ?? ''}',
                          ),
                        ),
                        UtenInput(
                          label: '银行实际净到账（账户币别）',
                          controller: _bankAmount,
                          enabled: enabled,
                          aiSensitive: true,
                          onChanged: (_) => _dirty = true,
                        ),
                        UtenInput(
                          label: '实际手续费（同账户币别）',
                          controller: _bankFee,
                          enabled: enabled,
                          aiSensitive: true,
                          onChanged: (_) => _dirty = true,
                        ),
                        UtenInput(
                          label: '实际账户币别折本币汇率',
                          controller: _bankRate,
                          enabled: enabled,
                          aiSensitive: true,
                          onChanged: (_) => _dirty = true,
                        ),
                        UtenInput(
                          label: '银行流水号',
                          controller: _bankReference,
                          enabled: enabled,
                          aiSensitive: true,
                          onChanged: (_) => _dirty = true,
                        ),
                        UtenInput(
                          label: '银行入账时间（如2026-11-03T14:20:00+08:00）',
                          controller: _bankDate,
                          enabled: enabled,
                          onChanged: (_) => _dirty = true,
                        ),
                      ],
                      if (widget.selected != null)
                        SelectableText(
                          '原币：${_exact(widget.selected!, 'amount_original')}\n原预付账面本币：${_exact(widget.selected!, 'source_local')}\n实际银行到账：${_exact(widget.selected!, 'bank_amount')}\n原依据：${widget.selected!['source_reference']}',
                        ),
                      if (_application || _refundDraft || _reverse)
                        UtenInput(
                          label: _reverse ? '反审依据' : '来源依据',
                          controller: _reason,
                          enabled: enabled,
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
                    onPressed: enabled ? _close : null,
                    child: const Text('取消'),
                  ),
                  UtenButton(
                    onPressed: _busy || !canWrite ? null : _submit,
                    child: Text(_unknown ? '核对并重试原请求' : _title),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_busy)
          const UtenBusyOverlay(title: '正在核对实际预付处理', showDoNotLeaveHint: false),
      ],
    );
  }
}

List<Map<String, dynamic>> _maps(dynamic value) => value is List
    ? value
          .whereType<Map<dynamic, dynamic>>()
          .map((r) => Map<String, dynamic>.from(r))
          .toList()
    : [];
String _exact(Map<String, dynamic> row, String key) =>
    '${row['${key}Exact'] ?? row[key] ?? '待核对'}';
bool _decimal(String value) =>
    RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value.trim());
String _message(Object error) =>
    error is ApiException ? error.message : error.toString();
bool _rejected(Object error) =>
    error is ApiException &&
    error.hasResponseCode &&
    (error.httpStatus ?? 0) >= 400 &&
    (error.httpStatus ?? 0) < 500 &&
    error.httpStatus != 408;
Widget _lost(BuildContext context) => UtenAlertDialog(
  showCloseButton: true,
  onClose: () => Navigator.pop(context),

  title: const Text('访问范围已变化'),
);

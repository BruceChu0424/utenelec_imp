import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../basic_data/models/account_node.dart';
import '../../../basic_data/repositories/account_repository.dart';
import '../models/finance_payable.dart';
import '../models/subcontract_loss_claim.dart';
import '../repositories/finance_payables_repository.dart';

class SubcontractLossDecisionDraft {
  const SubcontractLossDecisionDraft({
    required this.disputed,
    required this.reason,
    required this.resolutions,
  });

  final bool disputed;
  final String reason;
  final List<SubcontractLossResolutionInput> resolutions;
}

class SubcontractLossFulfillmentDraft {
  const SubcontractLossFulfillmentDraft({
    required this.fulfilledQuantity,
    this.fulfilledAmountLocal,
    required this.evidenceReference,
    this.fulfillmentDocType,
    this.fulfillmentDocId,
    this.fulfillmentDocItemId,
    this.fulfillmentDocNo,
    this.accountId,
    this.cashReceiptDate,
    this.note,
  });

  final String fulfilledQuantity;
  final String? fulfilledAmountLocal;
  final String evidenceReference;
  final String? fulfillmentDocType;
  final String? fulfillmentDocId;
  final String? fulfillmentDocItemId;
  final String? fulfillmentDocNo;
  final String? accountId;
  final String? cashReceiptDate;
  final String? note;
}

Future<SubcontractLossDecisionDraft?> showSubcontractLossDecisionPanel({
  required BuildContext context,
  required SubcontractLossClaimDetail detail,
}) => showUtenAdaptivePanel<SubcontractLossDecisionDraft>(
  context: context,
  drawerWidth: 940,
  compactHeightFactor: 0.96,
  barrierDismissible: false,
  panelElevation: 16,
  builder: (_) => _LossDecisionEditor(detail: detail),
);

Future<SubcontractLossFulfillmentDraft?> showSubcontractLossFulfillmentPanel({
  required BuildContext context,
  required SubcontractLossResolution resolution,
}) => showUtenAdaptivePanel<SubcontractLossFulfillmentDraft>(
  context: context,
  drawerWidth: 560,
  compactHeightFactor: 0.92,
  barrierDismissible: false,
  panelElevation: 16,
  builder: (_) => _LossFulfillmentEditor(resolution: resolution),
);

Future<String?> showSubcontractLossReasonDialog({
  required BuildContext context,
  required String title,
  required String label,
}) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 2000,
          maxLines: 4,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final reason = controller.text.trim();
              if (reason.isEmpty) return;
              Navigator.of(dialogContext).pop(reason);
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

class _ResolutionDraft {
  _ResolutionDraft({required this.line, required String quantity})
    : quantity = TextEditingController(text: quantity),
      amount = TextEditingController(),
      note = TextEditingController();

  final SubcontractLossClaimLine line;
  String? type;
  final TextEditingController quantity;
  final TextEditingController amount;
  final TextEditingController note;
  DateTime? dueDate;
  List<SubcontractLossOffsetTarget> offsetTargets = const [];

  void dispose() {
    quantity.dispose();
    amount.dispose();
    note.dispose();
  }
}

class _LossDecisionEditor extends ConsumerStatefulWidget {
  const _LossDecisionEditor({required this.detail});

  final SubcontractLossClaimDetail detail;

  @override
  ConsumerState<_LossDecisionEditor> createState() =>
      _LossDecisionEditorState();
}

class _LossDecisionEditorState extends ConsumerState<_LossDecisionEditor> {
  final _reason = TextEditingController();
  late final Map<String, List<_ResolutionDraft>> _drafts;
  bool _disputed = false;

  @override
  void initState() {
    super.initState();
    _drafts = {
      for (final line in widget.detail.lines)
        line.id: [
          _ResolutionDraft(line: line, quantity: line.excessLossQty ?? '0'),
        ],
    };
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final drafts in _drafts.values) {
      for (final draft in drafts) {
        draft.dispose();
      }
    }
    super.dispose();
  }

  String _fmtDate(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  void _add(SubcontractLossClaimLine line) {
    setState(() {
      _drafts[line.id]!.add(_ResolutionDraft(line: line, quantity: '0'));
    });
  }

  void _remove(String lineId, _ResolutionDraft draft) {
    if (_drafts[lineId]!.length == 1) return;
    setState(() => _drafts[lineId]!.remove(draft));
    draft.dispose();
  }

  Future<void> _pickDueDate(_ResolutionDraft draft) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: draft.dueDate ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => draft.dueDate = picked);
  }

  Future<void> _pickOffsets(_ResolutionDraft draft) async {
    final targets =
        await showUtenAdaptivePanel<List<SubcontractLossOffsetTarget>>(
          context: context,
          drawerWidth: 760,
          compactHeightFactor: 0.92,
          panelElevation: 18,
          builder: (_) => _OffsetTargetPicker(
            supplierId: widget.detail.summary.supplierId,
            initial: draft.offsetTargets,
          ),
        );
    if (targets != null && mounted) {
      setState(() => draft.offsetTargets = targets);
    }
  }

  void _submit() {
    final reason = _reason.text.trim();
    if (reason.isEmpty) {
      context.appError(_disputed ? '请填写争议原因' : '请填写责任决定说明');
      return;
    }
    if (_disputed) {
      Navigator.of(context).pop(
        SubcontractLossDecisionDraft(
          disputed: true,
          reason: reason,
          resolutions: const [],
        ),
      );
      return;
    }

    final resolutions = <SubcontractLossResolutionInput>[];
    for (final line in widget.detail.lines) {
      final expected = financeDecimalUnits(line.excessLossQty);
      if (expected == null) {
        context.appError('${line.goodsLabel} 的服务端超耗数量无效');
        return;
      }
      var allocated = BigInt.zero;
      for (final draft in _drafts[line.id]!) {
        final type = draft.type;
        if (type == null) {
          context.appError('请选择 ${line.goodsLabel} 的处理方案');
          return;
        }
        final quantity = financeDecimalUnits(draft.quantity.text);
        if (quantity == null || quantity.isNegative) {
          context.appError('${line.goodsLabel} 的处理数量必须是最多四位小数的非负数');
          return;
        }
        allocated += quantity;

        String? amount;
        if (SubcontractLossResolutionType.moneyTypes.contains(type)) {
          final amountUnits = financeDecimalUnits(draft.amount.text);
          if (amountUnits == null || amountUnits <= BigInt.zero) {
            context.appError(
              '${subcontractLossResolutionTypeLabel(type)}金额必须大于 0',
            );
            return;
          }
          amount = draft.amount.text.trim();
        }
        if (SubcontractLossResolutionType.offsetTypes.contains(type)) {
          if (draft.offsetTargets.isEmpty) {
            context.appError(
              '${subcontractLossResolutionTypeLabel(type)}必须逐笔选择正应付',
            );
            return;
          }
          final targetTotal = draft.offsetTargets.fold<BigInt>(
            BigInt.zero,
            (sum, target) =>
                sum +
                (financeDecimalUnits(target.amountOriginal) ?? BigInt.zero),
          );
          if (targetTotal != financeDecimalUnits(amount)) {
            context.appError('抵销目标原币合计必须等于处理金额');
            return;
          }
        }
        resolutions.add(
          SubcontractLossResolutionInput(
            caseLineId: line.id,
            type: type,
            quantity: draft.quantity.text.trim(),
            amountLocal: amount,
            dueDate: draft.dueDate == null ? null : _fmtDate(draft.dueDate!),
            note: draft.note.text,
            offsetTargets: draft.offsetTargets,
          ),
        );
      }
      if (allocated != expected) {
        context.appError(
          '${line.goodsLabel} 的各方案数量合计必须等于超耗量 ${line.excessLossQty}',
        );
        return;
      }
    }
    Navigator.of(context).pop(
      SubcontractLossDecisionDraft(
        disputed: false,
        reason: reason,
        resolutions: resolutions,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('委外超耗责任决定'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          children: [
            SwitchListTile.adaptive(
              value: _disputed,
              title: const Text('标记为争议'),
              subtitle: const Text('争议状态不生成赔偿、折让或抵销方案'),
              onChanged: (value) => setState(() => _disputed = value),
            ),
            TextField(
              controller: _reason,
              maxLength: 2000,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: _disputed ? '争议原因（必填）' : '责任决定说明（必填）',
              ),
            ),
            if (!_disputed) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '逐行责任方案',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              for (final line in widget.detail.lines) _lineCard(theme, line),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: UtenSpacing.s8),
              UtenButton(
                icon: _disputed
                    ? Icons.report_problem_outlined
                    : Icons.fact_check_outlined,
                onPressed: _submit,
                child: Text(_disputed ? '提交争议' : '提交责任决定'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lineCard(ThemeData theme, SubcontractLossClaimLine line) {
    final drafts = _drafts[line.id]!;
    return Card(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              line.goodsLabel.isEmpty ? '未命名材料' : line.goodsLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '实际 ${line.actualLossQty ?? '—'} · 允许 ${line.allowedLossQty ?? '—'}'
              ' · 超耗 ${line.excessLossQty ?? '—'} · 账面损失 ¥${line.lossBookValueLocal ?? '—'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            for (final draft in drafts)
              _resolutionEditor(theme, line.id, draft),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _add(line),
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加混合方案'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resolutionEditor(
    ThemeData theme,
    String lineId,
    _ResolutionDraft draft,
  ) {
    final money = SubcontractLossResolutionType.moneyTypes.contains(draft.type);
    final offset = SubcontractLossResolutionType.offsetTypes.contains(
      draft.type,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(UtenRadius.md),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  initialValue: draft.type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '处理方案'),
                  items: [
                    for (final type in SubcontractLossResolutionType.values)
                      DropdownMenuItem(
                        value: type,
                        child: Text(subcontractLossResolutionTypeLabel(type)),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    draft.type = value;
                    draft.offsetTargets = const [];
                  }),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextField(
                  controller: draft.quantity,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '处理数量'),
                ),
              ),
              if (_drafts[lineId]!.length > 1)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: '移除此方案',
                  onPressed: () => _remove(lineId, draft),
                ),
            ],
          ),
          if (money) ...[
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: draft.amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '处理金额（本币）'),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => _pickDueDate(draft),
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(
                  draft.dueDate == null ? '约定履约日期' : _fmtDate(draft.dueDate!),
                ),
              ),
              if (offset) ...[
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickOffsets(draft),
                    icon: const Icon(Icons.link_rounded, size: 18),
                    label: Text(
                      draft.offsetTargets.isEmpty
                          ? '选择同供应商正应付'
                          : '已选 ${draft.offsetTargets.length} 笔抵销目标',
                    ),
                  ),
                ),
              ],
            ],
          ),
          TextField(
            controller: draft.note,
            maxLines: 2,
            decoration: const InputDecoration(labelText: '方案说明'),
          ),
        ],
      ),
    );
  }
}

class _OffsetTargetPicker extends ConsumerStatefulWidget {
  const _OffsetTargetPicker({required this.supplierId, required this.initial});

  final String supplierId;
  final List<SubcontractLossOffsetTarget> initial;

  @override
  ConsumerState<_OffsetTargetPicker> createState() =>
      _OffsetTargetPickerState();
}

class _OffsetTargetPickerState extends ConsumerState<_OffsetTargetPicker> {
  List<FinancePayableItem> _items = const [];
  final Map<String, TextEditingController> _amounts = {};
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final target in widget.initial) {
      _selected.add(target.payableId);
      _amounts[target.payableId] = TextEditingController(
        text: target.amountOriginal,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final controller in _amounts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await ref
          .read(financePayablesRepositoryProvider)
          .list(
            size: 200,
            filter: FinancePayablesFilter(supplierId: widget.supplierId),
          );
      if (!mounted) return;
      setState(() {
        _items = result.items
            .where(
              (item) =>
                  item.openItemKind == 'PAYABLE' && item.status != 'SETTLED',
            )
            .toList(growable: false);
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载可抵销应付失败';
      });
    }
  }

  void _confirm() {
    final result = <SubcontractLossOffsetTarget>[];
    for (final id in _selected) {
      final amount = _amounts[id]?.text.trim() ?? '';
      final units = financeDecimalUnits(amount);
      if (units == null || units <= BigInt.zero) {
        context.appError('每笔抵销原币金额必须大于 0');
        return;
      }
      result.add(
        SubcontractLossOffsetTarget(payableId: id, amountOriginal: amount),
      );
    }
    if (result.isEmpty) {
      context.appError('请至少选择一笔同供应商正应付');
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择抵销目标'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : _error != null
          ? Center(child: Text(_error!))
          : _items.isEmpty
          ? const Center(child: Text('该委外商暂无可抵销的正应付'))
          : ListView.separated(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = _items[index];
                final selected = _selected.contains(item.id);
                final controller = _amounts.putIfAbsent(
                  item.id,
                  () => TextEditingController(),
                );
                return CheckboxListTile(
                  value: selected,
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _selected.add(item.id);
                      if (controller.text.isEmpty) {
                        controller.text = item.outstandingOriginal ?? '';
                      }
                    } else {
                      _selected.remove(item.id);
                    }
                  }),
                  title: Text(
                    '${item.sourceDocNo ?? '—'} · ${item.sourceTypeLabel}',
                  ),
                  subtitle: Text(
                    '未付 ${item.currencyCode ?? ''} ${item.outstandingOriginal ?? '—'}',
                  ),
                  secondary: SizedBox(
                    width: 150,
                    child: TextField(
                      controller: controller,
                      enabled: selected,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: '抵销原币金额',
                      ),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenButton(
            icon: Icons.check_rounded,
            onPressed: _loading ? null : _confirm,
            child: Text('确认选择 (${_selected.length})'),
          ),
        ),
      ),
    );
  }
}

class _LossFulfillmentEditor extends ConsumerStatefulWidget {
  const _LossFulfillmentEditor({required this.resolution});

  final SubcontractLossResolution resolution;

  @override
  ConsumerState<_LossFulfillmentEditor> createState() =>
      _LossFulfillmentEditorState();
}

class _LossFulfillmentEditorState
    extends ConsumerState<_LossFulfillmentEditor> {
  late final TextEditingController _quantity;
  late final TextEditingController _amount;
  final _evidence = TextEditingController();
  final _docId = TextEditingController();
  final _docItemId = TextEditingController();
  final _docNo = TextEditingController();
  final _note = TextEditingController();
  List<AccountListItem> _cashAccounts = const [];
  String? _accountId;
  DateTime _cashReceiptDate = DateTime.now();
  bool _accountsLoading = false;
  String? _accountsError;

  @override
  void initState() {
    super.initState();
    _quantity = TextEditingController(text: widget.resolution.quantity ?? '0');
    _amount = TextEditingController(text: widget.resolution.amountLocal ?? '0');
    if (widget.resolution.isCashCompensation) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadCashAccounts());
    }
  }

  Future<void> _loadCashAccounts() async {
    setState(() {
      _accountsLoading = true;
      _accountsError = null;
    });
    try {
      const fundTypes = {
        'BANK',
        'CASH',
        'CHECK',
        'FOREIGN_CHECK',
        'THIRD_PARTY',
        'OFFSHORE',
      };
      final accounts = await ref.read(accountRepositoryProvider).dict();
      if (!mounted) return;
      setState(() {
        _cashAccounts = accounts
            .where(
              (account) =>
                  account.status == '使用' &&
                  fundTypes.contains(account.accountType),
            )
            .toList(growable: false);
        _accountsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _accountsLoading = false;
        _accountsError = '加载启用资金账户失败';
      });
    }
  }

  @override
  void dispose() {
    _quantity.dispose();
    _amount.dispose();
    _evidence.dispose();
    _docId.dispose();
    _docItemId.dispose();
    _docNo.dispose();
    _note.dispose();
    super.dispose();
  }

  String? get _documentType => switch (widget.resolution.type) {
    SubcontractLossResolutionType.materialReplacement =>
      'SUPPLIER_MATERIAL_REPLACEMENT',
    SubcontractLossResolutionType.outputReplacement => 'SUBCONTRACT_RECEIPT',
    SubcontractLossResolutionType.scrapReturn => 'SUBCONTRACT_MATERIAL_RETURN',
    _ => null,
  };

  String _fmtDate(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Future<void> _pickCashReceiptDate() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _cashReceiptDate,
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (picked != null && mounted) {
      setState(() => _cashReceiptDate = picked);
    }
  }

  bool _validUuid(String value) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);

  void _submit() {
    final evidence = _evidence.text.trim();
    if (evidence.isEmpty) {
      context.appError('请填写履约证据');
      return;
    }
    if (widget.resolution.isCashCompensation) {
      if (_accountId == null) {
        context.appError('请选择启用资金账户');
        return;
      }
      final received = financeDecimalUnits(_amount.text);
      final confirmed = financeDecimalUnits(widget.resolution.amountLocal);
      if (received == null ||
          confirmed == null ||
          received <= BigInt.zero ||
          received != confirmed) {
        context.appError('现金赔偿到账金额必须等于方案确认额');
        return;
      }
      final today = DateTime.now();
      final receiptDay = DateTime(
        _cashReceiptDate.year,
        _cashReceiptDate.month,
        _cashReceiptDate.day,
      );
      if (receiptDay.isAfter(DateTime(today.year, today.month, today.day))) {
        context.appError('现金赔偿到账日不能晚于今天');
        return;
      }
    }
    if (widget.resolution.requiresPhysicalDocument &&
        (!_validUuid(_docId.text.trim()) ||
            !_validUuid(_docItemId.text.trim()))) {
      context.appError('请填写已审核实物单据头和明细的有效 UUID');
      return;
    }
    Navigator.of(context).pop(
      SubcontractLossFulfillmentDraft(
        fulfilledQuantity: _quantity.text.trim(),
        fulfilledAmountLocal: _amount.text.trim(),
        evidenceReference: evidence,
        fulfillmentDocType: _documentType,
        fulfillmentDocId: widget.resolution.requiresPhysicalDocument
            ? _docId.text.trim()
            : null,
        fulfillmentDocItemId: widget.resolution.requiresPhysicalDocument
            ? _docItemId.text.trim()
            : null,
        fulfillmentDocNo: _docNo.text.trim(),
        accountId: widget.resolution.isCashCompensation ? _accountId : null,
        cashReceiptDate: widget.resolution.isCashCompensation
            ? _fmtDate(_cashReceiptDate)
            : null,
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('登记履约 · ${widget.resolution.typeLabel}'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          children: [
            TextField(
              controller: _quantity,
              readOnly: true,
              decoration: const InputDecoration(labelText: '整笔履约数量'),
            ),
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: _amount,
              readOnly: !widget.resolution.isCashCompensation,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: widget.resolution.isCashCompensation
                    ? '到账金额（本币，必须等于确认额）'
                    : '方案金额（本币）',
              ),
            ),
            if (widget.resolution.isCashCompensation) ...[
              const SizedBox(height: UtenSpacing.s8),
              if (_accountsLoading)
                const LinearProgressIndicator()
              else if (_accountsError != null)
                Text(
                  _accountsError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _accountId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '启用资金账户（必选）'),
                  items: [
                    for (final account in _cashAccounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(
                          '${account.code ?? ''} · ${account.name ?? ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _accountId = value),
                ),
              const SizedBox(height: UtenSpacing.s8),
              TextButton.icon(
                onPressed: _pickCashReceiptDate,
                icon: const Icon(Icons.event_outlined),
                label: Text('到账日期 ${_fmtDate(_cashReceiptDate)}'),
              ),
            ],
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: _evidence,
              maxLength: 1000,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '履约证据（必填）'),
            ),
            if (widget.resolution.requiresPhysicalDocument) ...[
              const SizedBox(height: UtenSpacing.s8),
              InputDecorator(
                decoration: const InputDecoration(labelText: '实物单据类型'),
                child: Text(_documentType ?? '—'),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _docId,
                decoration: const InputDecoration(
                  labelText: '已审核实物单头 UUID（必填）',
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _docItemId,
                decoration: const InputDecoration(
                  labelText: '已审核实物单明细 UUID（必填）',
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _docNo,
                decoration: const InputDecoration(labelText: '实物单号'),
              ),
            ],
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: _note,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '履约说明'),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenButton(
            icon: Icons.verified_outlined,
            onPressed: _submit,
            child: const Text('确认履约'),
          ),
        ),
      ),
    );
  }
}

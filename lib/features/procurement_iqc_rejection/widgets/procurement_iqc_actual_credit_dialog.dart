import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/procurement_iqc_rejection.dart';

class ProcurementIqcActualCreditDialog extends StatefulWidget {
  const ProcurementIqcActualCreditDialog({
    super.key,
    required this.detail,
    required this.onPreview,
    required this.onConfirm,
    required this.onRefresh,
  });
  final ProcurementIqcRejectionDetail detail;
  final Future<ProcurementIqcCreditPreview> Function(
    ProcurementIqcConfirmCreditCommand,
  )
  onPreview;
  final Future<ProcurementIqcRejectionDetail> Function(
    ProcurementIqcConfirmCreditCommand,
  )
  onConfirm;
  final Future<ProcurementIqcRejectionDetail> Function() onRefresh;
  @override
  State<ProcurementIqcActualCreditDialog> createState() =>
      _ProcurementIqcActualCreditDialogState();
}

class _CreditCaseDraft {
  _CreditCaseDraft(this.source, {required this.selected})
    : quantity = TextEditingController(text: source.creditableBaseQty);
  ProcurementIqcCreditCase source;
  bool selected;
  final TextEditingController quantity;
  final amount = TextEditingController();
  void dispose() {
    quantity.dispose();
    amount.dispose();
  }
}

class _ProcurementIqcActualCreditDialogState
    extends State<ProcurementIqcActualCreditDialog> {
  final _form = GlobalKey<FormState>();
  final _reference = TextEditingController(),
      _reason = TextEditingController(),
      _actual = TextEditingController();
  final _commandId = const Uuid().v4();
  late ProcurementIqcRejectionDetail _detail;
  String? _sourceId, _error;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  final List<_CreditCaseDraft> _cases = [];
  ProcurementIqcCreditPreview? _preview;
  ProcurementIqcConfirmCreditCommand? _reviewedCommand;
  bool _busy = false, _needsRefresh = false, _uncertain = false;
  int _generation = 0;
  ProcurementIqcCreditSource? get _source => _detail.creditSources
      .where((s) => s.sourceApLedgerId == _sourceId)
      .firstOrNull;
  bool get _editable => !_busy && !_uncertain;
  bool get _masked => _detail.caseItem.priceMasked;
  String get _dateText =>
      '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _detail = widget.detail;
    if (_detail.creditSources.length == 1) {
      _selectSource(_detail.creditSources.single.sourceApLedgerId);
    }
    for (final controller in [_reference, _reason, _actual]) {
      _listenText(controller);
    }
  }

  @override
  void dispose() {
    for (final c in [_reference, _reason, _actual]) {
      c.dispose();
    }
    for (final c in _cases) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      _generation++;
      _preview = null;
      _reviewedCommand = null;
      _error = null;
    });
  }

  void _listenText(TextEditingController controller) {
    var previous = controller.text;
    controller.addListener(() {
      if (controller.text != previous) {
        previous = controller.text;
        _changed();
      }
    });
  }

  void _selectSource(String? id) {
    for (final draft in _cases) {
      draft.dispose();
    }
    _cases.clear();
    _sourceId = id;
    for (final item in _source?.cases ?? <ProcurementIqcCreditCase>[]) {
      final draft = _CreditCaseDraft(
        item,
        selected: item.caseId == _detail.caseItem.id,
      );
      _listenText(draft.quantity);
      _listenText(draft.amount);
      _cases.add(draft);
    }
    _generation++;
    _preview = null;
    _reviewedCommand = null;
  }

  static BigInt? _money(String? text) {
    final parsed = financeAmountUnits(text);
    return parsed != null && parsed.abs() < BigInt.from(10).pow(64)
        ? parsed
        : null;
  }

  static BigInt? _quantity(String? text) {
    final value = financeExactDecimalUnits(text);
    return value != null && value.abs() < BigInt.from(10).pow(18)
        ? value
        : null;
  }

  String? _validateActual(String? raw) {
    final amount = _money(raw);
    if (amount == null || amount <= BigInt.zero) {
      return '填写实际贷项原币金额，最多 24 位有效小数，不能四舍五入';
    }
    final capacity = _money(_source?.remainingAmountOriginal);
    if (capacity == null) return '请先选择具有明确余额的来源应付';
    if (amount > capacity) return '实际贷项超过此来源尚未贷项的原币余额';
    final selected = _cases.where((c) => c.selected).toList();
    if (selected.isEmpty ||
        !selected.any((c) => c.source.caseId == _detail.caseItem.id)) {
      return '分项必须包含当前案件';
    }
    var sum = BigInt.zero;
    for (final row in selected) {
      final value = _money(row.amount.text);
      if (value == null || value <= BigInt.zero) return '请完整填写每个已选案件的实际分项金额';
      sum += value;
    }
    return sum == amount ? null : '案件分项合计必须与实际贷项原币金额完全一致';
  }

  ProcurementIqcConfirmCreditCommand _command() =>
      ProcurementIqcConfirmCreditCommand(
        expectedVersion: _detail.caseItem.version,
        commandId: _commandId,
        creditReference: _reference.text,
        creditDate: _dateText,
        reason: _reason.text,
        actualAmountOriginal: _actual.text.trim(),
        sourceApLedgerId: _sourceId,
        allocations: [
          for (final row in _cases.where((c) => c.selected))
            ProcurementIqcCreditAllocationCommand(
              caseId: row.source.caseId,
              expectedVersion: row.source.version,
              baseQty: row.quantity.text.trim(),
              amountOriginal: row.amount.text.trim(),
            ),
        ],
      );

  Future<void> _previewAmount() async {
    if (!_editable ||
        _needsRefresh ||
        !(_form.currentState?.validate() ?? false)) {
      return;
    }
    final generation = _generation;
    final command = _command();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await widget.onPreview(command);
      if (!mounted || generation != _generation) return;
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(preview.bookAllocationHash) ||
          preview.amountLocal == null ||
          _money(preview.amountOriginal) !=
              _money(command.actualAmountOriginal) ||
          preview.caseAllocations.length != command.allocations.length ||
          command.allocations.any(
            (input) => !preview.caseAllocations.any(
              (part) =>
                  part.caseId == input.caseId &&
                  _money(part.amountOriginal) == _money(input.amountOriginal) &&
                  _quantity(part.baseQty) == _quantity(input.baseQty),
            ),
          )) {
        throw ApiException('INVALID_PREVIEW', '账面分配预览不完整，请刷新来源后重试');
      }
      setState(() {
        _preview = preview;
        _reviewedCommand = command.withBookHash(preview.bookAllocationHash);
      });
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _needsRefresh = error.code == 'CONFLICT';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '预览失败，尚未确认贷项，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final command = _reviewedCommand;
    if (_busy || command == null || _needsRefresh) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.onConfirm(command);
      if (mounted) Navigator.pop(context, result);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _uncertain = {
          'NETWORK',
          'NETWORK_TIMEOUT',
          'INTERNAL',
          'UNKNOWN',
        }.contains(error.code);
        if (!_uncertain) {
          _preview = null;
          _reviewedCommand = null;
          _needsRefresh = true;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _uncertain = true;
          _error = '暂未收到确认结果，请查询处理结果或重试同一次请求';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final next = await widget.onRefresh();
      if (!mounted) return;
      if (_uncertain) {
        if (next.creditDocuments.any((d) => d.creditDocumentId == _commandId)) {
          Navigator.pop(context, next);
          return;
        }
        setState(() => _error = '尚未查到该凭证的处理结果。请重试同一次确认，金额和命令编号保持不变。');
        return;
      }
      final saved = {
        for (final row in _cases)
          row.source.caseId: (row.selected, row.quantity.text, row.amount.text),
      };
      final previousSource = _sourceId;
      setState(() {
        _detail = next;
        _selectSource(
          next.creditSources.any((s) => s.sourceApLedgerId == previousSource)
              ? previousSource
              : next.creditSources.length == 1
              ? next.creditSources.single.sourceApLedgerId
              : null,
        );
        for (final row in _cases) {
          final old = saved[row.source.caseId];
          if (old != null) {
            row.selected = old.$1;
            row.quantity.text = old.$2;
            row.amount.text = old.$3;
          }
        }
        _needsRefresh = false;
        _error = '来源与版本已刷新，请核对剩余数量、金额并重新预览。';
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '刷新来源失败，保留当前填写内容，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateUtils.dateOnly(DateTime.now()),
    );
    if (picked != null && mounted) {
      _date = picked;
      _changed();
    }
  }

  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    String? info,
    String? Function(String?)? validator,
    int lines = 1,
  }) => TextFormField(
    key: Key(key),
    controller: controller,
    enabled: _editable,
    minLines: lines,
    maxLines: lines == 1 ? 1 : 4,
    keyboardType: lines == 1 && key != 'iqc-action-reference'
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text,
    validator: validator,
    errorBuilder: utenTextFieldErrorBuilder,
    decoration: UtenInputDecoration(
      InputDecoration(labelText: label),
      info: info,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = _source;
    final preview = _preview;
    final canInput =
        !_masked &&
        _detail.resolution?.legacyUnclassified != true &&
        _detail.creditSources.isNotEmpty &&
        _detail.caseItem.allows(ProcurementIqcRejectionAction.confirmCredit);
    final sum = financeExactSumTexts(
      _cases.where((r) => r.selected).map((r) => r.amount.text),
    );
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 900),
          child: SafeArea(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '确认供应商实际贷项',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: _busy
                              ? null
                              : () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${_detail.caseItem.supplierName ?? '供应商'} · ${_detail.caseItem.receiptBillNo ?? '—'}',
                          ),
                          const SizedBox(height: 12),
                          if (!canInput)
                            Container(
                              padding: const EdgeInsets.all(12),
                              color: theme.colorScheme.surfaceContainerLow,
                              child: Text(
                                _masked
                                    ? '当前金额已隐藏，无法确认实际贷项。'
                                    : '当前没有可确认的资金来源。历史案件须先核对原应付和资金份额；已被补回或贷项占用的数量不能重复使用。',
                              ),
                            ),
                          if (canInput) ...[
                            KeyedSubtree(
                              key: ValueKey('source-$_sourceId'),
                              child: FormField<String>(
                                initialValue: _sourceId,
                                validator: (value) =>
                                    value == null ? '请选择来源应付' : null,
                                builder: (field) => UtenDropdownField(
                                  key: const Key('iqc-credit-source'),
                                  value: _sourceId,
                                  label: '来源应付',
                                  required: true,
                                  enabled: _editable,
                                  info: '一个实际凭证使用同一原应付；其他案件也必须来自该应付',
                                  errorMessage: field.errorText,
                                  items: [
                                    for (final s in _detail.creditSources)
                                      UtenDropdownItem(
                                        value: s.sourceApLedgerId,
                                        label:
                                            '${s.sourceBillNo ?? s.sourceApLedgerId} · 未贷项原币 ${s.remainingAmountOriginal ?? '待核对'}',
                                      ),
                                  ],
                                  onChanged: (value) {
                                    field.didChange(value);
                                    setState(() => _selectSource(value));
                                  },
                                ),
                              ),
                            ),
                            if (source != null) ...[
                              const SizedBox(height: 8),
                              SelectableText(
                                '原应付原币 ${source.amountOriginal ?? '待核对'} · 已贷项 ${source.creditedAmountOriginal ?? '待核对'} · 可用原币 ${source.remainingAmountOriginal ?? '待核对'}',
                              ),
                            ],
                            const SizedBox(height: 12),
                            _field(
                              'iqc-credit-actual',
                              '实际贷项原币金额 *',
                              _actual,
                              validator: _validateActual,
                              info: '按供应商原始凭证填写。保留最多 24 位有效小数，不从不合格数量或冻结金额推算。',
                            ),
                            const SizedBox(height: 12),
                            Text('明确案件分项', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 4),
                            Text(
                              '各案件使用各自基本单位。填写实际分项金额，合计须与供应商凭证一致。',
                              style: theme.textTheme.bodySmall,
                            ),
                            for (final row in _cases) ...[
                              const SizedBox(height: 8),
                              Card(
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      CheckboxListTile(
                                        key: Key(
                                          'iqc-credit-case-${row.source.caseId}',
                                        ),
                                        contentPadding: EdgeInsets.zero,
                                        value: row.selected,
                                        title: Text(
                                          '${row.source.receiptBillNo ?? '—'} · ${row.source.goodsName ?? '—'}',
                                        ),
                                        subtitle: Text(
                                          '可贷项 ${row.source.creditableBaseQty ?? '待核对'} ${row.source.baseUnitName ?? '基本单位'}${row.source.caseId == _detail.caseItem.id ? ' · 当前案件必选' : ''}',
                                        ),
                                        onChanged:
                                            _editable &&
                                                row.source.caseId !=
                                                    _detail.caseItem.id
                                            ? (value) {
                                                row.selected = value ?? false;
                                                _changed();
                                              }
                                            : null,
                                      ),
                                      if (row.selected) ...[
                                        _field(
                                          'iqc-credit-qty-${row.source.caseId}',
                                          '退回基本量（${row.source.baseUnitName ?? '基本单位'}） *',
                                          row.quantity,
                                          validator: (raw) {
                                            final q = _quantity(raw),
                                                max = _quantity(
                                                  row.source.creditableBaseQty,
                                                );
                                            if (q == null || q <= BigInt.zero) {
                                              return '基本量必须大于零，最多 4 位有效小数';
                                            }
                                            return max == null || q > max
                                                ? '不能超过该案件当前可贷项基本量'
                                                : null;
                                          },
                                        ),
                                        const SizedBox(height: 12),
                                        _field(
                                          'iqc-credit-amount-${row.source.caseId}',
                                          '案件实际原币金额 *',
                                          row.amount,
                                          validator: (raw) {
                                            final value = _money(raw);
                                            return value == null ||
                                                    value <= BigInt.zero
                                                ? '填写大于零的实际分项金额，最多 24 位有效小数'
                                                : null;
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            SelectableText(
                              '分项合计：${sum ?? '待完整填写'} ${_detail.caseItem.currencyCode ?? ''}',
                              key: const Key('iqc-credit-sum'),
                            ),
                            const SizedBox(height: 12),
                            _field(
                              'iqc-action-reference',
                              '供应商贷项凭证号 *',
                              _reference,
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? '供应商贷项凭证号不能为空'
                                  : value.trim().length > 200
                                  ? '凭证号不能超过 200 个字符'
                                  : null,
                            ),
                            const SizedBox(height: 12),
                            InkWell(
                              onTap: _editable ? _pickDate : null,
                              child: InputDecorator(
                                decoration: const InputDecoration(
                                  labelText: '供应商贷项日期 *',
                                  suffixIcon: Icon(Icons.event_outlined),
                                ),
                                child: Text(_dateText),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _field(
                              'iqc-action-note',
                              '贷项确认原因 *',
                              _reason,
                              lines: 3,
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? '贷项确认原因不能为空'
                                  : value.trim().length > 2000
                                  ? '原因不能超过 2000 个字符'
                                  : null,
                            ),
                          ],
                          if (preview != null) ...[
                            const SizedBox(height: 16),
                            _previewPanel(preview),
                          ],
                          if (_uncertain) ...[
                            const SizedBox(height: 12),
                            Text(
                              '确认结果尚未查明，保留同一个请求编号与完整金额重试，避免重复贷项。',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                _error!,
                                key: const Key('iqc-credit-error'),
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : _refresh,
                          child: Text(_uncertain ? '查询处理结果' : '刷新来源与余额'),
                        ),
                        if (canInput)
                          UtenButton(
                            key: const Key('iqc-credit-preview'),
                            type: preview == null
                                ? UtenButtonType.primary
                                : UtenButtonType.secondary,
                            isLoading: _busy && preview == null,
                            onPressed: _editable && !_needsRefresh
                                ? _previewAmount
                                : null,
                            child: const Text('预览账面分配'),
                          ),
                        if (preview != null)
                          UtenButton(
                            key: const Key('iqc-action-submit'),
                            isLoading: _busy,
                            onPressed: _busy || _needsRefresh ? null : _confirm,
                            child: Text(_uncertain ? '重试同一次确认' : '确认以上金额与分项'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewPanel(ProcurementIqcCreditPreview preview) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('iqc-credit-book-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: .3),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('请核对本次账面分配', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(
            '实际原币 ${preview.amountOriginal ?? '—'} · 账面本币 ${preview.amountLocal ?? '—'}',
          ),
          SelectableText(
            '抵销原应付：原币 ${preview.offsetOriginal ?? '—'} / 本币 ${preview.offsetLocal ?? '—'}',
          ),
          SelectableText(
            '贷项保留余额：原币 ${preview.creditRemainingOriginal ?? '—'} / 本币 ${preview.creditRemainingLocal ?? '—'}',
          ),
          SelectableText(
            '来源分配前：原币 ${preview.sourceBeforeOriginal ?? '—'} / 本币 ${preview.sourceBeforeLocal ?? '—'}',
          ),
          SelectableText(
            '来源分配后：原币 ${preview.sourceAfterOriginal ?? '—'} / 本币 ${preview.sourceAfterLocal ?? '—'}',
          ),
          for (final part in preview.caseAllocations) ...[
            const Divider(),
            Text(
              _cases
                      .where((r) => r.source.caseId == part.caseId)
                      .map(
                        (r) =>
                            '${r.source.receiptBillNo ?? '—'} · ${r.source.goodsName ?? '—'}',
                      )
                      .firstOrNull ??
                  part.caseId,
            ),
            SelectableText(
              '实际分项原币 ${part.amountOriginal ?? '—'} · 已分配本币 ${part.amountLocal ?? '—'}',
            ),
            SelectableText(
              '本凭证待分余额：原币 ${part.afterOriginal ?? '—'} / 本币 ${part.afterLocal ?? '—'}',
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '本币按同一资金来源分配，未分金额保留在来源余额，最后一项取完余额。未把分摊余量转为汇兑或损失。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

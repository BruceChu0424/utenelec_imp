import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../models/procurement_iqc_rejection.dart';

enum ProcurementIqcRejectionActionKind {
  recordReturn,
  confirmCredit,
  closeNoCredit,
  reverse,
  retryFinanceProjection,
}

typedef ProcurementIqcRejectionCommandSubmit =
    Future<ProcurementIqcRejectionDetail> Function(Object command);

class ProcurementIqcRejectionActionDialog extends StatefulWidget {
  const ProcurementIqcRejectionActionDialog({
    super.key,
    required this.caseItem,
    required this.kind,
    required this.onSubmit,
  });

  final ProcurementIqcRejectionCase caseItem;
  final ProcurementIqcRejectionActionKind kind;
  final ProcurementIqcRejectionCommandSubmit onSubmit;

  @override
  State<ProcurementIqcRejectionActionDialog> createState() =>
      _ProcurementIqcRejectionActionDialogState();
}

class _ProcurementIqcRejectionActionDialogState
    extends State<ProcurementIqcRejectionActionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reference = TextEditingController();
  final _note = TextEditingController();
  late final String _commandId = const Uuid().v4();
  late DateTime _date = _today();
  bool _busy = false;
  String? _error;

  bool get _usesReference =>
      widget.kind == ProcurementIqcRejectionActionKind.recordReturn ||
      widget.kind == ProcurementIqcRejectionActionKind.confirmCredit;

  bool get _usesDate => _usesReference;

  @override
  void dispose() {
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  String _dateText(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final value = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: _today(),
    );
    if (value != null && mounted) setState(() => _date = value);
  }

  String? _requiredReference(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '$_referenceLabel不能为空';
    if (text.length > 200) return '$_referenceLabel不能超过 200 个字符';
    return null;
  }

  String? _requiredNote(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '$_noteLabel不能为空';
    if (text.length > 2000) return '$_noteLabel不能超过 2000 个字符';
    return null;
  }

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Object command = switch (widget.kind) {
        ProcurementIqcRejectionActionKind.recordReturn =>
          ProcurementIqcRecordReturnCommand(
            expectedVersion: widget.caseItem.version,
            commandId: _commandId,
            returnReference: _reference.text,
            returnDate: _dateText(_date),
            returnNote: _note.text,
          ),
        ProcurementIqcRejectionActionKind.confirmCredit =>
          ProcurementIqcConfirmCreditCommand(
            expectedVersion: widget.caseItem.version,
            commandId: _commandId,
            creditReference: _reference.text,
            creditDate: _dateText(_date),
            reason: _note.text,
          ),
        ProcurementIqcRejectionActionKind.closeNoCredit ||
        ProcurementIqcRejectionActionKind.reverse ||
        ProcurementIqcRejectionActionKind.retryFinanceProjection =>
          ProcurementIqcReasonCommand(
            expectedVersion: widget.caseItem.version,
            commandId: _commandId,
            reason: _note.text,
          ),
      };
      final result = await widget.onSubmit(command);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '提交失败，请检查网络后使用当前表单重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _title => switch (widget.kind) {
    ProcurementIqcRejectionActionKind.recordReturn => '登记实物退回',
    ProcurementIqcRejectionActionKind.confirmCredit => '确认供应商贷项',
    ProcurementIqcRejectionActionKind.closeNoCredit => '零金额无需贷项结案',
    ProcurementIqcRejectionActionKind.reverse => '反向当前处理',
    ProcurementIqcRejectionActionKind.retryFinanceProjection => '重试财务投影',
  };

  String get _submitLabel => switch (widget.kind) {
    ProcurementIqcRejectionActionKind.recordReturn => '确认已实物退回',
    ProcurementIqcRejectionActionKind.confirmCredit => '确认供应商贷项',
    ProcurementIqcRejectionActionKind.closeNoCredit => '确认零金额结案',
    ProcurementIqcRejectionActionKind.reverse => '确认反向',
    ProcurementIqcRejectionActionKind.retryFinanceProjection => '确认重试投影',
  };

  String get _referenceLabel =>
      widget.kind == ProcurementIqcRejectionActionKind.recordReturn
      ? '退回凭证号'
      : '供应商贷项凭证号';

  String get _dateLabel =>
      widget.kind == ProcurementIqcRejectionActionKind.recordReturn
      ? '实物退回日期'
      : '供应商贷项日期';

  String get _noteLabel => switch (widget.kind) {
    ProcurementIqcRejectionActionKind.recordReturn => '退回说明',
    ProcurementIqcRejectionActionKind.confirmCredit => '贷项确认原因',
    ProcurementIqcRejectionActionKind.closeNoCredit => '无需贷项原因',
    ProcurementIqcRejectionActionKind.reverse => '反向原因',
    ProcurementIqcRejectionActionKind.retryFinanceProjection => '重试原因',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(UtenSpacing.s16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 720),
        child: SafeArea(
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UtenSpacing.s16,
                    UtenSpacing.s16,
                    UtenSpacing.s8,
                    UtenSpacing.s8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        tooltip: '关闭',
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerLow,
                            borderRadius: UtenRadius.mdAll,
                          ),
                          child: Text(
                            '${widget.caseItem.receiptType?.label ?? '未知来源'} '
                            '${widget.caseItem.receiptBillNo ?? '—'} · '
                            '${widget.caseItem.goodsLabel} · '
                            '拒收 ${widget.caseItem.failedQty ?? '—'} '
                            '${widget.caseItem.unitName ?? ''}',
                          ),
                        ),
                        if (widget.kind ==
                            ProcurementIqcRejectionActionKind
                                .confirmCredit) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          InputDecorator(
                            decoration: const InputDecoration(
                              labelText: '服务器冻结贷项金额(只读)',
                            ),
                            child: Text(
                              widget.caseItem.amountLabel(
                                widget.caseItem.failedAmountOriginal,
                              ),
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                        if (_usesReference) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          TextFormField(
                            key: const Key('iqc-action-reference'),
                            controller: _reference,
                            autofocus: true,
                            maxLength: 200,
                            validator: _requiredReference,
                            errorBuilder: utenTextFieldErrorBuilder,
                            decoration: InputDecoration(
                              labelText: '$_referenceLabel *',
                              helper: const UtenFieldMessage.helper(
                                '填写可向供应商或物流凭证回查的结构化编号',
                              ),
                            ),
                          ),
                        ],
                        if (_usesDate) ...[
                          const SizedBox(height: UtenSpacing.s8),
                          Semantics(
                            key: const Key('iqc-action-date'),
                            button: true,
                            label: '$_dateLabel ${_dateText(_date)}',
                            child: InkWell(
                              borderRadius: UtenRadius.smAll,
                              onTap: _busy ? null : _pickDate,
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: '$_dateLabel *',
                                  suffixIcon: const Icon(Icons.event_outlined),
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 24,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(_dateText(_date)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: UtenSpacing.s8),
                        TextFormField(
                          key: const Key('iqc-action-note'),
                          controller: _note,
                          minLines: 3,
                          maxLines: 5,
                          maxLength: 2000,
                          validator: _requiredNote,
                          errorBuilder: utenTextFieldErrorBuilder,
                          decoration: InputDecoration(
                            labelText: '$_noteLabel *',
                            helper: const UtenFieldMessage.helper(
                              '说明将进入追加式审计事件，提交后不能覆盖原记录',
                            ),
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: UtenSpacing.s8),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              key: const Key('iqc-action-error'),
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      UtenButton(
                        key: const Key('iqc-action-submit'),
                        size: UtenButtonSize.large,
                        icon: _busy ? null : Icons.check_rounded,
                        isLoading: _busy,
                        onPressed: _busy ? null : _submit,
                        child: Text(_submitLabel),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

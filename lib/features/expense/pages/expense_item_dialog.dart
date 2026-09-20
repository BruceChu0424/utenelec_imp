// 报销明细添加/编辑对话框（V608 从新建页内嵌对话框升位为共享组件：新建与编辑共用，
// initial 非空 = 修改现有明细行）。

import 'package:flutter/material.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/utils/rmb_amount.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/expense_item.dart';

class ExpenseItemDialog extends StatefulWidget {
  const ExpenseItemDialog({super.key, this.initial});

  final ExpenseItem? initial;

  @override
  State<ExpenseItemDialog> createState() => _ExpenseItemDialogState();
}

class _ExpenseItemDialogState extends State<ExpenseItemDialog> {
  late ExpenseCategory _category;
  late DateTime _date;
  late final TextEditingController _amountController;
  late final TextEditingController _descController;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _category = initial?.category ?? ExpenseCategory.transport;
    _date = initial?.date ?? ChinaDateTime.today();
    _amountController = TextEditingController(
      text: initial == null ? '' : initial.amount.toStringAsFixed(2),
    );
    _descController = TextEditingController(text: initial?.description ?? '');
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '添加报销明细' : '修改报销明细'),
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '类别',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final cat in ExpenseCategory.values)
                      ChoiceChip(
                        label: Text(cat.label),
                        avatar: Icon(cat.icon, size: 16, color: cat.color),
                        selected: _category == cat,
                        selectedColor: cat.color.withValues(alpha: 0.15),
                        onSelected: (_) => setState(() => _category = cat),
                      ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s16),
                TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const UtenInputDecoration(
                    InputDecoration(
                      labelText: '金额 *',
                      prefixText: '¥ ',
                      hintText: '0.00',
                    ),
                    info: '按这项费用的实际票据填写人民币金额，同一笔费用不要拆成重复明细。',
                  ),
                  validator: (v) {
                    final amount = parseExpenseAmountCents(v ?? '');
                    if (amount == null) {
                      return AppLocalizations.of(
                        context,
                      ).expenseFlowAmountInvalid;
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('费用发生日期'),
                  subtitle: Text(_fmtDate(_date)),
                  trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                  onTap: _pickDate,
                ),
                TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  controller: _descController,
                  maxLength: 500,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? AppLocalizations.of(
                          context,
                        ).expenseFlowItemPurposeRequired
                      : null,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: AppLocalizations.of(
                        context,
                      ).expenseFlowItemPurpose,
                    ),
                    info: AppLocalizations.of(
                      context,
                    ).expenseFlowItemPurposeHint,
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(
                context,
                ExpenseItem(
                  id:
                      widget.initial?.id ??
                      DateTime.now().microsecondsSinceEpoch.toString(),
                  category: _category,
                  amount:
                      parseExpenseAmountCents(_amountController.text)! / 100,
                  date: _date,
                  description: _descController.text.trim().isEmpty
                      ? null
                      : _descController.text.trim(),
                ),
              );
            }
          },
          child: const Text('确认'),
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final today = ChinaDateTime.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.utc(2000),
      lastDate: today,
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

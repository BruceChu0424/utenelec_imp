// 新建报销页
// 文档：docs/03-页面/新建报销页.md（待写）
//
// 步骤：填标题 → 添加明细项 → 填备注 → 提交/保存草稿

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/expense_item.dart';
import '../providers/expense_providers.dart';

class ExpenseNewPage extends ConsumerStatefulWidget {
  const ExpenseNewPage({super.key});

  @override
  ConsumerState<ExpenseNewPage> createState() => _ExpenseNewPageState();
}

class _ExpenseNewPageState extends ConsumerState<ExpenseNewPage> {
  final _titleController = TextEditingController();
  final _remarkController = TextEditingController();
  final List<ExpenseItem> _items = [];
  bool _isSubmitting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  double get _total => _items.fold<double>(0, (s, i) => s + i.amount);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const UtenAppBar(showBackButton: true),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                UtenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UtenInput(
                        controller: _titleController,
                        label: '报销标题',
                        hint: '如：上海客户拜访差旅',
                        textInputAction: TextInputAction.next,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // 明细
                UtenSectionHeader(
                  title: '报销明细 (${_items.length})',
                  trailing: TextButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('添加'),
                  ),
                ),
                const SizedBox(height: 8),
                if (_items.isEmpty)
                  _buildEmptyItems(theme)
                else
                  ..._items.map(
                    (i) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildItemCard(theme, i),
                    ),
                  ),

                const SizedBox(height: 16),

                // 备注
                UtenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UtenInput(
                        controller: _remarkController,
                        label: '备注（可选）',
                        hint: '补充说明，如客户名称、项目背景',
                        maxLines: 3,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 底部
          UtenBottomActionBar(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '合计',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '¥ ${_total.toStringAsFixed(2)}',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: UtenColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                UtenButton(
                  type: UtenButtonType.ghost,
                  onPressed: _isSubmitting
                      ? null
                      : () => _submit(saveOnly: true),
                  child: const Text('存草稿'),
                ),
                const SizedBox(width: 12),
                UtenButton(
                  isLoading: _isSubmitting,
                  icon: Icons.send_rounded,
                  onPressed: _isSubmitting
                      ? null
                      : () => _submit(saveOnly: false),
                  child: const Text('提交'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyItems(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.add_circle_outline_rounded,
            size: 32,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            '点击右上角"添加"创建报销项',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemCard(ThemeData theme, ExpenseItem item) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: item.category.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              item.category.icon,
              color: item.category.color,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.category.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${_fmtDate(item.date)}${item.description != null ? '  ·  ${item.description}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '¥ ${item.amount.toStringAsFixed(2)}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: UtenColors.primary,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            splashRadius: 16,
            onPressed: () => setState(() => _items.remove(item)),
          ),
        ],
      ),
    );
  }

  Future<void> _addItem() async {
    final item = await showDialog<ExpenseItem>(
      context: context,
      builder: (_) => const _AddItemDialog(),
    );
    if (item != null) {
      setState(() => _items.add(item));
    }
  }

  Future<void> _submit({required bool saveOnly}) async {
    if (_titleController.text.trim().isEmpty) {
      UtenToast.warning(context, '请填写报销标题');
      return;
    }
    if (_items.isEmpty) {
      UtenToast.warning(context, '请至少添加一项报销明细');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final claim = await createExpense(
        ref,
        title: _titleController.text.trim(),
        items: List.from(_items),
        remark: _remarkController.text.trim().isEmpty
            ? null
            : _remarkController.text.trim(),
      );

      if (saveOnly) {
        if (mounted) {
          UtenToast.success(context, '已保存草稿');
          context.push(RoutePath.expenseDetail(claim.id));
        }
      } else {
        await submitExpense(ref, claim.id);
        if (mounted) {
          UtenToast.success(context, '已提交，等待审批');
          context.go(RouteName.expense);
        }
      }
    } catch (e) {
      if (mounted) UtenToast.error(context, '提交失败：$e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 添加报销项对话框
class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog();

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  ExpenseCategory _category = ExpenseCategory.transport;
  DateTime _date = DateTime.now();
  final _amountController = TextEditingController();
  final _descController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _amountController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加报销项'),
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 类别选择
                const Text(
                  '类别',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
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
                const SizedBox(height: 16),
                // 金额
                TextFormField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '金额 *',
                    prefixText: '¥ ',
                    hintText: '0.00',
                  ),
                  validator: (v) {
                    final amount = double.tryParse(v ?? '');
                    if (amount == null || amount <= 0) return '请输入有效金额';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                // 日期
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('日期'),
                  subtitle: Text(_fmtDate(_date)),
                  trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                  onTap: _pickDate,
                ),
                // 说明
                TextFormField(
                  controller: _descController,
                  decoration: const InputDecoration(
                    labelText: '说明（可选）',
                    hintText: '如：客户名称、项目背景',
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
      ),
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
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  category: _category,
                  amount: double.parse(_amountController.text),
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
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(DateTime.now().year - 1),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

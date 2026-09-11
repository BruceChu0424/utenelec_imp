// 新建报销页
// 文档：docs/03-页面/新建报销页.md（待写）
//
// 步骤：填标题 → 添加明细项 → 填备注 → 提交/保存草稿
//
// 响应式：全断点套 UtenContentContainer.narrow（maxWidth 1120）——
// 外壳只收敛到 1600，表单页需自行钳窄居中

import 'package:flutter/material.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
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
      appBar: const UtenAppBar(title: '新建报销', showBackButton: true),
      body: Column(
        children: [
          Expanded(
            // narrow 容器：compact 提供 gutter，medium+ 把表单钳到 1120 居中
            child: UtenContentContainer.narrow(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                children: [
                  UtenCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        UtenInput(
                          controller: _titleController,
                          label: '报销标题',
                          required: true,
                          hint: '如：上海客户拜访差旅',
                          textInputAction: TextInputAction.next,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),

                  // 明细
                  // 计数括号 2026-09-11 去除（明细区不再重复报行数）；本页是卡片堆叠，
                  // 标题是唯一的区块分隔，故保留标题本身。
                  UtenSectionHeader(
                    title: '报销明细',
                    trailing: TextButton.icon(
                      onPressed: _addItem,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('添加'),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  if (_items.isEmpty)
                    _buildEmptyItems(theme)
                  else
                    ..._items.map(
                      (i) => Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                        child: _buildItemCard(theme, i),
                      ),
                    ),

                  const SizedBox(height: UtenSpacing.s16),

                  // Optional context is kept out of the core title/items flow.
                  UtenCollapsibleSection(
                    title: '补充说明(选填)',
                    initiallyExpanded: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        UtenInput(
                          controller: _remarkController,
                          label: '备注(可选)',
                          hint: '补充说明，如客户名称、项目背景',
                          maxLines: 3,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
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
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s16),
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
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(
            Icons.add_circle_outline_rounded,
            size: 32,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: UtenSpacing.s8),
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
    // 明细小卡：UtenCard 无阴影变体（radius 14 + 细边框）
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s12),
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
        try {
          await submitExpense(ref, claim.id);
          if (mounted) {
            UtenToast.success(context, '已提交，等待审批');
            context.go(RouteName.expense);
          }
        } catch (error) {
          if (mounted) {
            UtenToast.error(context, '草稿已保存，但提交失败：$error。请在详情页重试。');
            context.push(RoutePath.expenseDetail(claim.id));
          }
        }
      }
    } catch (_) {
      if (mounted) UtenToast.error(context, '保存失败，请检查网络后重试');
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
  DateTime _date = ChinaDateTime.today();
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
                // 金额
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
                    final amount = double.tryParse(v ?? '');
                    if (amount == null || !amount.isFinite || amount <= 0) {
                      return '请输入有效金额';
                    }
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
                  errorBuilder: utenTextFieldErrorBuilder,
                  controller: _descController,
                  decoration: const UtenInputDecoration(
                    InputDecoration(
                      labelText: '说明(可选)',
                      hintText: '如：客户名称、项目背景',
                    ),
                    info: '说明这笔费用的用途，便于审批人核对票据；可选，不影响金额计算。',
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
    final today = ChinaDateTime.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.utc(today.year - 1),
      lastDate: today,
    );
    if (picked != null) setState(() => _date = picked);
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

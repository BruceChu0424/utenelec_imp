import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../basic_data/models/payment_style_node.dart';
import '../../basic_data/pages/payment_style_page.dart';
import '../providers/finance_name_provider.dart';

/// Expense/income choices share one create entry, authoritative UUID handling
/// and immediate name publication across document grids and settlement forms.
class FinanceStylePicker extends ConsumerStatefulWidget {
  const FinanceStylePicker({
    super.key,
    required this.names,
    required this.category,
    required this.value,
    required this.onChanged,
    this.dense = false,
    this.label,
    this.enabled = true,
  });

  final FinanceNameService names;
  final String category;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool dense;
  final String? label;
  final bool enabled;

  @override
  ConsumerState<FinanceStylePicker> createState() => _FinanceStylePickerState();
}

class _FinanceStylePickerState extends ConsumerState<FinanceStylePicker> {
  bool _adding = false;

  Future<void> _add() async {
    if (_adding || !widget.enabled) return;
    final current = captureReadOwner(ref);
    final names = widget.names;
    final category = widget.category;
    setState(() => _adding = true);
    try {
      final created = await showPaymentStyleAddDialog(
        context: context,
        ref: ref,
        category: category == 'INCOME'
            ? PaymentStyleCategory.income
            : PaymentStyleCategory.expense,
        tree: names.styleTreeFor(category),
      );
      if (!mounted ||
          !current() ||
          created == null ||
          !identical(widget.names, names) ||
          widget.category != category) {
        return;
      }
      names.registerCreatedStyle(created);
      unawaited(names.loadStyleCategory(category, force: true));
      if (created.status == '使用' && created.childCount == 0) {
        widget.onChanged(created.id);
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final canCreate =
        permissions.contains(Perm.paymentStyleCreate) &&
        permissions.contains(Perm.paymentStyleView);
    return ListenableBuilder(
      listenable: widget.names,
      builder: (context, _) {
        final styles = widget.names.stylesFor(widget.category);
        final value = widget.value;
        final label =
            widget.label ?? (widget.category == 'INCOME' ? '收入项目' : '费用项目');
        final oldName = widget.names.styleName(value, widget.category);
        return UtenDropdownField(
          dense: widget.dense,
          label: label,
          value: value,
          enabled: widget.enabled && !_adding,
          items: [
            for (final style in styles)
              UtenDropdownItem(
                value: style.id,
                label: style.name ?? style.code ?? style.id,
              ),
            if (value != null &&
                value.isNotEmpty &&
                !styles.any((style) => style.id == value))
              UtenDropdownItem(
                value: value,
                label: oldName == '—' ? value : oldName,
                visible: false,
              ),
          ],
          onChanged: widget.onChanged,
          onAddNew: canCreate ? _add : null,
          addNewLabel: '添加${widget.category == 'INCOME' ? '收入' : '费用'}项目',
        );
      },
    );
  }
}

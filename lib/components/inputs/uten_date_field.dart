// UtenDateField - 编辑/详情页日期字段（outlined，与下拉/文本框同款）。
//
// 背景：原编辑页日期（单据日期/交货日期）用 ListTile 渲染（无边框、标题大字、值小字），
// 与旁边 outlined 下拉/文本框风格不一致（plans/witty-imagining-reef.md Workstream B2）。
// 本组件用 InputDecorator + Text（同货品选择器范式），outlined 边框与浮动小字 label
// 由主题 inputDecorationTheme 提供，与其它字段完全一致。
//
// 用法：
//   UtenDateField(
//     label: '单据日期',
//     required: true,
//     value: _billDate,
//     onChanged: (d) => setState(() => _billDate = d),
//   )

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/utils/china_datetime.dart';
import 'required_field_decoration.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';

/// outlined 日期选择字段。点按弹 showDatePicker；值/占位"未选择"显示在框内。
class UtenDateField extends StatefulWidget {
  const UtenDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.required = false,
    this.firstDate,
    this.lastDate,
    this.enabled = true,
    this.info,
    this.errorMessage,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final bool required;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool enabled;

  /// Field guidance disclosed by the info icon inside the input.
  final String? info;

  /// Validation error shown by a red border and an in-field error icon.
  final String? errorMessage;

  @override
  State<UtenDateField> createState() => _UtenDateFieldState();
}

class _UtenDateFieldState extends State<UtenDateField> {
  Future<void> _pick() async {
    final now = ChinaDateTime.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.value ?? now,
      firstDate: widget.firstDate ?? DateTime(2010),
      lastDate: widget.lastDate ?? DateTime(2100),
    );
    if (picked != null && mounted) widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasValue = widget.value != null;
    final requiredEmpty =
        widget.enabled &&
        widget.required &&
        !hasValue &&
        widget.errorMessage == null;
    return InkWell(
      onTap: widget.enabled ? _pick : null,
      borderRadius: BorderRadius.circular(UtenSpacing.s8),
      child: InputDecorator(
        decoration: applyRequiredEmpty(
          UtenInputDecoration(
            InputDecoration(
              enabled: widget.enabled,
              label: fieldLabel(
                widget.label,
                theme,
                required: widget.required,
                info: widget.info,
                base: theme.inputDecorationTheme.labelStyle,
              ),
              error: widget.errorMessage == null
                  ? null
                  : UtenFieldMessage.error(widget.errorMessage!),
              suffixIcon: const Icon(Icons.event_outlined, size: 18),
            ),
          ),
          theme,
          requiredEmpty: requiredEmpty,
        ),
        child: Text(
          hasValue ? ChinaDateTime.formatDate(widget.value!) : '未选择',
          style: hasValue
              ? TextStyle(color: theme.colorScheme.onSurface)
              : TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

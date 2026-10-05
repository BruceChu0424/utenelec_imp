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
import '../../shared/ai/page_context/ai_page_context.dart';

/// outlined 日期选择字段。点按弹 showDatePicker；值/占位"未选择"显示在框内。
class UtenDateField extends StatefulWidget {
  const UtenDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.required = false,
    this.autofilled = false,
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

  /// 值来自系统预填(如新建报价的默认有效期)：黄框提醒核对，用户改动即由宿主清除。
  final bool autofilled;
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
  // ADR-150: AI page context registration; an AI-chosen date stays framed
  // yellow ("AI filled, please review") until the user picks a date.
  final _aiSlot = AiPageSlot();
  DateTime? _aiFilledDate;

  bool get _aiFilledNow =>
      _aiFilledDate != null &&
      widget.value != null &&
      DateUtils.isSameDay(widget.value, _aiFilledDate);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _aiAttach();
  }

  @override
  void didUpdateWidget(covariant UtenDateField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _aiAttach();
  }

  @override
  void dispose() {
    _aiSlot.detach();
    super.dispose();
  }

  void _aiAttach() => _aiSlot.attach(
    context,
    AiFieldSource(
      capture: _aiField,
      setValue: widget.enabled ? _aiSetValue : null,
    ),
  );

  AiFieldSnapshot? _aiField(AiCaptureContext ctx) {
    final label = aiSnapshotLabel(widget.label);
    if (!mounted || label == null) return null;
    final hasValue = widget.value != null;
    final requiredEmpty =
        widget.enabled &&
        widget.required &&
        !hasValue &&
        widget.errorMessage == null;
    final autofilled = (widget.autofilled || _aiFilledNow) && hasValue;
    return AiFieldSnapshot(
      label: label,
      value: hasValue ? ChinaDateTime.formatDate(widget.value!) : null,
      state: widget.errorMessage != null
          ? AiFieldState.error
          : requiredEmpty
          ? AiFieldState.requiredEmpty
          : autofilled
          ? AiFieldState.autofilled
          : AiFieldState.normal,
      required: widget.required,
      message: aiSnapshotValue(
        widget.errorMessage ??
            (_aiFilledNow
                ? ctx.l10n.fieldAiFilledReview
                : autofilled
                ? ctx.l10n.fieldAutofilledReview
                : null),
        AiSnapshotLimits.info,
      ),
      info: aiSnapshotValue(widget.info, AiSnapshotLimits.info),
    );
  }

  Future<void> _aiSetValue(String value, AiCaptureContext ctx) async {
    if (!mounted || !widget.enabled) {
      throw AiActionFailure(ctx.l10n.aiActionFieldReadOnly(widget.label));
    }
    final match = RegExp(
      r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$',
    ).firstMatch(value.trim());
    final date = match == null
        ? null
        : DateTime(
            int.parse(match.group(1)!),
            int.parse(match.group(2)!),
            int.parse(match.group(3)!),
          );
    if (date == null ||
        date.month != int.parse(match!.group(2)!) ||
        date.day != int.parse(match.group(3)!) ||
        date.isBefore(widget.firstDate ?? DateTime(2010)) ||
        date.isAfter(widget.lastDate ?? DateTime(2100))) {
      throw AiActionFailure(ctx.l10n.aiActionDateInvalid);
    }
    widget.onChanged(date);
    setState(() => _aiFilledDate = date);
  }

  Future<void> _pick() async {
    final now = ChinaDateTime.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.value ?? now,
      firstDate: widget.firstDate ?? DateTime(2010),
      lastDate: widget.lastDate ?? DateTime(2100),
    );
    if (picked != null && mounted) {
      _aiFilledDate = null;
      widget.onChanged(picked);
    }
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
          applyAutofillHint(
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
            autofilled: widget.autofilled || _aiFilledNow,
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

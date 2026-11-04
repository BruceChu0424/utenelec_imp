import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/utils/china_datetime.dart';
import '../../shared/ai/page_context/ai_page_context.dart';
import '../feedback/uten_date_range_picker.dart';
import 'required_field_decoration.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';
import 'uten_table_cell_spec.dart';

/// 年月字段：支持键盘输入和月份选择，不为只有月份的业务数据捏造日期。
class UtenMonthField extends StatefulWidget {
  const UtenMonthField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.firstYear = 1900,
    this.lastYear = 2100,
    this.info,
  });

  final String label;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;
  final int firstYear;
  final int lastYear;
  final String? info;

  /// 兼容老库中文年月和旧客户端日期；严格验证月份/日期，避免 DateTime 自动进位。
  static DateTime? parse(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    final match =
        RegExp(r'^(\d{4})[-/](\d{1,2})(?:[-/](\d{1,2}))?$').firstMatch(text) ??
        RegExp(r'^(\d{4})\s*年\s*(\d{1,2})\s*月$').firstMatch(text);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = match.groupCount >= 3
        ? int.tryParse(match.group(3) ?? '1') ?? 1
        : 1;
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? DateTime(year, month)
        : null;
  }

  static String format(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

  @override
  State<UtenMonthField> createState() => _UtenMonthFieldState();
}

class _UtenMonthFieldState extends State<UtenMonthField> {
  late final TextEditingController _controller;
  final _aiSlot = AiPageSlot();
  String? _aiValue;
  bool _edited = false;
  bool _picking = false;

  bool get _invalid =>
      _edited &&
      _controller.text.trim().isNotEmpty &&
      _validMonth(_controller.text) == null;

  bool get _aiFilled => _aiValue != null && _aiValue == _controller.text;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value ?? '');
  }

  @override
  void didUpdateWidget(covariant UtenMonthField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value ?? '';
    }
    _aiAttach();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _aiAttach();
  }

  @override
  void dispose() {
    _aiSlot.detach();
    _controller.dispose();
    super.dispose();
  }

  void _aiAttach() => _aiSlot.attach(
    context,
    AiFieldSource(
      capture: (ctx) => AiFieldSnapshot(
        label: widget.label,
        value: aiSnapshotValue(_controller.text, AiSnapshotLimits.info),
        state: _invalid
            ? AiFieldState.error
            : _aiFilled
            ? AiFieldState.autofilled
            : AiFieldState.normal,
        message: _invalid
            ? '请输入有效年月，如 2018-07'
            : _aiFilled
            ? ctx.l10n.fieldAiFilledReview
            : null,
      ),
      setValue: widget.enabled
          ? (value, ctx) async {
              final month = _validMonth(value);
              if (!mounted || !widget.enabled) {
                throw AiActionFailure(
                  ctx.l10n.aiActionFieldReadOnly(widget.label),
                );
              }
              if (month == null) {
                throw AiActionFailure(ctx.l10n.aiActionDateInvalid);
              }
              final normalized = UtenMonthField.format(month);
              setState(() {
                _controller.text = normalized;
                _edited = true;
                _aiValue = normalized;
              });
              widget.onChanged(normalized);
            }
          : null,
    ),
  );

  DateTime? _validMonth(String? raw) {
    final parsed = UtenMonthField.parse(raw);
    return parsed != null &&
            parsed.year >= widget.firstYear &&
            parsed.year <= widget.lastYear
        ? parsed
        : null;
  }

  Future<void> _pick() async {
    if (!widget.enabled || _picking) return;
    _picking = true;
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      final current = _validMonth(_controller.text) ?? ChinaDateTime.today();
      final year = current.year.clamp(widget.firstYear, widget.lastYear);
      final month = await showUtenMonthPicker(
        context: context,
        firstYear: widget.firstYear,
        lastYear: widget.lastYear,
        initialMonth: DateTime(year, current.month),
        helpText: widget.label,
      );
      if (month == null || !mounted || !widget.enabled) return;
      final value = UtenMonthField.format(month);
      setState(() {
        _aiValue = null;
        _edited = true;
        _controller.text = value;
      });
      widget.onChanged(value);
    } finally {
      _picking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconExtent = UtenTableCellInputTheme.contains(context)
        ? UtenEditableGridCellSpec.heightOf(context)
        : UtenPageField.heightOf(context);
    return TextField(
      controller: _controller,
      enabled: widget.enabled,
      decoration: applyAutofillHint(
        UtenInputDecoration(
          InputDecoration(
            labelText: widget.label,
            hintText: '如 2018-07',
            error: _invalid
                ? const UtenFieldMessage.error('请输入有效年月，如 2018-07')
                : null,
            suffixIcon: IconButton(
              constraints: BoxConstraints.tightFor(
                width: iconExtent,
                height: iconExtent,
              ),
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
              ),
              tooltip: '选择${widget.label}',
              onPressed: widget.enabled ? _pick : null,
              icon: const Icon(Icons.event_outlined, size: 18),
            ),
          ),
          info: [
            '可输入年月，也可点击日历选择月份。',
            if (widget.info case final String info when info.trim().isNotEmpty)
              info,
          ].join('\n'),
        ),
        Theme.of(context),
        autofilled: _aiFilled,
      ),
      onChanged: (value) {
        setState(() {
          _edited = true;
          _aiValue = null;
        });
        final month = _validMonth(value);
        // 无效输入也回传，保存时由服务端拒绝，不能悄悄提交上一次有效值。
        widget.onChanged(
          value.trim().isEmpty
              ? null
              : month == null
              ? value.trim()
              : UtenMonthField.format(month),
        );
      },
    );
  }
}

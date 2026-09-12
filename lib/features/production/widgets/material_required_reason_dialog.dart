import 'package:flutter/material.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';

// 通用「必填原因」对话框：标题/初始值/说明文案/确认按钮文案由调用方给定。
// 说明文案走 fieldLabel 的 ⓘ 悬停提示（Tooltip 不依赖 LayoutBuilder，
// 与 AlertDialog 固有宽度量测兼容）。
class MaterialRequiredReasonDialog extends StatefulWidget {
  const MaterialRequiredReasonDialog({
    super.key,
    required this.title,
    required this.fieldKey,
    required this.initialValue,
    required this.info,
    required this.confirmLabel,
    this.requireReason = true,
    this.reasonLabel,
    this.minReasonLength = 1,
    this.maxReasonLength = 1000,
  });

  final String title;
  final Key fieldKey;
  final String initialValue;
  final String info;
  final String confirmLabel;
  final bool requireReason;
  final String? reasonLabel;
  final int minReasonLength;
  final int maxReasonLength;

  @override
  State<MaterialRequiredReasonDialog> createState() =>
      _MaterialRequiredReasonDialogState();
}

class _MaterialRequiredReasonDialogState
    extends State<MaterialRequiredReasonDialog> {
  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: TextFormField(
            key: widget.fieldKey,
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (value) {
              final reason = value?.trim() ?? '';
              if (widget.requireReason && reason.isEmpty) {
                return l10n.materialReasonRequired;
              }
              if (reason.isNotEmpty && reason.length < widget.minReasonLength) {
                return l10n.materialReasonTooShort(widget.minReasonLength);
              }
              if (reason.length > widget.maxReasonLength) {
                return l10n.materialReasonTooLong(widget.maxReasonLength);
              }
              return null;
            },
            errorBuilder: utenTextFieldErrorBuilder,
            decoration: UtenInputDecoration(
              InputDecoration(
                label: fieldLabel(
                  widget.reasonLabel ?? l10n.materialReasonLabel,
                  Theme.of(context),
                  required: widget.requireReason,
                  info: widget.info,
                ),
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final value = _controller.text.trim();
            Navigator.pop(context, value);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

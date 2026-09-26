import 'package:flutter/material.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';

/// The caller retains the draft reason while its review command is retried.
Future<String?> showProductionReviewReasonDialog(
  BuildContext context, {
  required String title,
  required String initialValue,
  required ValueChanged<String> onDraftChanged,
}) => showDialog<String>(
  context: context,
  builder: (_) => _ProductionReviewReasonDialog(
    title: title,
    initialValue: initialValue,
    onDraftChanged: onDraftChanged,
  ),
);

class _ProductionReviewReasonDialog extends StatefulWidget {
  const _ProductionReviewReasonDialog({
    required this.title,
    required this.initialValue,
    required this.onDraftChanged,
  });
  final String title;
  final String initialValue;
  final ValueChanged<String> onDraftChanged;
  @override
  State<_ProductionReviewReasonDialog> createState() =>
      _ProductionReviewReasonDialogState();
}

class _ProductionReviewReasonDialogState
    extends State<_ProductionReviewReasonDialog> {
  late final TextEditingController controller = TextEditingController(
    text: widget.initialValue,
  );
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: form,
      child: TextFormField(
        controller: controller,
        minLines: 2,
        maxLines: 4,
        maxLength: 500,
        onChanged: widget.onDraftChanged,
        errorBuilder: utenTextFieldErrorBuilder,
        // maxLength 的 0/N 计数默认占一整行把多行框顶高（全站口径：限制仍
        // 生效、计数不渲染）。
        decoration: const UtenInputDecoration(
          InputDecoration(labelText: '原因（必填）', counterText: ''),
        ),
        validator: (value) =>
            (value?.trim().length ?? 0) < 2 ? '请填写 2 至 500 字的原因' : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, controller.text.trim());
          }
        },
        child: const Text('确认'),
      ),
    ],
  );
}

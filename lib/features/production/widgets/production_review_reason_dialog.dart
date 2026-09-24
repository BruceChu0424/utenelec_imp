import 'package:flutter/material.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';

/// The caller retains the draft reason while its review command is retried.
Future<String?> showProductionReviewReasonDialog(
  BuildContext context, {
  required String title,
  required String initialValue,
  required ValueChanged<String> onDraftChanged,
}) async {
  final controller = TextEditingController(text: initialValue);
  final form = GlobalKey<FormState>();
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Form(
          key: form,
          child: TextFormField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
            maxLength: 500,
            onChanged: onDraftChanged,
            errorBuilder: utenTextFieldErrorBuilder,
            // maxLength 的 0/N 计数默认占一整行把多行框顶高（全站口径：限制仍
            // 生效、计数不渲染）。
            decoration: const UtenInputDecoration(
              InputDecoration(
                labelText: '原因（必填）',
                counterText: '',
              ),
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
      ),
    );
  } finally {
    // 弹窗退场动画期间 TextFormField 还会重建（计数/错误），立刻 dispose 会让
    // 「确认后失败重开」的链路踩「used after being disposed」；延迟到动画后释放。
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
  }
}

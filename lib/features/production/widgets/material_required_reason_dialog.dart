import 'package:flutter/material.dart';

// 通用「必填原因」对话框：标题/初始值/辅助文案/确认按钮文案由调用方给定。
class MaterialRequiredReasonDialog extends StatefulWidget {
  const MaterialRequiredReasonDialog({
    super.key,
    required this.title,
    required this.fieldKey,
    required this.initialValue,
    required this.helperMessage,
    required this.confirmLabel,
  });

  final String title;
  final Key fieldKey;
  final String initialValue;
  final String helperMessage;
  final String confirmLabel;

  @override
  State<MaterialRequiredReasonDialog> createState() =>
      _MaterialRequiredReasonDialogState();
}

class _MaterialRequiredReasonDialogState
    extends State<MaterialRequiredReasonDialog> {
  late final TextEditingController _controller;

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
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: widget.fieldKey,
      controller: _controller,
      autofocus: true,
      minLines: 2,
      maxLines: 4,
      decoration: InputDecoration(
        labelText: '原因(必填)',
        // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing does not support LayoutBuilder.
        helperText: widget.helperMessage,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final value = _controller.text.trim();
          if (value.isEmpty) return;
          Navigator.pop(context, value);
        },
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}

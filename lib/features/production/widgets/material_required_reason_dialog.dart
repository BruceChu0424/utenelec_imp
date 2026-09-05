import 'package:flutter/material.dart';

import '../../../components/inputs/required_field_decoration.dart';

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
  });

  final String title;
  final Key fieldKey;
  final String initialValue;
  final String info;
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
        label: fieldLabel('原因(必填)', Theme.of(context), info: widget.info),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_input_decoration.dart';

/// Shared dense grid input; review state belongs to its row controller.
class WarehouseAutofillTextField extends StatelessWidget {
  const WarehouseAutofillTextField({
    super.key,
    required this.controller,
    required this.source,
    this.enabled = true,
    this.onChanged,
    this.hintText = '可修改',
    this.inputFormatters,
    this.sourceOf,
  });

  final UtenAutofillTextController controller;
  final String source;
  final bool enabled;
  final String hintText;
  final List<TextInputFormatter>? inputFormatters;

  /// 预填来源会随值异步变化时传入：每次值变化重绘都现取来源说明(优先于 [source])。
  final String Function()? sourceOf;

  /// 用户敲键盘时回调（用于「勾选多行后改一行 = 改一批」的同步落值）。
  /// 程序回写 controller.text 不会触发，不会形成回环。
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, _, _) => TextField(
          controller: controller,
          enabled: enabled,
          onChanged: onChanged,
          inputFormatters: inputFormatters,
          decoration: applyAutofillHint(
            UtenInputDecoration(
              InputDecoration(hintText: hintText, isDense: true),
              info: controller.autofilled ? (sourceOf?.call() ?? source) : null,
            ),
            Theme.of(context),
            autofilled: controller.autofilled,
          ),
        ),
      );
}

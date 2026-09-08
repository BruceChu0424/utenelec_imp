import 'package:flutter/material.dart';

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
  });

  final UtenAutofillTextController controller;
  final String source;
  final bool enabled;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, _, _) => TextField(
          controller: controller,
          enabled: enabled,
          decoration: applyAutofillHint(
            UtenInputDecoration(
              const InputDecoration(hintText: '可修改', isDense: true),
              info: controller.autofilled ? source : null,
            ),
            Theme.of(context),
            autofilled: controller.autofilled,
          ),
        ),
      );
}

import 'package:flutter/material.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';

/// The API stores a ratio (0.1); production forms display a percentage (10).
/// Keep the same decimal precision and range as the planning approval ledger.
double? parseProductionOverproductionPercent(String text) {
  final raw = text.trim();
  if (!RegExp(r'^(?:\d+(?:\.\d{0,4})?|\.\d{1,4})$').hasMatch(raw)) return null;
  final percent = double.tryParse(raw);
  if (percent == null ||
      !percent.isFinite ||
      percent < 0 ||
      percent >= 100000) {
    return null;
  }
  return double.parse((percent / 100).toStringAsFixed(6));
}

String productionOverproductionPercentText(double rate) =>
    (rate * 100).toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

class ProductionOverproductionRateField extends StatelessWidget {
  const ProductionOverproductionRateField({
    super.key,
    required this.controller,
    this.enabled = true,
    this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: onChanged,
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              suffixText: '%',
              hintText: '0',
              error: parseProductionOverproductionPercent(value.text) == null
                  ? const UtenFieldMessage.error('请输入非负百分比，最多 4 位小数')
                  : null,
            ),
          ),
        ),
      );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/widgets/currency_text.dart';
import '../providers/currency_dict.dart';

/// Shared by goods full-page forms, inline editing and inline creation.
class GoodsCurrencyField extends ConsumerWidget {
  const GoodsCurrencyField({
    super.key,
    required this.value,
    required this.onChanged,
    this.currentName,
    this.currentCode,
    this.dense = false,
    this.readOnly = false,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String? currentName;
  final String? currentCode;
  final bool dense;
  final bool readOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (readOnly) {
      return InputDecorator(
        decoration: const UtenInputDecoration(InputDecoration(labelText: '币种')),
        child: CurrencyText(name: currentName, code: currentCode),
      );
    }
    final dictionary = ref.watch(currencyDictProvider);
    if (dictionary.hasError) {
      return TextButton(
        onPressed: () => ref.invalidate(currencyDictProvider),
        child: const Text('重新加载币种'),
      );
    }
    final entries = dictionary.value ?? const [];
    final selected = value?.trim().isEmpty == true ? null : value;
    return UtenDropdownField(
      key: const ValueKey('goods-currency-field'),
      label: dense ? null : '币种',
      hintText: '未登记',
      info: dense ? null : '货品价格使用的币种；变更币种不会自动换算价格。',
      dense: dense,
      menuMatchContentWidth: true,
      enabled: dictionary.hasValue,
      value: selected,
      items: [
        if (selected != null && !entries.any((entry) => entry.id == selected))
          UtenDropdownItem(
            value: selected,
            label:
                financeCurrencyDisplayLabel(
                  name: currentName,
                  code: currentCode,
                ) ??
                '未登记',
            foregroundColor: currencyTextColor(
              context,
              name: currentName,
              code: currentCode,
            ),
            visible: false,
          ),
        for (final entry in entries)
          UtenDropdownItem(
            value: entry.id,
            enabled: entry.status != '禁用' || entry.id == selected,
            visible: entry.status != '禁用' || entry.id == selected,
            label:
                financeCurrencyDisplayLabel(
                  name: entry.name,
                  code: entry.code,
                ) ??
                '未登记',
            foregroundColor: currencyTextColor(
              context,
              name: entry.name,
              code: entry.code,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

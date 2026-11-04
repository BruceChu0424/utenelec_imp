import '../../../shared/formatters/exact_decimal.dart';
export '../models/goods_bom_copy.dart';
import 'package:flutter/material.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/goods_bom_item.dart';
import '../models/goods_node.dart';

/// The compact quantity input shared by single-product and batch assembly maintenance.
class BomComponentQuantityField extends StatelessWidget {
  const BomComponentQuantityField({
    super.key,
    required this.goods,
    required this.controller,
    this.enabled = true,
    this.fieldKey,
    this.onChanged,
  });

  final GoodsListItem goods;
  final TextEditingController controller;
  final bool enabled;
  final Key? fieldKey;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final invalid = !bomDesignQuantityValid(controller.text);
        final border = BorderSide(
          color: invalid
              ? theme.colorScheme.error
              : theme.colorScheme.outlineVariant,
        );
        return TextField(
          key: fieldKey,
          controller: controller,
          enabled: enabled,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: theme.textTheme.bodyMedium,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: goods.isPeriodicIssue
                ? bomPeriodicQuantityLabel(context, goods.unitName)
                : AppLocalizations.of(context).bomDesignQty,
            suffixText: goods.isPeriodicIssue ? null : goods.unitName ?? '',
            isDense: true,
            contentPadding: const EdgeInsets.all(UtenSpacing.s8),
            border: OutlineInputBorder(borderSide: border),
            enabledBorder: OutlineInputBorder(borderSide: border),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: invalid
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
                width: 1.6,
              ),
            ),
          ),
        );
      },
    );
  }
}

bool bomDesignQuantityValid(String raw) {
  final value = financeAmountUnits(raw);
  return value != null &&
      value > BigInt.zero &&
      value < BigInt.from(10).pow(64);
}

String? bomDesignQtyError(AppLocalizations l10n, String raw) =>
    raw.trim().isEmpty
    ? l10n.bomDesignQtyRequired
    : bomDesignQuantityValid(raw)
    ? null
    : l10n.bomDesignQtyInvalid;

String bomPeriodicQuantityLabel(BuildContext context, String? unitName) {
  if (periodicGramsPerBaseUnit(unitName) != null) {
    return AppLocalizations.of(context).wmUnitWeightGrams;
  }
  return AppLocalizations.of(context).goodsBomBatchWeightUnit(
    unitName?.trim().isNotEmpty == true ? unitName! : '—',
  );
}

/// A periodic edge is entered in grams when its base unit has a mass conversion.
Map<String, dynamic> periodicBomQuantityBody(
  String componentId,
  Object entered,
  String? unitName,
) {
  final factor = periodicGramsPerBaseUnit(unitName);
  final exact = financeExactDecimal(entered);
  if (exact == null || !bomDesignQuantityValid(exact)) {
    throw ArgumentError.value(
      entered,
      'entered',
      'must be an exact positive native quantity',
    );
  }
  return {
    'componentGoodsId': componentId,
    if (factor == null) 'qty': exact else 'unitWeightGrams': exact,
  };
}

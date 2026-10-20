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
        final value = double.tryParse(controller.text.trim());
        final invalid = value == null || !value.isFinite || value <= 0;
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
  double entered,
  String? unitName,
) {
  final factor = periodicGramsPerBaseUnit(unitName);
  return {
    'componentGoodsId': componentId,
    'qty': factor == null
        ? entered
        : double.parse((entered / factor).toStringAsFixed(5)),
    if (factor != null) 'unitWeightGrams': entered,
  };
}

/// Copy design values only; learning quantities and audit flags belong to the original edge.
Map<String, dynamic> bomComponentCopyBody(GoodsBomItem item) => {
  'componentGoodsId': item.componentGoodsId,
  'qty': item.qty,
  'price': item.price,
  'total': item.total,
  'summary': item.summary,
  if (!item.isPeriodicEdge) ...{
    'controlStage': item.controlStage.code,
    'consumptionBasis': item.consumptionBasis.code,
    'basisOutputQty': item.basisOutputQty,
    'allowPartialPackage': item.allowPartialPackage,
    'hardGate': item.hardGate,
  },
  if (item.colorId != null) 'colorId': item.colorId,
  if (item.defaultSupplierId != null)
    'defaultSupplierId': item.defaultSupplierId,
};

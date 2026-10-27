import 'package:flutter/material.dart';

import '../../features/basic_data/widgets/master_data_table_view.dart';
import '../formatters/exact_decimal.dart';
import '../formatters/quantity_display.dart';
import '../presentation/procurement_delivery_difference_l10n.dart';

export '../presentation/procurement_delivery_difference_l10n.dart'
    show ProcurementDifferenceScope;

/// Displays server-authored facts; an unavailable or masked fact stays unknown.
/// Local document details may filter their complete rows. Paged task hosts must
/// keep filtering and sorting under their existing server query contract.
MasterColumnDef<T> procurementDifferenceColumn<T>({
  required BuildContext context,
  required String? Function(T) differenceOf,
  required String? Function(T) unitOf,
  String key = 'differenceQty',
  ProcurementDifferenceScope scope = ProcurementDifferenceScope.order,
  bool filterFromRows = true,
}) {
  final words = procurementDeliveryDifferenceL10n(context);
  String display(T item) {
    final value = formatExactQtyWithUnit(differenceOf(item), unitOf(item));
    return value.isEmpty ? '—' : value;
  }

  return MasterColumnDef<T>(
    key: key,
    label: words.labelFor(scope),
    width: 130,
    type: 'number',
    sortable: true,
    filterFromRows: filterFromRows,
    info: words.hintFor(scope),
    value: display,
    exactValueOf: differenceOf,
    cellBuilder: (context, item) {
      final exact = financeExactTrimmed(
        financeExactDecimal(differenceOf(item)),
      );
      final outstanding =
          exact != null && exact.startsWith('-') && exact != '-0';
      final selection = MasterDataTableCellScope.maybeOf(context);
      return Text(
        display(item),
        style: outstanding
            ? TextStyle(
                color: selection?.selected == true
                    ? selection?.foregroundColor
                    : Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w700,
              )
            : null,
      );
    },
  );
}

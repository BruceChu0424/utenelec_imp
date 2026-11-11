import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';

typedef ReturnProbeRow = ({
  TextEditingController qty,
  TextEditingController price,
  String? upstreamItemId,
});

/// Captures the actual controller once, so retirement checks can still inspect its preserved rows.
class ReturnProbeGrid {
  ReturnProbeGrid._(this._read);
  final List<ReturnProbeRow> Function() _read;
  List<ReturnProbeRow> get rows => _read();

  factory ReturnProbeGrid.capture(WidgetTester tester, bool purchase) {
    if (purchase) {
      final controller = tester
          .widget<UtenEditableGrid<PurchaseGridRow>>(
            find.byType(UtenEditableGrid<PurchaseGridRow>),
          )
          .controller;
      return ReturnProbeGrid._(
        () => [
          for (final row in controller.rows)
            (
              qty: row.qty,
              price: row.price,
              upstreamItemId: row.upstreamItemId,
            ),
        ],
      );
    }
    final controller = tester
        .widget<UtenEditableGrid<SubcontractGridRow>>(
          find.byType(UtenEditableGrid<SubcontractGridRow>),
        )
        .controller;
    return ReturnProbeGrid._(
      () => [
        for (final row in controller.rows)
          (qty: row.qty, price: row.price, upstreamItemId: row.upstreamItemId),
      ],
    );
  }
}

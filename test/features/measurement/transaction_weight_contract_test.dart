import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('physical document editors preserve optional actual line weight', () {
    final stockGrid = source(
      'lib/features/warehouse/widgets/stock_grid_columns.dart',
    );
    final stockEdit = source(
      'lib/features/warehouse/pages/stock_doc_edit_page.dart',
    );
    final purchaseGrid = source(
      'lib/features/purchase/widgets/purchase_grid_columns.dart',
    );
    final purchaseEdit = source(
      'lib/features/purchase/pages/purchase_doc_edit_page.dart',
    );
    final salesGrid = source(
      'lib/features/sales/widgets/sales_grid_columns.dart',
    );
    final salesEdit = source(
      'lib/features/sales/pages/sales_doc_edit_page.dart',
    );
    final arrival = source(
      'lib/features/warehouse/pages/warehouse_arrival_receipt_page.dart',
    );
    final dailyGrid = source(
      'lib/features/production/widgets/production_daily_grid_columns.dart',
    );
    final dailyEdit = source(
      'lib/features/production/pages/production_daily_report_edit_page.dart',
    );

    for (final grid in [stockGrid, purchaseGrid, salesGrid, dailyGrid]) {
      expect(grid, contains("key: 'weight'"));
      expect(grid, contains("label: '实际重量'"));
    }
    for (final edit in [
      stockEdit,
      purchaseEdit,
      salesEdit,
      arrival,
      dailyEdit,
    ]) {
      expect(edit, contains("'weight'"));
      expect(edit, contains('实际重量必须大于 0'));
    }
  });

  test('business quantity keeps unit rate and never derives parcel count', () {
    final picker = source(
      'lib/components/layout/uten_doc_link_picker_sheet.dart',
    );
    final purchaseEdit = source(
      'lib/features/purchase/pages/purchase_doc_edit_page.dart',
    );
    final salesEdit = source(
      'lib/features/sales/pages/sales_doc_edit_page.dart',
    );

    expect(picker, contains('unitRate: _cfg.itemFields.unitRate?.call(it)'));
    expect(purchaseEdit, contains("'unitRate': r.unitRate"));
    expect(salesEdit, contains("'unitRate': r.unitRate"));
    expect(salesEdit, isNot(contains('_computedParcelCount')));
    expect(salesEdit, contains("labelText: '物流件数'"));
    expect(salesEdit, contains('measurementTotalsText('));
  });

  test('arrival, batch shipment and stock ledger expose weight', () {
    final batch = source(
      'lib/features/sales/widgets/sales_batch_ship_panel.dart',
    );
    final movementModel = source('lib/features/stock/models/stock_query.dart');
    final movementPage = source(
      'lib/features/stock/pages/stock_movement_page.dart',
    );

    expect(batch, contains("'weight': ?weight"));
    expect(movementModel, contains("weight: (json['weight'] as num?)"));
    expect(movementModel, contains("unitId: json['unitId'] as String?"));
    expect(movementPage, contains("label: '实际重量'"));
    expect(movementPage, contains("label: '单位'"));
  });
}

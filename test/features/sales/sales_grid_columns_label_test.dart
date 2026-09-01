import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';

void main() {
  test('销售单据数量列统一使用“数量”', () {
    final orderColumns = salesGridColumns(
      onPickGoods: (_) async {},
      docType: SalesDocType.order,
      colorEntries: const {},
      unitEntries: const {},
    );
    final shipmentColumns = salesGridColumns(
      onPickGoods: (_) async {},
      docType: SalesDocType.shipment,
      colorEntries: const {},
      unitEntries: const {},
    );

    expect(
      orderColumns.singleWhere((column) => column.key == 'qty').label,
      '数量',
    );
    expect(
      shipmentColumns.singleWhere((column) => column.key == 'qty').label,
      '数量',
    );
  });
}

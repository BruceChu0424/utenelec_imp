import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';

void main() {
  test('stock document item parses optional weight', () {
    final item = StockDocItem.fromJson({
      'id': 'line-1',
      'qty': 8,
      'weight': 3.75,
    });
    final legacyItem = StockDocItem.fromJson({'id': 'line-2', 'qty': 2});

    expect(item.qty, 8);
    expect(item.weight, 3.75);
    expect(legacyItem.weight, isNull);
  });

  test('stock document detail chooser includes weight and quantity facts', () {
    final source = File(
      'lib/features/warehouse/pages/stock_doc_detail_page.dart',
    ).readAsStringSync();

    expect(source, contains("key: 'weight'"));
    expect(source, contains("label: '重量'"));
    expect(source, contains('it.weight?.toStringAsFixed(2)'));

    for (final quantityKey in [
      'bookQty',
      'countQty',
      'surplusQty',
      'qty',
      'issuedQty',
      'remainingQty',
      'reportedQty',
      'acceptedQty',
    ]) {
      expect(
        source,
        contains("key: '$quantityKey'"),
        reason: '$quantityKey must remain available to the column chooser',
      );
    }
  });
}

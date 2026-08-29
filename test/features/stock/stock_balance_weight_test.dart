import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';

void main() {
  test('balance row parses inventory weight', () {
    final row = BalanceRow.fromJson({
      'id': 'balance-1',
      'qty': 12.5,
      'weight': 7.25,
    });

    expect(row.qty, 12.5);
    expect(row.weight, 7.25);
  });

  test('stock balance table keeps quantity and exposes sortable weight', () {
    final source = File(
      'lib/features/stock/pages/stock_balance_page.dart',
    ).readAsStringSync();

    expect(source, contains("key: 'qty'"));
    expect(source, contains("label: '数量'"));

    final weightStart = source.indexOf("key: 'weight'");
    expect(weightStart, greaterThanOrEqualTo(0));
    final weightColumn = source.substring(
      weightStart,
      source.indexOf('),', weightStart) + 2,
    );
    expect(weightColumn, contains("label: '库存重量'"));
    expect(weightColumn, contains("type: 'number'"));
    expect(weightColumn, contains('sortable: true'));
    expect(weightColumn, contains('b.weight?.toStringAsFixed(2)'));
  });
}

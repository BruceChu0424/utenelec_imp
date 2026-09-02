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

  test('stock item detail keeps quantity and exposes sortable weight', () {
    // 库存余额并入库存详情页（/stock/item/:goodsId）后，数量/重量列契约随之迁移。
    final source = File('lib/features/stock/pages/stock_item_detail_page.dart')
        .readAsStringSync();

    expect(source, contains("key: 'qty'"));
    expect(source, contains("label: '当前数量'"));

    final weightStart = source.indexOf("key: 'weight'");
    expect(weightStart, greaterThanOrEqualTo(0));
    final weightColumn = source.substring(
      weightStart,
      source.indexOf('),', weightStart) + 2,
    );
    expect(weightColumn, contains("label: '库存重量'"));
    expect(weightColumn, contains("type: 'number'"));
    expect(weightColumn, contains('sortable: true'));
  });
}

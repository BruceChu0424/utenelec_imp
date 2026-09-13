import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';

void main() {
  test(
    'partial workshop request keeps original demand while limiting warehouse issue',
    () {
      final item = StockDocItem.fromJson({
        'id': 'line',
        'qty': 1000,
        'requestedQty': 10,
        'issuedQty': 4,
      });
      expect(item.qty, 1000);
      expect(item.remainingQty, 6);
      expect(
        StockDocItem.fromJson({
          'qty': 1000,
          'requestedQty': 0,
          'issuedQty': 0,
        }).remainingQty,
        0,
      );
      expect(
        StockDocItem.fromJson({'qty': 1000, 'issuedQty': 4}).remainingQty,
        996,
      );
    },
  );
}

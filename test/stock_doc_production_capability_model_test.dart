import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';

void main() {
  group('stock document production capabilities', () {
    test('older response without capabilities fails closed', () {
      final detail = StockDocDetail.fromJson({'id': 'doc-1'});

      expect(detail.productionLinked, isFalse);
      expect(detail.canEdit, isFalse);
      expect(detail.canDelete, isFalse);
    });

    test('preserves authoritative production restriction', () {
      final detail = StockDocDetail.fromJson({
        'id': 'doc-1',
        'productionLinked': true,
        'canEdit': false,
        'canDelete': false,
        'restrictionReason': '请在对应生产任务中维护',
      });

      expect(detail.productionLinked, isTrue);
      expect(detail.canEdit, isFalse);
      expect(detail.canDelete, isFalse);
      expect(detail.restrictionReason, '请在对应生产任务中维护');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';

void main() {
  group('sales server capability fields', () {
    test('default to fail-closed when an older response omits them', () {
      final list = SalesDocListItem.fromJson({'id': 'doc-1'});
      final detail = SalesDocDetail.fromJson({'id': 'doc-1'});
      final line = ShippableLine.fromJson({
        'orderItemId': 'line-1',
        'orderId': 'order-1',
      });

      expect(list.writable, isFalse);
      expect(list.canReject, isFalse);
      expect(detail.writable, isFalse);
      expect(detail.canReject, isFalse);
      expect(line.writable, isFalse);
    });

    test('preserve capabilities returned by the server', () {
      final list = SalesDocListItem.fromJson({
        'id': 'doc-1',
        'writable': true,
        'canReject': true,
      });
      final detail = SalesDocDetail.fromJson({
        'id': 'doc-1',
        'writable': true,
        'canReject': true,
      });
      final line = ShippableLine.fromJson({
        'orderItemId': 'line-1',
        'orderId': 'order-1',
        'writable': true,
      });

      expect(list.writable, isTrue);
      expect(list.canReject, isTrue);
      expect(detail.writable, isTrue);
      expect(detail.canReject, isTrue);
      expect(line.writable, isTrue);
    });
  });
}

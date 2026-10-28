import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/widgets/bom_component_quantity_field.dart';

void main() {
  test(
    'copy payload retains all exact design decimals while numeric API remains available',
    () {
      final item = GoodsBomItem.fromJson({
        'id': 'edge',
        'componentGoodsId': 'component',
        'qty': 1234567890123.1235,
        'qtyText': '1234567890123.12345',
        'price': 12345678901234.568,
        'priceText': '12345678901234.5678',
        'total': 12345678901234.988,
        'totalText': '12345678901234.9876',
        'basisOutputQty': 1234567890123.5432,
        'basisOutputQtyText': '1234567890123.54321',
        'unitWeightGrams': 1.234567,
        'unitWeightGramsText': '1.234567',
      });
      expect(item.qty, isA<double>());
      expect(item.price, isA<double>());
      expect(item.designQtyText, '1234567890123.12345');
      expect(item.basisOutputQtyText, '1234567890123.54321');
      expect(item.unitWeightGramsExactText, '1.234567');
      final body = bomComponentCopyBody(item)..['summary'] = '只修改备注';
      expect(body['qty'], '1234567890123.12345');
      expect(body['price'], '12345678901234.5678');
      expect(body['total'], '12345678901234.9876');
      expect(body['basisOutputQty'], '1234567890123.54321');
      body['qty'] = 2.5;
      expect(body['qty'], 2.5);
      expect(body['price'], '12345678901234.5678');
    },
  );

  test(
    'legacy numeric responses and explicitly constructed models keep copy compatibility',
    () {
      final item = GoodsBomItem.fromJson({
        'id': 'edge',
        'componentGoodsId': 'component',
        'qty': 2,
        'price': 3,
        'total': 6,
        'basisOutputQty': 10,
      });
      expect(bomComponentCopyBody(item), containsPair('qty', 2));
      expect(bomComponentCopyBody(item), containsPair('price', 3));
      expect(bomComponentCopyBody(item), containsPair('total', 6));
      expect(bomComponentCopyBody(item), containsPair('basisOutputQty', 10));
    },
  );

  test(
    'exact decimal strings from a local draft remain exact after model materialization',
    () {
      final item = GoodsBomItem.fromJson({
        'id': 'draft',
        'componentGoodsId': 'component',
        'qty': '1234567890123.12345',
        'price': '0.1234',
        'total': null,
        'basisOutputQty': '1.00001',
      });
      expect(item.qtyExactText, '1234567890123.12345');
      expect(bomComponentCopyBody(item)['qty'], '1234567890123.12345');
      expect(item.price, 0.1234);
      expect(item.totalExactText, isNull);
      expect(item.basisOutputQtyText, '1.00001');
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';

void main() {
  test(
    'master two-place display keeps the server decimal text used by header comparisons',
    () {
      final goods = GoodsListItem.fromJson({
        'id': 'goods',
        'price': 1.005,
        'discount': 0.905,
        'stockQty': 9007199254740993.25,
        'priceDisplayText': '1.01',
        'discountDisplayText': '0.91',
        'stockQtyDisplayText': '9007199254740993.25',
      });
      expect(goods.priceDisplayText, '1.01');
      expect(goods.discountDisplayText, '0.91');
      expect(goods.stockQtyDisplayText, '9007199254740993.25');
      final client = ClientListItem.fromJson({
        'id': 'client',
        'credit': 1.005,
        'creditFloor': 0.005,
        'creditDisplayText': '1.01',
        'creditFloorDisplayText': '0.01',
      });
      expect(client.creditDisplayText, '1.01');
      expect(client.creditFloorDisplayText, '0.01');
      expect(
        GoodsListItem.fromJson({
          'id': 'masked',
          'price': null,
          'priceDisplayText': null,
        }).priceDisplayText,
        isNull,
      );
    },
  );
}

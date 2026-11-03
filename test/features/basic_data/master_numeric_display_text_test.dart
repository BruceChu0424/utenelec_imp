import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';

void main() {
  test(
    'goods list and detail preserve full server price and legacy decimal text',
    () {
      for (final raw in [
        '0.914',
        '1.005',
        '99999999999999.1234567890',
        '0.0000000001',
        '0',
      ]) {
        final json = <String, dynamic>{
          'id': 'goods',
          'price': 0.82,
          'priceDisplayText': raw,
        };
        final expected = raw == '99999999999999.1234567890'
            ? '99999999999999.123456789'
            : raw;
        expect(GoodsListItem.fromJson(json).priceText, expected);
        expect(GoodsDetail.fromJson(json).priceText, expected);
        final legacy = <String, dynamic>{'id': 'legacy', 'price': raw};
        expect(GoodsListItem.fromJson(legacy).priceText, expected);
        expect(GoodsDetail.fromJson(legacy).priceText, expected);
      }
      expect(const GoodsListItem(id: 'old', price: 0.914).priceText, '0.914');
      expect(
        GoodsListItem.fromJson({'id': 'null', 'price': null}).priceText,
        isNull,
      );
      expect(
        GoodsDetail.fromJson({
          'id': 'masked',
          'price': 0.914,
          'priceMasked': true,
        }).priceText,
        isNull,
      );
    },
  );

  test(
    'opt-in exact money field submits original price text without double conversion',
    () {
      final controller = MasterEditFormController(
        fields: const [
          MasterFieldDef(
            key: 'price',
            label: '价格',
            type: MasterFieldType.money,
            exactDecimal: true,
          ),
        ],
        initialValues: const {'price': '99999999999999.1234567890'},
      );
      addTearDown(controller.dispose);
      expect(controller.buildBody()!['price'], '99999999999999.1234567890');
      controller.controllers['price']!.text = '0.914';
      expect(controller.buildBody()!['price'], '0.914');
      controller.controllers['price']!.text = 'invalid';
      expect(controller.buildBody(), isNull);
    },
  );

  test(
    'master display keeps exact goods price text and existing other numeric contracts',
    () {
      final goods = GoodsListItem.fromJson({
        'id': 'goods',
        'price': 1.005,
        'discount': 0.905,
        'stockQty': 9007199254740993.25,
        'priceDisplayText': '1.005',
        'discountDisplayText': '0.91',
        'stockQtyDisplayText': '9007199254740993.25',
      });
      expect(goods.priceDisplayText, '1.005');
      expect(goods.priceText, '1.005');
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

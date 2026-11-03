import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/currency_display.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';

void main() {
  test('registered prices require explicit server base-currency proof', () {
    for (final proof in [false, null]) {
      expect(
        baseCurrencyPricePreview(
          price: 12.3456,
          currencyId: 'currency-usd',
          currencyIsBase: proof,
        ),
        isNull,
      );
    }
    expect(
      baseCurrencyPricePreview(
        price: 12.3456,
        currencyId: 'currency-base',
        currencyIsBase: true,
      ),
      12.3456,
    );
  });

  test(
    'unregistered legacy, masked and zero prices retain their contracts',
    () {
      for (final price in [12.3456, 0.0, null]) {
        expect(
          baseCurrencyPricePreview(
            price: price,
            currencyId: null,
            currencyIsBase: null,
          ),
          price,
        );
      }
      expect(
        baseCurrencyPricePreview(
          price: null,
          currencyId: 'currency-base',
          currencyIsBase: true,
        ),
        isNull,
      );
    },
  );

  test(
    'goods delegates to the common rule without mutating original currency facts',
    () {
      for (final proof in [false, null]) {
        final foreign = GoodsListItem(
          id: 'foreign',
          price: 12.3456,
          currencyId: 'currency-usd',
          currencyName:
              '人民币', // A display label cannot prove currency identity.
          currencyIsBase: proof,
        );
        expect(foreign.baseCurrencyPrice, isNull);
        expect(foreign.price, 12.3456);
        expect(foreign.currencyId, 'currency-usd');
      }
      const base = GoodsListItem(
        id: 'base',
        price: 12.3456,
        currencyId: 'currency-base',
        currencyName: '公司本位币',
        currencyIsBase: true,
      );
      expect(base.baseCurrencyPrice, 12.3456);
      const legacy = GoodsListItem(id: 'legacy', price: 12.3456);
      expect(legacy.baseCurrencyPrice, 12.3456);
      expect(legacy.currencyId, isNull);
    },
  );
}

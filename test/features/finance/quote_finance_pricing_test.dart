// 报价核价「成交单价 ↔ 折扣」换算(ADR-134)：与服务端 MoneyPolicy.discountFromUnitPrice
// (汇率 1)逐项同口径——先 12 位再 4 位四舍五入、高于标价绝不截成 1、没标价不给折扣。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/quote_finance_pricing.dart';

void main() {
  group('quoteDiscountFromDealPrice', () {
    test('exact discount has no rounding gap', () {
      final result = quoteDiscountFromDealPrice('95', '100');
      expect(result.flag, QuoteDiscountFlag.ok);
      expect(result.discount, '0.9500');
      expect(result.unitGap, '0');
    });

    test('non-terminating ratio rounds half up to 4 places with a gap', () {
      final third = quoteDiscountFromDealPrice('1', '3');
      expect(third.flag, QuoteDiscountFlag.rounded);
      expect(third.discount, '0.3333');
      expect(third.unitGap, '0.0001');

      final twoThirds = quoteDiscountFromDealPrice('2', '3');
      expect(twoThirds.flag, QuoteDiscountFlag.rounded);
      expect(twoThirds.discount, '0.6667');
      expect(twoThirds.unitGap, '0.0001');
    });

    test('mirrors the server double rounding (12 places, then 4)', () {
      // 0.123449999999995: 一次取 4 位是 0.1234，服务端先取 12 位得 0.123450000000
      // 再取 4 位得 0.1235——前端必须给出和服务端一样的数。
      final result = quoteDiscountFromDealPrice('0.123449999999995', '1');
      expect(result.discount, '0.1235');
    });

    test('deal price above the list price is never clamped to 1', () {
      final result = quoteDiscountFromDealPrice('22.11', '21');
      expect(result.flag, QuoteDiscountFlag.aboveList);
      expect(result.discount, isNull);
    });

    test('deal price equal to list price is discount 1', () {
      final result = quoteDiscountFromDealPrice('21.00', '21');
      expect(result.flag, QuoteDiscountFlag.ok);
      expect(result.discount, '1.0000');
    });

    test('missing or zero list price asks finance to price directly', () {
      for (final list in [null, '', '0', '0.00', '-3']) {
        expect(
          quoteDiscountFromDealPrice('10', list).flag,
          QuoteDiscountFlag.noListPrice,
          reason: 'list=$list',
        );
      }
    });

    test('invalid deal prices give no discount', () {
      for (final deal in [null, '', '0', 'abc', '-1']) {
        final result = quoteDiscountFromDealPrice(deal, '10');
        expect(result.flag, QuoteDiscountFlag.invalid, reason: 'deal=$deal');
        expect(result.hasDiscount, isFalse);
      }
    });

    test('a tiny deal price that rounds to 0 is invalid', () {
      expect(
        quoteDiscountFromDealPrice('0.00001', '100').flag,
        QuoteDiscountFlag.invalid,
      );
    });
  });

  group('discount validation', () {
    test('accepts (0, 1] with at most 4 decimals', () {
      for (final ok in ['1', '0.5', '0.9500', '0.0001', '1.0000']) {
        expect(isValidQuoteDiscount(ok), isTrue, reason: ok);
      }
      for (final bad in ['0', '1.0001', '0.12345', '-0.5', '', 'x', '1.5']) {
        expect(isValidQuoteDiscount(bad), isFalse, reason: bad);
      }
    });

    test('normalizes to 4 decimals', () {
      expect(normalizeQuoteDiscount('0.95'), '0.9500');
      expect(normalizeQuoteDiscount('1'), '1.0000');
      expect(normalizeQuoteDiscount('1.2'), isNull);
    });

    test('finance price allows zero but not negatives', () {
      expect(isValidFinancePrice('0'), isTrue);
      expect(isValidFinancePrice('12.5'), isTrue);
      expect(isValidFinancePrice('-1'), isFalse);
      expect(isValidFinancePrice(''), isFalse);
    });
  });

  group('previews', () {
    test('deal price from discount is the exact product', () {
      expect(quoteDealPriceFromDiscount('100', '0.95'), '95');
      expect(quoteDealPriceFromDiscount('12.34', '0.9'), '11.106');
      expect(quoteDealPriceFromDiscount(null, '0.9'), isNull);
    });

    test('line amount and file difference stay exact', () {
      expect(
        quoteLineAmountPreview(qty: '3', price: '10', discount: '0.9'),
        '27',
      );
      expect(
        quoteFileDifference(lineAmount: '27', qty: '3', filePriceLocal: '9'),
        '0',
      );
      expect(
        quoteFileDifference(lineAmount: '27', qty: '3', filePriceLocal: '10'),
        '-3',
      );
      expect(
        quoteFileDifference(lineAmount: '30', qty: '3', filePriceLocal: '9.5'),
        '1.5',
      );
      expect(
        quoteFileDifference(lineAmount: null, qty: '3', filePriceLocal: '9'),
        isNull,
      );
    });

    test('decimal helpers compare numerically', () {
      expect(sameDecimal('0.9500', '0.95'), isTrue);
      expect(sameDecimal('1', '1.0000'), isTrue);
      expect(sameDecimal('0.95', '0.9'), isFalse);
      expect(isZeroDecimal('0.00'), isTrue);
      expect(isZeroDecimal('0.01'), isFalse);
    });
  });
}

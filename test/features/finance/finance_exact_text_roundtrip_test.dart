import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

void main() {
  test(
    'finance DTO model prefers exact document and bank facts over display numbers',
    () {
      const amount = '1234567890123.123456789012345678901234';
      final detail = FinanceDocDetail.fromJson({
        'id': 'document',
        'amountOriginal': 1234567890123.1,
        'amountOriginalExact': amount,
        'accountAmount': 1234567890123.0,
        'accountAmountExact': '1234567890123.000000000000000000000001',
        'exchangeRate': 7.123456,
        'exchangeRateExact': '7.123456',
        'settlementGrossLocalExact': amount,
        'items': [
          {
            'qty': 2,
            'qtyExact': '2.0000',
            'price': 1.23456789,
            'priceExact': '1.2345678901',
            'amountOriginal': 1234567890123.1,
            'amountOriginalExact': amount,
            'amountLocalExact': amount,
          },
        ],
      });
      expect(detail.amountOriginalText, amount);
      expect(detail.settlementGrossLocalText, amount);
      expect(
        detail.accountAmountText,
        '1234567890123.000000000000000000000001',
      );
      expect(detail.items.single.amountOriginalText, amount);
      expect(detail.items.single.amountLocalText, amount);
      expect(detail.items.single.qtyText, '2.0000');
      expect(detail.items.single.priceText, '1.2345678901');
      final ledger = ArApLedgerItem.fromJson({
        'id': 'ledger',
        'amountBalanceOriginal': 0.1,
        'amountBalanceOriginalExact': '0.100000000000000000000001',
        'amountBalanceExact': '0.700000000000000000000007',
        'amountOffsetOriginalExact': '0.012345678901234567890123',
      });
      expect(ledger.amountBalanceOriginalText, '0.100000000000000000000001');
      expect(ledger.amountBalanceText, '0.700000000000000000000007');
      expect(ledger.amountOffsetOriginal, '0.012345678901234567890123');
    },
  );
  test(
    'financial units preserve 24 digits while legacy quantity defaults stay four',
    () {
      const value = '0.123456789012345678901234';
      expect(financeAmountFromUnits(financeAmountUnits(value)!), value);
      expect(
        financeAmountFromUnits(
          financeAmountUnits('123.450000000000000000000000')!,
        ),
        '123.4500',
      );
      expect(financeAmountUnits('0.0000000000000000000000001'), isNull);
      expect(financeExactDecimalUnits('0.00001'), isNull);
      expect(financeExactProductUnits('0.0001', '0.5'), BigInt.one);
    },
  );
  test(
    'finite multiplication keeps all digits and lossless conversion never rounds',
    () {
      expect(
        financeExactMultiplyTexts(['0.000000000000000000000001', '7.000001']),
        '0.000000000000000000000007000001',
      );
      expect(
        financeExactProductUnitsLossless(
          '0.000000000000000000000001',
          '7.000001',
        ),
        isNull,
      );
      final product = financeExactProductUnitsLossless(
        '0.123456789012345678',
        '7.123456',
      );
      expect(product, isNotNull);
      expect(
        financeAmountFromUnits(product!),
        financeExactMultiplyTexts(['0.123456789012345678', '7.123456']),
      );
      expect(
        financeExactSumTexts(['1.000000000000000000000000000001', '-1']),
        '0.000000000000000000000000000001',
      );
      expect(financeExactSumTexts(['1', null]), isNull);
    },
  );
}

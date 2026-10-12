import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/shared/models/procurement_source_terms.dart';

void main() {
  const original = ProcurementSourceTerms(
    currencyId: 'usd',
    exchangeRate: '7.123456',
    taxRate: '13.120000',
    settlementMethodId: 'monthly',
  );

  test('local draft JSON preserves exact terms and unknown rates', () {
    final restored = ProcurementSourceTerms.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(restored.toJson(), original.toJson());
    final unknown = ProcurementSourceTerms.fromJson(
      jsonDecode(jsonEncode(const ProcurementSourceTerms().toJson()))
          as Map<String, dynamic>,
    );
    expect(unknown.exchangeRate, isNull);
    expect(unknown.taxRate, isNull);
    expect(unknown.currencyId, isNull);
    expect(unknown.settlementMethodId, isNull);
  });

  test('decimal trailing zeros do not split otherwise equal source terms', () {
    expect(
      original.compatibleWith(
        const ProcurementSourceTerms(
          currencyId: 'usd',
          exchangeRate: '7.1234560',
          taxRate: '13.12',
          settlementMethodId: 'monthly',
        ),
      ),
      isTrue,
    );
  });

  for (final changed in [
    const ProcurementSourceTerms(currencyId: 'cny'),
    const ProcurementSourceTerms(exchangeRate: '7.123457'),
    const ProcurementSourceTerms(taxRate: '13.13'),
    const ProcurementSourceTerms(settlementMethodId: 'cash'),
  ]) {
    test('known conflicting terms cannot merge ${changed.toJson()}', () {
      expect(original.compatibleWith(changed), isFalse);
      expect(changed.compatibleWith(original), isFalse);
    });
  }

  for (final (name, terms)
      in <
        (String, ProcurementSourceTerms Function(Map<String, dynamic>, bool))
      >[
        (
          'purchase',
          (json, orderSource) => PurchaseDocDetail.fromJson(
            json,
          ).sourceCommercialTerms(orderSource: orderSource),
        ),
        (
          'subcontract',
          (json, orderSource) => SubcontractDocDetail.fromJson(
            json,
          ).sourceCommercialTerms(orderSource: orderSource),
        ),
      ]) {
    test('$name order uses the approved rate with exact tax text', () {
      final source = terms(const {
        'id': 'order-1',
        'currencyId': 'usd',
        'exchangeRate': 1,
        'effectiveFinanceExchangeRate': '7.123456',
        'taxRate': 13.12,
        'taxRateExact': '13.120001',
        'settlementMethodId': 'monthly',
      }, true);
      expect(source.exchangeRate, '7.123456');
      expect(source.taxRate, '13.120001');
      expect(source.currencyId, 'usd');
      expect(source.settlementMethodId, 'monthly');
    });

    test('$name legacy order keeps its recorded contract rate', () {
      final source = terms(const {
        'id': 'order-legacy',
        'exchangeRate': 7.1,
        'exchangeRateExact': '7.100000',
      }, true);
      expect(source.exchangeRate, '7.100000');
    });

    test('$name receipt retains original posted rate for a return source', () {
      final source = terms(const {
        'id': 'receipt-1',
        'exchangeRate': 1,
        'exchangeRateExact': '1.000000',
        'effectiveFinanceExchangeRate': '7.123456',
      }, false);
      expect(source.exchangeRate, '1.000000');
    });

    for (final orderSource in [true, false]) {
      test(
        '$name masked source never supplies a guessed or stale rate $orderSource',
        () {
          final source = terms(const {
            'id': 'masked-source',
            'priceMasked': true,
            'exchangeRate': 1,
            'exchangeRateExact': '1.000000',
            'effectiveFinanceExchangeRate': '7.123456',
          }, orderSource);
          expect(source.exchangeRate, isNull);
        },
      );
    }
  }
}

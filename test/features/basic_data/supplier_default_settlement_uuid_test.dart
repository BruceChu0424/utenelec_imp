import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';

/// V452：供应商默认结算方式 UUID 权威（模型解析 + 编辑页只上送 UUID 契约）。
void main() {
  group('supplier default settlement UUID models', () {
    test('detail parses UUID authority and display name', () {
      final detail = SupplierDetail.fromJson(const {
        'id': 'supplier-id',
        'defaultSettlementMethodId': 'settlement-uuid',
        'defaultSettlementMethodName': '月结30天',
      });

      expect(detail.defaultSettlementMethodId, 'settlement-uuid');
      expect(detail.defaultSettlementMethodName, '月结30天');
    });

    test('absent fields stay null without crashing', () {
      final detail = SupplierDetail.fromJson(const {'id': 'supplier-id'});

      expect(detail.defaultSettlementMethodId, isNull);
      expect(detail.defaultSettlementMethodName, isNull);
    });
  });

  group('supplier editor UUID-only contract', () {
    final pageSource = File(
      'lib/features/basic_data/pages/supplier_category_page.dart',
    ).readAsStringSync();

    test('edit form submits UUID key and prefills from detail', () {
      expect(pageSource, contains("key: 'defaultSettlementMethodId'"));
      expect(
        pageSource,
        contains(
          "'defaultSettlementMethodId': d.defaultSettlementMethodId ?? ''",
        ),
      );
    });

    test('detail rows expose the display name', () {
      expect(
        pageSource,
        contains("MasterDetailRow('默认结算方式', d.defaultSettlementMethodName)"),
      );
    });
  });

  group('purchase/subcontract prefill contract', () {
    test('edit pages prefill settlement from supplier default once', () {
      final purchaseSource = File(
        'lib/features/purchase/pages/purchase_doc_edit_page.dart',
      ).readAsStringSync();
      final subcontractSource = File(
        'lib/features/subcontract/pages/subcontract_doc_edit_page.dart',
      ).readAsStringSync();

      for (final source in [purchaseSource, subcontractSource]) {
        expect(source, contains('_prefillSettlementForSupplier'));
        expect(source, contains('supplierDefaultSettlement'));
        // 上游引入优先来源单据快照；供应商默认只是回退。
        expect(source, contains('settlementMethodId'));
      }
    });
  });
}

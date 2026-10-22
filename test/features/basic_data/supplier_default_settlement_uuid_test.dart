import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';

/// V452：供应商默认结算方式 UUID 权威（模型解析 + 编辑页只上送 UUID 契约）。
void main() {
  group('supplier default settlement UUID models', () {
    test(
      'list parses canonical settlement even when legacy snapshot is absent',
      () {
        final item = SupplierListItem.fromJson(const {
          'id': 'supplier-id',
          'defaultSettlementMethodId': 'settlement-uuid',
          'defaultSettlementMethodName': 'Local UAT Net30',
          'priceStyle': null,
        });
        expect(item.defaultSettlementMethodId, 'settlement-uuid');
        expect(item.defaultSettlementMethodName, 'Local UAT Net30');
        final legacy = SupplierListItem.fromJson(const {
          'id': 'legacy',
          'priceStyle': 30,
        });
        expect(legacy.defaultSettlementMethodId, isNull);
        expect(legacy.defaultSettlementMethodName, isNull);
      },
    );

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
    // 2026-09-14：供应商编辑表单抽到 widgets/supplier_master_edit.dart，分类页
    // 只留列表与详情。契约按两文件并集判定，不绑死在某一个文件里。
    final pageSource =
        File(
          'lib/features/basic_data/pages/supplier_category_page.dart',
        ).readAsStringSync() +
        File(
          'lib/features/basic_data/widgets/supplier_master_edit.dart',
        ).readAsStringSync() +
        File(
          'lib/features/basic_data/pages/party_detail_page.dart',
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
      // 契约匹配对 dart format 换行不敏感：折行不应使契约失效。
      final normalized = pageSource.replaceAll(RegExp(r'\s+'), '');
      expect(
        normalized,
        // 当前查看态复用编辑字段定义；UUID 仍映射到服务端返回的名称。
        contains(
          "'defaultSettlementMethodId'=>detail.defaultSettlementMethodName",
        ),
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

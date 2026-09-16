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
        // 不断言收尾括号：formatter 可能加尾逗号
        // 2026-09-14：详情面板整页化后这一行搬到 pages/party_detail_page.dart，
        // 渲染器由 MasterDetailRow 换成本页的 _kv。契约不变——详情显示的必须是
        // UUID 解析出来的**名称**，不是 legacy 值。
        contains("_kv(theme,'默认结算方式',d.defaultSettlementMethodName"),
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

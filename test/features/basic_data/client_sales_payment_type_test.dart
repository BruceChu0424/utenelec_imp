import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';

void main() {
  test('client list and detail parse sales payment type and zero floor', () {
    final listItem = ClientListItem.fromJson(const {
      'id': 'client-1',
      'salesPaymentType': 'MONTHLY',
      'creditFloor': 50000,
    });
    final detail = ClientDetail.fromJson(const {
      'id': 'client-1',
      'salesPaymentType': 'DEPOSIT',
    });

    expect(listItem.salesPaymentType, ClientSalesPaymentType.monthly);
    expect(listItem.creditFloor, 50000);
    expect(detail.salesPaymentType, ClientSalesPaymentType.deposit);
    expect(detail.creditFloor, 0);
  });

  test(
    'sales payment type labels are explicit and legacy null stays visible',
    () {
      expect(salesPaymentTypeLabel(ClientSalesPaymentType.monthly), '月结');
      expect(salesPaymentTypeLabel(ClientSalesPaymentType.cash), '现金');
      expect(salesPaymentTypeLabel(ClientSalesPaymentType.deposit), '定金');
      expect(salesPaymentTypeLabel(null), '待人工分类');
      expect(salesPaymentTypeLabel('LEGACY_OTHER'), '未知类型(LEGACY_OTHER)');
    },
  );

  test('client editor requires the three-way type and list exports floor', () {
    final source = File(
      'lib/features/basic_data/pages/client_category_page.dart',
    ).readAsStringSync();
    final field = _between(
      source,
      "key: 'salesPaymentType'",
      "key: 'defaultSettlementMethodId'",
    );

    expect(field, contains('required: true'));
    expect(field, contains('ClientSalesPaymentType.monthly'));
    expect(field, contains('ClientSalesPaymentType.cash'));
    expect(field, contains('ClientSalesPaymentType.deposit'));
    expect(source, contains("'salesPaymentType': d.salesPaymentType ?? ''"));
    expect(source, contains("key: 'creditFloor'"));
    expect(source, contains("label: '铺底额'"));
  });

  test(
    'legacy Credit is a read-only snapshot distinct from the active floor',
    () {
      final source = File(
        'lib/features/basic_data/pages/client_category_page.dart',
      ).readAsStringSync();

      expect(source, contains("if (d.legacyId != null) 'credit'"));
      expect(source, contains('legacyCreditSnapshot: d.legacyId != null'));
      expect(source, contains('旧库 Credit 快照（只读）'));
      expect(source, contains('信用额度 / 旧库 Credit 快照'));
      expect(source, contains("key: 'creditFloor'"));
    },
  );
}

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  expect(startIndex, greaterThanOrEqualTo(0));
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, greaterThan(startIndex));
  return source.substring(startIndex, endIndex);
}

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

  test(
    'client editor offers the three-way type as optional and list exports floor',
    () {
      // 2026-09-14：客户编辑表单抽到 widgets/client_master_edit.dart，分类页只留
      // 列表与详情。字段切片必须只取 widgets 文件：分类页列表列也带
      // key: 'salesPaymentType'（MasterColumnDef），并集切片会把「基础」组的
      // 名称/状态 required: true 误圈进来（2026-09-19 改选填断言时暴露）。
      final editorSource = File(
        'lib/features/basic_data/widgets/client_master_edit.dart',
      ).readAsStringSync();
      final source =
          File(
            'lib/features/basic_data/pages/client_category_page.dart',
          ).readAsStringSync() +
          editorSource;
      final field = _between(
        editorSource,
        "key: 'salesPaymentType'",
        "key: 'defaultSettlementMethodId'",
      );

      // 2026-09-19 用户口径：除「基础」组（名称/状态）外全部选填——货款类型不再
      // 必填（未分类客户财务放行时有专门闸门拦截补选），三选项词表保持不动。
      expect(field, isNot(contains('required: true')));
      expect(field, contains('ClientSalesPaymentType.monthly'));
      expect(field, contains('ClientSalesPaymentType.cash'));
      expect(field, contains('ClientSalesPaymentType.deposit'));
      expect(source, contains("'salesPaymentType': d.salesPaymentType ?? ''"));
      expect(source, contains("key: 'creditFloor'"));
      expect(source, contains("label: '铺底额'"));
    },
  );

  test(
    'legacy Credit is a read-only snapshot distinct from the active floor',
    () {
      final source =
          File(
            'lib/features/basic_data/pages/client_category_page.dart',
          ).readAsStringSync() +
          File(
            'lib/features/basic_data/widgets/client_master_edit.dart',
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

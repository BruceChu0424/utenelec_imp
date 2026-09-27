import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_master_names.dart';

FormDraft _draft(Map<String, dynamic> data) => FormDraft(
  id: 'draft-1',
  title: '销售订货单',
  module: BadgeModule.sales,
  route: '/sales/orders/new',
  permission: 'sales_order:create',
  updatedAt: DateTime.utc(2026, 9, 26),
  data: data,
);

void main() {
  test(
    'client column aliases display cached selected-party name without a server row',
    () {
      final draft = _draft({'clientId': 'local-only-client'});
      for (final key in ['client', 'clientName', 'clientId']) {
        expect(
          formDraftMasterColumnValue(
            draft,
            key,
            clients: const {'local-only-client': '本机草稿所选客户'},
          ),
          '本机草稿所选客户',
        );
      }
    },
  );

  test(
    'multiple row suppliers and commercial currencies resolve without dropping selections',
    () {
      final draft = _draft({
        'rows': [
          {
            'supplierId': 'supplier-a',
            'commercial': {'currencyId': 'cny'},
          },
          {
            'supplierId': 'supplier-b',
            'commercial': {'currencyId': 'usd'},
          },
          {
            'supplierId': 'supplier-a',
            'commercial': {'currencyId': 'cny'},
          },
        ],
      });
      expect(
        formDraftMasterColumnValue(
          draft,
          'supplier',
          suppliers: const {'supplier-a': '甲供应商', 'supplier-b': '乙供应商'},
        ),
        '甲供应商、乙供应商',
      );
      expect(
        formDraftMasterColumnValue(
          draft,
          'currencyName',
          currencies: const {'cny': '人民币', 'usd': '美元'},
        ),
        '人民币、美元',
      );
    },
  );

  test(
    'warehouse names resolve while missing dictionaries keep the offline fallback',
    () {
      final draft = _draft({
        'warehouseId': 'warehouse-1',
        'supplierId': 'unknown',
      });
      expect(
        formDraftMasterColumnValue(
          draft,
          'warehouseName',
          warehouses: const {'warehouse-1': '成品仓'},
        ),
        '成品仓',
      );
      expect(formDraftMasterColumnValue(draft, 'supplier'), isNull);
      expect(formDraftMasterColumnValue(draft, 'billDate'), isNull);
    },
  );

  test(
    'partial dictionary preserves visible names and signals unresolved selections without UUIDs',
    () {
      final draft = _draft({
        'rows': [
          {'supplierId': 'supplier-a'},
          {'supplierId': 'unresolved-private-id'},
        ],
      });
      final text = formDraftMasterColumnValue(
        draft,
        'supplierName',
        suppliers: const {'supplier-a': '甲供应商'},
      );
      expect(text, '甲供应商、另 1 项已选择');
      expect(text, isNot(contains('unresolved-private-id')));
    },
  );
}

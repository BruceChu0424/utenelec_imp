import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';

void main() {
  test(
    'purchase list and facets retain independent text searches and exact IDs',
    () async {
      final api = _ColumnSearchApi();
      final repository = PurchaseRepository(api, PurchaseDocType.receipt);
      const filter = PurchaseDocFilter(
        supplierId: 'supplier-uuid',
        warehouseId: 'warehouse-uuid',
        status: 0,
        billNo: 'CD-exact',
        dateFrom: '2026-10-01',
        columnSearch: {
          'search.billNo': ' CD2026 ',
          'search.supplier': '华东 M3_20%',
          'billNo': 'ignored',
        },
      );
      await repository.list(filter: filter);
      await repository.billNoFacets(filter: filter);
      for (final query in api.queries) {
        expect(query['search.billNo'], 'CD2026');
        expect(query['search.supplier'], '华东 M3_20%');
        expect(query['supplierId'], 'supplier-uuid');
        expect(query['warehouseId'], 'warehouse-uuid');
        expect(query['status'], 0);
        expect(query['dateFrom'], '2026-10-01');
      }
      expect(api.queries.first['billNo'], 'CD-exact');
      expect(api.queries.last.containsKey('billNo'), isFalse);
    },
  );

  test(
    'sales list and facets share text filters without replacing customer identity',
    () async {
      final api = _ColumnSearchApi();
      final repository = SalesRepository(api, SalesDocType.order);
      const filter = SalesDocFilter(
        clientId: 'client-uuid',
        columnSearch: {
          'search.billNo': 'XD2026',
          'search.client': '客户 A',
          'search.warehouse': null,
        },
      );
      await repository.list(filter: filter);
      await repository.billNoFacets(filter: filter);
      for (final query in api.queries) {
        expect(query['search.billNo'], 'XD2026');
        expect(query['search.client'], '客户 A');
        expect(query['clientId'], 'client-uuid');
        expect(query.containsKey('search.warehouse'), isFalse);
      }
    },
  );

  test(
    'subcontract facet cloning retains searches and financial state controls',
    () async {
      final api = _ColumnSearchApi();
      final repository = SubcontractRepository(
        api,
        SubcontractDocType.returnDoc,
      );
      const filter = SubcontractDocFilter(
        supplierId: 'supplier-uuid',
        apPosted: true,
        columnSearch: {
          'search.billNo': 'ET2026',
          'search.supplier': '加工商',
          'search.warehouse': '仓库',
        },
      );
      await repository.list(filter: filter);
      await repository.billNoFacets(filter: filter);
      for (final query in api.queries) {
        expect(query['search.billNo'], 'ET2026');
        expect(query['search.supplier'], '加工商');
        expect(query['search.warehouse'], '仓库');
        expect(query['supplierId'], 'supplier-uuid');
        expect(query['hf.apPosted'], isTrue);
      }
    },
  );
}

class _ColumnSearchApi extends ApiClient {
  _ColumnSearchApi() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add({...?query});
    return {
      'items': <dynamic>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
      'billNo': <dynamic>[],
    };
  }
}

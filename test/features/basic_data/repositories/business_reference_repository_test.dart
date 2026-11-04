import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/repositories/business_reference_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_facet_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  test(
    'business account dict uses minimal source while reconciliation dict keeps full master contract',
    () async {
      final api = _Api();
      final container = _container(api);
      final minimal =
          (await container
                  .read(businessAccountReferenceRepositoryProvider)
                  .dict())
              .single;
      expect(minimal.accountType, 'CASH');
      expect(minimal.bankAccountNo, isNull);
      expect(minimal.balanceCurrent, isNull);
      final master = (await DioAccountRepository(api).dict()).single;
      expect(master.bankAccountNo, 'master-only-bank');
      expect(master.balanceCurrent, 99);
      expect(api.lists, [
        ApiEndpoints.businessReferenceAccounts,
        AccountEndpoints.dict,
      ]);
    },
  );
  test(
    'narrow warehouse role reads minimal party identities rather than master fields',
    () async {
      final api = _Api();
      final container = _container(api);
      final supplier =
          (await container
                  .read(businessSupplierReferenceRepositoryProvider)
                  .list('category', selectableOnly: true))
              .items
              .single;
      expect(supplier.id, 'party');
      expect(supplier.code, 'P001');
      expect(supplier.defaultSettlementMethodId, 'settlement');
      expect([
        supplier.bankAccount,
        supplier.taxId,
        supplier.mobile,
        supplier.linkman,
      ], everyElement(isNull));
      final client =
          (await container
                  .read(businessClientReferenceRepositoryProvider)
                  .list('category'))
              .items
              .single;
      expect(client.code, 'P001');
      expect([
        client.bankAccount,
        client.taxId,
        client.mobile,
        client.credit,
      ], everyElement(isNull));
      expect(api.gets.map((entry) => entry.$1), [
        ApiEndpoints.businessReferenceSuppliers,
        ApiEndpoints.businessReferenceClients,
      ]);
      expect(api.gets.first.$2['selectableOnly'], true);
      expect(api.gets.last.$2['excludeLegacyFinanceStub'], true);
    },
  );

  test(
    'party search and location context retain keyword in exact read POST bodies',
    () async {
      final api = _Api();
      final container = _container(api);
      final suppliers = container.read(
        businessSupplierReferenceRepositoryProvider,
      );
      final clients = container.read(businessClientReferenceRepositoryProvider);
      await suppliers.search(' 13900000000 ', selectableOnly: true);
      await suppliers.list('category', keyword: ' 供应商 ', selectableOnly: true);
      await suppliers.searchContext(' 名称 ', selectableOnly: true);
      await clients.search(' 客户 ', selectableOnly: true);
      await clients.searchContext(' 客户 ', selectableOnly: true);
      expect(api.posts.map((entry) => entry.$1), [
        '${ApiEndpoints.businessReferenceSuppliers}/search',
        '${ApiEndpoints.businessReferenceSuppliers}/search',
        '${ApiEndpoints.businessReferenceSuppliers}/search-context',
        '${ApiEndpoints.businessReferenceClients}/search',
        '${ApiEndpoints.businessReferenceClients}/search-context',
      ]);
      for (final request in api.posts) {
        expect(request.$2.containsKey('keyword'), false);
        expect(request.$3['keyword'], isA<String>());
        expect(request.$3['selectableOnly'], true);
      }
      expect(api.posts.first.$3['keyword'], '13900000000');
      expect(api.posts[1].$2['categoryId'], 'category');
      expect(api.posts[3].$3['excludeLegacyFinanceStub'], true);
    },
  );

  test('business category trees use minimal explicit sources', () async {
    final api = _Api();
    final container = _container(api);
    expect(
      (await container.read(businessSupplierCategoryRepositoryProvider).tree())
          .single
          .code,
      'CAT',
    );
    expect(
      (await container.read(businessClientCategoryRepositoryProvider).tree())
          .single
          .legacyId,
      2149,
    );
    expect(
      (await container.read(businessGoodsCategoryRepositoryProvider).tree())
          .single
          .id,
      'category',
    );
    expect(api.lists, [
      ApiEndpoints.businessReferenceSupplierCategories,
      ApiEndpoints.businessReferenceClientCategories,
      ApiEndpoints.businessReferenceGoodsCategories,
    ]);
  });

  test(
    'goods list body search locations and facets share the original query engine on minimal sources',
    () async {
      final api = _Api();
      final repository = DioGoodsRepository(
        api,
        queryBasePath: ApiEndpoints.businessReferenceGoods,
      );
      final rows = await repository.list(
        'category',
        filters: {'search.name': '螺丝', 'unitLegacyId': 'unit'},
        excludeDisabled: true,
        excludeStub: true,
      );
      expect(rows.items.single.unitId, 'unit');
      expect(rows.items.single.price, isNull);
      await repository.searchColumns(
        'bolt',
        filters: {'search.model': 'M1'},
        categoryRootIds: List.generate(33, (i) => 'root-$i').toSet(),
        sort: 'code',
        order: 'asc',
      );
      await repository.searchColumnCategoryIds(
        'bolt',
        filters: {'search.spec': 'S1'},
        categoryRootIds: {'root'},
        excludeDisabled: true,
      );
      await repository.facets('category', filters: {'search.code': 'B'});
      await repository.globalFacets(keyword: 'bolt', categoryRootIds: {'root'});
      await GoodsFacetRepository(
        api,
        queryBasePath: ApiEndpoints.businessReferenceGoods,
      ).values(field: 'unitLegacyId', search: '件', categoryId: 'category');
      expect(
        api.gets.every(
          (entry) => entry.$1.startsWith(ApiEndpoints.businessReferenceGoods),
        ),
        true,
      );
      expect(api.gets.first.$2['unitRef'], 'unit');
      expect(
        api.gets
            .where((entry) => entry.$2.containsKey('categoryRootIds'))
            .length,
        1,
      );
      expect(
        api.posts.single.$1,
        '${ApiEndpoints.businessReferenceGoods}/search',
      );
      expect(
        ((api.posts.single.$3['filter'] as Map)['categoryRootIds'] as List)
            .length,
        33,
      );
      expect((api.posts.single.$3['filter'] as Map)['columnSearch'], {
        'model': 'M1',
      });
      expect(api.gets.last.$2['field'], 'unitRef');
      expect(
        api.stringLists.single.$1,
        '${ApiEndpoints.businessReferenceGoods}/search-category-ids',
      );
    },
  );

  test(
    'query base never redirects protected master detail or writes into reference endpoints',
    () async {
      final api = _Api();
      final goods = DioGoodsRepository(
        api,
        queryBasePath: ApiEndpoints.businessReferenceGoods,
      );
      await expectLater(goods.detail('g'), throwsA(isA<ApiException>()));
      final supplier = DioSupplierRepository(
        api,
        queryBasePath: ApiEndpoints.businessReferenceSuppliers,
      );
      await expectLater(supplier.detail('s'), throwsA(isA<ApiException>()));
      final client = DioClientRepository(
        api,
        queryBasePath: ApiEndpoints.businessReferenceClients,
      );
      await expectLater(client.detail('c'), throwsA(isA<ApiException>()));
      expect(api.masterReads, [
        '/master/goods/g',
        '/master/suppliers/s',
        '/master/clients/c',
      ]);
      expect(api.posts, isEmpty);
    },
  );
}

ProviderContainer _container(_Api api) {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'warehouse', epoch: 1),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.warehouseInboundView,
        Perm.warehouseInboundStockIn,
      }),
      isSuperAdminProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final gets = <(String, Map<String, dynamic>)>[];
  final posts = <(String, Map<String, dynamic>, Map<String, dynamic>)>[];
  final lists = <String>[];
  final stringLists = <(String, Map<String, dynamic>)>[];
  final masterReads = <String>[];

  Map<String, dynamic> page(String path, Map<String, dynamic> query) => {
    'items': [
      path.contains('/goods')
          ? {
              'id': 'g',
              'code': 'G001',
              'name': '螺丝',
              'categoryId': 'category',
              'unitId': 'unit',
              'unitName': '件',
            }
          : {
              'id': 'party',
              'code': 'P001',
              'name': '业务名称',
              'categoryId': 'category',
              'status': '使用',
              'defaultSettlementMethodId': 'settlement',
              'bankAccount': 'MUST-NOT-RETAIN',
              'taxId': 'MUST-NOT-RETAIN',
              'mobile': 'MUST-NOT-RETAIN',
              'linkman': 'MUST-NOT-RETAIN',
              'credit': 999,
            },
    ],
    'page': query['page'] ?? 1,
    'size': query['size'] ?? 20,
    'total': 1,
    'totalPages': 1,
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.startsWith('/master/')) {
      masterReads.add(path);
      throw ApiException('PERMISSION_DENIED', '主档权限仍独立', httpStatus: 403);
    }
    gets.add((path, {...?query}));
    if (path.endsWith('/facets')) {
      return {
        'fields': {
          'name': [
            {'value': '螺丝', 'count': 1},
          ],
        },
        'nullCounts': {'name': 0},
      };
    }
    if (path.endsWith('/facet-values')) {
      return {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 50,
        'total': 0,
        'totalPages': 0,
      };
    }
    return page(path, query ?? {});
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path, {...?query}, Map<String, dynamic>.from(body! as Map)));
    if (path.endsWith('/search-context')) {
      return {
        'categories': [
          {'categoryId': 'category'},
        ],
        'totalMatches': 1,
        'page': 1,
        'totalPages': 1,
        'totalCategories': 1,
      };
    }
    return page(path, query ?? {});
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lists.add(path);
    if (path == ApiEndpoints.businessReferenceAccounts) {
      return [
        {
          'id': 'cash',
          'code': '1001',
          'name': '现金',
          'accountType': 'CASH',
          'status': '使用',
        },
      ];
    }
    if (path == AccountEndpoints.dict) {
      return [
        {
          'id': 'cash',
          'code': '1001',
          'name': '现金',
          'accountType': 'CASH',
          'status': '使用',
          'bankAccountNo': 'master-only-bank',
          'balanceCurrent': 99,
        },
      ];
    }
    return [
      {
        'id': 'category',
        'code': 'CAT',
        'codePrefix': 'G',
        'name': '半成品',
        'level': 0,
        'legacyId': 2149,
        'parentId': null,
        'children': <Object>[],
      },
    ];
  }

  @override
  Future<List<String>> getStringList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    stringLists.add((path, {...?query}));
    return ['category'];
  }
}

// 基础资料表头筛选冒烟测试（2026-09-16 补齐批次）：
// - 供应商资料页：服务端 empId 桶（值=业务员 UUID、label=人名）remap 到业务员列
//   key ownerEmployeeName；选桶回传服务端参数名 ownerEmployeeId。
// - 基本单位页：计量维度列固定枚举桶（六维度全量可选）+ 回传 dimension 参数；
//   空值桶走 nullFields（服务端筛未设置维度的单位）。
// - 仓库资料页：上级仓库列（桶 label=上级仓名）回传 parentId；核算列回传
//   accountable（true/false）；上级仓库空值桶走 nullFields parentId。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/models/warehouse_node.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/pages/warehouse_page.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/unit_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_keeper_repository.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();

  group('supplier category page', () {
    testWidgets('业务员表头筛选 empId 桶 remap 到列 key 并回传 ownerEmployeeId', (
      tester,
    ) async {
      final suppliers = _FakeSupplierRepository(
        facetPayload: const SupplierFacets(
          fields: {
            'empId': [
              MasterFacetBucket(value: 'emp-9', count: 3, label: '李业务'),
            ],
          },
          nullCounts: {'empId': 2},
        ),
      );
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            supplierCategoryRepositoryProvider.overrideWithValue(
              _FakeSupplierCategoryRepository(),
            ),
            supplierRepositoryProvider.overrideWithValue(suppliers),
            currentPermissionsProvider.overrideWithValue(<String>{
              Perm.supplierView,
            }),
          ],
          child: const SupplierCategoryPage(),
        ),
      );

      await tester.tap(find.text('五金类(S-HW)'));
      await tester.pumpAndSettle();

      final table = _tableOf<SupplierListItem>(tester);
      expect(table.facets.keys, contains('ownerEmployeeName'));
      expect(table.facets['ownerEmployeeName']?.single.label, '李业务');
      expect(table.nullCounts['ownerEmployeeName'], 2);

      table.onFilterChanged('ownerEmployeeName', 'emp-9');
      await tester.pumpAndSettle();
      expect(suppliers.lastFilters?['ownerEmployeeId'], 'emp-9');

      _tableOf<SupplierListItem>(
        tester,
      ).onFilterChanged('ownerEmployeeName', null);
      await tester.pumpAndSettle();
      expect(suppliers.lastFilters?.containsKey('ownerEmployeeId'), isFalse);
    });
  });

  group('unit page', () {
    testWidgets('计量维度列固定枚举桶 + dimension 参数回传', (tester) async {
      final units = _FakeUnitRepository(
        facetPayload: const UnitFacets(
          fields: {
            'dimension': [MasterFacetBucket(value: 'MASS', count: 4)],
          },
          nullCounts: {'dimension': 7},
        ),
      );
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(units),
            currentPermissionsProvider.overrideWithValue(<String>{
              Perm.unitView,
            }),
          ],
          child: const UnitPage(),
        ),
      );
      await tester.pumpAndSettle();

      final table = _tableOf<UnitListItem>(tester);
      // 固定枚举桶：六个维度全量可选（无数据的也列出），服务端计数并入。
      final dimensionBuckets =
          table.facets['dimension'] ?? const <MasterFacetBucket>[];
      expect(
        dimensionBuckets.map((b) => b.value),
        containsAll(<String>[
          'COUNT',
          'MASS',
          'LENGTH',
          'AREA',
          'VOLUME',
          'OTHER',
        ]),
      );
      final mass = dimensionBuckets.singleWhere((b) => b.value == 'MASS');
      expect(mass.label, '重量');
      expect(mass.count, 4);
      expect(table.nullCounts['dimension'], 7);

      table.onFilterChanged('dimension', 'MASS');
      await tester.pumpAndSettle();
      expect(units.lastFilters?['dimension'], 'MASS');

      // 空值桶（筛未设置维度）→ 哨兵值按 dimension 键送到仓储
      //（真实仓储把它收集进 nullFields，服务端筛未设置维度的单位）。
      _tableOf<UnitListItem>(
        tester,
      ).onFilterChanged('dimension', kMasterFilterNullValue);
      await tester.pumpAndSettle();
      expect(units.lastFilters?['dimension'], kMasterFilterNullValue);
    });
  });

  group('warehouse page', () {
    testWidgets('上级仓库/核算表头筛选回传 parentId/accountable', (tester) async {
      final warehouses = _FakeWarehouseRepository(
        facetPayload: const WarehouseFacets(
          fields: {
            'parent': [
              MasterFacetBucket(value: 'wh-parent', count: 2, label: '成品仓库'),
            ],
            'accountable': [
              MasterFacetBucket(value: 'true', count: 5, label: '是'),
              MasterFacetBucket(value: 'false', count: 1, label: '否'),
            ],
          },
          nullCounts: {'parent': 3},
        ),
      );
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            warehouseRepositoryProvider.overrideWithValue(warehouses),
            currentPermissionsProvider.overrideWithValue(<String>{
              Perm.warehouseView,
            }),
          ],
          child: const WarehousePage(),
        ),
      );
      await tester.pumpAndSettle();

      final table = _tableOf<WarehouseListItem>(tester);
      expect(table.facets['parent']?.single.label, '成品仓库');
      expect(table.nullCounts['parent'], 3);
      expect(table.facets['accountable']?.first.label, '是');

      table.onFilterChanged('parent', 'wh-parent');
      await tester.pumpAndSettle();
      expect(warehouses.lastFilters?['parentId'], 'wh-parent');

      _tableOf<WarehouseListItem>(
        tester,
      ).onFilterChanged('accountable', 'false');
      await tester.pumpAndSettle();
      expect(warehouses.lastFilters?['accountable'], 'false');

      // 上级仓库空值桶（顶层/独立仓）→ 哨兵值按 parentId 键送到仓储
      //（真实仓储收集进 nullFields，服务端筛 parent_id is null）。
      _tableOf<WarehouseListItem>(
        tester,
      ).onFilterChanged('parent', kMasterFilterNullValue);
      await tester.pumpAndSettle();
      expect(warehouses.lastFilters?['parentId'], kMasterFilterNullValue);
    });

    // ADR-115：列表「负责人」列按全部负责关系显示；没登记的仓显示「—」。
    testWidgets('负责人列显示登记的仓管员', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            warehouseRepositoryProvider.overrideWithValue(
              _FakeWarehouseRepository(),
            ),
            warehouseKeeperRepositoryProvider.overrideWithValue(
              _FakeWarehouseKeeperRepository(),
            ),
            currentPermissionsProvider.overrideWithValue(<String>{
              Perm.warehouseView,
            }),
          ],
          child: const WarehousePage(),
        ),
      );
      await tester.pumpAndSettle();

      final table = _tableOf<WarehouseListItem>(tester);
      final keepers = table.columns.singleWhere((c) => c.key == 'keepers');
      expect(keepers.label, '负责人');
      expect(
        keepers.value(
          const WarehouseListItem(id: 'wh-1', code: 'C01', name: '成品仓库'),
        ),
        '成品仓管、仓库主管',
      );
      expect(
        keepers.value(
          const WarehouseListItem(id: 'wh-2', code: 'C02', name: '五金仓库'),
        ),
        '—',
      );
    });
  });
}

class _FakeWarehouseKeeperRepository extends WarehouseKeeperRepository {
  _FakeWarehouseKeeperRepository() : super(ApiClient(Dio()));

  @override
  Future<List<WarehouseKeeperAssignment>> assignments() async => const [
    WarehouseKeeperAssignment(
      warehouseId: 'wh-1',
      employeeId: 'e-1',
      name: '成品仓管',
    ),
    WarehouseKeeperAssignment(
      warehouseId: 'wh-1',
      employeeId: 'e-3',
      name: '仓库主管',
    ),
  ];
}

MasterDataTableView<T> _tableOf<T>(WidgetTester tester) =>
    tester.widget<MasterDataTableView<T>>(
      find.byWidgetPredicate((widget) => widget is MasterDataTableView<T>),
    );

Future<void> _pump(WidgetTester tester, Widget app) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        home: app,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeSupplierCategoryRepository implements SupplierCategoryRepository {
  final _tree = <ProductCategoryNode>[
    ProductCategoryNode(
      id: 'hardware',
      code: 'S-HW',
      name: '五金类',
      level: 0,
      codePrefix: 'SH',
      children: const [],
    ),
  ];

  @override
  Future<List<ProductCategoryNode>> tree() async => _tree;

  @override
  Future<ProductCategoryDetail> detail(String id) async {
    final node = _tree.firstWhere((n) => n.id == id);
    return ProductCategoryDetail(
      id: node.id,
      code: node.code,
      name: node.name,
      level: node.level,
      path: node.name,
      childCount: 0,
      codePrefix: node.codePrefix,
      effectivePrefix: node.codePrefix,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSupplierRepository implements SupplierRepository {
  _FakeSupplierRepository({this.facetPayload});

  final SupplierFacets? facetPayload;
  Map<String, String?>? lastFilters;

  @override
  Future<PagedResult<SupplierListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool selectableOnly = false,
  }) async {
    lastFilters = Map<String, String?>.of(filters);
    return PagedResult(
      items: const [SupplierListItem(id: 'sup-1', name: '供应商甲')],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<SupplierFacets> facets(String categoryId) async =>
      facetPayload ?? const SupplierFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUnitRepository implements UnitRepository {
  _FakeUnitRepository({this.facetPayload});

  final UnitFacets? facetPayload;
  Map<String, String?>? lastFilters;

  @override
  Future<PagedResult<UnitListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async {
    lastFilters = Map<String, String?>.from(filters);
    return PagedResult(
      items: const [UnitListItem(id: 'unit-1', name: '个', status: '使用')],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<UnitFacets> facets() async =>
      facetPayload ?? const UnitFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWarehouseRepository implements WarehouseRepository {
  _FakeWarehouseRepository({this.facetPayload});

  final WarehouseFacets? facetPayload;
  Map<String, String?>? lastFilters;

  @override
  Future<PagedResult<WarehouseListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async {
    lastFilters = Map<String, String?>.from(filters);
    return PagedResult(
      items: const [WarehouseListItem(id: 'wh-1', code: 'C01', name: '成品仓库')],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<WarehouseFacets> facets() async =>
      facetPayload ?? const WarehouseFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

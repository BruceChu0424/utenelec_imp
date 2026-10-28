// 基础资料表头筛选冒烟测试（2026-09-16 补齐批次）：
// - 供应商资料页：服务端 empId 桶（值=业务员 UUID、label=人名）remap 到业务员列
//   key ownerEmployeeName；选桶回传服务端参数名 ownerEmployeeId。
// - 基本单位页：ADR-190 只展示编号/名称/状态；可见列 facets 与编号筛选原样回传，
//   编号空值桶走 nullFields。
// - 仓库资料页：目录按用途/状态筛选且保留命中仓的祖先；固定上级/核算与负责人事实在详情展示。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/widgets/master_detail_card.dart';
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
import 'package:uten_imp/features/basic_data/widgets/master_read_only_fields.dart';
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
              Perm.supplierCategoryView,
            }),
          ],
          child: const SupplierCategoryPage(),
        ),
      );

      await tester.tap(find.text('五金类'));
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
    testWidgets('日常三字段 facets 与编号筛选参数回传', (tester) async {
      final units = _FakeUnitRepository(
        facetPayload: const UnitFacets(
          fields: {
            'code': [MasterFacetBucket(value: 'DW000017', count: 4)],
            'name': [MasterFacetBucket(value: '个', count: 5)],
            'status': [MasterFacetBucket(value: '使用', count: 9)],
          },
          nullCounts: {'code': 7},
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
      expect(table.columns.map((column) => column.key), [
        'code',
        'name',
        'status',
      ]);
      expect(table.facets['code']?.single.value, 'DW000017');
      expect(table.facets['code']?.single.count, 4);
      expect(table.facets['name']?.single.value, '个');
      expect(table.facets['status']?.single.value, '使用');
      expect(table.nullCounts['code'], 7);
      expect(find.text('计量维度'), findsNothing);

      table.onFilterChanged('code', 'DW000017');
      await tester.pumpAndSettle();
      expect(units.lastFilters?['code'], 'DW000017');

      // 空值桶仍由真实仓储转换为 nullFields，保留共享筛选契约。
      _tableOf<UnitListItem>(
        tester,
      ).onFilterChanged('code', kMasterFilterNullValue);
      await tester.pumpAndSettle();
      expect(units.lastFilters?['code'], kMasterFilterNullValue);
    });
  });

  group('warehouse page', () {
    testWidgets('目录用途/状态筛选保留上级，固定上级与核算事实只读', (tester) async {
      final warehouses = _FakeWarehouseRepository();
      await _pumpWarehouse(tester, warehouses);

      UtenDropdownField useFilter() => tester.widget<UtenDropdownField>(
        find.byKey(const Key('warehouse-directory-use-filter')),
      );
      UtenCategoryTreeView directory() => tester.widget<UtenCategoryTreeView>(
        find.byKey(const Key('warehouse-directory-tree')),
      );
      expect(directory().visibleFilterIds, isNull);
      expect(useFilter().items.map((item) => item.value), [
        null,
        'false',
        'true',
      ]);

      useFilter().onChanged('true');
      await tester.pumpAndSettle();
      expect(directory().visibleFilterIds, {'wh-main', 'wh-bad'});
      expect(find.text('不良品仓库'), findsOneWidget);
      expect(find.text('成品仓库'), findsNothing);

      useFilter().onChanged(null);
      await tester.pumpAndSettle();
      final statusFilter = tester.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenDropdownField &&
              widget.label ==
                  AppLocalizations.of(
                    tester.element(find.byType(WarehousePage)),
                  ).warehouseMasterStatusLabel,
        ),
      );
      statusFilter.onChanged('禁用');
      await tester.pumpAndSettle();
      expect(directory().visibleFilterIds, {'wh-main', 'wh-2'});
      await tester.tap(find.text('五金仓库'));
      await tester.pumpAndSettle();

      final summary = tester.widget<MasterDetailCard>(
        find.byKey(const Key('warehouse-master-summary')),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(WarehousePage)),
      );
      final fieldsFinder = find.byKey(
        const ValueKey('warehouse-read-only-fields-wh-2'),
      );
      final fields = tester.widget<MasterReadOnlyFields>(fieldsFinder);
      expect(
        find.descendant(
          of: fieldsFinder,
          matching: find.text(l10n.warehouseMasterParentLabel),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: fieldsFinder, matching: find.text('总仓库')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: fieldsFinder, matching: find.text('不使用(不核算)')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: fieldsFinder, matching: find.text('禁用')),
        findsOneWidget,
      );
      expect(
        fields.fields.singleWhere((f) => f.key == 'parentName').readOnly,
        isTrue,
      );
      expect(
        find.descendant(of: fieldsFinder, matching: find.byType(TextField)),
        findsNothing,
      );
      expect(summary.canEdit, isFalse);
      expect(warehouses.detailIds, ['wh-2']);
      // Directory filters are facts over the complete dictionary, not a stale paged table.
      expect(warehouses.dictCalls, 1);
      expect(warehouses.listCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('详情显示全部登记仓管员，未登记显示破折号', (tester) async {
      await _pumpWarehouse(tester, _FakeWarehouseRepository());
      expect(find.text('成品仓库'), findsNothing);
      await tester.tap(find.byTooltip('展开总仓库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('成品仓库'));
      await tester.pumpAndSettle();
      MasterDetailCard summary() => tester.widget<MasterDetailCard>(
        find.byKey(const Key('warehouse-master-summary')),
      );
      expect(
        summary().stats.singleWhere((stat) => stat.label == '仓库负责人').value,
        '成品仓管、仓库主管',
      );
      expect(find.text('仓库负责人：成品仓管、仓库主管'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('warehouse-read-only-fields-wh-1')),
          matching: find.text('使用(参与核算)'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('五金仓库'));
      await tester.pumpAndSettle();
      expect(
        summary().stats.singleWhere((stat) => stat.label == '仓库负责人').value,
        '—',
      );
      expect(find.text('仓库负责人：—'), findsOneWidget);
      expect(find.textContaining('成品仓管'), findsNothing);
      expect(tester.takeException(), isNull);
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

Future<void> _pumpWarehouse(
  WidgetTester tester,
  _FakeWarehouseRepository warehouses,
) async {
  await _pump(
    tester,
    ProviderScope(
      overrides: [
        warehouseRepositoryProvider.overrideWithValue(warehouses),
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
}

class _FakeWarehouseRepository implements WarehouseRepository {
  int dictCalls = 0;
  int listCalls = 0;
  final detailIds = <String>[];

  static const _items = [
    WarehouseListItem(id: 'wh-main', code: '001', name: '总仓库', status: '使用'),
    WarehouseListItem(
      id: 'wh-1',
      code: 'C01',
      name: '成品仓库',
      parentId: 'wh-main',
      parentName: '总仓库',
      status: '使用',
    ),
    WarehouseListItem(
      id: 'wh-2',
      code: 'C02',
      name: '五金仓库',
      parentId: 'wh-main',
      parentName: '总仓库',
      status: '禁用',
      accountable: false,
    ),
    WarehouseListItem(
      id: 'wh-bad',
      code: 'C03',
      name: '不良品仓库',
      parentId: 'wh-main',
      parentName: '总仓库',
      status: '使用',
      defective: true,
    ),
  ];

  @override
  Future<List<WarehouseListItem>> dict() async {
    dictCalls++;
    return _items;
  }

  @override
  Future<WarehouseDetail> detail(String id) async {
    detailIds.add(id);
    final item = _items.singleWhere((item) => item.id == id);
    return WarehouseDetail(
      id: item.id,
      code: item.code,
      name: item.name,
      parentId: item.parentId,
      status: item.status,
      accountable: item.accountable,
      defective: item.defective,
    );
  }

  @override
  Future<PagedResult<WarehouseListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async {
    listCalls++;
    return PagedResult(
      items: _items,
      page: page,
      size: size,
      total: _items.length,
      totalPages: 1,
    );
  }

  @override
  Future<WarehouseFacets> facets() async =>
      const WarehouseFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

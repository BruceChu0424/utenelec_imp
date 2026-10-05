// 仓库资料页(ADR-145 单主仓)：
// - 列表主仓置顶带「主仓」标签、子仓缩进；新增「仓库用途」列(良品仓/不良品仓)可表头筛选，参数 defective；
// - 编辑子仓：上级仓库只读、固定显示主仓名；内料仓标记只读；保存时不上送上级仓库与内料仓标记
//   (上级由服务端补成主仓)，仓库用途按 'true'/'false' 上送；
// - 主仓的仓库用途只读(主仓不能是不良品仓)；
// - 车间内料仓(ADR-147)只由「车间内料仓」开通和撤销：详情只读，没有编辑/停用/删除。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/warehouse_node.dart';
import 'package:uten_imp/features/basic_data/pages/warehouse_page.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_keeper_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _main = WarehouseListItem(id: 'main', code: '001', name: '仓库(14年版)');
const _hardware = WarehouseListItem(
  id: 'c01',
  code: 'C01',
  name: '五金仓库',
  parentId: 'main',
  parentName: '仓库(14年版)',
  selectableForNew: true,
);
const _bin = WarehouseListItem(
  id: 'bin',
  code: 'LS-WS_ZHUANG',
  name: '装配第一车间内料仓',
  parentId: 'main',
  parentName: '仓库(14年版)',
  lineSide: true,
);
const _defective = WarehouseListItem(
  id: 'c0401',
  code: 'C0401',
  name: '成品不良品仓',
  parentId: 'main',
  parentName: '仓库(14年版)',
  defective: true,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('仓库用途列可筛选，主仓置顶带标签', (tester) async {
    final warehouses = _FakeWarehouseRepository(
      facetPayload: const WarehouseFacets(
        fields: {
          'defective': [
            MasterFacetBucket(value: 'false', count: 9, label: '良品仓'),
            MasterFacetBucket(value: 'true', count: 2, label: '不良品仓'),
          ],
        },
        nullCounts: {},
      ),
    );
    await _pump(tester, warehouses, permissions: {Perm.warehouseView});

    final table = tester.widget<MasterDataTableView<WarehouseListItem>>(
      find.byType(MasterDataTableView<WarehouseListItem>),
    );
    final use = table.columns.singleWhere((c) => c.key == 'defective');
    expect(use.label, '仓库用途');
    expect(use.value(_hardware), '良品仓');
    expect(use.value(_defective), '不良品仓');
    expect(table.facets['defective']?.last.label, '不良品仓');
    expect(table.items.first.id, 'main');
    // 主仓行名称旁带「主仓」标签，子仓没有。
    expect(find.text('主仓'), findsOneWidget);

    table.onFilterChanged('defective', 'true');
    await tester.pumpAndSettle();
    expect(warehouses.lastFilters?['defective'], 'true');
  });

  testWidgets('编辑子仓：上级仓库只读固定主仓，不上送上级与内料仓', (tester) async {
    final warehouses = _FakeWarehouseRepository(
      details: {
        'c01': const WarehouseDetail(
          id: 'c01',
          code: 'C01',
          name: '五金仓库',
          status: '使用',
          parentId: 'main',
          selectableForNew: true,
        ),
      },
    );
    await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseEdit},
    );
    final table = tester.widget<MasterDataTableView<WarehouseListItem>>(
      find.byType(MasterDataTableView<WarehouseListItem>),
    );
    table.onRowTap!(_hardware);
    await tester.pumpAndSettle();
    // 详情：上级仓库显示主仓名，仓库用途显示良品仓。
    expect(find.text('仓库(14年版)'), findsWidgets);
    expect(find.text('良品仓'), findsWidgets);
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();

    expect(find.text('编辑仓库'), findsOneWidget);
    // 上级仓库与内料仓标记都是禁用的只读展示(不是可选下拉)：上级固定显示主仓名。
    TextField readOnly(String label) => tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      ),
    );
    expect(readOnly('上级仓库').enabled, isFalse);
    expect(readOnly('上级仓库').controller!.text, '仓库(14年版)');
    expect(readOnly('内料仓').enabled, isFalse);
    expect(readOnly('内料仓').controller!.text, '否');

    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    final body = warehouses.updates.single;
    expect(body['name'], '五金仓库');
    expect(body['defective'], 'false');
    expect(body.containsKey('parentId'), isFalse);
    expect(body.containsKey('parentName'), isFalse);
    expect(body.containsKey('isLineSide'), isFalse);
  });

  testWidgets('车间内料仓只读：详情说明由车间内料仓管理，没有编辑、停用、删除', (tester) async {
    final warehouses = _FakeWarehouseRepository(
      details: {
        'bin': const WarehouseDetail(
          id: 'bin',
          code: 'LS-WS_ZHUANG',
          name: '装配第一车间内料仓',
          status: '使用',
          parentId: 'main',
          lineSide: true,
        ),
      },
    );
    await _pump(
      tester,
      warehouses,
      permissions: {
        Perm.warehouseView,
        Perm.warehouseEdit,
        Perm.warehouseStatus,
        Perm.warehouseDelete,
      },
    );
    tester
        .widget<MasterDataTableView<WarehouseListItem>>(
          find.byType(MasterDataTableView<WarehouseListItem>),
        )
        .onRowTap!(_bin);
    await tester.pumpAndSettle();
    expect(find.text('是, 由「车间内料仓」开通和管理 (这里只读)'), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
    expect(find.text('停用'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(warehouses.updates, isEmpty);
  });

  testWidgets('编辑主仓：仓库用途只读', (tester) async {
    final warehouses = _FakeWarehouseRepository(
      details: {
        'main': const WarehouseDetail(
          id: 'main',
          code: '001',
          name: '仓库(14年版)',
          status: '使用',
        ),
      },
    );
    await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseEdit},
    );
    tester
        .widget<MasterDataTableView<WarehouseListItem>>(
          find.byType(MasterDataTableView<WarehouseListItem>),
        )
        .onRowTap!(_main);
    await tester.pumpAndSettle();
    expect(find.text('这是主仓, 只作汇总、负责人范围和导航, 不能选作单据仓库'), findsWidgets);
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    final body = warehouses.updates.single;
    // 只读字段不上送：主仓的用途不会被改成不良品仓，上级也不传。
    expect(body.containsKey('defective'), isFalse);
    expect(body.containsKey('parentId'), isFalse);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _FakeWarehouseRepository warehouses, {
  required Set<String> permissions,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        warehouseRepositoryProvider.overrideWithValue(warehouses),
        warehouseKeeperRepositoryProvider.overrideWithValue(
          _FakeKeeperRepository(),
        ),
        masterNameServiceProvider.overrideWithValue(
          MasterNameService(_DictApi()),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        home: WarehousePage(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeWarehouseRepository implements WarehouseRepository {
  _FakeWarehouseRepository({this.facetPayload, this.details = const {}});

  final WarehouseFacets? facetPayload;
  final Map<String, WarehouseDetail> details;
  Map<String, String?>? lastFilters;
  final updates = <Map<String, dynamic>>[];

  @override
  Future<PagedResult<WarehouseListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async {
    lastFilters = Map<String, String?>.from(filters);
    return PagedResult(
      items: const [_main, _hardware, _defective],
      page: page,
      size: size,
      total: 3,
      totalPages: 1,
    );
  }

  @override
  Future<WarehouseFacets> facets() async =>
      facetPayload ?? const WarehouseFacets(fields: {}, nullCounts: {});

  @override
  Future<List<WarehouseWorkshopOption>> workshops() async => const [];

  @override
  Future<WarehouseDetail> detail(String id) async => details[id]!;

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    updates.add(Map<String, dynamic>.from(body));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeKeeperRepository implements WarehouseKeeperRepository {
  @override
  Future<List<WarehouseKeeperAssignment>> assignments() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 仓库字典：主仓 + 子仓(服务端算好的 selectableForNew)。
class _DictApi implements ApiClient {
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehousesDict) {
      return [
        {'id': 'main', 'name': '仓库(14年版)', 'code': '001'},
        {
          'id': 'c01',
          'name': '五金仓库',
          'code': 'C01',
          'parentId': 'main',
          'selectableForNew': true,
        },
      ];
    }
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

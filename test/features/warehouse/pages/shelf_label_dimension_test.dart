import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_rack_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/stock/repositories/stock_query_repository.dart';
import 'package:uten_imp/features/warehouse/pages/shelf_label_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'same goods keeps separate warehouse and explicit color identities',
    (tester) async {
      final repository = await _pump(tester);
      final table = _table(tester);
      expect(table.items, hasLength(6));
      expect(table.items.map((row) => row.rowKey).toSet(), hasLength(6));
      final sameGoods = table.items
          .where((row) => row.goodsId == 'goods')
          .toList();
      expect(sameGoods.map((row) => row.qty), [10, 3, 20]);
      expect(
        sameGoods.map((row) => table.rowKeyOf!(row)).toSet(),
        hasLength(3),
      );
      expect(find.text('实际仓库'), findsOneWidget);
      expect(find.text('A仓'), findsWidgets);
      expect(find.text('B仓'), findsWidgets);
      expect(find.textContaining('库存按实际仓库和颜色统计'), findsOneWidget);
      expect(find.textContaining('当前包含多个仓库'), findsOneWidget);
      expect(find.byType(UtenRackGrid), findsNothing);
      expect(repository.layoutCalls, 0);
    },
  );

  testWidgets(
    'filtering to A cannot borrow B ninth shelf level or master-only layout',
    (tester) async {
      final repository = await _pump(tester);
      final search = find.descendant(
        of: find.byKey(const Key('shelf-label-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '仅A');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(_table(tester).items.single.warehouseId, 'wa');
      final grid = tester.widget<UtenRackGrid>(find.byType(UtenRackGrid));
      expect(grid.racks, isEmpty);
      expect(grid.items.single.level, 2);
      expect(find.byKey(const Key('rack-cell-X-2-1')), findsOneWidget);
      expect(find.byKey(const Key('rack-cell-X-9-1')), findsNothing);
      expect(
        repository.layoutCalls,
        0,
        reason: 'The old all-warehouse layout deliberately returns level nine.',
      );
    },
  );

  testWidgets(
    'one warehouse excludes master-only rows from diagram and cell selection',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('shelf-label-warehouse')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-wa')));
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(4));
      final grid = tester.widget<UtenRackGrid>(find.byType(UtenRackGrid));
      expect(grid.items, hasLength(3));
      expect(grid.items.every((item) => item.id.startsWith('wa|')), isTrue);
      expect(grid.items.map((item) => item.id).toSet(), hasLength(3));
      await tester.tap(find.byKey(const Key('rack-cell-X-1-1')));
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(2));
      expect(
        _table(tester).items.every((row) => row.warehouseId == 'wa'),
        isTrue,
      );
      expect(_table(tester).items.map((row) => row.colorId).toSet(), {
        'red',
        null,
      });
    },
  );
}

MasterDataTableView<ShelfLabelRow> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<ShelfLabelRow>>(
      find.byType(MasterDataTableView<ShelfLabelRow>),
    );

Future<_DimensionRepository> _pump(WidgetTester tester) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1600, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final repository = _DimensionRepository();
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: request.path.contains('warehouses/dict')
              ? const [
                  {'id': 'wa', 'code': 'WA', 'name': 'A仓'},
                  {'id': 'wb', 'code': 'WB', 'name': 'B仓'},
                ]
              : const <Map<String, dynamic>>[],
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.stockView,
          Perm.stockReportExport,
        }),
        stockQueryRepositoryProvider.overrideWithValue(repository),
        masterNameServiceProvider.overrideWithValue(
          MasterNameService(ApiClient(dio)),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ShelfLabelPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return repository;
}

class _DimensionRepository extends StockQueryRepository {
  _DimensionRepository() : super(ApiClient(Dio()));
  int layoutCalls = 0;
  static const rows = [
    ShelfLabelRow(
      goodsId: 'goods',
      goodsName: '共用物料',
      goodsCode: 'G',
      warehouseId: 'wa',
      warehouseName: 'A仓',
      colorId: 'red',
      colorName: '红',
      rack: 'X',
      place: 'X-1-1',
      level: 1,
      slot: 1,
      parsed: true,
      qty: 10,
    ),
    ShelfLabelRow(
      goodsId: 'goods',
      goodsName: '共用物料',
      goodsCode: 'G',
      warehouseId: 'wa',
      warehouseName: 'A仓',
      rack: 'X',
      place: 'X-1-1',
      level: 1,
      slot: 1,
      parsed: true,
      qty: 3,
    ),
    ShelfLabelRow(
      goodsId: 'goods',
      goodsName: '共用物料',
      goodsCode: 'G',
      warehouseId: 'wb',
      warehouseName: 'B仓',
      colorId: 'red',
      colorName: '红',
      rack: 'X',
      place: 'X-1-1',
      level: 1,
      slot: 1,
      parsed: true,
      qty: 20,
    ),
    ShelfLabelRow(
      goodsId: 'only-a',
      goodsName: '仅A物料',
      goodsCode: 'A',
      warehouseId: 'wa',
      warehouseName: 'A仓',
      rack: 'X',
      place: 'X-2-1',
      level: 2,
      slot: 1,
      parsed: true,
      qty: 5,
    ),
    ShelfLabelRow(
      goodsId: 'only-b',
      goodsName: '仅B物料',
      goodsCode: 'B',
      warehouseId: 'wb',
      warehouseName: 'B仓',
      rack: 'X',
      place: 'X-9-1',
      level: 9,
      slot: 1,
      parsed: true,
      qty: 9,
    ),
    ShelfLabelRow(
      goodsId: 'suggestion',
      goodsName: '主档建议',
      goodsCode: 'M',
      rack: 'X',
      place: 'X-1-1',
      level: 1,
      slot: 1,
      parsed: true,
    ),
  ];

  @override
  Future<List<String>> shelfLabelRacks({
    String? warehouseId,
    bool includeDisabled = false,
  }) async => const ['X'];

  @override
  Future<List<ShelfLayoutRack>> shelfLabelLayout({
    String? warehouseId,
    bool includeDisabled = false,
  }) async {
    layoutCalls++;
    return const [
      ShelfLayoutRack(rack: 'X', maxLevel: 9, maxSlot: 1, count: 6),
    ];
  }

  @override
  Future<List<ShelfLabelRow>> shelfLabels({
    String? rack,
    String? keyword,
    String? warehouseId,
    bool includeDisabled = false,
  }) async => rows
      .where(
        (row) =>
            (warehouseId == null ||
                row.warehouseId == null ||
                row.warehouseId == warehouseId) &&
            (rack == null || row.rack == rack) &&
            (keyword == null || row.goodsName!.contains(keyword)),
      )
      .toList();
}

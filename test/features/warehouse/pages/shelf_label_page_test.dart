// 货架目视化清单页 widget 测试（2026-09-10 信息架构重做后）。
//
// 覆盖：货架图 + 统一表格并存、点格定位（表格收敛 + 定位 chip + 再点取消）、
// 点表格行反查货架图、库行分段重查、「显示已禁用货品」开关、未分层残值桶与 chip、
// 仓库切换（侧滑面板选仓）三个查询全部带 warehouseId 重查。
// 数据全部走假仓储 + 字典接口走 Dio 拦截器（仅仓库字典返真值），不触网。
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

  testWidgets('初始加载：货架图画出格子（同格多货显 +n）+ 统一表格列出全部行', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);

    // 货架图：库行卡 + 格子；A31-3-1 两个货品聚合成一格。
    expect(find.byKey(const Key('shelf-label-rack-grid')), findsOneWidget);
    expect(find.byKey(const Key('rack-card-A31')), findsOneWidget);
    expect(find.byKey(const Key('rack-cell-A31-3-1')), findsOneWidget);
    expect(find.byKey(const Key('rack-cell-B02-1-4')), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);

    // 统一表格：新列头 + 全量行（禁用货品默认不查）。
    for (final label in const ['货架', '层', '位', '库位号', '货品编码', '即时库存', '状态']) {
      expect(find.text(label), findsWidgets);
    }
    expect(_table(tester).items.length, 4);
    expect(find.text('共 4 项'), findsOneWidget);
    expect(repo.includeDisabledCalls, [false]);
  });

  testWidgets('点货架图格子：表格收敛到该库位 + 定位 chip；再点一次取消', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);

    await tester.tap(find.byKey(const Key('rack-cell-A31-3-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shelf-label-locate-chip')), findsOneWidget);
    expect(_grid(tester).selectedPlace, 'A31-3-1');
    // 同库位两个货品都留在表里，其余行收敛掉。
    expect(_table(tester).items.length, 2);
    expect(_table(tester).items.every((r) => r.place == 'A31-3-1'), isTrue);

    await tester.tap(find.byKey(const Key('rack-cell-A31-3-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shelf-label-locate-chip')), findsNothing);
    expect(_grid(tester).selectedPlace, isNull);
    expect(_table(tester).items.length, 4);
  });

  testWidgets('点表格行：反查货架图高亮对应格，表格不收敛', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);

    // 颜色列只在表格里出现，用它精确点到表格行（货架图不画颜色）。
    await tester.tap(find.text('白色'));
    await tester.pumpAndSettle();

    expect(_grid(tester).selectedPlace, 'B02-1-4');
    expect(find.byKey(const Key('shelf-label-locate-chip')), findsNothing);
    expect(_table(tester).items.length, 4);
  });

  testWidgets('库行分段：选中后带 rack 重查，定位态清空', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);
    expect(repo.rackCalls, [null]); // 初始未选分段 = 全部

    // 「B02 库行」在分段条与货架图卡头各有一处，限定在分段条内点。
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('shelf-label-rack-segments')),
        matching: find.text('B02 库行'),
      ),
    );
    await tester.pumpAndSettle();

    expect(repo.rackCalls, [null, 'B02']);
    expect(_table(tester).items.length, 1);
    expect(_table(tester).items.single.place, 'B02-1-4');
  });

  testWidgets('「显示已禁用货品」开关：带 includeDisabled 重查并标记状态', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);
    expect(find.text('已禁用'), findsNothing);

    await tester.tap(find.byKey(const Key('shelf-label-include-disabled')));
    await tester.pumpAndSettle();

    expect(repo.includeDisabledCalls, [false, true]);
    expect(_table(tester).items.length, 5);
    expect(find.text('已禁用'), findsOneWidget);
  });

  testWidgets('未分层残值：归未分层桶 + chip 计数，点 chip 收敛表格', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);

    // 残值不进库行分段，只进未分层桶。
    expect(find.text('Y12 库行'), findsNothing);
    expect(find.byKey(const Key('rack-card-unparsed')), findsOneWidget);
    expect(find.text('未分层（1）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('shelf-label-unparsed-chip')));
    await tester.pumpAndSettle();

    expect(_table(tester).items.length, 1);
    expect(_table(tester).items.single.place, 'Y12');
  });

  testWidgets('切换抬头仓库（侧滑面板）：清单/库行/布局三个查询都带 warehouseId 重查', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);
    expect(repo.warehouseCalls, [null]);
    expect(repo.racksWarehouseCalls, [null]);
    expect(repo.layoutWarehouseCalls, [null]);

    // 仓库筛选 = 侧滑面板（2026-09-11 全站统一）：点字段拉面板，点仓行即选即关。
    await tester.tap(find.byKey(const Key('shelf-label-warehouse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-picker-all')), findsOneWidget);
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-w1')));
    await tester.pumpAndSettle();

    expect(repo.warehouseCalls, [null, 'w1']);
    expect(repo.racksWarehouseCalls, [null, 'w1']);
    expect(repo.layoutWarehouseCalls, [null, 'w1']);
  });

  testWidgets('无已维护库位号的货品时显示引导空态', (tester) async {
    final repo = _FakeStockQueryRepository(
      rows: const [],
      layout: const [],
      racks: const [],
    );
    await _pumpPage(tester, repo);

    expect(find.byKey(const Key('rack-grid-empty')), findsOneWidget);
    expect(find.textContaining('请先在货品资料中填写'), findsOneWidget);
    expect(find.text('共 0 项'), findsOneWidget);
  });
}

MasterDataTableView<ShelfLabelRow> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<ShelfLabelRow>>(
      find.byType(MasterDataTableView<ShelfLabelRow>),
    );

UtenRackGrid _grid(WidgetTester tester) =>
    tester.widget<UtenRackGrid>(find.byType(UtenRackGrid));

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeStockQueryRepository repo,
) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1600, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.stockView,
          Perm.stockReportExport,
        }),
        stockQueryRepositoryProvider.overrideWithValue(repo),
        masterNameServiceProvider.overrideWithValue(
          MasterNameService(_dictApi()),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ShelfLabelPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 字典接口：仓库字典返一条真值（测仓库切换），其余字典返空表（名称服务已容错）。
ApiClient _dictApi() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: request.path.contains('warehouses/dict')
              ? const [
                  {'id': 'w1', 'name': '五金仓库', 'code': 'WH01'},
                ]
              : const <Map<String, dynamic>>[],
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

/// 假库存查询仓储：记录 rack/keyword/warehouseId/includeDisabled 入参并按之过滤。
class _FakeStockQueryRepository extends StockQueryRepository {
  _FakeStockQueryRepository({
    List<ShelfLabelRow>? rows,
    List<ShelfLayoutRack>? layout,
    List<String>? racks,
  }) : rows = rows ?? _defaultRows,
       layout = layout ?? _defaultLayout,
       racks = racks ?? const ['A31', 'B02'],
       super(ApiClient(Dio()));

  final List<ShelfLabelRow> rows;
  final List<ShelfLayoutRack> layout;
  final List<String> racks;

  final rackCalls = <String?>[];
  final keywordCalls = <String?>[];
  final warehouseCalls = <String?>[];
  final includeDisabledCalls = <bool>[];
  final racksWarehouseCalls = <String?>[];
  final layoutWarehouseCalls = <String?>[];

  static const _defaultRows = [
    ShelfLabelRow(
      goodsId: 'g1',
      rack: 'A31',
      place: 'A31-3-1',
      goodsCode: 'GL-1001',
      series: 'YF-60',
      goodsName: '静音风扇电机',
      colorName: '黑色',
      unitName: '只',
      qty: 12,
      level: 3,
      slot: 1,
      parsed: true,
    ),
    ShelfLabelRow(
      goodsId: 'g2',
      rack: 'A31',
      place: 'A31-3-1',
      goodsCode: 'GL-1002',
      series: 'YF-60',
      goodsName: '风扇电容',
      colorName: '银色',
      unitName: '只',
      qty: 5,
      level: 3,
      slot: 1,
      parsed: true,
    ),
    ShelfLabelRow(
      goodsId: 'g3',
      rack: 'B02',
      place: 'B02-1-4',
      goodsCode: 'GL-2001',
      series: 'HK-12',
      goodsName: '温控器旋钮',
      colorName: '白色',
      unitName: '个',
      level: 1,
      slot: 4,
      parsed: true,
    ),
    // 老库残值：不符合「库行-层-位」三段格式 → 未分层桶。
    ShelfLabelRow(
      goodsId: 'g4',
      rack: '',
      place: 'Y12',
      goodsCode: 'V51012',
      goodsName: '老库残值件',
      colorName: '原色',
      unitName: '个',
    ),
  ];

  /// 只有 includeDisabled=true 才出现的禁用货品。
  static const _disabledRow = ShelfLabelRow(
    goodsId: 'g5',
    rack: 'B02',
    place: 'B02-1-5',
    goodsCode: 'GL-2002',
    goodsName: '停用件',
    colorName: '灰色',
    unitName: '个',
    disabled: true,
    level: 1,
    slot: 5,
    parsed: true,
  );

  static const _defaultLayout = [
    ShelfLayoutRack(rack: 'A31', maxLevel: 3, maxSlot: 2, count: 2),
    ShelfLayoutRack(rack: 'B02', maxLevel: 1, maxSlot: 4, count: 1),
    ShelfLayoutRack(rack: '', count: 1),
  ];

  @override
  Future<List<String>> shelfLabelRacks({
    String? warehouseId,
    bool includeDisabled = false,
  }) async {
    racksWarehouseCalls.add(warehouseId);
    return racks;
  }

  @override
  Future<List<ShelfLayoutRack>> shelfLabelLayout({
    String? warehouseId,
    bool includeDisabled = false,
  }) async {
    layoutWarehouseCalls.add(warehouseId);
    return layout;
  }

  @override
  Future<List<ShelfLabelRow>> shelfLabels({
    String? rack,
    String? keyword,
    String? warehouseId,
    bool includeDisabled = false,
  }) async {
    rackCalls.add(rack);
    keywordCalls.add(keyword);
    warehouseCalls.add(warehouseId);
    includeDisabledCalls.add(includeDisabled);
    var out = includeDisabled && rows.isNotEmpty
        ? [...rows, _disabledRow]
        : rows;
    if (rack != null) {
      out = out.where((r) => r.rack == rack).toList();
    }
    if (keyword != null && keyword.isNotEmpty) {
      out = out.where((r) => (r.goodsName ?? '').contains(keyword)).toList();
    }
    return out;
  }
}

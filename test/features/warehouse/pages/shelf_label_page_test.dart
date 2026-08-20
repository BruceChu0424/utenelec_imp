// 货架目视化清单页 widget 测试。
//
// 覆盖：初始加载按库行分组渲染、库行下拉筛选重查、关键字搜索下传、空态。
// 数据全部走假仓储 + 字典接口走 Dio 拦截器（返回空表），不触网。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/stock/repositories/stock_query_repository.dart';
import 'package:uten_imp/features/warehouse/pages/shelf_label_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('初始加载：按库行分组渲染卡片与计数', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);

    // 库行徽章 + 项数 + 总计数。
    expect(find.text('A31 库行'), findsOneWidget);
    expect(find.text('B02 库行'), findsOneWidget);
    expect(find.text('共 3 项 · 2 个库行'), findsOneWidget);
    // 行内容（库位号/编码/名称）。
    expect(find.text('A31-3-1'), findsOneWidget);
    expect(find.text('GL-1001'), findsOneWidget);
    expect(find.text('静音风扇电机'), findsOneWidget);
    expect(find.text('B02-1-4'), findsOneWidget);
    // 表头五列（与挂牌一致）。
    for (final h in const ['库位号', '物料编码', '物料系列', '物料名称', '颜色']) {
      expect(find.text(h), findsWidgets);
    }
  });

  testWidgets('库行下拉筛选：选中后带 rack 重查并只显示该库行', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);
    expect(repo.rackCalls, [null]); // 初始全量

    // 打开「库行」下拉（第二个 DropdownButtonFormField），选 B02。
    await tester.tap(find.byType(DropdownButtonFormField<String?>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B02 库行').last);
    await tester.pumpAndSettle();

    expect(repo.rackCalls, [null, 'B02']);
    expect(find.text('共 1 项 · 1 个库行'), findsOneWidget);
    expect(find.text('A31-3-1'), findsNothing);
    expect(find.text('B02-1-4'), findsOneWidget);
  });

  testWidgets('搜索关键字下传后端并重查列表', (tester) async {
    final repo = _FakeStockQueryRepository();
    await _pumpPage(tester, repo);

    await tester.enterText(find.byType(TextField).last, '电机');
    await tester.pump(const Duration(milliseconds: 350)); // 防抖窗口
    await tester.pumpAndSettle();

    expect(repo.keywordCalls, contains('电机'));
    // 假仓储按名称模糊：只剩「静音风扇电机」一行。
    expect(find.text('共 1 项 · 1 个库行'), findsOneWidget);
    expect(find.text('B02-1-4'), findsNothing);
  });

  testWidgets('无已维护库位号的货品时显示引导空态', (tester) async {
    final repo = _FakeStockQueryRepository(rows: const []);
    await _pumpPage(tester, repo);

    expect(find.textContaining('暂无已维护库位号的货品'), findsOneWidget);
    expect(find.text('共 0 项 · 0 个库行'), findsOneWidget);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeStockQueryRepository repo,
) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1440, 900));
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
          MasterNameService(_emptyDictApi()),
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

/// 字典接口统一返回空表（名称服务内部已容错降级）。
ApiClient _emptyDictApi() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: const <Map<String, dynamic>>[],
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

/// 假库存查询仓储：记录 rack/keyword 入参，按库行与名称模糊过滤。
class _FakeStockQueryRepository extends StockQueryRepository {
  _FakeStockQueryRepository({List<ShelfLabelRow>? rows})
    : rows = rows ?? _defaultRows,
      super(ApiClient(Dio()));

  final List<ShelfLabelRow> rows;
  final rackCalls = <String?>[];
  final keywordCalls = <String?>[];

  static const _defaultRows = [
    ShelfLabelRow(
      goodsId: 'g1',
      rack: 'A31',
      place: 'A31-3-1',
      goodsCode: 'GL-1001',
      series: 'YF-60',
      goodsName: '静音风扇电机',
      colorName: '黑色',
    ),
    ShelfLabelRow(
      goodsId: 'g2',
      rack: 'A31',
      place: 'A31-3-2',
      goodsCode: 'GL-1002',
      series: 'YF-60',
      goodsName: '风扇电容',
      colorName: '银色',
    ),
    ShelfLabelRow(
      goodsId: 'g3',
      rack: 'B02',
      place: 'B02-1-4',
      goodsCode: 'GL-2001',
      series: 'HK-12',
      goodsName: '温控器旋钮',
      colorName: '白色',
    ),
  ];

  @override
  Future<List<String>> shelfLabelRacks() async => ['A31', 'B02'];

  @override
  Future<List<ShelfLabelRow>> shelfLabels({
    String? rack,
    String? keyword,
  }) async {
    rackCalls.add(rack);
    keywordCalls.add(keyword);
    var out = rows;
    if (rack != null) {
      out = out.where((r) => r.rack == rack).toList();
    }
    if (keyword != null && keyword.isNotEmpty) {
      out = out.where((r) => (r.goodsName ?? '').contains(keyword)).toList();
    }
    return out;
  }
}

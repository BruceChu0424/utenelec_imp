// 盘点模式独立页（/stock/count-session）的行为锁定：
// - 进入即选仓（带 warehouseId 直达，不再弹选仓窗），列表走盘点单口径(sheet)：
//   主档归属本仓 ∪ 本仓有余额，各仓行数不同；
// - 默认「全部物料」（账面为 0 也要盘），「有库存」为筛段；
// - 换仓库用平台自研下拉（只显仓库名，不带「财务审核」后缀），按仓保留输入；
// - 盘点说明在「保存并送审」确认弹窗里选填；送审走 stock_count_requests；
// - 切换仓库按仓保留未送审输入（内存暂存，随本机草稿落盘由 FormDraftMixin 负责，
//   测试环境无登录身份，草稿通道自然关闭，只验业务流）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/stock/counts/pages/stock_count_session_page.dart';
import 'package:uten_imp/features/stock/counts/repositories/stock_count_request_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _warehouseA = StockCountWarehouse(
  id: 'leaf-a',
  name: '原料仓 A',
  kind: 'NORMAL',
  reviewRoute: 'FINANCE',
);
const _warehouseB = StockCountWarehouse(
  id: 'leaf-b',
  name: '原料仓 B',
  kind: 'NORMAL',
  reviewRoute: 'FINANCE',
);
const _screw = '11111111-1111-1111-1111-111111111111';
const _nut = '22222222-2222-2222-2222-222222222222';

CountStockRow _row(
  String goodsId, {
  String qty = '0',
  String? weight,
  String? factor,
}) => CountStockRow(
  goodsId: goodsId,
  goodsName: goodsId == _screw ? '螺丝' : '螺母',
  goodsCode: goodsId,
  categoryId: 'raw',
  unitId: 'unit-1',
  unitName: factor == null ? '个' : '克',
  qty: qty,
  weightKg: weight,
  kgPerBaseUnit: factor,
  goodsVersion: 7,
  allowedActions: const ['EDIT'],
);

class _SessionRepo extends StockCountRequestRepository {
  _SessionRepo(this.stock) : super(ApiClient(Dio()));
  final Map<String, List<CountStockRow>> stock;
  final warehouses = <StockCountWarehouse>[_warehouseA, _warehouseB];
  bool canSubmit = true;
  final candidateQueries =
      <({String warehouse, bool stockedOnly, bool sheet, String? keyword})>[];
  final categoryQueries = <({String warehouse, bool sheet})>[];
  final submissions =
      <({String warehouse, List<Map<String, dynamic>> lines, String reason})>[];

  @override
  Future<StockCountScope> scope({String? warehouseId}) async => StockCountScope(
    warehouses: warehouses
        .where((w) => warehouseId == null || w.id == warehouseId)
        .toList(),
    allowedActions: canSubmit ? const ['SUBMIT'] : const [],
  );

  @override
  Future<PagedResult<CountStockRow>> candidates({
    required String warehouseId,
    String? keyword,
    String? categoryId,
    List<String> goodsIds = const [],
    bool stockedOnly = false,
    bool sheet = false,
    int page = 1,
    int size = 50,
  }) async {
    candidateQueries.add((
      warehouse: warehouseId,
      stockedOnly: stockedOnly,
      sheet: sheet,
      keyword: keyword,
    ));
    var rows = stock[warehouseId] ?? const <CountStockRow>[];
    if (goodsIds.isNotEmpty) {
      rows = rows.where((r) => goodsIds.contains(r.goodsId)).toList();
    }
    if (stockedOnly) {
      rows = rows.where((r) => (double.tryParse(r.qty) ?? 0) != 0).toList();
    }
    return PagedResult(
      items: rows,
      page: 1,
      size: size,
      total: rows.length,
      totalPages: 1,
    );
  }

  @override
  Future<List<ProductCategoryNode>> candidateCategories(
    String warehouseId, {
    bool sheet = false,
  }) async {
    categoryQueries.add((warehouse: warehouseId, sheet: sheet));
    return [
      ProductCategoryNode(
        id: 'raw',
        code: '',
        name: '原材料',
        level: 0,
        children: [],
      ),
    ];
  }

  @override
  Future<StockCountRequest> submit({
    required String warehouseId,
    required String reason,
    required String idempotencyKey,
    required List<Map<String, dynamic>> lines,
  }) async {
    submissions.add((warehouse: warehouseId, lines: lines, reason: reason));
    return StockCountRequest(
      id: 'request-1',
      requestNo: 'PD-1',
      warehouseId: warehouseId,
      warehouseName: '目标仓',
      reviewRoute: 'FINANCE',
      status: 'PENDING',
      version: 0,
    );
  }
}

Future<GoRouter> _mount(
  WidgetTester tester,
  _SessionRepo repo, {
  String? warehouseId,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view
    ..physicalSize = const Size(2200, 1200)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: warehouseId == null
        ? RouteName.stockCountSession
        : Uri(
            path: RouteName.stockCountSession,
            queryParameters: {'warehouseId': warehouseId},
          ).toString(),
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: SizedBox()),
      ),
      GoRoute(
        path: RouteName.stockCountSession,
        builder: (_, state) => StockCountSessionPage(
          warehouseId: state.uri.queryParameters['warehouseId'],
        ),
      ),
      GoRoute(
        path: RouteName.stockCountRequests,
        builder: (_, _) => const Scaffold(body: SizedBox()),
      ),
      GoRoute(
        path: RouteName.stockInstantInventory,
        builder: (_, _) => const Scaffold(body: SizedBox()),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        sharedPreferencesProvider.overrideWithValue(prefs),
        stockCountRequestRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// 打开右下「保存并送审」的确认弹窗（盘点说明在这里选填）。
Future<void> _confirmSubmit(WidgetTester tester, {String? reason}) async {
  await tester.tap(find.byKey(const Key('stock-count-save')));
  await tester.pumpAndSettle();
  if (reason != null) {
    await tester.enterText(find.byKey(const Key('stock-count-reason')), reason);
  }
  await tester.tap(find.text('确认送审'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('进入即选仓，盘点单口径列出全部物料(账面为 0 也要盘)', (tester) async {
    final repo = _SessionRepo({
      'leaf-a': [_row(_screw, qty: '10', weight: '1.5'), _row(_nut)],
    });
    await _mount(tester, repo, warehouseId: 'leaf-a');
    expect(find.text('盘点仓库'), findsNothing, reason: '带仓库直达不再弹选仓窗');
    expect(repo.candidateQueries.first, (
      warehouse: 'leaf-a',
      stockedOnly: false,
      sheet: true,
      keyword: null,
    ), reason: '默认全部物料 + 盘点单口径');
    expect(repo.categoryQueries.first, (
      warehouse: 'leaf-a',
      sheet: true,
    ), reason: '分类树同盘点单口径');
    final table = tester.widget<MasterDataTableView<CountStockRow>>(
      find.byType(MasterDataTableView<CountStockRow>),
    );
    expect(
      table.items.map((r) => r.goodsId),
      containsAll([_screw, _nut]),
      reason: '零库存行默认就在表里',
    );
    expect(
      table.columns.map((c) => c.key),
      containsAll([
        'stockPlace',
        'countTargetQty',
        'countTargetWeight',
        'delta',
      ]),
    );
    // 行距=读表密度(36~38)，与任务中心一致；就地编辑：点格→变输入框→输入。
    final screwCell = find.byKey(const ValueKey('stock-count-qty-$_screw|'));
    final nutCell = find.byKey(const ValueKey('stock-count-qty-$_nut|'));
    expect(
      tester.getTopLeft(nutCell).dy - tester.getTopLeft(screwCell).dy,
      lessThan(42),
      reason: '未编辑行保持读表行距（约 36）',
    );
    await tester.tap(screwCell);
    await tester.pump();
    await tester.enterText(screwCell, '12');
    await tester.pump();
    await _confirmSubmit(tester, reason: '例行盘点');
    expect(repo.submissions.single.warehouse, 'leaf-a');
    expect(repo.submissions.single.reason, '例行盘点');
    expect(repo.submissions.single.lines.single['targetQty'], '12');
    expect(tester.takeException(), isNull);
  });

  testWidgets('「有库存」筛段只列账面数量非零的行', (tester) async {
    final repo = _SessionRepo({
      'leaf-a': [_row(_screw, qty: '10'), _row(_nut)],
    });
    await _mount(tester, repo, warehouseId: 'leaf-a');
    expect(
      find.byKey(const ValueKey('stock-count-qty-$_nut|')),
      findsOneWidget,
    );
    await tester.tap(find.text('有库存'));
    await tester.pumpAndSettle();
    expect(
      repo.candidateQueries.last.stockedOnly,
      true,
      reason: '筛段透传 stockedOnly',
    );
    expect(find.byKey(const ValueKey('stock-count-qty-$_nut|')), findsNothing);
    final qty = find.byKey(const ValueKey('stock-count-qty-$_screw|'));
    await tester.tap(qty);
    await tester.pump();
    await tester.enterText(qty, '9');
    await tester.pump();
    await _confirmSubmit(tester);
    expect(repo.submissions.single.lines.single['targetQty'], '9');
    expect(repo.submissions.single.reason, '', reason: '说明选填，不填即空');
    expect(tester.takeException(), isNull);
  });

  testWidgets('换仓库用下拉列表(只显仓名)并按仓保留未送审输入', (tester) async {
    final repo = _SessionRepo({
      'leaf-a': [_row(_screw, qty: '10')],
      'leaf-b': [_row(_nut, qty: '7')],
    });
    await _mount(tester, repo, warehouseId: 'leaf-a');
    final aCell = find.byKey(const ValueKey('stock-count-qty-$_screw|'));
    await tester.tap(aCell);
    await tester.pump();
    await tester.enterText(aCell, '11');
    await tester.pump();
    await tester.tap(find.byKey(const Key('stock-count-warehouse')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('财务审核'),
      findsNothing,
      reason: '审核路由是默认信息，不占下拉文案',
    );
    await tester.tap(find.text('原料仓 B'));
    await tester.pumpAndSettle();
    expect(repo.candidateQueries.last.warehouse, 'leaf-b', reason: '切仓后按新仓查询');
    final bQty = find.byKey(const ValueKey('stock-count-qty-$_nut|'));
    expect(bQty, findsOneWidget);
    await tester.tap(bQty);
    await tester.pump();
    await tester.enterText(bQty, '8');
    await tester.pump();
    // 切回 A：之前填的 11 必须还在（按仓暂存）。
    await tester.tap(find.byKey(const Key('stock-count-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原料仓 A'));
    await tester.pumpAndSettle();
    final aText = tester.widget<Text>(
      find.byKey(const ValueKey('stock-count-qty-$_screw|')),
    );
    expect(aText.data, '11', reason: '切仓回来显示已填的实盘值');
    // 送审只提交当前仓 A 的行。
    await _confirmSubmit(tester);
    expect(repo.submissions.single.warehouse, 'leaf-a');
    expect(repo.submissions.single.lines.single['targetQty'], '11');
    expect(tester.takeException(), isNull);
  });

  testWidgets('「有库存」筛段为空时引导切回全部物料', (tester) async {
    final repo = _SessionRepo({
      'leaf-a': [_row(_nut)],
    });
    await _mount(tester, repo, warehouseId: 'leaf-a');
    // 默认全部物料：零库存行也在表里，直接可录实盘数。
    expect(
      find.byKey(const ValueKey('stock-count-qty-$_nut|')),
      findsOneWidget,
    );
    expect(find.text('共 1 项'), findsOneWidget);
    await tester.tap(find.text('有库存'));
    await tester.pumpAndSettle();
    expect(find.text('共 0 项'), findsOneWidget);
    expect(find.text('本仓暂无有库存的物料；可切回「全部物料」或用「添加物料」录入盘盈'), findsOneWidget);
    await tester.tap(find.text('全部物料'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('stock-count-qty-$_nut|')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有可盘点仓库或提交权限时给出明确提示', (tester) async {
    final repo = _SessionRepo({})..canSubmit = false;
    await _mount(tester, repo);
    expect(find.text('当前没有提交盘点的权限'), findsOneWidget);
    expect(find.byKey(const Key('stock-count-save')), findsNothing);
  });
}

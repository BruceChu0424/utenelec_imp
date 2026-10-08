// 盘点模式独立页（/stock/count-session）的行为锁定：
// - 进入即选仓（带 warehouseId 直达，不再弹选仓窗），默认「有库存」段；
// - 「全部物料」段补齐零库存行；实盘列可编辑、送审走 stock_count_requests；
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
      <({String warehouse, bool stockedOnly, String? keyword})>[];
  final submissions = <
    ({
      String warehouse,
      List<Map<String, dynamic>> lines,
      String reason,
    })
  >[];

  @override
  Future<StockCountScope> scope({String? warehouseId}) async =>
      StockCountScope(
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
    int page = 1,
    int size = 50,
  }) async {
    candidateQueries.add((
      warehouse: warehouseId,
      stockedOnly: stockedOnly,
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
  Future<StockCountRequest> submit({
    required String warehouseId,
    required String reason,
    required String idempotencyKey,
    required List<Map<String, dynamic>> lines,
  }) async {
    submissions.add((
      warehouse: warehouseId,
      lines: lines,
      reason: reason,
    ));
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

void main() {
  testWidgets('进入即选仓并列出全部物料(账面为 0 也要盘)', (tester) async {
    final repo = _SessionRepo({
      'leaf-a': [
        _row(_screw, qty: '10', weight: '1.5'),
        _row(_nut),
      ],
    });
    await _mount(tester, repo, warehouseId: 'leaf-a');
    expect(find.text('盘点仓库'), findsNothing, reason: '带仓库直达不再弹选仓窗');
    expect(
      repo.candidateQueries.first,
      (warehouse: 'leaf-a', stockedOnly: false, keyword: null),
      reason: '2026-10-08 用户口径: 默认全部物料, 账面为 0 也要显示并录入',
    );
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
      containsAll(['stockPlace', 'countTargetQty', 'countTargetWeight', 'delta']),
    );
    final qty = find.byKey(const ValueKey('stock-count-qty-$_screw|'));
    await tester.enterText(qty, '12');
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('stock-count-reason')),
      '例行盘点',
    );
    await tester.tap(find.byKey(const Key('stock-count-save')));
    await tester.pumpAndSettle();
    expect(repo.submissions.single.warehouse, 'leaf-a');
    expect(repo.submissions.single.reason, '例行盘点');
    expect(repo.submissions.single.lines.single['targetQty'], '12');
    expect(tester.takeException(), isNull);
  });

  testWidgets('「有库存」筛段只列账面数量非零的行', (tester) async {
    final repo = _SessionRepo({
      'leaf-a': [
        _row(_screw, qty: '10'),
        _row(_nut),
      ],
    });
    await _mount(tester, repo, warehouseId: 'leaf-a');
    expect(find.byKey(const ValueKey('stock-count-qty-$_nut|')), findsOneWidget);
    await tester.tap(find.text('有库存'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-count-qty-$_nut|')), findsNothing);
    final qty = find.byKey(const ValueKey('stock-count-qty-$_screw|'));
    await tester.enterText(qty, '9');
    await tester.pump();
    await tester.tap(find.byKey(const Key('stock-count-save')));
    await tester.pumpAndSettle();
    expect(repo.submissions.single.lines.single['targetQty'], '9');
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换仓库按仓保留未送审输入', (tester) async {
    final repo = _SessionRepo({
      'leaf-a': [_row(_screw, qty: '10')],
      'leaf-b': [_row(_nut, qty: '7')],
    });
    await _mount(tester, repo, warehouseId: 'leaf-a');
    await tester.enterText(
      find.byKey(const ValueKey('stock-count-qty-$_screw|')),
      '11',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('stock-count-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原料仓 B · 财务审核'));
    await tester.pumpAndSettle();
    final bQty = find.byKey(const ValueKey('stock-count-qty-$_nut|'));
    expect(bQty, findsOneWidget);
    await tester.enterText(bQty, '8');
    await tester.pump();
    // 切回 A：之前填的 11 必须还在（按仓暂存）。
    await tester.tap(find.byKey(const Key('stock-count-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原料仓 A · 财务审核'));
    await tester.pumpAndSettle();
    final aField = tester.widget<TextField>(
      find.byKey(const ValueKey('stock-count-qty-$_screw|')),
    );
    expect(aField.controller?.text, '11');
    // 送审只提交当前仓 A 的行。
    await tester.tap(find.byKey(const Key('stock-count-save')));
    await tester.pumpAndSettle();
    expect(repo.submissions.single.warehouse, 'leaf-a');
    expect(repo.submissions.single.lines.single['targetQty'], '11');
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有可盘点仓库或提交权限时给出明确提示', (tester) async {
    final repo = _SessionRepo({})..canSubmit = false;
    await _mount(tester, repo);
    expect(find.text('当前没有提交盘点的权限'), findsOneWidget);
    expect(find.byKey(const Key('stock-count-save')), findsNothing);
  });

  testWidgets('「有库存」筛段为空时引导切回全部物料', (tester) async {
    final repo = _SessionRepo({
      'leaf-a': [_row(_nut)],
    });
    await _mount(tester, repo, warehouseId: 'leaf-a');
    // 默认全部物料：零库存行也在表里，直接可录实盘数。
    expect(find.byKey(const ValueKey('stock-count-qty-$_nut|')), findsOneWidget);
    expect(find.text('共 1 项'), findsOneWidget);
    await tester.tap(find.text('有库存'));
    await tester.pumpAndSettle();
    expect(find.text('共 0 项'), findsOneWidget);
    expect(
      find.text('本仓暂无有库存的物料；可切回「全部物料」或用「添加物料」录入盘盈'),
      findsOneWidget,
    );
    await tester.tap(find.text('全部物料'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-count-qty-$_nut|')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

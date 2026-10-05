import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/stock/models/instant_inventory_scope.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/pages/stock_item_detail_page.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/stock_ledger/goods_stock_ledger_panel.dart';

class _Prefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();
  @override
  void persist() {}
}

class _ScopeApi extends ApiClient {
  _ScopeApi() : super(Dio());
  final requests = <(String, Map<String, dynamic>)>[];
  bool failContext = false;
  bool failInsight = false;
  Completer<Map<String, dynamic>>? deferredContext;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requests.add((path, query ?? {}));
    if (path.contains('departments') ||
        path.contains('employees') ||
        path.contains('goods/lookup')) {
      throw StateError('stock:view must not need goods:view or HR');
    }
    if (path.contains('warehouses')) {
      return [
        {'id': 'parent', 'name': '总仓'},
        {'id': 'w1', 'parentId': 'parent', 'name': '实际成品仓'},
        {'id': 'non', 'name': '非核算展示仓'},
      ];
    }
    if (path.contains('colors')) {
      return [
        {'id': 'red', 'name': '红色'},
        {'id': 'blue', 'name': '蓝色'},
      ];
    }
    if (path.contains('units')) {
      return [
        {'id': 'u1', 'name': '个'},
      ];
    }
    if (path.contains('material-categories/tree')) {
      return [
        {'id': 'cat', 'name': '成品', 'goodsCount': 1},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final q = Map<String, dynamic>.from(query ?? {});
    requests.add((path, q));
    if (path.endsWith('/inventory-context')) {
      if (failContext) throw StateError('context unavailable');
      final deferred = deferredContext;
      deferredContext = null;
      if (deferred != null) return deferred.future;
      return contextResponse(q);
    }
    if (path.contains('/stock/insights/goods')) {
      if (failInsight) throw StateError('insight unavailable');
      return {
        'qty': 999999,
        'weightKg': 9999,
        'unitWeightKg': 0.002,
        'tier': 'GREEN',
      };
    }
    if (path == '/stock/instant-inventory') {
      return {
        'items': [
          {
            'goodsId': 'g1',
            'colorId': null,
            'name': '库存成品',
            'qty': 9,
            'owningWarehouseName': '主档归属仓',
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path == '/stock/balances') {
      return {
        'items': q['colorNull'] == true
            ? <Map<String, dynamic>>[]
            : [
                {
                  'id': 'b1',
                  'warehouseId': 'w1',
                  'goodsId': 'g1',
                  'colorId': q['colorId'] ?? 'red',
                  'qty': 9,
                  'weight': null,
                  'costMasked': true,
                  'amountLocal': 888888,
                },
              ],
        'page': 1,
        'size': 50,
        'total': 99,
        'totalPages': 2,
      };
    }
    if (path.endsWith('/ledger')) {
      return {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 50,
        'total': 0,
        'totalPages': 1,
        'summary': {'openingQty': 42, 'closingQty': 42},
      };
    }
    return {};
  }

  Map<String, dynamic> contextResponse(Map<String, dynamic> q) {
    final qty = q['colorNull'] == true
        ? 0
        : q['inventoryOnly'] == false
        ? 88
        : 42;
    return {
      'items': [
        {
          'goodsId': 'g1',
          'name': '库存成品',
          'goodsCode': 'P-001',
          'categoryName': '成品',
          'model': '型号M-1',
          'cNumber': '客户型号C-9',
          'spec': '真实规格：长度与层数来自货品主档',
          'series': '成品系列',
          'stockPlace': 'A-1-2',
          'owningWarehouseId': 'owner',
          'owningWarehouseName': '主档归属仓',
          'unitName': '个',
          'remark': '货品主档纸张备注',
          'colorId': q['colorId'],
          'colorName': q['colorId'] == 'red' ? '红色' : null,
          'qty': qty,
          'weight': qty == 0 ? 0 : null,
          'weightUnknown': qty != 0,
          'pendingQty': 5,
          'pendingStockInQty': 7,
          'moreQty': 3.4,
          'costMasked': true,
          'costAmount': 888888,
        },
      ],
      'scope': q,
      'page': 1,
      'size': 500,
      'total': 1,
      'totalPages': 1,
      'totals': [
        for (final entry in {
          'qty': qty,
          'pending_qty': 5,
          'pending_stock_in_qty': 7,
        }.entries)
          {
            'key': entry.key,
            'label': {
              'qty': '合计库存数量',
              'pending_qty': '合计待检量',
              'pending_stock_in_qty': '合计合格待入库',
            }[entry.key],
            'type': 'number',
            'groupKey': 'unit_name',
            'groups': [
              {'unit': '个', 'value': entry.value},
            ],
          },
        {
          'key': 'weight',
          'label': '合计库存重量',
          'type': 'weight',
          'groupKey': null,
          'groups': qty == 0
              ? [
                  {'unit': null, 'value': 0},
                ]
              : <Map<String, dynamic>>[],
        },
        {
          'key': 'weight_unknown_rows',
          'label': '重量未知',
          'type': 'count',
          'groupKey': null,
          'groups': [
            {'unit': null, 'value': qty == 0 ? 0 : 1},
          ],
        },
      ],
    };
  }

  Map<String, dynamic> last(String suffix) =>
      requests.lastWhere((r) => r.$1.endsWith(suffix)).$2;
}

Future<({GoRouter router, ProviderContainer container})> _open(
  WidgetTester tester,
  _ScopeApi api, {
  String? location,
  double scale = 1,
}) async {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      currentPermissionsProvider.overrideWithValue({Perm.stockView}),
      isSuperAdminProvider.overrideWithValue(false),
      warehouseWeightUnitsPrefsProvider.overrideWith(_Prefs.new),
    ],
  );
  final router = GoRouter(
    initialLocation: location ?? RouteName.stockItemDetail('g1'),
    routes: [
      GoRoute(
        path: RouteName.stockInstantInventory,
        builder: (_, s) => InstantInventoryPage(
          initialScope: s.uri.queryParameters.isEmpty
              ? null
              : InstantInventoryScope.fromQuery(s.uri.queryParameters),
        ),
      ),
      GoRoute(
        path: '${RouteName.stockItemBase}/:goodsId',
        builder: (_, s) => StockItemDetailPage(
          goodsId: s.pathParameters['goodsId']!,
          initialTab: s.uri.queryParameters['tab'],
          initialScope: InstantInventoryScope.fromQuery(
            s.uri.queryParameters,
            inventoryDefault: false,
          ),
          returnTo: s.uri.queryParameters['returnTo'],
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const ValueKey('scope-screenshot'),
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(fontFamily: 'NotoSansSC'),
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
  });
  return (router: router, container: container);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'existing inventory scope retains default overview and explicit full goods range',
    () {
      expect(InstantInventoryScope.fromQuery({}).inventoryOnly, isTrue);
      expect(
        InstantInventoryScope.fromQuery({}, inventoryDefault: false),
        const InstantInventoryScope.full(),
      );
      final scope = InstantInventoryScope.fromQuery({
        'warehouseId': 'parent',
        'colorNull': 'true',
        'includeDefective': 'false',
      });
      final roundTrip = InstantInventoryScope.fromQuery(
        Uri.parse(
          RouteName.stockItemDetail('g1', scope: scope),
        ).queryParameters,
        inventoryDefault: false,
      );
      expect(roundTrip, scope);
      expect(
        () => InstantInventoryScope.fromQuery({
          'colorId': 'red',
          'colorNull': 'true',
        }),
        throwsFormatException,
      );
      expect(
        BalanceRow.fromJson({
          'id': 'b',
          'costMasked': true,
          'amountLocal': 100,
        }).amountLocal,
        isNull,
      );
      expect(
        InstantInventoryRow.fromJson({
          'costMasked': true,
          'costAmount': 100,
        }).costAmount,
        isNull,
      );
    },
  );
  testWidgets(
    'detail preserves warehouse color and flags through refresh segment and full warehouse switch',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ScopeApi();
      const scope = InstantInventoryScope(
        warehouseId: 'parent',
        colorId: 'red',
      );
      final env = await _open(
        tester,
        api,
        location: RouteName.stockItemDetail('g1', scope: scope),
      );
      for (final suffix in ['/inventory-context', '/stock/balances']) {
        expect(api.last(suffix), containsPair('warehouseId', 'parent'));
        expect(api.last(suffix), containsPair('colorId', 'red'));
        expect(api.last(suffix), containsPair('inventoryOnly', true));
        expect(api.last(suffix), containsPair('includeDefective', false));
      }
      expect(find.textContaining('客户型号C-9'), findsOneWidget);
      expect(find.textContaining('货品主档纸张备注'), findsOneWidget);
      expect(find.textContaining('主档归属仓库：主档归属仓'), findsOneWidget);
      expect(find.textContaining('全局生产计划'), findsOneWidget);
      expect(find.textContaining('999999'), findsNothing);
      expect(find.textContaining('888888'), findsNothing);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(api.last('/inventory-context')['warehouseId'], 'parent');
      await tester.tap(find.text('出入库流水').first);
      await tester.pumpAndSettle();
      expect(api.last('/ledger')['colorId'], 'red');
      expect(api.last('/ledger')['includeLineSide'], false);
      expect(env.router.state.uri.queryParameters['tab'], 'ledger');
      await tester.tap(find.text('库存余额').first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('stock-inventory-all-warehouses')),
      );
      await tester.pumpAndSettle();
      expect(api.last('/inventory-context')['inventoryOnly'], false);
      expect(api.last('/stock/balances')['inventoryOnly'], false);
      expect(api.last('/stock/balances').containsKey('warehouseId'), isFalse);
      await tester.ensureVisible(
        find.byKey(
          const ValueKey('stock-inventory-scope-label'),
          skipOffstage: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('全部仓库（含非核算仓）'), findsWidgets);
      expect(env.router.state.uri.queryParameters['inventoryOnly'], 'false');
      expect(
        api.requests.where(
          (r) => r.$1.contains('departments') || r.$1.contains('goods/lookup'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'no-color zero stock retains master data and exact null scope; changing color replaces range',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ScopeApi();
      final env = await _open(
        tester,
        api,
        location: RouteName.stockItemDetail(
          'g1',
          scope: const InstantInventoryScope(colorNull: true),
        ),
      );
      expect(api.last('/inventory-context')['colorNull'], true);
      expect(api.last('/stock/balances')['colorNull'], true);
      expect(find.textContaining('型号M-1'), findsOneWidget);
      expect(find.text('该货品暂无库存余额'), findsOneWidget);
      final panel = tester.state<GoodsStockLedgerPanelState>(
        find.byType(GoodsStockLedgerPanel),
      );
      panel.selectScope(panel.scope.withDimensions(colorId: 'blue'));
      await tester.pumpAndSettle();
      expect(api.last('/inventory-context')['colorId'], 'blue');
      expect(api.last('/inventory-context').containsKey('colorNull'), isFalse);
      expect(env.router.state.uri.queryParameters['colorId'], 'blue');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed context and global KPI remain visible with retry; no stale scope totals survive',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ScopeApi()
        ..failContext = true
        ..failInsight = true;
      await _open(tester, api);
      expect(
        find.byKey(const ValueKey('stock-inventory-context-error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('goods-stock-kpi-error')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('stock-scoped-totals')), findsNothing);
      api.failContext = false;
      api.failInsight = false;
      await tester.tap(find.text('重新读取库存概况'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试分析参考'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stock-scoped-totals')), findsOneWidget);
      expect(find.textContaining('999999'), findsNothing);
      final deferred = Completer<Map<String, dynamic>>();
      api.deferredContext = deferred;
      final panel = tester.state<GoodsStockLedgerPanelState>(
        find.byType(GoodsStockLedgerPanel),
      );
      panel.reload();
      await tester.pump();
      panel.selectScope(panel.scope.withDimensions(colorNull: true));
      await tester.pumpAndSettle();
      deferred.complete(api.contextResponse({'inventoryOnly': false}));
      await tester.pumpAndSettle();
      expect(panel.scope.colorNull, true);
      expect(api.last('/inventory-context')['colorNull'], true);
      expect(find.text('该货品暂无库存余额'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'real instant inventory row navigation retains list warehouse flags and no-color geometry',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ScopeApi();
      final env = await _open(
        tester,
        api,
        location: Uri(
          path: RouteName.stockInstantInventory,
          queryParameters: const InstantInventoryScope(
            warehouseId: 'parent',
            includeLineSide: true,
          ).toQuery(),
        ).toString(),
      );
      await tester.tap(find.text('库存成品').first);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('库存成品').first);
      await tester.pumpAndSettle();
      expect(api.last('/inventory-context')['warehouseId'], 'parent');
      expect(api.last('/inventory-context')['colorNull'], true);
      expect(api.last('/inventory-context')['includeDefective'], false);
      expect(api.last('/inventory-context')['includeLineSide'], true);
      env.router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(InstantInventoryPage), findsOneWidget);
      await tester.tap(find.text('含不良品仓'));
      await tester.pumpAndSettle();
      expect(api.last('/stock/instant-inventory')['includeDefective'], true);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    testWidgets(
      'stock:view detail representative screenshot ${size.width} with large text and masked costs',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final font = FontLoader('NotoSansSC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
        await tester.runAsync(font.load);
        await _open(
          tester,
          _ScopeApi(),
          scale: 1.5,
          location: RouteName.stockItemDetail(
            'g1',
            scope: const InstantInventoryScope(colorId: 'red'),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.textContaining('888888'), findsNothing);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('scope-screenshot')),
        );
        await tester.runAsync(() async {
          final pixels = await boundary.toImage();
          final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/ui-audit/inventory-b04/stock-detail-${size.width.toInt()}-scale150.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          pixels.dispose();
        });
      },
    );
  }
}

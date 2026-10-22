import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/production/widgets/where_used_material_picker.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/stock/counts/widgets/stock_count_candidate_picker.dart';
import 'package:uten_imp/features/stock/models/instant_inventory_scope.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_CONTEXT_SEARCH');
final _captureKey = GlobalKey();
const _warehouse = StockCountWarehouse(
  id: 'warehouse-snapshot',
  name: '注塑内料仓',
  kind: 'WORKSHOP',
  reviewRoute: 'WAREHOUSE',
);
Finder get _related => find.byKey(const ValueKey('goods-search-related'));

void main() {
  test(
    'inventory related scope roundtrips and remains distinct from primary scope',
    () {
      const scope = InstantInventoryScope(
        keyword: '螺丝',
        includeRelated: true,
        categoryId: 'raw',
        warehouseId: 'warehouse-snapshot',
        includeDefective: true,
        includeLineSide: true,
        colorId: 'red',
        series: 'M3',
      );
      expect(InstantInventoryScope.fromQuery(scope.toQuery()), scope);
      expect(scope.toQuery()['includeRelated'], 'true');
      expect(
        scope,
        const InstantInventoryScope(
          keyword: '螺丝',
          includeRelated: true,
          categoryId: 'raw',
          warehouseId: 'warehouse-snapshot',
          includeDefective: true,
          includeLineSide: true,
          colorId: 'red',
          series: 'M3',
        ),
      );
      expect(
        scope,
        isNot(
          const InstantInventoryScope(
            keyword: '螺丝',
            categoryId: 'raw',
            warehouseId: 'warehouse-snapshot',
            includeDefective: true,
            includeLineSide: true,
            colorId: 'red',
            series: 'M3',
          ),
        ),
      );
      expect(
        const InstantInventoryScope(includeRelated: true).toQuery(),
        isNot(contains('includeRelated')),
      );
      expect(
        InstantInventoryScope.fromQuery({
          'includeRelated': 'true',
        }).includeRelated,
        isFalse,
      );
    },
  );

  testWidgets('盘点相关搜索只用单仓候选API、同分类定位，颜色版本快照保持', (tester) async {
    final api = _ContextApi();
    final selected = <CountStockRow>[];
    await _pump(tester, api, 'count', selectedCount: selected);
    await _query(tester, '螺丝');
    expect(tester.widget<CheckboxListTile>(_related).value, isFalse);
    expect(find.byKey(const ValueKey('goods-picker-item-r|red')), findsNothing);
    await tester.tap(_related);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('goods-picker-item-r|red')),
      findsOneWidget,
    );
    await tester.tap(_category('成品'));
    await tester.pumpAndSettle();
    final rows = api.last('/stock/count-requests/candidates');
    final location = api.last('/stock/count-requests/candidate-category-ids');
    for (final q in [rows, location]) {
      expect(q['warehouseId'], _warehouse.id);
      expect(q['categoryId'], 'finished');
      expect(q['includeRelated'], isTrue);
      expect(q['keyword'], '螺丝');
    }
    expect(rows['sheet'], isFalse);
    expect(rows['stockedOnly'], isFalse);
    await tester.tap(find.byKey(const ValueKey('goods-picker-item-r|red')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(selected.single.goodsId, 'r');
    expect(selected.single.colorId, 'red');
    expect(selected.single.qty, '12.3400');
    expect(selected.single.goodsVersion, 17);
    expect(selected.single.canEdit, isTrue);
    expect(selected.single.searchMatchKind, 'RELATED');
    expect(api.paths.where((p) => p.startsWith('/master/goods')), isEmpty);
  });

  testWidgets('物料反查仅报表权限展开相关，历史禁用占位删除标记与UUID保留', (tester) async {
    final api = _ContextApi();
    final selected = <GoodsListItem>[];
    await _pump(tester, api, 'where-used', selectedGoods: selected);
    await _query(tester, '螺丝');
    await tester.tap(_related);
    await tester.pumpAndSettle();
    expect(find.text('状态：禁用'), findsOneWidget);
    expect(find.text('已删除'), findsOneWidget);
    expect(find.text('自动占位'), findsOneWidget);
    await tester.tap(_category('成品'));
    await tester.pumpAndSettle();
    for (final path in [
      '/production/reports/where-used/materials',
      '/production/reports/where-used/material-category-matches',
    ]) {
      final q = api.last(path);
      expect(q['categoryId'], 'finished');
      expect(q['includeRelated'], isTrue);
      expect(q['keyword'], '螺丝');
    }
    await tester.tap(find.byKey(const ValueKey('goods-picker-item-r')));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected.single.id, 'r');
    expect(selected.single.status, '禁用');
    expect(selected.single.autoCreated, isTrue);
    expect(selected.single.isRelatedSearchMatch, isTrue);
    expect(api.paths.where((p) => p.startsWith('/master/goods')), isEmpty);
  });

  testWidgets('即时库存相关开关同步列表facet导出，显式分类可清除且恢复原浏览类', (tester) async {
    final api = _ContextApi();
    await _pump(tester, api, 'instant');
    await _chooseInventoryCategory(tester, '原材料');
    await _query(tester, '螺丝');
    expect(_inventory(tester).items.map((r) => r.goodsId), ['a']);
    final old = await tester
        .widget<UtenExportButton>(find.byType(UtenExportButton))
        .prepareExport!();
    await tester.tap(_related);
    await tester.pumpAndSettle();
    expect(old!.stillCurrent!(), isFalse);
    expect(_inventory(tester).items.map((r) => r.goodsId), ['a', 'r']);
    expect(_inventory(tester).facets['series']!.single.value, 'expanded');
    expect(
      tester
          .widget<UtenExportButton>(find.byType(UtenExportButton))
          .queryParams['includeRelated'],
      isTrue,
    );
    _inventory(tester).onFilterChanged('series', 'M3');
    await tester.pumpAndSettle();
    expect(api.last('/stock/instant-inventory')['series'], 'M3');
    await _chooseInventoryCategory(tester, '成品');
    expect(api.last('/stock/instant-inventory')['categoryId'], 'finished');
    expect(_inventory(tester).items.map((r) => r.goodsId), ['r']);
    await tester.ensureVisible(
      find.byKey(const Key('instant-inventory-category')),
    );
    await tester.tap(find.byKey(const Key('instant-inventory-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category-picker-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();
    expect(_inventory(tester).items.map((r) => r.goodsId), ['a', 'r']);
    await _query(tester, '');
    expect(_related, findsNothing);
    expect(api.last('/stock/instant-inventory')['categoryId'], 'raw');
    expect(
      api.last('/stock/instant-inventory'),
      isNot(contains('includeRelated')),
    );
  });

  for (final kind in ['count', 'where-used', 'instant']) {
    testWidgets('$kind 相关模式ABA不接受旧同模式返回', (tester) async {
      final api = _ContextApi();
      await _pump(tester, api, kind);
      await _query(tester, '螺丝');
      api.holdRelated = true;
      await tester.tap(_related);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(_related);
      await tester.pumpAndSettle();
      await tester.tap(_related);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.held.length, greaterThanOrEqualTo(2));
      api.complete(api.held.length - 1, 'new');
      await tester.pumpAndSettle();
      for (var i = 0; i < api.held.length - 1; i++) {
        api.complete(i, 'old');
      }
      await tester.pumpAndSettle();
      if (kind == 'instant') {
        expect(_inventory(tester).items.single.goodsId, 'new');
      } else {
        expect(
          find.byKey(
            ValueKey(
              'goods-picker-item-${kind == 'count' ? 'new|red' : 'new'}',
            ),
          ),
          findsOneWidget,
        );
        expect(find.text('旧响应'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final history in [true, false]) {
    testWidgets('compact2x盘点${history ? '历史' : '模式'}从AppBar可达且保留仓库导航', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: RouteName.stockInstantInventory,
        routes: [
          GoRoute(
            path: RouteName.stockInstantInventory,
            builder: (_, _) => const InstantInventoryPage(
              initialScope: InstantInventoryScope(
                warehouseId: 'warehouse-snapshot',
              ),
            ),
          ),
          GoRoute(
            path: RouteName.stockCountRequests,
            builder: (_, _) => const Scaffold(body: Text('盘点历史目标')),
          ),
          GoRoute(
            path: RouteName.stockCountSession,
            builder: (_, _) => const Scaffold(body: Text('盘点模式目标')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(
        tester,
        _ContextApi(),
        'instant',
        router: router,
        size: const Size(390, 900),
        scale: 2,
      );
      await _query(tester, '螺丝');
      await tester.tap(_related);
      await tester.pumpAndSettle();
      expect(find.byType(UtenFloatingActionGroup), findsNothing);
      expect(_inventory(tester).bottomContentPadding, 0);
      await tester.tap(find.byKey(const Key('uten-app-bar-more-actions')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stock-count-history')), findsOneWidget);
      expect(find.byKey(const Key('stock-count-mode')), findsOneWidget);
      await tester.tap(
        find.byKey(Key(history ? 'stock-count-history' : 'stock-count-mode')),
      );
      await tester.pumpAndSettle();
      expect(
        router.state.uri.path,
        history ? RouteName.stockCountRequests : RouteName.stockCountSession,
      );
      if (!history) {
        expect(
          router.state.uri.queryParameters['warehouseId'],
          'warehouse-snapshot',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('capture contextual related desktop and compact layouts', (
    tester,
  ) async {
    await loadAuditScreenshotFonts(tester);
    for (final kind in ['instant', 'count', 'where-used']) {
      for (final compact in [false, true]) {
        final api = _ContextApi();
        await _pump(
          tester,
          api,
          kind,
          capture: true,
          size: compact ? const Size(390, 900) : const Size(1600, 1000),
          scale: compact ? 2 : 1,
        );
        await _query(tester, '螺丝');
        await tester.tap(_related);
        await tester.pumpAndSettle();
        if (kind == 'count') {
          final weight = find.byKey(const ValueKey('count-weight-r|red'));
          await tester.ensureVisible(weight);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('count-related-r|red')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.widget<Text>(weight).data, '重量 未称');
          expect(
            tester.getBottomLeft(weight).dy,
            lessThanOrEqualTo(
              tester.getTopLeft(find.byType(UtenPickerConfirmBar)).dy,
            ),
          );
        }
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'context-$kind-related-${compact ? 'compact' : 'desktop'}',
        );
        if (kind == 'instant' && compact) {
          await tester.tap(find.byKey(const Key('uten-app-bar-more-actions')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('stock-count-history')), findsOneWidget);
          expect(find.byKey(const Key('stock-count-mode')), findsOneWidget);
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'context-instant-related-compact-actions',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    }
  }, skip: !_capture);
}

MasterDataTableView<InstantInventoryRow> _inventory(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<InstantInventoryRow>));
Finder _category(String text) => find.descendant(
  of: find.byType(UtenCategoryTreeView<ProductCategoryNode>),
  matching: find.text(text),
);
Future<void> _chooseInventoryCategory(WidgetTester tester, String text) async {
  final field = find.byKey(const Key('instant-inventory-category'));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(_category(text));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定').last);
  await tester.pumpAndSettle();
}

Future<void> _query(WidgetTester tester, String text) async {
  await tester.enterText(
    find.descendant(
      of: find.byType(UtenSearchBar).first,
      matching: find.byType(TextField),
    ),
    text,
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _ContextApi api,
  String kind, {
  List<CountStockRow>? selectedCount,
  List<GoodsListItem>? selectedGoods,
  Size size = const Size(1600, 1000),
  double scale = 1,
  bool capture = false,
  GoRouter? router,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(
          kind == 'where-used'
              ? {Perm.productionWhereUsedView}
              : {
                  Perm.stockView,
                  Perm.stockReportExport,
                  stockCountSubmitPermission,
                },
        ),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'scoped-operator'),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: RepaintBoundary(
        key: _captureKey,
        child: router != null
            ? MaterialApp.router(
                routerConfig: router,
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh'),
                theme: capture
                    ? auditScreenshotTheme(buildLightTheme())
                    : buildLightTheme(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
              )
            : MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh'),
                theme: capture
                    ? auditScreenshotTheme(buildLightTheme())
                    : buildLightTheme(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: kind == 'instant'
                    ? const InstantInventoryPage()
                    : Consumer(
                        builder: (context, ref, _) => Scaffold(
                          body: TextButton(
                            child: const Text('打开'),
                            onPressed: () async {
                              if (kind == 'count') {
                                final picked =
                                    await showStockCountCandidatePicker(
                                      context,
                                      ref,
                                      warehouse: _warehouse,
                                    );
                                selectedCount?.addAll(picked);
                              } else {
                                final picked =
                                    await showWhereUsedMaterialPicker(
                                      context,
                                      ref,
                                    );
                                if (picked != null) selectedGoods?.add(picked);
                              }
                            },
                          ),
                        ),
                      ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (kind != 'instant') {
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }
}

class _ContextApi extends ApiClient {
  _ContextApi() : super(Dio());
  final requests = <(String, Map<String, dynamic>)>[];
  final held =
      <(String, Map<String, dynamic>, Completer<Map<String, dynamic>>)>[];
  bool holdRelated = false;
  List<String> get paths => requests.map((r) => r.$1).toList();
  Map<String, dynamic> last(String path) =>
      requests.lastWhere((r) => r.$1 == path).$2;
  static const _nodes = [
    {
      'id': 'raw',
      'name': '原材料',
      'code': 'RAW',
      'level': 0,
      'goodsCount': 1,
      'children': <Object>[],
    },
    {
      'id': 'finished',
      'name': '成品',
      'code': 'FIN',
      'level': 0,
      'goodsCount': 1,
      'children': <Object>[],
    },
  ];
  List<Map<String, dynamic>> _rows(
    String path,
    Map<String, dynamic> q, {
    String? id,
  }) {
    final related = q['includeRelated'] == true;
    final ids = id == null ? ['a', if (related) 'r'] : [id];
    return [
      for (final key in ids)
        if (q['categoryId'] == null ||
            q['categoryId'] == (key == 'r' ? 'finished' : 'raw'))
          {
            'id': key,
            'goodsId': key,
            'code': key,
            'goodsCode': key,
            'name': key == 'a'
                ? '螺丝 M3'
                : key == 'r'
                ? '螺丝接线式插座'
                : key == 'old'
                ? '旧响应'
                : '最新结果',
            'goodsName': key == 'a'
                ? '螺丝 M3'
                : key == 'r'
                ? '螺丝接线式插座'
                : key == 'old'
                ? '旧响应'
                : '最新结果',
            'categoryId': key == 'r' ? 'finished' : 'raw',
            'categoryName': key == 'r' ? '成品' : '原材料',
            'unitId': 'unit',
            'unitName': '个',
            'colorId': 'red',
            'colorName': '红',
            'qty': '12.3400',
            'goodsVersion': 17,
            'allowedActions': ['EDIT'],
            'status': key == 'r' ? '禁用' : '使用',
            'autoCreated': key == 'r',
            'deleted': key == 'r',
            'currentBom': false,
            'productionHistory': key == 'r',
            'subcontractHistory': false,
            'bomIssue': false,
            'searchRank': key == 'r' ? 100 : 20,
            'searchMatchKind': key == 'r' ? 'RELATED' : 'PRIMARY',
          },
    ];
  }

  Map<String, dynamic> _page(
    String path,
    Map<String, dynamic> q, {
    String? id,
  }) {
    var rows = _rows(path, q, id: id);
    if (path.startsWith('/stock/instant-inventory')) {
      rows = [
        for (final row in rows) {...row, 'qty': 12.34},
      ];
    }
    return {
      'items': rows,
      'page': q['page'] ?? 1,
      'size': q['size'] ?? 50,
      'total': rows.length,
      'totalPages': rows.isEmpty ? 0 : 1,
      'facets': {
        'series': [
          {
            'value': q['includeRelated'] == true ? 'expanded' : 'primary',
            'count': rows.length,
          },
        ],
      },
    };
  }

  void complete(int index, String id) {
    final (path, q, completer) = held[index];
    completer.complete(_page(path, q, id: id));
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final q = Map<String, dynamic>.from(query ?? {});
    requests.add((path, q));
    if (path.endsWith('/material-categories')) return {'items': _nodes};
    if (path.endsWith('/material-category-matches')) return {'items': _ids(q)};
    if (path == '/stock/instant-inventory' ||
        path.endsWith('/candidates') ||
        path.endsWith('/materials')) {
      if (holdRelated && q['includeRelated'] == true) {
        final c = Completer<Map<String, dynamic>>();
        held.add((path, q, c));
        return c.future;
      }
      final page = _page(path, q);
      return page;
    }
    return {};
  }

  List<String> _ids(Map<String, dynamic> q) => [
    for (final row in _rows('', q)) row['categoryId'] as String,
  ];
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requests.add((path, Map<String, dynamic>.from(query ?? {})));
    if (path.contains('material-categories/tree') ||
        path.endsWith('/candidate-categories')) {
      return _nodes.map((r) => Map<String, dynamic>.from(r)).toList();
    }
    return [];
  }

  @override
  Future<List<String>> getStringList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final q = Map<String, dynamic>.from(query ?? {});
    requests.add((path, q));
    return _ids(q);
  }
}

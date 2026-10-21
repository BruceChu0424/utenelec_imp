import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/warehouse_node.dart';
import 'package:uten_imp/features/basic_data/pages/warehouse_page.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/master_detail_card.dart';

import '../../../support/audit_screenshot_support.dart';

const _warehouses = [
  WarehouseListItem(id: 'main', code: '001', name: '总仓'),
  WarehouseListItem(id: 'hardware', code: '002', name: '五金仓', parentId: 'main'),
  WarehouseListItem(id: 'finished', code: '003', name: '成品仓', parentId: 'main'),
];

WarehouseDetail _detail(String id) {
  final warehouse = _warehouses.singleWhere((warehouse) => warehouse.id == id);
  return WarehouseDetail(
    id: id,
    code: warehouse.code,
    name: warehouse.name,
    parentId: warehouse.parentId,
    status: '使用',
    location: '$id-位置',
    remark: '$id-备注',
  );
}

class _Warehouses implements WarehouseRepository {
  final pendingDetails = <String, Completer<WarehouseDetail>>{};

  @override
  Future<List<WarehouseListItem>> dict() async => _warehouses;

  @override
  Future<WarehouseDetail> detail(String id) async =>
      pendingDetails[id]?.future ?? _detail(id);

  @override
  Future<WarehouseFacets> facets() async =>
      const WarehouseFacets(fields: {}, nullCounts: {});

  @override
  Future<PagedResult<WarehouseListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async => PagedResult(
    items: _warehouses,
    page: 1,
    size: size,
    total: 3,
    totalPages: 1,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InventoryApi extends ApiClient {
  _InventoryApi() : super(Dio());
  final inventoryQueries = <Map<String, dynamic>>[];
  final pendingInventories = <String, Completer<Map<String, dynamic>>>{};

  Map<String, dynamic> inventory(String warehouseId) => {
    'items': [
      {
        'goodsId': 'goods-$warehouseId',
        'goodsCode': 'LAY-$warehouseId',
        'name': '$warehouseId-库存货品',
        'qty': 17,
        'unitName': '个',
      },
    ],
    'page': 1,
    'size': 20,
    'total': 1,
    'totalPages': 1,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.stockInstantInventory) {
      final parameters = Map<String, dynamic>.from(query!);
      inventoryQueries.add(parameters);
      final warehouseId = parameters['warehouseId'] as String;
      return pendingInventories[warehouseId]?.future ?? inventory(warehouseId);
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehousesDict) {
      return [
        for (final warehouse in _warehouses)
          {
            'id': warehouse.id,
            'name': warehouse.name,
            'code': warehouse.code,
            'parentId': warehouse.parentId,
          },
      ];
    }
    return const [];
  }
}

Future<List<Uri>> _pump(
  WidgetTester tester, {
  required _Warehouses warehouses,
  required _InventoryApi api,
  Size size = const Size(1440, 900),
  Set<String> permissions = const {Perm.warehouseView, Perm.stockView},
  double textScale = 1,
  ThemeData? theme,
  GlobalKey? captureKey,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final opened = <Uri>[];
  final router = GoRouter(
    initialLocation: '/warehouse-records',
    routes: [
      GoRoute(
        path: '/warehouse-records',
        builder: (_, _) => const WarehousePage(),
      ),
      GoRoute(
        path: '/stock/item/:goodsId',
        builder: (_, state) {
          opened.add(state.uri);
          return const Scaffold(body: Text('仓库货品流水'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        warehouseRepositoryProvider.overrideWithValue(warehouses),
        authenticatedScopeProvider.overrideWithValue(null),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: theme ?? buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          final scaled = MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          );
          return captureKey == null
              ? scaled
              : RepaintBoundary(key: captureKey, child: scaled);
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

Future<void> _select(
  WidgetTester tester,
  String name, {
  bool settle = true,
}) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const Key('warehouse-directory-tree')),
      matching: find.text(name),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'wide warehouse records show the directory beside a summary and live inventory',
    (tester) async {
      final api = _InventoryApi();
      await _pump(tester, warehouses: _Warehouses(), api: api);
      expect(find.byType(UtenSplitView), findsOneWidget);
      final tree = tester.widget<UtenCategoryTreeView>(
        find.byKey(const Key('warehouse-directory-tree')),
      );
      expect(tree.flatLevelColors, isTrue);
      expect(tree.expandOnRowTap, isTrue);
      expect(tree.header, isNotNull);
      expect(find.text('选择仓库查看资料与即时库存'), findsOneWidget);
      expect(api.inventoryQueries, isEmpty);
      await _select(tester, '五金仓');
      final directory = tester.getRect(
        find.byKey(const Key('warehouse-directory-tree')),
      );
      final summary = tester.getRect(
        find.byKey(const Key('warehouse-master-summary')),
      );
      final inventory = tester.getRect(
        find.byKey(const Key('warehouse-inventory-panel')),
      );
      expect(summary.left, greaterThanOrEqualTo(directory.right));
      expect(summary.bottom, lessThanOrEqualTo(inventory.top));
      expect(find.textContaining('hardware-位置'), findsOneWidget);
      final card = tester.widget<MasterDetailCard>(
        find.byKey(const Key('warehouse-master-summary')),
      );
      expect(card.title, '五金仓 (hardware-备注)');
      expect(card.stats, isEmpty);
      expect(card.onEdit, isNull);
      expect(card.onDelete, isNull);
      expect(card.subtitle, contains('hardware-位置'));
      expect(find.text('hardware-库存货品'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(api.inventoryQueries.single['warehouseId'], 'hardware');
      expect(api.inventoryQueries.single['warehouseRelatedOnly'], isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'double-clicking stock opens the selected warehouse ledger with the same color scope',
    (tester) async {
      final api = _InventoryApi();
      final opened = await _pump(tester, warehouses: _Warehouses(), api: api);
      await _select(tester, '五金仓');
      final goods = find.text('hardware-库存货品');
      await tester.tap(goods);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(goods);
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(opened.single.path, '/stock/item/goods-hardware');
      expect(opened.single.queryParameters['tab'], 'ledger');
      expect(opened.single.queryParameters['warehouseId'], 'hardware');
      expect(opened.single.queryParameters['colorNull'], 'true');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late warehouse detail cannot replace a newer directory selection',
    (tester) async {
      final warehouses = _Warehouses();
      final oldDetail = Completer<WarehouseDetail>();
      warehouses.pendingDetails['hardware'] = oldDetail;
      final api = _InventoryApi();
      await _pump(tester, warehouses: warehouses, api: api);
      await _select(tester, '五金仓', settle: false);
      await _select(tester, '成品仓');
      expect(find.textContaining('finished-位置'), findsOneWidget);
      oldDetail.complete(_detail('hardware'));
      await tester.pumpAndSettle();
      expect(find.textContaining('finished-位置'), findsOneWidget);
      expect(find.textContaining('hardware-位置'), findsNothing);
      expect(
        api.inventoryQueries.every(
          (query) => query['warehouseId'] == 'finished',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('warehouse read permission does not grant stock access', (
    tester,
  ) async {
    final api = _InventoryApi();
    await _pump(
      tester,
      warehouses: _Warehouses(),
      api: api,
      permissions: {Perm.warehouseView},
    );
    await _select(tester, '五金仓');
    expect(find.textContaining('hardware-位置'), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-inventory-no-access')),
      findsOneWidget,
    );
    expect(api.inventoryQueries, isEmpty);
    expect(find.text('编辑'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final editSize in [const Size(1440, 900), const Size(390, 844)]) {
    testWidgets(
      'warehouse inline mode shares lazy editors at $editSize while inventory remains read only',
      (tester) async {
        const capture = bool.fromEnvironment('UTEN_AUDIT_SCREENSHOTS');
        if (capture) await loadAuditScreenshotFonts(tester);
        final captureKey = GlobalKey();
        final oldShadows = debugDisableShadows;
        if (capture) debugDisableShadows = false;
        addTearDown(() => debugDisableShadows = oldShadows);
        final api = _InventoryApi();
        await _pump(
          tester,
          warehouses: _Warehouses(),
          api: api,
          size: editSize,
          textScale: editSize.width < 840 ? 1.5 : 1,
          permissions: {Perm.warehouseView, Perm.warehouseEdit, Perm.stockView},
          captureKey: captureKey,
          theme: capture ? auditScreenshotTheme(buildLightTheme()) : null,
        );
        if (editSize.width < 840) {
          await tester.tap(
            find.ancestor(
              of: find.byIcon(Icons.account_tree_rounded),
              matching: find.byType(OutlinedButton),
            ),
          );
          await tester.pumpAndSettle();
        }
        await _select(tester, '五金仓');
        await tester.tap(find.text('编辑模式'));
        await tester.pumpAndSettle();
        expect(
          find.byType(MasterInlineRecordEditor<WarehouseDetail>),
          findsOneWidget,
        );
        expect(find.byType(Dialog), findsNothing);
        final table = find.byKey(const Key('warehouse-inventory-table'));
        if (table.evaluate().isEmpty) {
          final outerScroll = find
              .ancestor(
                of: find.byType(MasterInlineRecordEditor<WarehouseDetail>),
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.scrollUntilVisible(table, 300, scrollable: outerScroll);
          await tester.pumpAndSettle();
        }
        final inventory = tester
            .widget<MasterDataTableView<InstantInventoryRow>>(table);
        expect(inventory.columnEditingEnabled, isFalse);
        expect(inventory.canOpenRow!(inventory.items.single), isFalse);
        expect(
          inventory.columns.every((column) => !column.supportsKeywordSearch),
          isTrue,
        );
        expect(
          find.byKey(const ValueKey('inline-activate-hardware-name')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('inline-activate-hardware-code')),
          findsNothing,
        );
        final activation = find.byKey(
          const ValueKey('inline-activate-hardware-name'),
        );
        await Scrollable.ensureVisible(
          tester.element(activation),
          alignment: 0.2,
        );
        await tester.pumpAndSettle();
        await tester.tap(activation);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('inline-hardware-name')),
            matching: find.byType(TextField),
          ),
          findsOneWidget,
        );
        if (capture) {
          await saveAuditScreenshot(
            tester,
            captureKey,
            'warehouse-records-${editSize.width < 840 ? 'compact' : 'desktop'}-edit-mode',
          );
        }
        await tester.tap(find.text('取消编辑'));
        await tester.pumpAndSettle();
        expect(
          find.byType(MasterInlineRecordEditor<WarehouseDetail>),
          findsNothing,
        );
        expect(find.text('hardware-库存货品'), findsOneWidget);
        final readableInventory = tester
            .widget<MasterDataTableView<InstantInventoryRow>>(
              find.byKey(const Key('warehouse-inventory-table')),
            );
        expect(
          readableInventory.canOpenRow!(readableInventory.items.single),
          isTrue,
        );
        expect(
          api.inventoryQueries.every(
            (query) => query['warehouseId'] == 'hardware',
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        debugDisableShadows = oldShadows;
      },
    );
  }

  for (final size in [const Size(390, 844), const Size(760, 900)]) {
    testWidgets(
      'warehouse directory and inventory remain reachable at $size with large text',
      (tester) async {
        final api = _InventoryApi();
        await _pump(
          tester,
          warehouses: _Warehouses(),
          api: api,
          size: size,
          textScale: 1.5,
        );
        expect(
          find.byKey(const Key('warehouse-directory-search')).hitTestable(),
          findsOneWidget,
        );
        final openDirectory = find.ancestor(
          of: find.byIcon(Icons.account_tree_rounded),
          matching: find.byType(OutlinedButton),
        );
        await tester.tap(openDirectory);
        await tester.pumpAndSettle();
        await _select(tester, '五金仓');
        expect(
          find.byKey(const Key('warehouse-master-summary')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('warehouse-inventory-panel')),
          findsOneWidget,
        );
        expect(api.inventoryQueries.last['warehouseId'], 'hardware');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (
      name: 'desktop-light',
      size: const Size(1440, 900),
      scale: 1.0,
      dark: false,
    ),
    (name: 'desktop-dark', size: const Size(1440, 900), scale: 1.0, dark: true),
    (
      name: 'compact-large-text',
      size: const Size(390, 844),
      scale: 1.5,
      dark: false,
    ),
  ]) {
    testWidgets('warehouse audit layout ${scenario.name}', (tester) async {
      const capture = bool.fromEnvironment('UTEN_AUDIT_SCREENSHOTS');
      if (capture) await loadAuditScreenshotFonts(tester);
      final captureKey = GlobalKey();
      final oldShadows = debugDisableShadows;
      if (capture) debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = oldShadows);
      await _pump(
        tester,
        warehouses: _Warehouses(),
        api: _InventoryApi(),
        size: scenario.size,
        textScale: scenario.scale,
        permissions: {
          Perm.warehouseView,
          Perm.warehouseCreate,
          Perm.warehouseEdit,
          Perm.warehouseDelete,
          Perm.stockView,
        },
        captureKey: captureKey,
        theme: auditScreenshotTheme(
          scenario.dark ? buildDarkTheme() : buildLightTheme(),
        ),
      );
      if (scenario.size.width < 840) {
        final openDirectory = find.ancestor(
          of: find.byIcon(Icons.account_tree_rounded),
          matching: find.byType(OutlinedButton),
        );
        await tester.tap(openDirectory);
        await tester.pumpAndSettle();
        if (capture) {
          await saveAuditScreenshot(
            tester,
            captureKey,
            'warehouse-records-${scenario.name}-directory',
          );
        }
      }
      await _select(tester, '五金仓');
      expect(find.text('hardware-库存货品'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (capture) {
        await saveAuditScreenshot(
          tester,
          captureKey,
          'warehouse-records-${scenario.name}',
        );
      }
      debugDisableShadows = oldShadows;
    });
  }
}

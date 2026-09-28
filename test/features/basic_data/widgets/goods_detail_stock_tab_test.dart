// 货品详情「库存与出入库」页签 (ADR-135 §6.3):
//  - 页签按名字寻址 (?tab=stock), 旧深链数字 0/1/2 仍认;
//  - 有 stock:view 时追加在「图片和文件」之后, 内容就是单货品库存面板;
//  - 基本信息「出入库流水」按钮同页切到本页签的流水分段 (不再跳旧流水页);
//  - 库存段的重量合计用服务端 stockWeightKg/Unknown/Estimated, 不再前端逐行相加。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/stock_ledger/goods_stock_ledger_panel.dart';

class _MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();

  @override
  void persist() {}
}

class _StockApi extends ApiClient {
  _StockApi() : super(Dio());

  final ledgerQueries = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/stock/balances') {
      return {
        'items': [
          {
            'id': 'b1',
            'warehouseId': 'w1',
            'goodsId': 'goods-1',
            'qty': 5000,
            'weight': 11.55,
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path == '/stock/goods/goods-1/ledger') {
      ledgerQueries.add(Map.of(query ?? const {}));
      return {
        'items': [
          {
            'rowKind': 'M',
            'id': 'm1',
            'typeLabel': '其它入',
            'billNo': 'QR-001',
            'qtySigned': 10,
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async => const {'items': <Object?>[]};
}

GoodsDetail _detail({Map<String, dynamic> extra = const {}}) =>
    GoodsDetail.fromJson({
      'id': 'goods-1',
      'code': 'S-001',
      'name': '螺丝',
      'status': '使用',
      'unitName': '个',
      ...extra,
    });

Future<_StockApi> _pump(
  WidgetTester tester, {
  required Set<String> permissions,
  GoodsDetailTab initialTab = GoodsDetailTab.basic,
  GoodsDetail? detail,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1500, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _StockApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith((ref) async => const []),
        warehouseWeightUnitsPrefsProvider.overrideWith(
          _MemoryWeightUnitsPrefs.new,
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GoodsDetailBody(
            initialDetail: detail ?? _detail(),
            initialCategoryId: null,
            initialTab: initialTab,
            canCreate: false,
            canEdit: false,
            canStatus: false,
            canBomCreate: false,
            canBomEdit: false,
            canBomDelete: false,
            onToggleStatus: null,
            onDelete: null,
            onDataChanged: null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  test('goods detail tabs are addressed by name with legacy numbers', () {
    expect(GoodsDetailTab.parse('stock'), GoodsDetailTab.stock);
    expect(GoodsDetailTab.parse('FILES'), GoodsDetailTab.files);
    expect(GoodsDetailTab.parse('bom'), GoodsDetailTab.bom);
    expect(GoodsDetailTab.parse('1'), GoodsDetailTab.bom);
    expect(GoodsDetailTab.parse('2'), GoodsDetailTab.cost);
    expect(GoodsDetailTab.parse('0'), GoodsDetailTab.basic);
    expect(GoodsDetailTab.parse(null), GoodsDetailTab.basic);
    expect(GoodsDetailTab.parse('nope'), GoodsDetailTab.basic);
  });

  testWidgets('stock tab is appended after files and ?tab=stock opens the '
      'shared stock panel', (tester) async {
    await _pump(
      tester,
      permissions: const {Perm.goodsView, Perm.attachmentView, Perm.stockView},
      initialTab: GoodsDetailTab.stock,
    );
    final tabs = ['基本信息', '组装信息', '图片和文件', '库存与出入库'];
    final xs = [for (final t in tabs) tester.getTopLeft(find.text(t).first).dx];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i], greaterThan(xs[i - 1]), reason: '${tabs[i]} 的位置');
    }
    expect(find.byType(GoodsStockLedgerPanel), findsOneWidget);
    expect(find.text('11.55 kg'), findsOneWidget);
  });

  testWidgets('the ledger button switches to the stock tab ledger segment', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      permissions: const {Perm.goodsView, Perm.stockView},
    );
    expect(find.byType(GoodsStockLedgerPanel), findsNothing);

    await tester.tap(find.byKey(const ValueKey('goods-detail-view-ledger')));
    await tester.pumpAndSettle();

    expect(find.byType(GoodsStockLedgerPanel), findsOneWidget);
    expect(api.ledgerQueries, isNotEmpty);
    expect(find.text('QR-001'), findsOneWidget);
  });

  testWidgets('without stock:view there is no stock tab and no ledger button', (
    tester,
  ) async {
    await _pump(
      tester,
      permissions: const {Perm.goodsView},
      initialTab: GoodsDetailTab.stock,
    );
    expect(find.text('库存与出入库'), findsNothing);
    expect(
      find.byKey(const ValueKey('goods-detail-view-ledger')),
      findsNothing,
    );
    // 看不到的页签回落基本信息。
    expect(find.text('库存量(合计)'), findsOneWidget);
  });

  testWidgets('stock section shows the server weight total with estimates, '
      'unknowns and line-side rows', (tester) async {
    await _pump(
      tester,
      permissions: const {Perm.goodsView},
      detail: _detail(
        extra: {
          'stockQty': 5020,
          'stockWeightKg': 28.9,
          'stockWeightUnknown': 2,
          'stockWeightEstimated': true,
          'stockByWarehouse': [
            {
              'warehouseName': '五金仓库',
              'qty': 5000,
              'weight': 28.9,
              'weightEstimated': true,
            },
            {'warehouseName': '包材仓库', 'qty': 20, 'weight': null},
            {
              'warehouseName': '注塑线边仓',
              'qty': 7,
              'weight': 0.1,
              'lineSide': true,
            },
          ],
        },
      ),
    );
    expect(find.text('≈28.9 kg (另有 2 处未称)'), findsOneWidget);
    expect(find.text('5000.0 个 · 重量 ≈28.9 kg'), findsOneWidget);
    expect(find.text('20.0 个 · 重量 未称'), findsOneWidget);
    expect(find.textContaining('(线边仓, 不计入合计)'), findsOneWidget);
  });
}

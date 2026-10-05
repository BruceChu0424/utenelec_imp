// 仓库单据编辑页的重量口径 (ADR-135 §3.3/§3.4):
//  1. 库存分析「生成盘点单」经路由 extra 带 StockCheckPrefill: 预填仓库与明细, 读账面数量与
//     账面重量 (估算带「≈」); 实盘之后是「账面重量 / 实盘重量(kg)」;
//  2. 实盘空着时填实盘重量按学到的单重推算实盘 (黄框), 保存带 countWeight + qtyFromWeight;
//  3. 其它入库: 数量空着时填重量推算数量 (黄框、qtyFromWeight), 改重量才清标记;
//     出库类单据不推算数量, 占位是「应称」。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/warehouse/models/stock_check_prefill.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_edit_page.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import 'arrival_weight_test_support.dart';

const _goodsId = 'goods-screw';
const _warehouseId = 'wh-hardware';

void main() {
  testWidgets('盘点预填(路由 extra): 读账面重量, 实盘重量推算实盘并随单保存', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('库存分析')),
        GoRoute(
          path: '/warehouse/:code/new',
          builder: (_, state) => StockDocEditPage(
            docType: StockDocType.byCode(state.pathParameters['code']!),
          ),
        ),
        GoRoute(
          path: '/warehouse/:code/:id',
          builder: (_, state) => Text('详情 ${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.stockDocView,
            Perm.stockDocEdit,
          }),
          ...warehouseWeightTestOverrides(
            api,
            repository: FakeWeightRepository(
              api,
              byGoods: const {_goodsId: learnedTwoGramParams},
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    router.push<void>(
      '/warehouse/CHECK/new',
      extra: const StockCheckPrefill(
        warehouseId: _warehouseId,
        lines: [
          StockCheckPrefillLine(goodsId: _goodsId),
          // 同一货品同一颜色只盘一行。
          StockCheckPrefillLine(goodsId: _goodsId),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final grid = find.byType(UtenEditableGrid<StockGridRow>);
    final labels = tester
        .widget<UtenEditableGrid<StockGridRow>>(grid)
        .columns
        .map((column) => column.label)
        .toList();
    final check = labels.indexOf('实盘');
    expect(labels[check - 1], '账面');
    expect(labels[check + 1], '账面重量');
    expect(labels[check + 2], '实盘重量(kg)');
    expect(labels[check + 3], '盘盈亏');

    // 预填一行 (去重), 账面按仓库读取: 10 个, 账面重量 ≈5 kg (含估算)。
    expect(find.text('螺丝'), findsOneWidget);
    expect(api.balanceQueries.single['warehouseId'], _warehouseId);
    expect(api.balanceQueries.single['goodsId'], _goodsId);
    expect(find.text('≈5 kg'), findsOneWidget);

    // 实盘空着, 填实盘重量 20 g → 按约 2 g/个 推算实盘 10 (黄框待核对)。
    await tester.enterText(
      find.descendant(
        of: grid,
        matching: find.byKey(const ValueKey('weight-cell-input')),
      ),
      '20g',
    );
    await tester.pump();
    final checkQty =
        tester
                .widget<TextField>(
                  find.byKey(const ValueKey('stock-grid-check-qty')),
                )
                .controller!
            as UtenAutofillTextController;
    expect(checkQty.text, '10');
    expect(checkQty.autofilled, isTrue);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final body = api.createdBodies.single;
    expect(body['docType'], 'CHECK');
    expect(body['warehouseId'], _warehouseId);
    final item = (body['items'] as List).cast<Map<String, dynamic>>().single;
    expect(item['goodsId'], _goodsId);
    expect(item['qty'], 10); // 账面
    expect(item['countQty'], 10); // 实盘
    expect(item['countWeight'], 0.02);
    expect(item['qtyFromWeight'], isTrue);
    expect(item.containsKey('weight'), isFalse);
    expect(find.text('详情 doc-new'), findsOneWidget);
  });

  testWidgets('其它入库: 数量空着时按称重推算数量; 出库只给「应称」不推算', (tester) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final cache = _StaticParams({_goodsId: learnedTwoGramParams});
    addTearDown(cache.dispose);

    Future<StockGridRow> pumpGrid(WeightCaptureMode mode) async {
      final row = StockGridRow()
        ..goods = const GoodsOption(id: _goodsId, name: '螺丝')
        ..unitName = '个';
      final controller = UtenEditableGridController<StockGridRow>(
        initial: [row],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            warehouseWeightUnitsPrefsProvider.overrideWith(
              MemoryWeightUnitsPrefs.new,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  UtenEditableGrid<StockGridRow>(
                    controller: controller,
                    showColumnSettings: false,
                    columns: stockGridColumns(
                      (_) async {},
                      weight: StockGridWeightWiring(
                        entryUnit: WeightUnit.kg,
                        mode: mode,
                        paramsOf: (r) => cache.of(r.goods?.id),
                        paramsListenable: cache,
                      ),
                    ),
                    createBlankRow: StockGridRow.new,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return row;
    }

    // 其它入库: 数量空 → 填 20 g 推算 10 个 (黄框, qtyFromWeight)。
    final inbound = await pumpGrid(WeightCaptureMode.inbound);
    await tester.enterText(
      find.byKey(const ValueKey('weight-cell-input')),
      '0.02',
    );
    await tester.pump();
    expect(inbound.qty.text, '10');
    expect(inbound.qty.autofilled, isTrue);
    expect(inbound.weight.qtyFromWeight, isTrue);
    expect(inbound.weight.canonicalKeyPart, '0.02|1');
    // 改数量不恢复学习资格 (仍是按称重折算的行), 改重量才清标记。
    await tester.enterText(find.byKey(const ValueKey('stock-grid-qty')), '11');
    await tester.pump();
    expect(inbound.weight.qtyFromWeight, isTrue);

    // 出库: 数量是应发量, 按可信单重预填，建议不记实称。
    final outbound = await pumpGrid(WeightCaptureMode.outbound);
    await tester.enterText(find.byKey(const ValueKey('stock-grid-qty')), '10');
    await tester.pumpAndSettle();
    expect(outbound.weight.text.text, '0.02');
    expect(outbound.weight.kg, isNull);
    expect(outbound.weight.isSuggested, isTrue);
    expect(outbound.weight.canonicalKeyPart, '|0');
    await tester.enterText(
      find.byKey(const ValueKey('weight-cell-input')),
      '0.02',
    );
    await tester.pump();
    expect(outbound.qty.text, '10');
    expect(outbound.weight.qtyFromWeight, isFalse);
  });
}

/// 预置参数的缓存 (不走网络)。
class _StaticParams extends WeightParamsCache {
  _StaticParams(this.byGoods) : super(WeightRepository(_Api()));

  final Map<String, WeightParams> byGoods;

  @override
  WeightParams? of(
    String? goodsId, {
    String? supplierId,
    String? warehouseId,
    String? colorId,
  }) => goodsId == null ? null : byGoods[goodsId];
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  final List<Map<String, dynamic>> balanceQueries = [];
  final List<Map<String, dynamic>> createdBodies = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.stockBalances) {
      balanceQueries.add(Map<String, dynamic>.from(query ?? const {}));
      return {
        'items': [
          {
            'id': 'balance-1',
            'warehouseId': _warehouseId,
            'goodsId': _goodsId,
            'colorId': null,
            'qty': 10,
            'weight': 5,
            'weightEstimated': true,
          },
        ],
        'page': 1,
        'size': 100,
        'total': 1,
      };
    }
    if (path == ApiEndpoints.stockDocsBase) {
      return const {'items': <Object>[], 'page': 1, 'size': 1, 'total': 0};
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehousesDict) {
      return const [
        {'id': _warehouseId, 'name': '五金仓库', 'selectableForNew': true},
      ];
    }
    if (path == ApiEndpoints.unitsDict) {
      return const [
        {'id': 'unit-pcs', 'name': '个'},
      ];
    }
    if (path == ApiEndpoints.goodsLookup) {
      return const [
        {
          'id': _goodsId,
          'name': '螺丝',
          'code': 'SCR-01',
          'unitId': 'unit-pcs',
          'stockPlace': 'A-01',
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.stockDocsBase) {
      createdBodies.add(Map<String, dynamic>.from(body! as Map));
      return const {'id': 'doc-new', 'docType': 'CHECK', 'items': <Object>[]};
    }
    return const {};
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/plan_order_import_sheet.dart';

void main() {
  testWidgets(
    'positive-need product without child materials is selected as direct make',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _orderLinesApi();
      List<ScheduleOrderLine>? selected;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => FilledButton(
                  onPressed: () async {
                    selected = await showPlanOrderImportSheet(
                      context,
                      ref,
                      orderId: 'order-1',
                      billNo: 'SO-001',
                    );
                  },
                  child: const Text('打开订单产品'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开订单产品'));
      await tester.pumpAndSettle();

      expect(find.text('无下层物料'), findsOneWidget);
      expect(
        find.text(
          '该产品无子层级物料，按直接自制处理：可带入计划，不生成生产领料明细；'
          '最终可生产数量由物料分析确认。',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('物料分析的子层级齐套结果'), findsOneWidget);
      expect(find.textContaining('BOM 缺失'), findsNothing);
      expect(find.textContaining('必须先补资料'), findsNothing);
      expect(find.text('已选 1 个产品'), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

      await tester.tap(find.text('带入计划明细'));
      await tester.pumpAndSettle();

      expect(selected, hasLength(1));
      expect(selected!.single.orderItemId, 'order-item-1');
      expect(tester.takeException(), isNull);
    },
  );

  test('BOM 零件读服务端 periodic 标记, 缺省为 false', () {
    final periodic = ScheduleBomComponent.fromJson({
      'goodsId': 'pp',
      'name': 'PP 颗粒',
      'perQty': 0.0125,
      'needQty': 0,
      'onhand': 0,
      'periodic': true,
    });
    final insert = ScheduleBomComponent.fromJson({
      'goodsId': 'insert',
      'name': '铜嵌件',
      'perQty': 2,
      'needQty': 20,
      'onhand': 5,
    });
    expect(periodic.periodic, isTrue);
    expect(insert.periodic, isFalse);
  });

  testWidgets('车间内料仓供料的料标「不算需求」, 不计入库存初筛的缺料', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _orderLinesApi(
      bom: [
        {
          'goodsId': 'pp',
          'code': 'M-PP',
          'name': 'PP 颗粒',
          'perQty': 0.0125,
          'needQty': 0,
          'onhand': 0,
          'selfMade': false,
          'periodic': true,
        },
        {
          'goodsId': 'insert',
          'code': 'M-CU',
          'name': '铜嵌件',
          'perQty': 2,
          'needQty': 20,
          'onhand': 5,
          'selfMade': false,
        },
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => FilledButton(
                onPressed: () => showPlanOrderImportSheet(
                  context,
                  ref,
                  orderId: 'order-1',
                  billNo: 'SO-001',
                ),
                child: const Text('打开订单产品'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开订单产品'));
    await tester.pumpAndSettle();

    expect(find.text('车间内料仓供料, 不算需求'), findsOneWidget);
    expect(find.textContaining('已知缺 1 种'), findsOneWidget);
    expect(find.textContaining('车间内料仓供料 1 种 (不算需求)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

ApiClient _orderLinesApi({List<Map<String, dynamic>> bom = const []}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: request.path == '/production/schedule/order-lines'
              ? <Map<String, dynamic>>[
                  {
                    'orderItemId': 'order-item-1',
                    'goodsId': 'goods-1',
                    'goodsCode': 'P-001',
                    'goodsName': '直接自制产品',
                    'qty': 10,
                    'plannedQty': 0,
                    'needQty': 10,
                    'unitName': '个',
                    'orderBillNo': 'SO-001',
                    'bom': bom,
                  },
                ]
              : <Map<String, dynamic>>[],
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

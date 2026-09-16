// ADR-088 物料分析顶部卡片「关联销售订单」。
//
// 两条口径必须钉死：
//  ① 去重按 orderId，且**排除 MAKE_COMPONENT / SUBCONTRACT_MAKE 子层锚点行**——
//     子件行不是「这张分析是给谁做的」的答案，混进去会让 chip 数虚高；
//  ② 点 chip 进的是新写的只读货品清单页，**不是销售订单详情**。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets('顶部卡片按来源订单去重出 chip，子层锚点行不计入', (tester) async {
    await _pump(tester);

    final section = find.byKey(
      const Key('material-analysis-linked-sales-orders'),
    );
    expect(section, findsOneWidget);

    // alpha 与 gamma 同属 order-a(去重成一个)，beta 是 order-b，
    // delta 是 MAKE_COMPONENT 子层锚点(排除)，epsilon 没有订单号(排除)。
    expect(find.text('关联销售订单 2'), findsOneWidget);
    expect(find.text('SO-A · 客户甲'), findsOneWidget);
    expect(find.text('SO-B · 客户乙'), findsOneWidget);
    expect(find.textContaining('SO-CHILD'), findsNothing);

    expect(
      find.byKey(const ValueKey('linked-sales-order-order-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('linked-sales-order-order-b')),
      findsOneWidget,
    );
  });

  testWidgets('点订单编号进只读货品清单页，不进销售订单详情', (tester) async {
    await _pump(tester);

    final chip = find.byKey(const ValueKey('linked-sales-order-order-a'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(find.text('只读清单 analysis-1/order-a'), findsOneWidget);
    expect(find.textContaining('销售订单详情'), findsNothing);
  });
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓'},
          ],
          '/production/material-analyses/analysis-1' => _analysis(),
          '/production/material-analyses/sales-candidates' => {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          },
          _ => <Object>[],
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  final api = ApiClient(dio);
  final router = GoRouter(
    initialLocation: '/production/material-analysis',
    routes: [
      GoRoute(
        path: '/production/material-analysis',
        builder: (_, _) => const ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis-1',
            warehouseId: 'warehouse-1',
          ),
        ),
      ),
      GoRoute(
        path: '/production/material-analyses/:id/sales-orders/:orderId',
        builder: (_, state) => Scaffold(
          body: Text(
            '只读清单 ${state.pathParameters['id']}'
            '/${state.pathParameters['orderId']}',
          ),
        ),
      ),
      GoRoute(
        path: '/sales/orders/:id',
        builder: (_, _) => const Scaffold(body: Text('销售订单详情')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentRepositoryProvider.overrideWithValue(_DepartmentRepository()),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
        }),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _DepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs value) {
    state = value.normalized();
  }
}

Map<String, dynamic> _analysis() => {
  'analysisId': 'analysis-1',
  'status': 'ACTIVE',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'allowedActions': ['VIEW'],
  'products': [
    _product('alpha', '甲产品', 'SALES_ORDER_ITEM', 'order-a', 'SO-A', '客户甲'),
    _product('beta', '乙产品', 'SALES_ORDER_ITEM', 'order-b', 'SO-B', '客户乙'),
    // 同一张订单的第二条来源行：chip 必须去重成一个。
    _product('gamma', '丙产品', 'SALES_ORDER_ITEM', 'order-a', 'SO-A', '客户甲'),
    // 子层锚点行：即使服务端带了订单号也不计入「这张分析是给谁做的」。
    _product('delta', '丁子件', 'MAKE_COMPONENT', 'order-c', 'SO-CHILD', '客户丙'),
    // 手工来源行：没有订单，直接跳过。
    _product('epsilon', '戊物料', 'MANUAL', null, null, null),
  ],
  'flatMaterials': <Object>[],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _product(
  String id,
  String name,
  String sourceType,
  String? orderId,
  String? orderNo,
  String? clientName,
) => {
  'analysisLineId': id,
  'sourceType': sourceType,
  'goodsId': 'goods-$id',
  'goodsCode': 'P-$id',
  'goodsName': name,
  'requestedQty': 10,
  'remainingQty': 10,
  'readyNowQty': 0,
  'salesOrderId': ?orderId,
  'salesOrderNo': ?orderNo,
  'clientName': ?clientName,
};

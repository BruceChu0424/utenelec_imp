// 「新建生产计划单」入口 = 物料分析工作台的 planCreateEntry 模式（2026-10-08，
// /production/plans/new 由 ProductionPlanEditPage 换成 ProductionMaterialAnalysisPage）。
//
// 这里守住的契约：
//  1. 计划入口不读销售候选：零 /sales-candidates 请求，候选区没有销售分段条/
//     销售候选表，只有手工需求选货 + 单据日期/交货日 + 仓库 +「联合分析」；
//  2. 手工需求单选货→「联合分析」POST /preview 只带手工来源
//     （sourceType/sourceRef/goodsId/requestedQty/sourceReason/行需求日），
//     回来渲染与物料分析同一张层级表（material-analysis-results），
//     产品父行与 BOM 子件行照常显示；
//  3. 路由级：/production/plans/new 渲染物料分析工作台（标题「新建生产计划单」），
//     不再是 ProductionPlanEditPage 空白表单。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/pages/production_plan_edit_page.dart';
import 'package:uten_imp/features/production/production_routes.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/material_manual_demand_editor.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const _permissions = {
  Perm.productionMaterialAnalysisView,
  Perm.productionMaterialAnalysisCreate,
  Perm.productionMaterialAnalysisRefresh,
  Perm.productionMaterialAnalysisRoute,
  Perm.productionMaterialAnalysisNotify,
};

void main() {
  testWidgets('计划入口：不读销售候选，候选区只有手工需求选货+日期+仓库', (tester) async {
    final server = _Server();
    await _pumpPlanEntry(tester, server);
    await tester.pumpAndSettle();

    expect(find.text('新建生产计划单'), findsWidgets);
    // 不读销售候选（普通物料分析新建态会发的候选列表/facets 一个都不发）。
    expect(
      server.requests.where((r) => r.path.contains('/sales-candidates')),
      isEmpty,
    );
    // 无销售分段条 / 销售候选表。
    expect(
      find.byKey(const Key('material-analysis-candidate-tabs')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('material-analysis-candidate-table')),
      findsNothing,
    );
    // 手工需求选货区 + 单据日期/交货日 + 仓库。
    expect(
      find.byKey(const Key('plan-entry-manual-demand-list')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('plan-entry-bill-date')), findsOneWidget);
    expect(find.byKey(const Key('plan-entry-delivery-date')), findsOneWidget);
    expect(
      find.byKey(const Key('material-analysis-warehouse')),
      findsOneWidget,
    );
    // 右下「联合分析」按钮在（0 项禁用态）。
    expect(find.byKey(const Key('material-analysis-start')), findsOneWidget);
    expect(find.text('联合分析'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('计划入口：手工需求选货→联合分析只发手工来源并渲染同一张层级表', (tester) async {
    final server = _Server();
    await _pumpPlanEntry(
      tester,
      server,
      extraOverrides: [
        _manualPickerOverride([
          [_manualGoods('m1')],
        ]),
      ],
    );
    await tester.pumpAndSettle();

    await _fillManualDemandHeader(
      tester,
      sourceRef: 'RW-PLAN-1',
      reason: '计划入口投产',
    );
    await _pickManualDemandGoods(tester);
    final qtyFields = _manualDemandQtyFields(0);
    expect(qtyFields, findsOneWidget);
    await tester.enterText(qtyFields.first, '5');
    await tester.pumpAndSettle();
    expect(find.text('联合分析所选 1 项'), findsOneWidget);

    // 顶部「交货日」选定今天（弹窗默认值）→ 作为手工需求行的默认需求日随来源下发。
    final deliveryField = find.byKey(const Key('plan-entry-delivery-date'));
    await tester.ensureVisible(deliveryField);
    await tester.pumpAndSettle();
    await tester.tap(deliveryField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('material-analysis-start')));
    await tester.pumpAndSettle();

    final preview = server.requests.singleWhere(
      (r) =>
          r.method == 'POST' && r.path.endsWith('/material-analyses/preview'),
    );
    expect((preview.data as Map)['sources'], [
      {
        'sourceType': 'REWORK',
        'sourceRef': 'RW-PLAN-1',
        'goodsId': 'm1',
        'unitId': 'unit-1',
        'requestedQty': 5.0,
        'sourceReason': '计划入口投产',
        'deliveryDate': ChinaDateTime.formatDate(ChinaDateTime.today()),
      },
    ]);
    expect(
      server.requests.where((r) => r.path.contains('/sales-candidates')),
      isEmpty,
      reason: '计划入口的分析来源只有手工需求，全程不读销售候选',
    );
    // 回来是物料分析同一张层级表：产品父行 + BOM 子件行照常显示。
    expect(find.byKey(const Key('material-analysis-results')), findsOneWidget);
    expect(find.text('手工货品 m1'), findsWidgets);
    expect(find.text('紧固件 1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('/production/plans/new 渲染物料分析工作台，不再进空白表单页', (tester) async {
    final server = _Server();
    final dio = _dio(server);
    final api = ApiClient(dio);
    final router = GoRouter(
      initialLocation: '/production/plans/new',
      routes: productionRoutes,
    );
    addTearDown(router.dispose);
    await _pumpWithRouter(tester, server, api, router);

    expect(find.byType(ProductionMaterialAnalysisPage), findsOneWidget);
    expect(find.byType(ProductionPlanEditPage), findsNothing);
    expect(find.text('新建生产计划单'), findsWidgets);
    expect(
      find.byKey(const Key('plan-entry-manual-demand-list')),
      findsOneWidget,
    );
    expect(
      server.requests.where((r) => r.path.contains('/sales-candidates')),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}

// ===== 手工需求单驱动辅助（与 production_material_analysis_page_test 同款） =====

GoodsListItem _manualGoods(String id) => GoodsListItem(
  id: id,
  code: 'M-$id',
  name: '手工货品 $id',
  spec: '规格 $id',
  unitId: 'unit-1',
  unitName: '个',
);

/// 选货滑窗换成固定结果的桩。
Override _manualPickerOverride(List<List<GoodsListItem>> picks) {
  final queue = [...picks];
  return materialAnalysisManualGoodsPickerProvider.overrideWithValue(
    (context, ref) async =>
        queue.isEmpty ? const <GoodsListItem>[] : queue.removeAt(0),
  );
}

Finder _manualDemandField(String field, {int card = 0}) => find.descendant(
  of: find.byKey(ValueKey('manual-demand-$field-$card')),
  matching: find.byType(TextField),
);

Finder _manualDemandQtyFields(int card) => find.descendant(
  of: find.byKey(ValueKey('manual-demand-grid-$card')),
  matching: find.byType(TextField),
);

Future<void> _fillManualDemandHeader(
  WidgetTester tester, {
  int card = 0,
  String type = '返工',
  String? sourceRef,
  String? reason,
}) async {
  final dropdown = find.byKey(ValueKey('manual-demand-type-$card'));
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(type).last);
  await tester.pumpAndSettle();
  if (sourceRef != null) {
    await tester.enterText(_manualDemandField('ref', card: card), sourceRef);
    await tester.pumpAndSettle();
  }
  if (reason != null) {
    await tester.enterText(_manualDemandField('reason', card: card), reason);
    await tester.pumpAndSettle();
  }
}

/// 点这张单第一个空的「货品名称」格（弹多选选货）。
Future<void> _pickManualDemandGoods(WidgetTester tester, {int card = 0}) async {
  final cell = find
      .descendant(
        of: find.byKey(ValueKey('manual-demand-grid-$card')),
        matching: find.text('点击选择'),
      )
      .first;
  await tester.ensureVisible(cell);
  await tester.pumpAndSettle();
  await tester.tap(cell);
  await tester.pumpAndSettle();
}

// ===== 桩服务与页面装配 =====

class _Server {
  final List<RequestOptions> requests = [];

  Future<Object?> respond(RequestOptions request) async {
    final path = request.path;
    if (path == '/master/warehouses/dict') {
      return [
        {
          'id': 'warehouse-1',
          'name': '主仓',
          'code': '001',
          'selectableForNew': true,
        },
      ];
    }
    if (request.method == 'POST' &&
        path.endsWith('/material-analyses/preview')) {
      return _analysis();
    }
    if (path.endsWith('/future-transfers')) return <Object>[];
    if (path.endsWith('/workshop-urges')) return <Object>[];
    if (path.endsWith('/transferable-in-summary')) {
      return {'qtyByMaterialLineId': <String, Object>{}};
    }
    if (path.endsWith('/default-workshops')) return <Object>[];
    return <String, Object>{};
  }
}

Dio _dio(_Server server) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        server.requests.add(request);
        final result = await server.respond(request);
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: result,
          ),
        );
      },
    ),
  );
  return dio;
}

Future<void> _pumpPlanEntry(
  WidgetTester tester,
  _Server server, {
  List<Override> extraOverrides = const [],
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = ApiClient(_dio(server));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(_Prefs.new),
        currentPermissionsProvider.overrideWithValue(_permissions),
        ...extraOverrides,
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(planCreateEntry: true),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpWithRouter(
  WidgetTester tester,
  _Server server,
  ApiClient api,
  GoRouter router,
) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(_Prefs.new),
        currentPermissionsProvider.overrideWithValue(_permissions),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Prefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs(primaryWarehouseId: 'warehouse-1');
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs value) {
    state = value.normalized();
  }
}

/// 联合分析后的快照：手工需求产品（父行）+ 一条采购子件（BOM 子行）。
Map<String, dynamic> _analysis() => {
  'analysisId': 'analysis-1',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'status': 'ACTIVE',
  'allowedActions': [
    'VIEW',
    'REFRESH',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'VIEW_FUTURE_TRANSFERS',
  ],
  'products': [
    {
      'analysisLineId': 'product-1',
      'sourceType': 'REWORK',
      'sourceRef': 'RW-PLAN-1',
      'sourceReason': '计划入口投产',
      'goodsId': 'm1',
      'goodsCode': 'M-m1',
      'goodsName': '手工货品 m1',
      'requestedQty': 5,
      'remainingQty': 5,
      'readyNowQty': 0,
      'canSchedule': true,
      'maxSchedulableQty': 5,
      'unitName': '个',
      'unitId': 'unit-1',
    },
  ],
  'flatMaterials': [
    {
      'materialLineId': 'm-1',
      'analysisLineId': 'product-1',
      'nodeKey': 'n-1',
      'actionGroupKey': 'a-1',
      'goodsId': 'g-1',
      'goodsCode': 'M-0001',
      'goodsName': '紧固件 1',
      'unitName': '个',
      'unitId': 'unit-1',
      'level': 1,
      'path': ['手工货品 m1', '紧固件 1'],
      'requiredQty': 5,
      'allocatedAvailableQty': 1,
      'availableQty': 1,
      'shortageQty': 4,
      'demandSupplyGapQty': 4,
      'additionalSupplyRecommendedQty': 4,
      'sourceSuggestion': 'BUY',
      'sourceConfirmed': 'BUY',
      'routeConfirmed': true,
      'controlStage': 'START',
      'hardGate': true,
      'actionable': true,
    },
  ],
};

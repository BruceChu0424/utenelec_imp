// 物料分析准备页的进页等待与轮询 (2026-09-27 用户口径「一进物料分析准备页就弹窗
// 加载，会卡一会」，ADR-102 2026-09-27 修订)。
//
// 这里守住的契约：
//  1. 带着来源新建：第一次分析期间是页内进度卡「正在展开 N 个产品的 BOM 并核对
//     库存…」，不闪空候选表、不挂「联合分析」按钮；算完直接显示物料表，服务端
//     回包里的自动确认条数轻提示，页面零 PUT /routes、零全屏遮罩；
//  2. 打开已有分析：读取期间是页头骨架 + 一行说明，不是整页正中一个转圈；
//  3. 45 秒轮询：有人勾着行 (未提交编辑) 时，版本 / 指纹 / 动态投影都没变就
//     不重新套用 (不补发附带读取、不补发汇总预览)；真变了才按保留输入的口径
//     套用，勾选照旧保留;
//  4. 打开已有分析、服务端报还有能自动确认的行：静默刷新一次，只有一行小提示、
//     没有全屏遮罩，回来后轻提示条数、同一纪元不再刷。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
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
  testWidgets('带来源新建：第一次分析期间显示进度卡，不闪空候选表；算完零 PUT 并轻提示', (tester) async {
    final server = _Server()..autoConfirmedOnPreview = 2;
    final gate = server.gate('/preview');
    await _pumpPage(
      tester,
      server,
      const ProductionMaterialAnalysisSeed(
        warehouseId: 'warehouse-1',
        sources: [
          MaterialAnalysisSourceInput(
            salesOrderItemId: 'sales-1',
            requestedQty: 1000,
          ),
        ],
      ),
    );
    // 服务端还在展开 BOM：页内进度卡，而不是空候选表 +「暂无可分析…」。
    expect(
      find.byKey(const Key('material-analysis-first-preview-progress')),
      findsOneWidget,
    );
    expect(find.text('正在展开 1 个产品的 BOM 并核对库存…'), findsOneWidget);
    expect(
      find.byKey(const Key('material-analysis-candidate-table')),
      findsNothing,
    );
    expect(find.text('暂无可分析的已审销售订单产品'), findsNothing);
    expect(find.byKey(const Key('material-analysis-start')), findsNothing);
    expect(
      server.requests.where((r) => r.path.endsWith('/sales-candidates')),
      isEmpty,
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-first-preview-progress')),
      findsNothing,
    );
    expect(find.byKey(const Key('material-analysis-results')), findsOneWidget);
    expect(
      server.requests.where((r) => r.method == 'PUT'),
      isEmpty,
      reason: '自动确认在服务端那次分析里完成，页面不再补发 PUT /routes',
    );
    expect(
      find.byKey(const Key('material-analysis-action-busy')),
      findsNothing,
    );
    expect(_notices(tester), contains('已按货品档案自动确认 2 条供应方式'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开已有分析：读取期间是页头骨架 + 一行说明', (tester) async {
    final server = _Server();
    final gate = server.gate('/production/material-analyses/analysis-1');
    await _pumpPage(
      tester,
      server,
      const ProductionMaterialAnalysisSeed(
        analysisId: 'analysis-1',
        warehouseId: 'warehouse-1',
      ),
    );
    expect(
      find.byKey(const Key('material-analysis-opening-skeleton')),
      findsOneWidget,
    );
    expect(find.text('正在读取这份物料分析的 BOM 与库存结果…'), findsOneWidget);
    expect(find.byKey(const Key('material-analysis-start')), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-opening-skeleton')),
      findsNothing,
    );
    expect(find.byKey(const Key('material-analysis-results')), findsOneWidget);
    expect(server.requests.where((r) => r.method != 'GET'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('轮询：勾着行时数据没变不重新套用，变了才套用且保留勾选', (tester) async {
    final server = _Server();
    await _pumpPage(
      tester,
      server,
      const ProductionMaterialAnalysisSeed(
        analysisId: 'analysis-1',
        warehouseId: 'warehouse-1',
      ),
    );
    await tester.pumpAndSettle();
    // 套用快照时附带读取合成一批：在途调拨、车间在催、可调拨量各取一次。
    expect(server.count('/future-transfers'), 1);
    expect(server.count('/workshop-urges'), 1);

    // 勾两行 = 有未提交的选择 (编辑中)。
    final region = find.byKey(
      const Key('material-analysis-material-table-region'),
    );
    await tester.tap(
      find.descendant(
        of: region,
        matching: find.byKey(const Key('master-data-table-select-all')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    final detailReads = server.count(
      '/production/material-analyses/analysis-1',
    );

    // 45 秒一轮：服务端数据没变。
    await tester.pump(const Duration(seconds: 46));
    await tester.pumpAndSettle();
    expect(
      server.count('/production/material-analyses/analysis-1'),
      detailReads + 1,
      reason: '轮询照常读详情',
    );
    expect(
      server.count('/future-transfers'),
      1,
      reason: '没变就不重新套用，不再补发套用快照后的附带读取',
    );
    expect(server.count('/aggregate-orders/preview'), 0);
    expect(find.text('已选 2 项'), findsOneWidget);
    // 车间在催不依赖快照，照常随轮询重取。
    expect(server.count('/workshop-urges'), 2);

    // 服务端真变了 (别人办了到货：可用量变化, 版本进位)。
    server.data = {
      ...server.data,
      'version': 4,
      'fingerprint': 'b' * 64,
      'flatMaterials': [
        for (final row
            in (server.data['flatMaterials'] as List)
                .cast<Map<String, dynamic>>())
          {...row, 'availableQty': 300, 'allocatedAvailableQty': 300},
      ],
    };
    await tester.pump(const Duration(seconds: 46));
    await tester.pumpAndSettle();
    expect(server.count('/future-transfers'), 2, reason: '变了才套用');
    expect(find.text('已选 2 项'), findsOneWidget, reason: '套用时保留未提交的勾选');
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端报待确认：静默刷新一次，只有一行小提示、没有遮罩，完成后照常勾选', (tester) async {
    // 服务端报还有 1 组能按货品档案确认 (别的单据顺带重算后新冒出来的)。
    final server = _Server()
      ..data = {..._analysis(), 'pendingAutoConfirmRouteCount': 1}
      ..autoConfirmedOnPreview = 1;
    final gate = server.gate('/material-analyses/preview');
    await _pumpPage(
      tester,
      server,
      const ProductionMaterialAnalysisSeed(
        analysisId: 'analysis-1',
        warehouseId: 'warehouse-1',
      ),
    );
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // 静默刷新已发出：物料表照常显示，顶部一行小提示，没有全屏遮罩。
    expect(server.count('/material-analyses/preview'), 1);
    expect(find.byKey(const Key('material-analysis-results')), findsOneWidget);
    expect(
      find.byKey(const Key('material-analysis-route-auto-confirming')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('material-analysis-action-busy')),
      findsNothing,
    );
    final selectAll = find.descendant(
      of: find.byKey(const Key('material-analysis-material-table-region')),
      matching: find.byKey(const Key('master-data-table-select-all')),
    );
    // 刷新回来前表格只读 (与手动刷新相同)，勾不上，也就不会被回包冲掉。
    await tester.tap(selectAll, warnIfMissed: false);
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('已选 2 项'), findsNothing);

    // 服务端在那次刷新里确认完，版本进位、不再报待确认。
    server.data = {
      ...server.data,
      'pendingAutoConfirmRouteCount': 0,
      'version': 4,
      'fingerprint': 'b' * 64,
    };
    gate.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-route-auto-confirming')),
      findsNothing,
    );
    expect(_notices(tester), contains('已按货品档案自动确认 1 条供应方式'));
    expect(server.count('/material-analyses/preview'), 1, reason: '同一纪元只刷一次');
    expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);
    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

List<String> _notices(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(ProductionMaterialAnalysisPage)),
).read(appNotificationProvider).map((notice) => notice.message).toList();

class _Server {
  Map<String, dynamic> data = _analysis();
  int autoConfirmedOnPreview = 0;
  final List<RequestOptions> requests = [];
  final Map<String, Completer<void>> _gates = {};

  /// 挂住以 [suffix] 结尾的请求，直到返回的 Completer 完成。
  Completer<void> gate(String suffix) => _gates[suffix] = Completer<void>();

  int count(String suffix) =>
      requests.where((request) => request.path.endsWith(suffix)).length;

  Future<Object?> respond(RequestOptions request) async {
    for (final entry in _gates.entries) {
      if (request.path.endsWith(entry.key)) await entry.value.future;
    }
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
    if (path.endsWith('/sales-candidates')) {
      return {
        'items': <Object>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 1,
      };
    }
    if (path.endsWith('/sales-candidates/facets')) return <String, Object>{};
    if (request.method == 'POST' &&
        path.endsWith('/material-analyses/preview')) {
      return {...data, 'autoConfirmedRouteCount': autoConfirmedOnPreview};
    }
    if (path == '/production/material-analyses/analysis-1') return data;
    if (path.endsWith('/future-transfers')) return <Object>[];
    if (path.endsWith('/workshop-urges')) return <Object>[];
    if (path.endsWith('/transferable-in-summary')) {
      return {'qtyByMaterialLineId': <String, Object>{}};
    }
    if (path.endsWith('/default-workshops')) return <Object>[];
    return <String, Object>{};
  }
}

Future<void> _pumpPage(
  WidgetTester tester,
  _Server server,
  ProductionMaterialAnalysisSeed seed,
) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
  final api = ApiClient(dio);
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
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(seed: seed),
      ),
    ),
  );
  // 进度卡 / 骨架里有转圈动画，不能 pumpAndSettle：推几帧让首轮请求发出。
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(tester.takeException(), isNull);
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

/// 服务端建分析时已按货品档案确认了供应方式 (采购)，勾选只服务下单。
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
      'sourceType': 'SALES_ORDER',
      'salesOrderItemId': 'sales-1',
      'goodsId': 'product-goods',
      'goodsCode': 'UT-2026',
      'goodsName': '智能多功能插座',
      'requestedQty': 1000,
      'remainingQty': 1000,
      'readyNowQty': 0,
      'canSchedule': true,
      'maxSchedulableQty': 1000,
      'unitName': '件',
    },
  ],
  'flatMaterials': [
    for (var i = 1; i <= 2; i++)
      {
        'materialLineId': 'm-$i',
        'analysisLineId': 'product-1',
        'nodeKey': 'n-$i',
        'actionGroupKey': 'a-$i',
        'goodsId': 'g-$i',
        'goodsCode': 'M-000$i',
        'goodsName': '紧固件 $i',
        'unitName': '个',
        'unitId': 'unit-1',
        'level': 1,
        'path': ['智能多功能插座', '紧固件 $i'],
        'requiredQty': 1000,
        'allocatedAvailableQty': 200,
        'availableQty': 200,
        'shortageQty': 800,
        'demandSupplyGapQty': 800,
        'additionalSupplyRecommendedQty': 800,
        'sourceSuggestion': 'BUY',
        'sourceConfirmed': 'BUY',
        'routeConfirmed': true,
        'controlStage': 'START',
        'hardGate': true,
        'actionable': true,
      },
  ],
};

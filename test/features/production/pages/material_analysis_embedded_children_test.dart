import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  for (final subcontract in [false, true]) {
    testWidgets(
      '${subcontract ? "subcontract" : "make"} child materials stay actionable inside the source tree',
      (tester) async {
        await _pumpAnalysis(tester, _analysis(subcontract: subcontract));
        final parent = _row('source-parent');
        final child = _row('child-material');
        expect(parent, findsOneWidget);
        expect(child, findsOneWidget);
        expect(_row('delegated-shadow'), findsNothing);
        expect(
          tester.getTopLeft(child).dy,
          greaterThan(tester.getTopLeft(parent).dy),
        );
        expect(
          find.byKey(const ValueKey('material-route-dropdown-child-material')),
          findsOneWidget,
        );

        final search = find.descendant(
          of: find.byKey(const Key('material-bom-search')),
          matching: find.byType(TextField),
        );
        await tester.enterText(search, '真实子件原料');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(parent, findsOneWidget);
        expect(child, findsOneWidget);
        expect(find.text('原始销售产品'), findsWidgets);

        await tester.enterText(search, '');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        await tester.tap(find.text('按物料汇总'));
        await tester.pumpAndSettle();
        expect(find.text('真实子件原料'), findsWidgets);
        expect(find.text('委派旧原料'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('completed zero-quantity ownership boundary stays visible', (
    tester,
  ) async {
    final analysis = _analysis(subcontract: false);
    final materials = (analysis['flatMaterials'] as List)
        .cast<Map<String, dynamic>>();
    materials.first.addAll({
      'requiredQty': 0,
      'shortageQty': 0,
      'demandSupplyGapQty': 0,
      'requirementState': 'DELEGATED_TO_MAKE_CHILD',
      'delegatedToAnalysisLineId': 'child-product',
    });
    await _pumpAnalysis(tester, analysis);
    expect(_row('source-parent'), findsOneWidget);
    expect(_row('child-material'), findsOneWidget);
    expect(_row('delegated-shadow'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unlinked historical child remains visible without pretending to be an external product',
    (tester) async {
      final analysis = _analysis(subcontract: false);
      final materials = (analysis['flatMaterials'] as List)
          .cast<Map<String, dynamic>>();
      materials.removeWhere(
        (material) => material['materialLineId'] == 'delegated-shadow',
      );
      materials.first.remove('downstreamReferences');
      await _pumpAnalysis(tester, analysis);
      expect(_row('child-material'), findsOneWidget);
      expect(find.textContaining('未归属产品的 BOM 节点'), findsWidgets);
      expect(
        find.byKey(const ValueKey('material-route-dropdown-child-material')),
        findsNothing,
      );
      // 「全选筛选结果」已下线；无可选组时确认路线保持 0。
      await tester.pumpAndSettle();
      expect(
        find.text('确认路线(0)'),
        findsOneWidget,
        reason:
            'The resolved source already has a route; the unlinked child cannot be created.',
      );
      await tester.tap(find.text('按物料汇总'));
      await tester.pumpAndSettle();
      final orphan = find.byKey(
        const ValueKey('material-aggregate-child-goods||unit-1'),
      );
      expect(orphan, findsOneWidget);
      expect(
        find.descendant(
          of: orphan,
          matching: find.byType(DropdownButton<MaterialSupplyRoute>),
        ),
        findsNothing,
      );

      expect(tester.takeException(), isNull);
    },
  );
}

Finder _row(String id) => find.byKey(ValueKey('material-table-row-$id'));

Future<void> _pumpAnalysis(
  WidgetTester tester,
  Map<String, dynamic> analysis,
) async {
  tester.view.physicalSize = const Size(1500, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final Object data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓', 'isAccountable': true},
          ],
          '/production/material-analyses/analysis-child' => analysis,
          '/production/material-analyses/preview' => analysis,
          '/production/material-analyses/last-routes' => <String, dynamic>{},
          _ => <dynamic>[],
        };
        handler.resolve(
          Response(requestOptions: request, statusCode: 200, data: data),
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
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
        }),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis-child',
            warehouseId: 'warehouse-1',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs value) {
    state = value;
  }
}

Map<String, dynamic> _analysis({required bool subcontract}) => {
  'analysisId': 'analysis-child',
  'status': 'ACTIVE',
  'version': 2,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'allowedActions': ['VIEW', 'CONFIRM_ROUTES'],
  'products': [
    {
      'analysisLineId': 'external-product',
      'sourceType': 'SALES_ORDER_ITEM',
      'goodsId': 'product-goods',
      'goodsCode': 'P001',
      'goodsName': '原始销售产品',
      'requestedQty': 4,
      'remainingQty': 4,
      'readyNowQty': 0,
    },
    {
      'analysisLineId': 'child-product',
      'sourceType': subcontract ? 'SUBCONTRACT_MAKE' : 'MAKE_COMPONENT',
      'parentAnalysisLineId': 'external-product',
      'goodsId': 'parent-goods',
      'goodsCode': 'M001',
      'goodsName': '车间子件任务',
      'requestedQty': 4,
      'remainingQty': 4,
      'readyNowQty': 0,
    },
  ],
  'flatMaterials': [
    {
      ..._material(
        'source-parent',
        'external-product',
        'parent-goods',
        '来源自制件',
      ),
      'nodeKey': 'same-bom-node',
      'confirmedRoute': subcontract ? 'SUBCONTRACT' : 'MAKE',
      'sourceConfirmed': subcontract ? 'SUBCONTRACT' : 'MAKE',
      'routeConfirmed': true,
      'downstreamReferences': [
        {
          'actionId': 'source-action',
          'route': subcontract ? 'SUBCONTRACT' : 'MAKE',
          'documentType': subcontract
              ? 'SUBCONTRACT_MAKE_TASK'
              : 'PREPLAN_MAKE_TASK',
          'documentId': 'child-product',
          'status': 'IN_PROGRESS',
          'qty': 4,
        },
      ],
    },
    {
      ..._material(
        'delegated-shadow',
        'external-product',
        'child-goods',
        '委派旧原料',
      ),
      'nodeKey': 'same-bom-node/old-child',
      'parentNodeKey': 'same-bom-node',
      'level': 2,
      'requiredQty': 0,
      'shortageQty': 0,
      'demandSupplyGapQty': 0,
      'requirementState': 'DELEGATED_TO_MAKE_CHILD',
      'delegatedToAnalysisLineId': 'child-product',
      'actionable': false,
    },
    {
      ..._material('child-material', 'child-product', 'child-goods', '真实子件原料'),
      // A node key can repeat across products; source identity stays exact.
      'nodeKey': 'same-bom-node',
    },
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _material(
  String id,
  String product,
  String goods,
  String name,
) => {
  'materialLineId': id,
  'analysisLineId': product,
  'nodeKey': id,
  'actionGroupKey': 'group-$id',
  'goodsId': goods,
  'goodsCode': goods,
  'goodsName': name,
  'unitId': 'unit-1',
  'unitName': '个',
  'level': 1,
  'path': ['原始销售产品', name],
  'requiredQty': 4,
  'shortageQty': 4,
  'demandSupplyGapQty': 4,
  'additionalSupplyRecommendedQty': 4,
  'allocatedAvailableQty': 0,
  'availableQty': 0,
  'sourceSuggestion': 'BUY',
  'requirementState': 'ACTIVE',
  'controlStage': 'START',
  'hardGate': true,
  'actionable': true,
};

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

const _permissions = {
  Perm.productionMaterialAnalysisView,
  Perm.productionMaterialAnalysisRoute,
};

void main() {
  testWidgets(
    'table keeps eight decision columns and creates only chosen routes',
    (tester) async {
      final harness = await _pump(tester);
      expect(find.text('表头设置 8/8'), findsOneWidget);
      expect(find.text('处理'), findsNothing);
      expect(find.text('确认路线(0)'), findsOneWidget);
      expect(
        find.byKey(const Key('material-analysis-entry-workshop')),
        findsOneWidget,
      );
      expect(harness.writes, isEmpty);
      var dropdown = tester.widget<DropdownButton<MaterialSupplyRoute>>(
        _route('m-1'),
      );
      expect(dropdown.value, MaterialSupplyRoute.subcontract);
      final tree = tester.widget<UtenTreeTableCell>(
        find.byKey(const ValueKey('material-table-tree-MATERIAL|m-1')),
      );
      expect(tree.foregroundColor, Colors.black);
      await tester.tap(_route('m-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采购').last);
      await tester.pumpAndSettle();
      dropdown = tester.widget<DropdownButton<MaterialSupplyRoute>>(
        _route('m-1'),
      );
      expect(dropdown.value, MaterialSupplyRoute.buy);
      expect(
        harness.writes,
        isEmpty,
        reason: 'A dropdown change is a draft, not a write.',
      );
      expect(find.text('确认路线(1)'), findsOneWidget);
      expect(
        tester
            .widget<UtenTreeTableCell>(
              find.byKey(const ValueKey('material-table-tree-MATERIAL|m-1')),
            )
            .foregroundColor,
        Colors.white,
      );
      await tester.tap(
        find.byKey(const Key('material-analysis-create-routes')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('material-route-reason')), findsNothing);
      expect(harness.writes, hasLength(1));
      final body = harness.writes.single.data! as Map<String, dynamic>;
      expect(body['decisions'], [
        {'actionGroupKey': 'a-1', 'route': 'BUY'},
      ]);
      expect(
        harness.requests.any((r) => r.path.endsWith('/last-routes')),
        isTrue,
      );
    },
  );

  testWidgets(
    'current-page selection never selects hidden product descendants and clear is global',
    (tester) async {
      final harness = await _pump(tester, count: 250);
      final region = find.byKey(
        const Key('material-analysis-material-table-region'),
      );
      final header = find.descendant(
        of: region,
        matching: find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
      );
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('已选 99 项'), findsOneWidget);
      expect(find.text('确认路线(99)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('material-bom-search')),
        '紧固件 249',
      );
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      expect(
        find.text('已选 99 项'),
        findsOneWidget,
        reason: 'Filtering must not hide the global selected count.',
      );
      expect(find.text('确认路线(99)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('master-table-clear-selection')));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      // 筛选结果全选按钮已下线：表头复选框作用于当前筛选页，行为等价覆盖。
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('确认路线(1)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('material-bom-search')),
        '不存在的物料',
      );
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const Key('master-table-clear-selection')));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(harness.writes, isEmpty);
    },
  );

  testWidgets(
    'fullscreen preserves table state while switching layouts and filters',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('全屏'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      expect(find.text('退出全屏'), findsOneWidget);
      expect(
        find.byKey(const Key('material-analysis-material-table')),
        findsOneWidget,
      );
      // 全屏下按物料汇总布局没有 region key 包装：直接找当页表格的表头三态复选框。
      await tester.tap(
        find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-product')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      await tester.tap(find.text('退出全屏'));
      await tester.pumpAndSettle();
      expect(find.text('全屏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saving keeps selected white text on selected rows and blocks duplicate writes',
    (tester) async {
      final complete = Completer<void>();
      final harness = await _pump(
        tester,
        beforeRouteWrite: () => complete.future,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('material-analysis-material-table-region')),
          matching: find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('material-analysis-create-routes')),
      );
      for (var attempt = 0; attempt < 10 && harness.writes.isEmpty; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(harness.writes, hasLength(1));
      final tree = tester.widget<UtenTreeTableCell>(
        find.byKey(const ValueKey('material-table-tree-MATERIAL|m-1')),
      );
      expect(tree.foregroundColor, Colors.white);
      final checkbox = find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-1')),
        matching: find.byType(Checkbox),
      );
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);
      final button = tester.widget<UtenButton>(
        find.byKey(const Key('material-analysis-create-routes')),
      );
      expect(button.isLoading, isTrue);
      complete.complete();
      await tester.pumpAndSettle();
      expect(harness.writes, hasLength(1));
      expect(find.text('确认路线(0)'), findsOneWidget);
    },
  );

  testWidgets(
    'main warehouse selector exposes roots only and readonly scope cannot drift',
    (tester) async {
      final harness = await _pump(
        tester,
        permissions: {Perm.productionMaterialAnalysisView},
      );
      final selector = tester.widget<UtenDropdownField>(
        find.byKey(const ValueKey('material-analysis-main-warehouse-main')),
      );
      expect(selector.enabled, isFalse);
      expect(find.text('综合主仓'), findsOneWidget);
      expect(find.text('原料子仓'), findsNothing);
      expect(find.text('辅料子仓'), findsNothing);
      expect(
        find.byKey(const Key('material-analysis-issue-warehouse-settings')),
        findsNothing,
      );
      expect(selector.items.map((item) => item.value), ['main', 'other-main']);
      expect(harness.writes, isEmpty);
      expect(find.byType(DropdownButton<MaterialSupplyRoute>), findsNothing);
    },
  );

  testWidgets(
    'warehouse switch sends main scope and failed refresh restores old scope',
    (tester) async {
      final harness = await _pump(
        tester,
        permissions: {..._permissions, Perm.productionMaterialAnalysisRefresh},
        allowRefresh: true,
      );
      harness.failRefresh = true;
      final selector = find.byKey(
        const ValueKey('material-analysis-main-warehouse-main'),
      );
      await tester.tap(selector);
      await tester.pumpAndSettle();
      expect(find.text('原料子仓'), findsNothing);
      expect(find.text('辅料子仓'), findsNothing);
      await tester.tap(find.text('备用主仓').last);
      await tester.pumpAndSettle();
      final preview = harness.requests.lastWhere(
        (r) => r.path.endsWith('/preview'),
      );
      final body = preview.data! as Map<String, dynamic>;
      expect(body['warehouseId'], 'other-main');
      expect(body['warehouseIds'], ['other-main']);
      expect(
        find.byKey(const ValueKey('material-analysis-main-warehouse-main')),
        findsOneWidget,
      );
      expect(find.text('综合主仓'), findsOneWidget);

      harness.failRefresh = false;
      await tester.tap(find.byTooltip('按最新库存刷新分析'));
      await tester.pumpAndSettle();
      final restored =
          harness.requests
                  .lastWhere((request) => request.path.endsWith('/preview'))
                  .data!
              as Map<String, dynamic>;
      expect(restored['warehouseId'], 'warehouse-1');
      expect(restored['warehouseIds'], ['warehouse-1', 'warehouse-2']);
    },
  );

  testWidgets('light dark and compact layouts render with real fonts', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final font = await File('assets/fonts/NotoSansSC.ttf').readAsBytes();
      for (final family in ['NotoSansSC', 'Ahem']) {
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(font)))).load();
      }
      await (FontLoader('Roboto')..addFont(
            Future.value(
              ByteData.sublistView(
                await File('assets/fonts/Roboto-Regular.ttf').readAsBytes(),
              ),
            ),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    for (final config in [
      (
        name: 'light',
        size: const Size(1600, 1000),
        brightness: Brightness.light,
      ),
      (name: 'dark', size: const Size(1600, 1000), brightness: Brightness.dark),
      (
        name: 'compact',
        size: const Size(390, 844),
        brightness: Brightness.light,
      ),
    ]) {
      await _pump(tester, size: config.size, brightness: config.brightness);
      if (config.name == 'compact') {
        await tester.drag(
          find.byKey(const Key('material-analysis-results')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      if (Platform.environment['UTEN_CAPTURE_MATERIAL_UI'] == '1') {
        await _capture(tester, config.name);
      }
    }
  });
}

Finder _route(String id) => find.byKey(ValueKey('material-route-dropdown-$id'));

class _Harness {
  final requests = <RequestOptions>[];
  bool failRefresh = false;
  List<RequestOptions> get writes => requests
      .where((r) => r.method == 'PUT' && r.path.endsWith('/routes'))
      .toList();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  int count = 2,
  Set<String> permissions = _permissions,
  bool allowRefresh = false,
  Future<void> Function()? beforeRouteWrite,
  Size size = const Size(1600, 1000),
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness();
  var data = _analysis(count, allowRefresh: allowRefresh);
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        harness.requests.add(request);
        Object result = <Object>[];
        if (request.path.endsWith('/last-routes')) {
          result = <String, dynamic>{};
        } else if (request.path == '/master/warehouses/dict') {
          result = [
            {'id': 'main', 'name': '综合主仓', 'code': '001'},
            {
              'id': 'warehouse-1',
              'name': '原料子仓',
              'code': '010',
              'parentId': 'main',
            },
            {
              'id': 'warehouse-2',
              'name': '辅料子仓',
              'code': '020',
              'parentId': 'main',
            },
            {'id': 'other-main', 'name': '备用主仓', 'code': '002'},
            {
              'id': 'warehouse-3',
              'name': '备用子仓',
              'code': '030',
              'parentId': 'other-main',
            },
          ];
        } else if (request.path.endsWith('/routes') &&
            request.method == 'PUT') {
          if (beforeRouteWrite != null) await beforeRouteWrite();
          data = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
          final body = request.data! as Map<String, dynamic>;
          for (final decision
              in (body['decisions']! as List).cast<Map<String, dynamic>>()) {
            final material = (data['flatMaterials']! as List)
                .cast<Map<String, dynamic>>()
                .singleWhere(
                  (m) => m['actionGroupKey'] == decision['actionGroupKey'],
                );
            material['sourceConfirmed'] = decision['route'];
            material['routeConfirmed'] = true;
          }
          data['version'] = (data['version']! as int) + 1;
          data['fingerprint'] = 'b' * 64;
          result = data;
        } else if (request.path.endsWith('/preview')) {
          if (harness.failRefresh) {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: request,
                  statusCode: 400,
                  data: {'message': '仓库范围校验失败'},
                ),
              ),
            );
            return;
          }
          result = data;
        } else if (request.path == '/production/material-analyses/analysis-1') {
          result = data;
        } else if (request.path.endsWith('/sales-candidates')) {
          result = {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          };
        }
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
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: brightness == Brightness.light
            ? buildLightTheme()
            : buildDarkTheme(),
        home: const RepaintBoundary(
          key: Key('material-ui-capture'),
          child: ProductionMaterialAnalysisPage(
            seed: ProductionMaterialAnalysisSeed(
              analysisId: 'analysis-1',
              warehouseId: 'warehouse-1',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return harness;
}

Map<String, dynamic> _analysis(int count, {required bool allowRefresh}) => {
  'analysisId': 'analysis-1',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1', 'warehouse-2'],
  'status': 'ACTIVE',
  'allowedActions': ['VIEW', 'CONFIRM_ROUTES', if (allowRefresh) 'REFRESH'],
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
    for (var i = 1; i <= count; i++)
      {
        'materialLineId': 'm-$i',
        'analysisLineId': 'product-1',
        'nodeKey': 'n-$i',
        'actionGroupKey': 'a-$i',
        'goodsId': 'g-$i',
        'goodsCode': 'M-${i.toString().padLeft(4, '0')}',
        'goodsName': '紧固件 $i',
        'colorName': '本色',
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
        'sourceSuggestion': 'SUBCONTRACT',
        'routeConfirmed': false,
        'controlStage': 'START',
        'hardGate': true,
        'actionable': true,
      },
  ],
};

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs next) => state = next;
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('material-ui-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes != null) {
      final file = File('build/material-analysis-ui/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List());
    }
    image.dispose();
  });
}

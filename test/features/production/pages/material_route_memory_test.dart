import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'remembered routes match UUID color and unit while confirmed facts win',
    (tester) async {
      final harness = await _pump(tester, memory: (_) => _memories());
      expect(_value(tester, 'm1'), MaterialSupplyRoute.buy);
      expect(_value(tester, 'm2'), MaterialSupplyRoute.make);
      expect(_value(tester, 'm3'), MaterialSupplyRoute.subcontract);
      expect(_value(tester, 'm4'), MaterialSupplyRoute.subcontract);
      expect(_value(tester, 'm5'), MaterialSupplyRoute.subcontract);
      expect(harness.memoryReads, 1);
      expect(harness.writes, isEmpty);
    },
  );

  testWidgets(
    'confirmation saves selected actual mixed routes without mandatory reason',
    (tester) async {
      final harness = await _pump(tester, memory: (_) => _memories());
      await _choose(tester, 'm1', '委外');
      await _select(tester, 'm2');
      expect(_value(tester, 'm1'), MaterialSupplyRoute.subcontract);
      expect(_value(tester, 'm2'), MaterialSupplyRoute.make);
      await tester.tap(
        find.byKey(const Key('material-analysis-create-routes')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(harness.writes, hasLength(1));
      final decisions =
          (harness.writes.single.data as Map<String, dynamic>)['decisions'];
      expect(decisions, [
        {'actionGroupKey': 'a-m1', 'route': 'SUBCONTRACT'},
        {'actionGroupKey': 'a-m2', 'route': 'MAKE'},
      ]);
      expect(_value(tester, 'm1'), MaterialSupplyRoute.subcontract);
      expect(_value(tester, 'm2'), MaterialSupplyRoute.make);
      expect(_value(tester, 'm3'), MaterialSupplyRoute.subcontract);
      expect(
        harness.memoryReads,
        1,
        reason:
            'Unselected defaults stay frozen across this analysis confirmation.',
      );
    },
  );

  testWidgets('late memory never overwrites an explicit dropdown draft', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final harness = await _pump(
      tester,
      memory: (_) => pending.future,
      settle: false,
    );
    await _choose(tester, 'm1', '采购');
    pending.complete({
      'shared': [
        {'colorId': 'red', 'unitId': 'unit', 'route': 'SUBCONTRACT'},
      ],
    });
    await tester.pumpAndSettle();
    expect(_value(tester, 'm1'), MaterialSupplyRoute.buy);
    await tester.tap(find.byKey(const Key('material-analysis-create-routes')));
    await tester.pumpAndSettle();
    expect((harness.writes.single.data as Map<String, dynamic>)['decisions'], [
      {'actionGroupKey': 'a-m1', 'route': 'BUY'},
    ]);
  });

  testWidgets(
    'late memory from an older analysis version cannot replace a newer lookup',
    (tester) async {
      final old = Completer<Map<String, dynamic>>();
      final fresh = Completer<Map<String, dynamic>>();
      final harness = await _pump(
        tester,
        memory: (call) => call == 1 ? old.future : fresh.future,
        settle: false,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionMaterialAnalysisPage)),
      );
      harness.data['version'] = 4;
      harness.data['fingerprint'] = 'b' * 64;
      container.read(pageResumeProvider.notifier).state = (
        location: '/other',
        tick: 1,
      );
      container.read(pageResumeProvider.notifier).state = (
        location: RouteName.productionMaterialAnalysis,
        tick: 2,
      );
      for (
        var attempt = 0;
        attempt < 10 && harness.memoryReads < 2;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(harness.memoryReads, 2);
      fresh.complete({
        'shared': [
          {'colorId': 'red', 'unitId': 'unit', 'route': 'MAKE'},
        ],
      });
      await tester.pumpAndSettle();
      old.complete({
        'shared': [
          {'colorId': 'red', 'unitId': 'unit', 'route': 'BUY'},
        ],
      });
      await tester.pumpAndSettle();
      expect(_value(tester, 'm1'), MaterialSupplyRoute.make);
      expect(harness.writes, isEmpty);
    },
  );

  testWidgets('late memory from the previous effective account is discarded', (
    tester,
  ) async {
    final old = Completer<Map<String, dynamic>>();
    final fresh = Completer<Map<String, dynamic>>();
    final harness = await _pump(
      tester,
      memory: (call) => call == 1 ? old.future : fresh.future,
      settle: false,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionMaterialAnalysisPage)),
    );
    (container.read(sessionProvider.notifier) as _Session).switchAccount('B');
    for (var attempt = 0; attempt < 10 && harness.memoryReads < 2; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(harness.memoryReads, 2);
    fresh.complete({
      'shared': [
        {'colorId': 'red', 'unitId': 'unit', 'route': 'SUBCONTRACT'},
      ],
    });
    await tester.pumpAndSettle();
    old.complete({
      'shared': [
        {'colorId': 'red', 'unitId': 'unit', 'route': 'BUY'},
      ],
    });
    await tester.pumpAndSettle();
    expect(_value(tester, 'm1'), MaterialSupplyRoute.subcontract);
    expect(harness.writes, isEmpty);
  });

  testWidgets(
    'a disposed analysis cannot publish its late memory into a newly opened analysis',
    (tester) async {
      final old = Completer<Map<String, dynamic>>();
      await _pump(tester, memory: (_) => old.future, settle: false);
      await tester.pumpWidget(const SizedBox.shrink());
      final current = await _pump(
        tester,
        analysisId: 'next-analysis',
        memory: (_) => {
          'shared': [
            {'colorId': 'red', 'unitId': 'unit', 'route': 'SUBCONTRACT'},
          ],
        },
      );
      old.complete({
        'shared': [
          {'colorId': 'red', 'unitId': 'unit', 'route': 'BUY'},
        ],
      });
      await tester.pumpAndSettle();
      expect(_value(tester, 'm1'), MaterialSupplyRoute.subcontract);
      expect(current.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'memory failure is visible and confirmation keeps the displayed master route',
    (tester) async {
      final harness = await _pump(
        tester,
        memory: (_) => throw StateError('memory unavailable'),
      );
      expect(find.text('上次路线读取失败，请核对当前路线后确认'), findsOneWidget);
      expect(_value(tester, 'm1'), MaterialSupplyRoute.make);
      await _select(tester, 'm1');
      await tester.tap(
        find.byKey(const Key('material-analysis-create-routes')),
      );
      await tester.pumpAndSettle();
      expect(
        (harness.writes.single.data as Map<String, dynamic>)['decisions'],
        [
          {'actionGroupKey': 'a-m1', 'route': 'MAKE'},
        ],
      );
    },
  );

  testWidgets(
    'draft selection alone never submits routes until explicit confirmation',
    (tester) async {
      final harness = await _pump(tester, memory: (_) => _memories());
      await _select(tester, 'm1');
      await tester.pumpAndSettle();
      expect(harness.writes, isEmpty);
      await tester.tap(
        find.byKey(const Key('material-analysis-create-routes')),
      );
      await tester.pumpAndSettle();
      expect(
        (harness.writes.single.data as Map<String, dynamic>)['decisions'],
        [
          {'actionGroupKey': 'a-m1', 'route': 'BUY'},
        ],
      );
    },
  );

  test(
    'route memory lookup bounds each URL to 100 goods and retains all chunks',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final ids = (request.queryParameters['goodsIds'] as String).split(
              ',',
            );
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  for (final id in ids)
                    id: [
                      {'route': 'MAKE'},
                    ],
                },
              ),
            );
          },
        ),
      );
      final result = await ProductionPlanRepository(
        ApiClient(dio),
      ).materialAnalysisLastRoutes({for (var i = 0; i < 205; i++) 'goods-$i'});
      expect(requests, hasLength(3));
      expect(result, hasLength(205));
      for (final request in requests) {
        expect(
          (request.queryParameters['goodsIds'] as String).split(',').length,
          lessThanOrEqualTo(100),
        );
      }
    },
  );
}

Finder _dropdown(String id) =>
    find.byKey(ValueKey('material-route-dropdown-$id'));
MaterialSupplyRoute? _value(WidgetTester tester, String id) =>
    tester.widget<DropdownButton<MaterialSupplyRoute>>(_dropdown(id)).value;
Future<void> _choose(WidgetTester tester, String id, String label) async {
  await tester.ensureVisible(_dropdown(id));
  await tester.tap(_dropdown(id));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _select(WidgetTester tester, String id) async {
  final checkbox = find.descendant(
    of: find.byKey(ValueKey('material-table-row-$id')),
    matching: find.byType(Checkbox),
  );
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required FutureOr<Map<String, dynamic>> Function(int call) memory,
  bool settle = true,
  String analysisId = 'analysis',
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness()..data['analysisId'] = analysisId;
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        harness.requests.add(request);
        dynamic result = <String, dynamic>{};
        if (request.path.endsWith('/warehouses/dict')) {
          result = [
            {'id': 'warehouse', 'name': '主仓'},
          ];
        } else if (request.path.endsWith('/last-routes')) {
          try {
            result = await memory(++harness.memoryReads);
          } catch (error) {
            handler.reject(DioException(requestOptions: request, error: error));
            return;
          }
        } else if (request.method == 'PUT' &&
            request.path.endsWith('/routes')) {
          final decisions =
              (request.data as Map<String, dynamic>)['decisions'] as List;
          harness.data =
              jsonDecode(jsonEncode(harness.data)) as Map<String, dynamic>;
          for (final decision in decisions.cast<Map<String, dynamic>>()) {
            final row = (harness.data['flatMaterials'] as List)
                .cast<Map<String, dynamic>>()
                .singleWhere(
                  (row) => row['actionGroupKey'] == decision['actionGroupKey'],
                );
            row['sourceConfirmed'] = decision['route'];
            row['routeConfirmed'] = true;
          }
          harness.data['version'] = (harness.data['version'] as int) + 1;
          harness.data['fingerprint'] = 'c' * 64;
          result = harness.data;
        } else if (request.path ==
            '/production/material-analyses/$analysisId') {
          result = harness.data;
        } else if (request.path.endsWith('/sales-candidates')) {
          result = {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 0,
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
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
        }),
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(_Prefs.new),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: analysisId,
            warehouseId: 'warehouse',
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var attempt = 0; attempt < 20 && harness.memoryReads == 0; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  expect(tester.takeException(), isNull);
  expect(harness.memoryReads, 1);
  return harness;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => _state('A');
  void switchAccount(String id) {
    state = _state(id);
  }

  SessionState _state(String id) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: id, code: id, name: id, roles: const []),
  );
}

class _Prefs extends MaterialAnalysisWarehousePrefsNotifier {
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

class _Harness {
  Map<String, dynamic> data = _analysis();
  final List<RequestOptions> requests = [];
  int memoryReads = 0;
  List<RequestOptions> get writes =>
      requests.where((request) => request.method == 'PUT').toList();
}

Map<String, dynamic> _memories() => {
  'shared': [
    {'colorId': 'red', 'unitId': 'unit', 'route': 'BUY'},
    {'colorId': 'blue', 'unitId': 'unit', 'route': 'MAKE'},
    {'colorId': 'red', 'unitId': 'other-unit', 'route': 'SUBCONTRACT'},
  ],
};
Map<String, dynamic> _analysis() => {
  'analysisId': 'analysis',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse',
  'warehouseIds': ['warehouse'],
  'status': 'ACTIVE',
  'allowedActions': ['VIEW', 'CONFIRM_ROUTES'],
  'products': [
    {
      'analysisLineId': 'product',
      'sourceType': 'STOCK',
      'goodsId': 'root-goods',
      'goodsName': '测试产品',
      'requestedQty': 10,
      'remainingQty': 10,
    },
  ],
  'flatMaterials': [
    _material('m1', 'red', 'unit', 'MAKE'),
    _material('m2', 'blue', 'unit', 'BUY'),
    _material('m3', 'red', 'other-unit', 'MAKE'),
    _material('m4', 'red', 'unit', 'BUY')
      ..['sourceConfirmed'] = 'SUBCONTRACT'
      ..['routeConfirmed'] = true,
    _material('m5', null, null, null)..['goodsId'] = 'new-goods',
  ],
};
Map<String, dynamic> _material(
  String id,
  String? color,
  String? unit,
  String? suggestion,
) => {
  'materialLineId': id,
  'analysisLineId': 'product',
  'nodeKey': id,
  'actionGroupKey': 'a-$id',
  'goodsId': 'shared',
  'goodsName': '物料 $id',
  'goodsCode': id,
  'colorId': color,
  'unitId': unit,
  'level': 1,
  'path': ['测试产品', '物料 $id'],
  'requiredQty': 10,
  'shortageQty': 10,
  'demandSupplyGapQty': 10,
  'sourceSuggestion': suggestion,
  'routeConfirmed': false,
  'actionable': true,
};

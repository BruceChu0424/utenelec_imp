import 'dart:convert';

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
import 'package:uten_imp/shared/providers/session_provider.dart';

const _viewNotify = {
  Perm.productionMaterialAnalysisView,
  Perm.productionMaterialAnalysisNotify,
};
const _all = {..._viewNotify, Perm.productionMaterialAnalysisRoute};

void main() {
  testWidgets(
    'fully covered sales root confirms zero new purchasing while inactive BOM stays blocked',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(
          requiredQty: 10,
          allocated: 10,
          actionable: false,
          inactiveBom: true,
        ),
      );
      await _openBuy(tester);
      expect(
        find.byKey(const ValueKey('row:NODE|root-action|root-line')),
        findsOneWidget,
      );
      final inactiveRow = find.byKey(
        const ValueKey('row:NODE|inactive-action|inactive-bom'),
      );
      expect(inactiveRow, findsOneWidget);
      final inactiveCheckbox = find.descendant(
        of: inactiveRow,
        matching: find.byType(Checkbox),
      );
      expect(inactiveCheckbox, findsOneWidget);
      expect(tester.widget<Checkbox>(inactiveCheckbox).onChanged, isNull);
      await _selectAndOpenQuantity(tester);
      // 行内默认 0（缺口已被现货覆盖），现货交接提示进总结弹窗。
      final quantity = find.byKey(
        const ValueKey('material-analysis-bucket-submit-qty-root-action'),
      );
      expect(tester.widget<TextField>(quantity).controller!.text, '0');
      expect(find.textContaining('将优先交接已分配现货 10'), findsOneWidget);
      await tester.tap(find.byKey(const Key('supply-submit-confirm')));
      await tester.pumpAndSettle();
      final request = harness.notifications.single;
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'target': 'BUY',
        'actionGroupKeys': ['root-action'],
        'quantities': [
          {
            'actionGroupKey': 'root-action',
            'qty': 0.0,
            'safetyReplenishmentQty': 0.0,
            'publicExtraQty': 0.0,
          },
        ],
      });
      expect(
        harness.requests.where(
          (request) => request.path.startsWith('/purchase/'),
        ),
        isEmpty,
        reason:
            'The client sends a stock-handoff command, not a fabricated positive purchase quantity.',
      );
    },
  );

  for (final type in ['ROOT_STOCK_ALLOCATION', 'ROOT_OUTPUT_FULFILLMENT']) {
    testWidgets(
      'completed $type is not deducted again from remaining root demand',
      (tester) async {
        final harness = await _pump(
          tester,
          _analysis(
            requiredQty: 7,
            allocated: 0,
            output: _output(type: type, qty: 3),
          ),
        );
        await _openBuy(tester);
        await _selectAndOpenQuantity(tester);
        final quantity = find.byKey(
          const ValueKey('material-analysis-bucket-submit-qty-root-action'),
        );
        expect(tester.widget<TextField>(quantity).controller!.text, '7');
        expect(find.text('共 1 个品种，合计 7。'), findsOneWidget);
        await tester.tap(find.byKey(const Key('supply-submit-confirm')));
        await tester.pumpAndSettle();
        final quantities =
            (harness.notifications.single.data
                as Map<String, dynamic>)['quantities'];
        expect(quantities, [
          {
            'actionGroupKey': 'root-action',
            'qty': 7.0,
            'safetyReplenishmentQty': 0.0,
            'publicExtraQty': 0.0,
          },
        ]);
      },
    );
  }

  testWidgets(
    'completed stock output stays in issued history and authorized revoke uses the cancel contract',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(
          requiredQty: 0,
          allocated: 0,
          actionable: false,
          output: _output(qty: 10),
        ),
      );
      await _openBuy(tester);
      final issued = find.descendant(
        of: find.byKey(const Key('material-analysis-task-state')),
        matching: find.textContaining('已下达 ('),
      );
      await tester.ensureVisible(issued);
      await tester.tap(issued);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('row:NODE|root-action|root-line')),
        findsOneWidget,
      );
      expect(find.textContaining('ROOT-EVENT-1'), findsWidgets);
      await tester.tap(find.byTooltip('返回').last);
      await tester.pumpAndSettle();
      await _openRootDetails(tester);
      final revoke = find.byKey(
        const ValueKey('material-root-output-revoke-event-1'),
      );
      expect(revoke, findsOneWidget);
      await tester.ensureVisible(revoke);
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认取消'));
      await tester.pumpAndSettle();
      expect(
        harness.revocations,
        isEmpty,
        reason: 'Stock-output revoke still requires a reason.',
      );
      final reason = find.byKey(const Key('material-analysis-cancel-reason'));
      expect(reason, findsOneWidget);
      await tester.enterText(reason, '原订单调整，撤回未拣货现货');
      await tester.tap(find.text('确认取消'));
      await tester.pumpAndSettle();
      final request = harness.revocations.single;
      expect(
        request.path,
        '/production/material-analyses/analysis/root-outputs/event-1/revoke',
      );
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'reason': '原订单调整，撤回未拣货现货',
      });
      expect(
        find.byKey(const ValueKey('material-node-details-root-line')),
        findsNothing,
      );
      await _openRootDetails(tester);
      expect(find.textContaining('交接已撤回'), findsWidgets);
      expect(
        find.byKey(const ValueKey('material-root-output-revoke-event-1')),
        findsNothing,
      );
    },
  );

  for (final testCase
      in <
        ({
          String name,
          Set<String> permissions,
          bool serverAllowed,
          String type,
        })
      >[
        (
          name: 'view without notify',
          permissions: {Perm.productionMaterialAnalysisView},
          serverAllowed: true,
          type: 'ROOT_STOCK_ALLOCATION',
        ),
        (
          name: 'notify without view',
          permissions: {Perm.productionMaterialAnalysisNotify},
          serverAllowed: true,
          type: 'ROOT_STOCK_ALLOCATION',
        ),
        (
          name: 'server action absent',
          permissions: _viewNotify,
          serverAllowed: false,
          type: 'ROOT_STOCK_ALLOCATION',
        ),
        (
          name: 'receipt output uses receipt reversal',
          permissions: _viewNotify,
          serverAllowed: true,
          type: 'ROOT_OUTPUT_FULFILLMENT',
        ),
      ]) {
    testWidgets(
      '${testCase.name} cannot revoke root stock output from the detail panel',
      (tester) async {
        final harness = await _pump(
          tester,
          _analysis(
            requiredQty: 0,
            allocated: 0,
            actionable: false,
            output: _output(type: testCase.type, qty: 10),
            revokeAllowed: testCase.serverAllowed,
          ),
          permissions: testCase.permissions,
        );
        await _openRootDetails(tester);
        expect(
          find.byKey(const ValueKey('material-root-output-revoke-event-1')),
          findsNothing,
        );
        expect(harness.revocations, isEmpty);
      },
    );
  }

  testWidgets('a reversed root output does not keep route editing locked', (
    tester,
  ) async {
    final harness = await _pump(
      tester,
      _analysis(
        requiredQty: 10,
        allocated: 0,
        output: _output(status: 'REVERSED', qty: 3),
      ),
      permissions: _all,
    );
    final route = find.byKey(
      const ValueKey('material-route-dropdown-root-line'),
    );
    expect(route, findsOneWidget);
    expect(
      tester.widget<DropdownButton<MaterialSupplyRoute>>(route).onChanged,
      isNotNull,
    );
    await tester.tap(route);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自制').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('material-analysis-create-routes')));
    await tester.pumpAndSettle();
    final request = harness.requests.singleWhere(
      (request) => request.method == 'PUT',
    );
    expect((request.data as Map<String, dynamic>)['decisions'], [
      {'actionGroupKey': 'root-action', 'route': 'MAKE'},
    ]);
    expect(harness.notifications, isEmpty);
    expect(harness.revocations, isEmpty);
  });
}

Future<void> _openBuy(WidgetTester tester) async {
  final entry = find.byKey(const Key('material-analysis-entry-buy'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> _selectAndOpenQuantity(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('row:NODE|root-action|root-line'));
  final checkbox = find.descendant(of: row, matching: find.byType(Checkbox));
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
  final action = find.byKey(const Key('material-analysis-bucket-action-buy'));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('supply-submit-confirm-dialog')), findsOneWidget);
}

Future<void> _openRootDetails(WidgetTester tester) async {
  final name = find
      .descendant(
        of: find.byKey(const ValueKey('material-bom-product-p1')),
        matching: find.text('销售根产品'),
      )
      .first;
  await tester.ensureVisible(name);
  await tester.pumpAndSettle();
  await tester.tapAt(tester.getCenter(name));
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tapAt(tester.getCenter(name));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('material-node-details-root-line')),
    findsOneWidget,
  );
}

Future<_Harness> _pump(
  WidgetTester tester,
  Map<String, dynamic> data, {
  Set<String> permissions = _viewNotify,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness(data);
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        harness.requests.add(request);
        dynamic result = <String, dynamic>{};
        if (request.path.endsWith('/warehouses/dict')) {
          result = [
            {'id': 'warehouse', 'name': '主仓'},
          ];
        } else if (request.path.endsWith('/last-routes')) {
          result = <String, dynamic>{};
        } else if (request.path == '/production/material-analyses/analysis') {
          result = harness.data;
        } else if (request.path.endsWith('/root-outputs/event-1/revoke')) {
          harness.data =
              jsonDecode(jsonEncode(harness.data)) as Map<String, dynamic>;
          final root = (harness.data['flatMaterials'] as List)
              .cast<Map<String, dynamic>>()
              .first;
          for (final output
              in (root['downstreamReferences'] as List)
                  .cast<Map<String, dynamic>>()) {
            output['status'] = 'REVERSED';
          }
          root['requiredQty'] = 10;
          root['demandSupplyGapQty'] = 10;
          root['shortageQty'] = 10;
          root['actionable'] = true;
          harness.data['version'] = 4;
          harness.data['fingerprint'] = 'b' * 64;
          result = harness.data;
        } else if (request.path.endsWith('/notify')) {
          result = harness.data;
        } else if (request.method == 'PUT' &&
            request.path.endsWith('/routes')) {
          harness.data =
              jsonDecode(jsonEncode(harness.data)) as Map<String, dynamic>;
          final root = (harness.data['flatMaterials'] as List)
              .cast<Map<String, dynamic>>()
              .first;
          root['sourceConfirmed'] =
              ((request.data as Map<String, dynamic>)['decisions'] as List)
                  .cast<Map<String, dynamic>>()
                  .first['route'];
          root['routeConfirmed'] = true;
          harness.data['version'] = 4;
          harness.data['fingerprint'] = 'b' * 64;
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
        currentPermissionsProvider.overrideWithValue(permissions),
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(_Prefs.new),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis',
            warehouseId: 'warehouse',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return harness;
}

class _Harness {
  _Harness(this.data);
  Map<String, dynamic> data;
  final List<RequestOptions> requests = [];
  List<RequestOptions> get notifications => requests
      .where(
        (request) =>
            request.method == 'POST' && request.path.endsWith('/notify'),
      )
      .toList();
  List<RequestOptions> get revocations => requests
      .where(
        (request) =>
            request.method == 'POST' && request.path.contains('/root-outputs/'),
      )
      .toList();
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
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

Map<String, dynamic> _output({
  String type = 'ROOT_STOCK_ALLOCATION',
  String status = 'COMPLETED',
  required int qty,
}) => {
  'target': 'BUY',
  'documentType': type,
  'documentId': 'event-1',
  'documentNo': 'ROOT-EVENT-1',
  'status': status,
  'allocatedQty': qty,
  'actionId': null,
};
Map<String, dynamic> _analysis({
  required int requiredQty,
  required int allocated,
  bool actionable = true,
  bool inactiveBom = false,
  Map<String, dynamic>? output,
  bool revokeAllowed = true,
}) => {
  'analysisId': 'analysis',
  'version': 3,
  'fingerprint': 'a' * 64,
  'status': 'ACTIVE',
  'warehouseId': 'warehouse',
  'warehouseIds': ['warehouse'],
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    if (revokeAllowed) 'ROOT_OUTPUT_REVOKE',
  ],
  'products': [
    {
      'analysisLineId': 'p1',
      'sourceType': 'SALES_ORDER_ITEM',
      'salesOrderItemId': 'sales-line',
      'rootMaterialLineId': 'root-line',
      'goodsId': 'root-goods',
      'goodsName': '销售根产品',
      'goodsCode': 'ROOT-1',
      'unitId': 'unit',
      'unitName': '件',
      'unitRate': 1,
      'requestedQty': 10,
      'remainingQty': requiredQty,
      'rootFulfilledQty': 10 - requiredQty,
      'readyNowQty': 0,
      'canSchedule': false,
      'maxSchedulableQty': 0,
    },
  ],
  'flatMaterials': [
    {
      'materialLineId': 'root-line',
      'analysisLineId': 'p1',
      'nodeKey': 'ROOT_SUPPLY',
      'nodeRole': 'ROOT_SUPPLY',
      'actionGroupKey': 'root-action',
      'goodsId': 'root-goods',
      'goodsName': '销售根产品',
      'goodsCode': 'ROOT-1',
      'unitId': 'unit',
      'unitName': '件',
      'level': 0,
      'path': ['销售根产品'],
      'requiredQty': requiredQty,
      'availableQty': allocated,
      'allocatedAvailableQty': allocated,
      'shortageQty': requiredQty - allocated,
      'demandSupplyGapQty': requiredQty - allocated,
      'sourceSuggestion': 'BUY',
      'sourceConfirmed': 'BUY',
      'routeConfirmed': true,
      'actionable': actionable,
      'downstreamReferences': [?output],
      'warehouseBreakdown': [
        {
          'warehouseId': 'warehouse',
          'publicAvailableQty': allocated,
          'safetyReplenishmentGapQty': 0,
          'openSafetySupplyQty': 0,
        },
      ],
    },
    if (inactiveBom)
      {
        'materialLineId': 'inactive-bom',
        'analysisLineId': 'p1',
        'nodeKey': 'inactive-bom',
        'nodeRole': 'BOM_COMPONENT',
        'actionGroupKey': 'inactive-action',
        'goodsId': 'inactive-goods',
        'goodsName': '不可下达的普通BOM',
        'goodsCode': 'BOM-1',
        'unitId': 'unit',
        'unitName': '件',
        'level': 1,
        'path': ['销售根产品', '不可下达的普通BOM'],
        'requiredQty': 10,
        'availableQty': 5,
        'allocatedAvailableQty': 5,
        'shortageQty': 5,
        'demandSupplyGapQty': 5,
        'sourceSuggestion': 'BUY',
        'sourceConfirmed': 'BUY',
        'routeConfirmed': true,
        'actionable': false,
      },
  ],
};

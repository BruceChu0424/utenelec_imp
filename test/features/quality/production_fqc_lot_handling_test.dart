// ADR-148 产成品实物交接批：同一报工、同一产出批次、送入仓库的需求份与实际超产是一批实物。
//  - 检查单办理页一行 = 一批，「其中」列显示服务端算好的拆分，提交走整批判定接口；
//  - 单份任务页遇到多份的批只读，并给出「到检查单整批判定」入口(逐份判定服务端也会拒绝)。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _sheetId = '20000000-0000-0000-0000-000000000001';
const _lotId = '30000000-0000-0000-0000-000000000001';
const _demand = '40000000-0000-0000-0000-000000000001';
const _surplus = '40000000-0000-0000-0000-000000000002';

void main() {
  testWidgets('检查单一批一行：显示拆分，整批判定一次提交', (tester) async {
    final api = _LotApi();
    await _pump(tester, api, RouteName.productionFqcSheetHandling(_sheetId));

    // 两份(需求 1000 + 实际超产 100)合成一行，合格默认 = 整批待检 1100。
    expect(find.text('需求 1000 · 实际超产 100'), findsOneWidget);
    expect(find.byKey(const Key('fqc-sheet-pass-$_lotId')), findsOneWidget);
    expect(find.byKey(const Key('fqc-sheet-pass-$_demand')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('fqc-sheet-pass-$_lotId')))
          .controller
          ?.text,
      '1100',
    );

    await tester.tap(find.byKey(const Key('fqc-sheet-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.lotDecisionPaths, [
      '/production/quality-inspections/lots/$_lotId/decisions',
    ]);
    expect(api.lotDecisionBodies.single['passQty'], 1100);
    expect(api.lotDecisionBodies.single['failQty'], 0);
    expect(
      api.lotDecisionBodies.single['idempotencyKey'] as String,
      startsWith('fqc-report-'),
    );
    expect(api.singleDecisionCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单份任务页遇到多份的批只读，并指向检查单整批判定', (tester) async {
    final api = _LotApi();
    await _pump(
      tester,
      api,
      RouteName.productionFqcInspectionHandling(_surplus),
    );

    expect(find.byKey(const Key('fqc-inspection-submit-report')), findsNothing);
    expect(find.textContaining('请在检查单里按整批判定'), findsOneWidget);
    expect(
      find.byKey(const Key('fqc-inspection-open-sheet-for-lot')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('fqc-inspection-open-sheet-for-lot')),
    );
    await tester.pumpAndSettle();
    expect(find.text('需求 1000 · 实际超产 100'), findsOneWidget);
    expect(api.singleDecisionCount, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(WidgetTester tester, _LotApi api, String location) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '${RouteName.productionFqcSheetHandlingBase}/:sheetId',
        builder: (_, state) => ProductionFqcSheetHandlingPage(
          sheetId: state.pathParameters['sheetId']!,
        ),
      ),
      GoRoute(
        path: '${RouteName.productionFqcInspectionHandlingBase}/:inspectionId',
        builder: (_, state) => ProductionFqcInspectionPage(
          inspectionId: state.pathParameters['inspectionId']!,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionQualityInspectionApprove,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

class _LotApi extends ApiClient {
  _LotApi() : super(Dio());

  final lotDecisionPaths = <String>[];
  final lotDecisionBodies = <Map<String, dynamic>>[];
  int singleDecisionCount = 0;
  bool decided = false;

  Map<String, dynamic> _inspection(String id, int qty, String kind) => {
    'id': id,
    'sourceReportId': 'report-1',
    'sourceReportItemId': 'item-$id',
    'reportNo': 'RB-1',
    'goodsCode': 'V51043',
    'goodsName': '三极插套',
    'unitName': '只',
    'reportedQty': qty,
    'passedQty': decided ? qty : 0,
    'failedQty': 0,
    'remainingQty': decided ? 0 : qty,
    'authorizedInboundQty': 0,
    'status': decided ? 'RESOLVED' : 'PENDING',
    'sheetId': _sheetId,
    'sheetNo': 'FQC-1',
    'warehouseName': '成品仓',
    'place': 'CP-A-01',
    'lotId': _lotId,
    'sliceRank': kind == 'DEMAND' ? 0 : 2,
    'sliceKind': kind,
    'lotSliceCount': 2,
    'createdAt': '2026-10-05T01:00:00Z',
    'updatedAt': '2026-10-05T01:00:00Z',
  };

  Map<String, dynamic> get _lot => {
    'lotId': _lotId,
    'sourceReportId': 'report-1',
    'reportNo': 'RB-1',
    'goodsCode': 'V51043',
    'goodsName': '三极插套',
    'unitName': '只',
    'reportedQty': 1100,
    'passedQty': decided ? 1100 : 0,
    'failedQty': 0,
    'remainingQty': decided ? 0 : 1100,
    'demandQty': 1000,
    'publicQty': 0,
    'actualSurplusQty': 100,
    'splitText': '需求 1000 · 实际超产 100',
    'status': decided ? 'RESOLVED' : 'PENDING',
    'warehouseName': '成品仓',
    'place': 'CP-A-01',
    'members': [
      {
        'inspectionId': _demand,
        'sourceReportItemId': 'item-$_demand',
        'sliceRank': 0,
        'kind': 'DEMAND',
        'reportedQty': 1000,
        'status': decided ? 'RESOLVED' : 'PENDING',
      },
      {
        'inspectionId': _surplus,
        'sourceReportItemId': 'item-$_surplus',
        'sliceRank': 2,
        'kind': 'ACTUAL_SURPLUS',
        'reportedQty': 100,
        'status': decided ? 'RESOLVED' : 'PENDING',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/capability')) return {'canDecide': true};
    if (path == '/production/quality-inspections/sheets/$_sheetId') {
      return {
        'sheet': {
          'id': _sheetId,
          'sheetNo': 'FQC-1',
          'warehouseName': '成品仓',
          'itemCount': 2,
          'activeCount': decided ? 0 : 2,
          'status': decided ? 'CLOSED' : 'ACTIVE',
          'createdAt': '2026-10-05T01:00:00Z',
        },
        'inspections': [
          _inspection(_demand, 1000, 'DEMAND'),
          _inspection(_surplus, 100, 'ACTUAL_SURPLUS'),
        ],
        'lots': [_lot],
      };
    }
    if (path == '/production/quality-inspections/$_surplus') {
      return _inspection(_surplus, 100, 'ACTUAL_SURPLUS');
    }
    if (path.contains('/attachments')) {
      return {'items': <Object>[], 'total': 0};
    }
    return {'items': <Object>[], 'total': 0, 'totalPages': 0};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path == '/production/quality-inspections/lots/$_lotId/decisions') {
      lotDecisionPaths.add(path);
      lotDecisionBodies.add(Map<String, dynamic>.from(body! as Map));
      decided = true;
      return {'lotCommandId': 'lot-command-1', 'lot': _lot, 'replay': false};
    }
    if (path.endsWith('/decisions')) singleDecisionCount++;
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }
}

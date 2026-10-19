// ADR-148 产成品实物交接批：同一报工、同一产出批次、送入仓库的需求份与实际超产是一批实物。
//  - 检查单办理页一行 = 一批，「其中」列显示服务端算好的拆分，提交走整批判定接口；
//  - 单份任务页遇到多份的批只读，并给出「到检查单整批判定」入口(逐份判定服务端也会拒绝)。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _sheetId = '20000000-0000-0000-0000-000000000001';
const _lotId = '30000000-0000-0000-0000-000000000001';
const _demand = '40000000-0000-0000-0000-000000000001';
const _surplus = '40000000-0000-0000-0000-000000000002';
final _lotPermissions = StateProvider<Set<String>>((ref) => {});

void main() {
  testWidgets('FQC检查单实时授权与撤权只改变办理能力，原输入与幂等键保留', (tester) async {
    final api = _LotApi();
    await _pump(
      tester,
      api,
      RouteName.productionFqcSheetHandling(_sheetId),
      permissions: {Perm.productionQualityInspectionView},
    );
    final tableFinder = find.byKey(const Key('fqc-sheet-report-table'));
    MasterDataTableView<FqcReportRow> table() => tester.widget(tableFinder);
    final container = ProviderScope.containerOf(tester.element(tableFinder));
    expect(table().selectable, isFalse);
    container.read(_lotPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
      Perm.productionQualityInspectionApprove,
    };
    await tester.pumpAndSettle();
    expect(table().selectable, isTrue);
    final row = table().items.single;
    row.pass.text = '1090.';
    row.fail.text = '10';
    final key = row.idempotencyKey;
    container.read(_lotPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
    };
    await tester.pumpAndSettle();
    expect(table().selectable, isFalse);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('fqc-sheet-pass-$_lotId')))
          .enabled,
      isFalse,
    );
    container.read(_lotPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
      Perm.productionQualityInspectionApprove,
    };
    await tester.pumpAndSettle();
    expect(table().selectable, isTrue);
    expect(table().items.single.pass.text, '1090.');
    expect(table().items.single.fail.text, '10');
    expect(table().items.single.idempotencyKey, key);
    expect(api.lotDecisionBodies, isEmpty);
  });
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
    expect(
      find.byKey(const Key('inspection-report-atomic-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('已上架的合格部分自动点收入库'), findsOneWidget);
    expect(find.textContaining('均不直接增加库存'), findsNothing);
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.lotDecisionPaths, [
      '/production/quality-inspections/decisions/report',
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

Future<void> _pump(
  WidgetTester tester,
  _LotApi api,
  String location, {
  Set<String> permissions = const {Perm.productionQualityInspectionApprove},
}) async {
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
        _lotPermissions.overrideWith((ref) => permissions),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_lotPermissions),
        ),
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
    if (path == '/production/quality-inspections/decisions/report') {
      lotDecisionPaths.add(path);
      final item = Map<String, dynamic>.from(
        ((body! as Map)['items'] as List).single as Map,
      );
      expect(item['targetType'], 'LOT');
      expect(item['targetId'], _lotId);
      lotDecisionBodies.add(item);
      decided = true;
      return {
        'items': [
          {
            'targetType': 'LOT',
            'targetId': _lotId,
            'idempotencyKey': item['idempotencyKey'],
            'commandId': 'lot-command-1',
            'lot': _lot,
            'replay': false,
          },
        ],
      };
    }
    if (path.endsWith('/decisions')) singleDecisionCount++;
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }
}

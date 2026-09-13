import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/quality/models/production_fqc_inspection.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_inspections_page.dart';
import 'package:uten_imp/features/quality/pages/quality_batch_approval_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _inspectionId = '10000000-0000-0000-0000-000000000001';
const _reportNo = 'RB202608280001';

Future<void> _pumpPage(
  WidgetTester tester, {
  required _FqcApi api,
  required Set<String> permissions,
}) async {
  await tester.binding.setSurfaceSize(const Size(375, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // 批量审批页依赖 shared_preferences（页面偏好缓存）。
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      // 带路由壳：2026-09-12 起双击进 FQC 办理页、批量审批进汇总页（都不再弹窗）。
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const ProductionFqcInspectionsPage(),
            ),
            GoRoute(
              path:
                  '${RouteName.productionFqcInspectionHandlingBase}/:inspectionId',
              builder: (_, state) => ProductionFqcInspectionPage(
                inspectionId: state.pathParameters['inspectionId']!,
                extra: state.extra,
              ),
            ),
            GoRoute(
              path: RouteName.warehouseInspectionBatchApproval,
              builder: (_, state) => QualityBatchApprovalPage(
                selection: state.extra is QualityBatchApprovalSelection
                    ? state.extra! as QualityBatchApprovalSelection
                    : const QualityBatchApprovalSelection(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _drainAsyncWork(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

MasterDataTableView<ProductionFqcInspection> _taskTable(WidgetTester tester) =>
    tester.widget<MasterDataTableView<ProductionFqcInspection>>(
      find.byKey(const Key('production-fqc-inspection-table')),
    );

Future<void> _doubleTapRow(WidgetTester tester, String reportNo) async {
  final row = find.text(reportNo);
  await tester.tap(row);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('375px table supports selection, detail, and PASS decision', (
    tester,
  ) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );

    expect(find.text('生产成品质检'), findsOneWidget);
    expect(
      find.byKey(const Key('production-fqc-inspection-table')),
      findsOneWidget,
    );
    final initialTable = _taskTable(tester);
    expect(initialTable.selectable, isTrue);
    expect(initialTable.idOf!(initialTable.items.single), _inspectionId);
    expect(initialTable.selectedIds, isEmpty);
    expect(initialTable.batchActionsBuilder, isNotNull);
    expect(
      initialTable.columns.map((column) => column.key),
      containsAll(<String>{
        'status',
        'reportNo',
        'planNo',
        'goodsCode',
        'goodsName',
        'colorName',
        'reportedQty',
        'passedQty',
        'failedQty',
        'remainingQty',
        'authorizedInboundQty',
      }),
    );
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));

    await tester.tap(find.text(_reportNo));
    await tester.pump();
    expect(_taskTable(tester).selectedIds, {_inspectionId});
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(
      find.byKey(const Key('production-fqc-detail-$_inspectionId')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _doubleTapRow(tester, _reportNo);
    // 2026-09-12 弹窗改页：进入 FQC 单任务办理页（详情事实 + 决定表单）。
    expect(find.byKey(const Key('fqc-inspection-facts-table')), findsOneWidget);
    final submit = find.byKey(const Key('fqc-inspection-submit-report'));
    expect(submit, findsOneWidget);
    expect(find.text('合格数量'), findsOneWidget);

    await tester.tap(submit);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await _drainAsyncWork(tester);

    expect(api.decisionBody?['decision'], 'PASS');
    expect(api.decisionBody?['passQty'], 10);
    expect(api.decisionBody?['idempotencyKey'], startsWith('fqc-report-'));
    // 决定成功带结果返回：行已本地移除（不等刷新）。
    expect(find.text(_reportNo), findsNothing);
    expect(_taskTable(tester).items, isEmpty);
    expect(find.text('当前筛选下没有生产质检任务'), findsOneWidget);
    expect(api.listQueries.last['status'], 'ACTIVE');
    expect(api.listQueries.last['page'], 1);
    expect(tester.takeException(), isNull);
  });

  for (final scenario
      in <
        ({
          String name,
          Set<String> permissions,
          bool canDecide,
          int capabilityCalls,
        })
      >[
        (
          name: 'approve authority outside quality scope',
          permissions: const {
            Perm.productionQualityInspectionView,
            Perm.productionQualityInspectionApprove,
          },
          canDecide: false,
          // 列表 _load 查一次 + 办理页开页查一次。
          capabilityCalls: 2,
        ),
        (
          name: 'view-only authority',
          permissions: const {Perm.productionQualityInspectionView},
          canDecide: true,
          capabilityCalls: 0,
        ),
      ]) {
    testWidgets('${scenario.name} can open read-only detail', (tester) async {
      final api = _FqcApi(canDecide: scenario.canDecide);
      await _pumpPage(tester, api: api, permissions: scenario.permissions);

      expect(_taskTable(tester).selectable, isFalse);
      await _doubleTapRow(tester, _reportNo);
      // 办理页只读态：无决定表单，只有详情事实与证据。
      expect(
        find.byKey(const Key('fqc-inspection-facts-table')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('fqc-inspection-submit-report')),
        findsNothing,
      );
      expect(find.textContaining('当前为只读查看'), findsOneWidget);
      expect(api.capabilityCalls, scenario.capabilityCalls);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('successful decision stays locally resolved when reload fails', (
    tester,
  ) async {
    final api = _FqcApi(failReloadAfterDecision: true);
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );
    await _doubleTapRow(tester, _reportNo);
    await tester.tap(find.byKey(const Key('fqc-inspection-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await _drainAsyncWork(tester);

    expect(find.text(_reportNo), findsNothing);
    expect(_taskTable(tester).items, isEmpty);
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(api.listQueries, hasLength(2));
    expect(api.listQueries.last['status'], 'ACTIVE');
    expect(api.listQueries.last['page'], 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected active tasks go to batch approval page (pass-all)', (
    tester,
  ) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );

    await tester.tap(find.text(_reportNo));
    await tester.pump();
    expect(_taskTable(tester).selectedIds, {_inspectionId});
    // 2026-09-12 与待检处置统一：右下角「批量审批」进汇总页（默认全勾=全部合格）。
    final action = find.byKey(const Key('production-fqc-batch-approval'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('batch-approval-submit-report')),
      findsOneWidget,
    );
    expect(find.textContaining('勾选即全部合格'), findsOneWidget);
    await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await _drainAsyncWork(tester);

    expect(api.batchBody?['inspectionIds'], [_inspectionId]);
    expect(api.batchBody?['idempotencyKey'], startsWith('fqc-batch-approval-'));
    expect(find.text(_reportNo), findsNothing);
    expect(_taskTable(tester).items, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FQC queue exposes server paging controls at 375px', (
    tester,
  ) async {
    final api = _FqcApi(totalPages: 2);
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );

    expect(_taskTable(tester).currentPage, 1);
    expect(_taskTable(tester).totalPages, 2);
    expect(find.text('/ 2'), findsOneWidget);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(api.requestedPage, 2);
    expect(_taskTable(tester).currentPage, 2);
    expect(_taskTable(tester).totalPages, 2);
  });

  testWidgets('status segments reset page and clear controlled selection', (
    tester,
  ) async {
    final api = _FqcApi(totalPages: 2);
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );

    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_reportNo));
    await tester.pump();
    expect(_taskTable(tester).selectedIds, {_inspectionId});

    await tester.tap(find.text('已决定').first);
    await tester.pumpAndSettle();
    expect(api.listQueries.last['status'], 'RESOLVED');
    expect(api.listQueries.last['page'], 1);
    expect(_taskTable(tester).currentPage, 1);
    expect(_taskTable(tester).selectedIds, isEmpty);
    expect(_taskTable(tester).selectable, isFalse);
    expect(find.text('RB-RESOLVED'), findsOneWidget);

    await tester.tap(find.text('已取消').first);
    await tester.pumpAndSettle();
    expect(api.listQueries.last['status'], 'CANCELLED');
    expect(api.listQueries.last['page'], 1);
    expect(find.text('RB-CANCELLED'), findsOneWidget);

    await tester.tap(find.text('全部').first);
    await tester.pumpAndSettle();
    expect(api.listQueries.last['status'], 'ALL');
    expect(api.listQueries.last['page'], 1);
  });

  testWidgets('search uses the built-in 300ms debounce and resets page', (
    tester,
  ) async {
    final api = _FqcApi(totalPages: 2);
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );

    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_reportNo));
    await tester.pump();
    expect(_taskTable(tester).selectedIds, {_inspectionId});

    final listCallsBeforeSearch = api.listQueries.length;
    await tester.enterText(find.byType(TextField).first, 'V51043');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));
    expect(api.listQueries, hasLength(listCallsBeforeSearch));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(api.listQueries, hasLength(listCallsBeforeSearch + 1));
    expect(api.listQueries.last['keyword'], 'V51043');
    expect(api.listQueries.last['page'], 1);
    expect(_taskTable(tester).currentPage, 1);
    expect(find.text(_reportNo), findsOneWidget);
  });
}

class _FqcApi extends ApiClient {
  _FqcApi({
    this.canDecide = true,
    this.failReloadAfterDecision = false,
    this.totalPages = 1,
  }) : super(Dio());

  Map<String, dynamic>? decisionBody;
  Map<String, dynamic>? batchBody;
  final bool canDecide;
  final bool failReloadAfterDecision;
  final int totalPages;
  bool decided = false;
  int requestedPage = 1;
  int capabilityCalls = 0;
  int detailCalls = 0;
  final List<Map<String, dynamic>> listQueries = [];

  Map<String, dynamic> get _inspection => const {
    'id': '10000000-0000-0000-0000-000000000001',
    'sourceReportId': '10000000-0000-0000-0000-000000000002',
    'sourceReportItemId': '10000000-0000-0000-0000-000000000003',
    'reportNo': 'RB202608280001',
    'sourcePlanItemId': '10000000-0000-0000-0000-000000000004',
    'planId': '10000000-0000-0000-0000-000000000005',
    'planNo': 'SJ202608280001',
    'executionSegmentId': '10000000-0000-0000-0000-000000000006',
    'warehouseId': '10000000-0000-0000-0000-000000000007',
    'goodsId': '10000000-0000-0000-0000-000000000008',
    'goodsCode': 'V51043',
    'goodsName': 'V5多功能三极插座E极插套(酸洗)',
    'colorId': '10000000-0000-0000-0000-000000000012',
    'colorName': '本色',
    'unitId': '10000000-0000-0000-0000-000000000009',
    'unitName': '件',
    'unitRate': 1,
    'reportedQty': 10,
    'passedQty': 0,
    'failedQty': 0,
    'remainingQty': 10,
    'authorizedInboundQty': 0,
    'status': 'PENDING',
    'reportMakerId': '10000000-0000-0000-0000-000000000010',
    'createdAt': '2026-08-28T05:00:00Z',
    'updatedAt': '2026-08-28T05:00:00Z',
  };

  Map<String, dynamic> get _resolvedInspection => {
    ..._inspection,
    'id': '20000000-0000-0000-0000-000000000001',
    'reportNo': 'RB-RESOLVED',
    'passedQty': 10,
    'remainingQty': 0,
    'authorizedInboundQty': 10,
    'status': 'RESOLVED',
  };

  Map<String, dynamic> get _cancelledInspection => {
    ..._inspection,
    'id': '30000000-0000-0000-0000-000000000001',
    'reportNo': 'RB-CANCELLED',
    'remainingQty': 0,
    'status': 'CANCELLED',
  };

  Map<String, dynamic> get _decidedInspection => {
    ..._inspection,
    'passedQty': 10,
    'remainingQty': 0,
    'authorizedInboundQty': 10,
    'status': 'RESOLVED',
  };

  List<Map<String, dynamic>> _itemsFor(String status) {
    return switch (status) {
      'RESOLVED' => [if (decided) _decidedInspection, _resolvedInspection],
      'CANCELLED' => [_cancelledInspection],
      'ALL' => [
        if (!decided) _inspection else _decidedInspection,
        _resolvedInspection,
        _cancelledInspection,
      ],
      _ => decided ? <Map<String, dynamic>>[] : [_inspection],
    };
  }

  Map<String, dynamic> _detail(String id) {
    return <Map<String, dynamic>>[
      if (!decided) _inspection else _decidedInspection,
      _resolvedInspection,
      _cancelledInspection,
    ].firstWhere((item) => item['id'] == id, orElse: () => _inspection);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/capability')) {
      capabilityCalls++;
      return {'canDecide': canDecide};
    }
    if (path.endsWith('/count')) return const {'count': 1};
    const listPath = '/production/quality-inspections';
    if (path.startsWith('$listPath/') && !path.endsWith('/decisions')) {
      detailCalls++;
      return _detail(path.substring('$listPath/'.length));
    }
    final effectiveQuery = Map<String, dynamic>.from(query ?? const {});
    listQueries.add(effectiveQuery);
    if (failReloadAfterDecision && decided) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.connectionError,
      );
    }
    requestedPage = (effectiveQuery['page'] as num?)?.toInt() ?? 1;
    final status = effectiveQuery['status']?.toString() ?? 'ACTIVE';
    final keyword = effectiveQuery['keyword']?.toString().toLowerCase() ?? '';
    final items = _itemsFor(status)
        .where((item) {
          if (keyword.isEmpty) return true;
          return [
            item['reportNo'],
            item['planNo'],
            item['goodsCode'],
            item['goodsName'],
            item['colorName'],
          ].whereType<String>().join(' ').toLowerCase().contains(keyword);
        })
        .toList(growable: false);
    final effectiveTotalPages = items.isEmpty ? 0 : totalPages;
    return {
      'items': items,
      'page': requestedPage,
      'size': 40,
      'total': items.isEmpty ? 0 : totalPages,
      'totalPages': effectiveTotalPages,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path == ApiEndpoints.productionQualityInspectionPassAll) {
      batchBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
      decided = true;
      return {
        'batchId': 'fqc-batch-1',
        'replay': false,
        'processedCount': 1,
        'items': [
          {
            'inspectionId': _inspectionId,
            'decisionEventId': '10000000-0000-0000-0000-000000000011',
            'inspection': _decidedInspection,
          },
        ],
      };
    }
    expect(path, '/production/quality-inspections/$_inspectionId/decisions');
    decisionBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
    decided = true;
    return {
      'decisionEventId': '10000000-0000-0000-0000-000000000011',
      'inspection': _decidedInspection,
      'replay': false,
    };
  }
}

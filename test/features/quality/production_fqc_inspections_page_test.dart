import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_inspections_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('production FQC supports a 375px idempotent PASS decision', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _FqcApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionQualityInspectionView,
            Perm.productionQualityInspectionApprove,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProductionFqcInspectionsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('生产成品质检'), findsOneWidget);
    expect(find.text('待检'), findsWidgets);
    expect(find.text('待处理 1 条'), findsOneWidget);
    expect(find.text('登记检验决定'), findsOneWidget);

    await tester.tap(find.text('登记检验决定'));
    await tester.pumpAndSettle();
    expect(find.text('登记生产成品质检决定'), findsOneWidget);
    expect(find.text('本次合格数量'), findsOneWidget);

    await tester.tap(find.text('确认决定'));
    await tester.pumpAndSettle();

    expect(api.decisionBody?['decision'], 'PASS');
    expect(api.decisionBody?['passQty'], 10);
    expect(api.decisionBody?['idempotencyKey'], startsWith('fqc-decision-'));
    expect(find.text('登记检验决定'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FQC approve authority outside SUB_QA remains read only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_FqcApi(canDecide: false)),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionQualityInspectionView,
            Perm.productionQualityInspectionApprove,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProductionFqcInspectionsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('登记检验决定'), findsNothing);
    expect(find.textContaining('当前为只读查看'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful decision stays locally resolved when reload fails', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _FqcApi(failReloadAfterDecision: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionQualityInspectionView,
            Perm.productionQualityInspectionApprove,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProductionFqcInspectionsPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记检验决定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认决定'));
    await tester.pumpAndSettle();

    expect(find.text('登记检验决定'), findsNothing);
    expect(find.textContaining('刷新失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FQC queue exposes server paging controls at 375px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _FqcApi(totalPages: 2);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionQualityInspectionView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProductionFqcInspectionsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第 1 / 2 页'), findsOneWidget);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(api.requestedPage, 2);
    expect(find.text('第 2 / 2 页'), findsOneWidget);
  });
}

class _FqcApi extends ApiClient {
  _FqcApi({
    this.canDecide = true,
    this.failReloadAfterDecision = false,
    this.totalPages = 1,
  }) : super(Dio());

  Map<String, dynamic>? decisionBody;
  final bool canDecide;
  final bool failReloadAfterDecision;
  final int totalPages;
  bool decided = false;
  int requestedPage = 1;

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

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/capability')) return {'canDecide': canDecide};
    if (path.endsWith('/count')) return const {'count': 1};
    if (failReloadAfterDecision && decided) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.connectionError,
      );
    }
    requestedPage = (query?['page'] as num?)?.toInt() ?? 1;
    final items = decided ? <Map<String, dynamic>>[] : [_inspection];
    return {
      'items': items,
      'page': requestedPage,
      'size': 40,
      'total': decided ? 0 : totalPages,
      'totalPages': totalPages,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    decisionBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
    decided = true;
    return {
      'decisionEventId': '10000000-0000-0000-0000-000000000011',
      'inspection': {
        ..._inspection,
        'passedQty': 10,
        'remainingQty': 0,
        'authorizedInboundQty': 10,
        'status': 'RESOLVED',
      },
      'replay': false,
    };
  }
}

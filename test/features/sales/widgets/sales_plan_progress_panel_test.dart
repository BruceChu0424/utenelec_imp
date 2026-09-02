import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/sales/widgets/sales_plan_progress_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('submitted analysis plan is not shown as unplanned', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          salesRepositoryProvider(
            SalesDocType.order,
          ).overrideWithValue(_analysisRepository()),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SalesPlanProgressPanel(orderId: 'order-1'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('已提交待批准'), findsOneWidget);
    expect(find.textContaining('已提交 4'), findsOneWidget);
    expect(find.textContaining('最后分析 2026-08-08 10:00:00'), findsOneWidget);
    expect(find.text('尚未排产'), findsNothing);
    expect(find.textContaining('生产计划已提交待批准'), findsOneWidget);
  });

  testWidgets(
    'sales execution-segment row opens its production plan deep link',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(
              body: SingleChildScrollView(
                child: SalesPlanProgressPanel(orderId: 'order-1'),
              ),
            ),
          ),
          GoRoute(
            path: '/production/plans/:id',
            builder: (context, state) => Scaffold(
              body: Text(
                '计划 ${state.pathParameters['id']} '
                '执行段 ${state.uri.queryParameters['executionSegmentId']}',
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            salesRepositoryProvider(
              SalesDocType.order,
            ).overrideWithValue(_repository()),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionPlanView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.text('SEG-001'));
      await tester.pumpAndSettle();

      expect(find.text('计划 plan-1 执行段 segment-1'), findsOneWidget);
    },
  );
}

SalesRepository _analysisRepository() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: [
            {
              'orderItemId': 'order-item-1',
              'goodsCode': 'P-001',
              'goodsName': '成品灯',
              'qty': 10,
              'plannedQty': 0,
              'producedQty': 0,
              'shippedQty': 0,
              'materialAnalysis': {
                'analysisId': 'analysis-1',
                'analysisStatus': 'PARTIAL',
                'requestedQty': 10,
                'readyNowQty': 4,
                'submittedQty': 4,
                'approvedQty': 0,
                'analyzedAt': '2026-08-08T10:00:00Z',
              },
              'links': <Map<String, dynamic>>[],
            },
          ],
        ),
      ),
    ),
  );
  return SalesRepository(ApiClient(dio), SalesDocType.order);
}

SalesRepository _repository() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: [
            {
              'orderItemId': 'order-item-1',
              'goodsCode': 'P-001',
              'goodsName': '成品灯',
              'qty': 10,
              'reservedQty': 0,
              'plannedQty': 10,
              'producedQty': 0,
              'shippedQty': 0,
              'chainStatus': 3,
              'links': [
                {
                  'planId': 'plan-1',
                  'planNo': 'SJ-001',
                  'planStatus': 1,
                  'allocatedQty': 10,
                  'producedQty': 0,
                  'inboundQty': 0,
                  'executionSegments': [
                    {
                      'executionSegmentId': 'segment-1',
                      'segmentCode': 'SEG-001',
                      'status': 'READY',
                      'allocatedQty': 10,
                      'reportedQty': 0,
                      'inboundQty': 0,
                    },
                  ],
                },
              ],
            },
          ],
        ),
      ),
    ),
  );
  return SalesRepository(ApiClient(dio), SalesDocType.order);
}

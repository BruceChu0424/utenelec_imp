import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/sales/widgets/sales_plan_progress_sheet.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'sales execution-segment row opens its production plan deep link',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Consumer(
              builder: (context, ref, child) => Scaffold(
                body: FilledButton(
                  onPressed: () =>
                      showPlanProgressSheet(context, ref, 'order-1'),
                  child: const Text('查看排产进度'),
                ),
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

      await tester.tap(find.text('查看排产进度'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SEG-001'));
      await tester.pumpAndSettle();

      expect(find.text('计划 plan-1 执行段 segment-1'), findsOneWidget);
    },
  );
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

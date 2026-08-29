import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets(
    'plan detail traceability card renders link chips and navigates to source documents',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var planReads = 0;
      final api = _traceApi(onPlanRead: () => planReads++);

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const ProductionPlanDetailPage(id: 'plan-1'),
          ),
          GoRoute(
            path: '/sales/orders/:id',
            builder: (context, state) =>
                Scaffold(body: Text('已打开销售订单 ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/warehouse/DRAW/:id',
            builder: (context, state) =>
                Scaffold(body: Text('已打开领料单 ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/warehouse/FINISHED_IN/:id',
            builder: (context, state) =>
                Scaffold(body: Text('已打开成品入库 ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/purchase/requests/:id',
            builder: (context, state) =>
                Scaffold(body: Text('已打开采购申请 ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/subcontract/applications/:id',
            builder: (context, state) =>
                Scaffold(body: Text('已打开委外申请 ${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            currentPermissionsProvider.overrideWithValue(const <String>{}),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(const Key('production-plan-traceability'));
      await tester.scrollUntilVisible(
        card,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(card, findsOneWidget);
      expect(find.text('来源销售订单'), findsOneWidget);
      expect(find.text('生产领料单'), findsOneWidget);
      expect(find.text('成品入库单'), findsOneWidget);
      expect(find.text('采购申请'), findsOneWidget);
      expect(find.text('委外申请'), findsOneWidget);
      expect(find.text('SO-2026-001'), findsOneWidget);
      expect(find.text('LL-2026-009'), findsOneWidget);
      expect(find.text('RK-2026-010'), findsOneWidget);
      expect(find.text('PR-2026-017'), findsOneWidget);
      expect(find.text('SA-2026-021'), findsOneWidget);

      await tester.tap(find.text('SO-2026-001'));
      await tester.pumpAndSettle();
      expect(find.text('已打开销售订单 so-1'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('LL-2026-009'));
      await tester.pumpAndSettle();
      expect(find.text('已打开领料单 draw-1'), findsOneWidget);

      final readsBeforeDrawReturn = planReads;
      router.pop();
      await tester.pumpAndSettle();
      expect(planReads, greaterThan(readsBeforeDrawReturn));
      await tester.tap(find.text('RK-2026-010'));
      await tester.pumpAndSettle();
      expect(find.text('已打开成品入库 inbound-1'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('PR-2026-017'));
      await tester.pumpAndSettle();
      expect(find.text('已打开采购申请 pr-1'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('SA-2026-021'));
      await tester.pumpAndSettle();
      expect(find.text('已打开委外申请 sa-1'), findsOneWidget);
    },
  );

  testWidgets('plan detail hides traceability card when no links', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _traceApi(includeLinks: false);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
        ],
        child: const MaterialApp(home: ProductionPlanDetailPage(id: 'plan-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('production-plan-traceability')), findsNothing);
  });
}

ApiClient _traceApi({bool includeLinks = true, VoidCallback? onPlanRead}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.path == '/production/plans/plan-1') {
          onPlanRead?.call();
        }
        final Object data = switch (request.path) {
          '/production/plans/plan-1' => <String, dynamic>{
            'id': 'plan-1',
            'billNo': 'SJ-1',
            'billDate': '2026-08-11',
            'status': 1,
            'allowedActions': const ['VIEW'],
            'items': <Map<String, dynamic>>[],
            if (includeLinks) ...{
              'traceSalesOrders': <Map<String, dynamic>>[
                {'id': 'so-1', 'billNo': 'SO-2026-001', 'kind': 'SALES_ORDER'},
              ],
              'traceMaterialDraws': <Map<String, dynamic>>[
                {'id': 'draw-1', 'billNo': 'LL-2026-009', 'kind': 'STOCK_DRAW'},
                {
                  'id': 'inbound-1',
                  'billNo': 'RK-2026-010',
                  'kind': 'FINISHED_IN',
                },
              ],
              'tracePurchaseRequests': <Map<String, dynamic>>[
                {
                  'id': 'pr-1',
                  'billNo': 'PR-2026-017',
                  'kind': 'PURCHASE_REQUEST',
                },
              ],
              'traceSubcontractApplications': <Map<String, dynamic>>[
                {
                  'id': 'sa-1',
                  'billNo': 'SA-2026-021',
                  'kind': 'SUBCONTRACT_APPLICATION',
                },
              ],
            },
          },
          '/production/plans/plan-1/mrp/planning-draft' => <String, dynamic>{},
          _ => <Map<String, dynamic>>[],
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

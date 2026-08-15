import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('production board child-plan row opens the child plan', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const ProductionBoardPage(initialTab: 1),
        ),
        GoRoute(
          path: '/production/plans/:id',
          builder: (context, state) =>
              Scaffold(body: Text('已打开计划 ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(_repository()),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('物料已齐 6 / 10（1/2 段） · 可开工'), findsOneWidget);
    await tester.tap(find.text('子计划 1 张（点开展示进度）'));
    await tester.pumpAndSettle();
    expect(find.text('物料待齐套（0/1 段）'), findsOneWidget);
    await tester.tap(find.text('SJ-CHILD'));
    await tester.pumpAndSettle();

    expect(find.text('已打开计划 child-plan-1'), findsOneWidget);
  });

  testWidgets('compact board child-plan stays usable at 1.3 text scale', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const ProductionBoardPage(initialTab: 1),
        ),
        GoRoute(
          path: '/production/plans/:id',
          builder: (context, state) =>
              Scaffold(body: Text('已打开计划 ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(_repository()),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final expand = find.text('子计划 1 张（点开展示进度）');
    await tester.ensureVisible(expand);
    final boardScroll = find.ancestor(
      of: expand,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    expect(boardScroll, findsOneWidget);
    await tester.drag(boardScroll, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(expand.hitTestable(), findsOneWidget);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('已报工 2'), findsOneWidget);
    expect(find.text('已入库 1 / 排产 5'), findsOneWidget);
    expect(find.text('物料待齐套（0/1 段）'), findsOneWidget);
    final childBill = find.text('SJ-CHILD');
    await tester.ensureVisible(childBill);
    await tester.drag(boardScroll, const Offset(0, -80));
    await tester.pumpAndSettle();
    final childRow = find.ancestor(
      of: childBill,
      matching: find.byType(InkWell),
    );
    expect(childRow, findsOneWidget);
    expect(tester.widget<InkWell>(childRow).onTap, isNotNull);
    expect(tester.getSize(childRow).height, greaterThanOrEqualTo(56));

    await tester.tap(childBill);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('已打开计划 child-plan-1'), findsOneWidget);
  });
}

ProductionPlanRepository _repository() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/production/plans/progress/summary' => {
            'count': 1,
            'sumQty': 10,
            'sumInbound': 0,
          },
          '/production/plans/progress/workshops' => <Map<String, dynamic>>[],
          '/production/plans/progress' => {
            'items': [
              {
                'planId': 'parent-plan-1',
                'billNo': 'SJ-PARENT',
                'lineCount': 1,
                'totalQty': 10,
                'inboundQty': 0,
                'materialState': 'PARTIAL',
                'materialSegmentCount': 2,
                'materialReadySegmentCount': 1,
                'materialTotalQty': 10,
                'materialReadyQty': 6,
                'materialPercent': 0.6,
                'canStartNow': true,
                'percent': 0,
                'closed': false,
                'subplans': [
                  {
                    'planId': 'child-plan-1',
                    'billNo': 'SJ-CHILD',
                    'status': 1,
                    'closed': false,
                    'totalQty': 5,
                    'reportedQty': 2,
                    'inboundQty': 1,
                    'materialState': 'WAITING',
                    'materialSegmentCount': 1,
                    'materialReadySegmentCount': 0,
                    'materialTotalQty': 5,
                    'materialReadyQty': 0,
                    'materialPercent': 0,
                    'canStartNow': false,
                    'percent': 0,
                  },
                ],
              },
            ],
            'page': 1,
            'size': 20,
            'total': 1,
            'totalPages': 1,
          },
          _ => <String, dynamic>{},
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
  return ProductionPlanRepository(ApiClient(dio));
}

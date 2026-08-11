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

    await tester.tap(find.text('子计划 1 张（点开展示进度）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SJ-CHILD'));
    await tester.pumpAndSettle();

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
                'percent': 0,
                'closed': false,
                'subplans': [
                  {
                    'planId': 'child-plan-1',
                    'billNo': 'SJ-CHILD',
                    'status': 1,
                    'closed': false,
                    'totalQty': 5,
                    'inboundQty': 0,
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

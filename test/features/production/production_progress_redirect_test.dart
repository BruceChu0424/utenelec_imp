// 2026-10-19 同页双路由收口契约：旧 /production/progress 深链（通知办理路由、
// 历史收藏）一律重定向到 /production/schedule?tab=progress，「进行中」预选语义
// 不变；该路由不再渲染页面（AI 功能目录随之只收 /production/schedule 一条）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/production_routes.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

/// 任意 GET 都回空页：进行中面板拉不到数据只显示空态，不影响路由断言。
class _EmptyApi extends ApiClient {
  _EmptyApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async => const {};
}

void main() {
  testWidgets('旧 /production/progress 深链重定向到 ?tab=progress 且渲染看板页', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(_EmptyApi()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'planner-1'),
        ),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionPlanView,
        }),
        fixedBadgeSummaryOverride(),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: RouteName.productionSchedule,
      routes: productionRoutes,
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    router.go(RouteName.productionProgress);
    await tester.pump(const Duration(milliseconds: 300));

    // 重定向落点：路径回主路由，tab=progress 保住「进行中」预选语义。
    final uri = router.routerDelegate.currentConfiguration.uri;
    expect(uri.path, RouteName.productionSchedule);
    expect(uri.queryParameters['tab'], 'progress');
    expect(find.byType(ProductionBoardPage), findsOneWidget);

    // 转发表本身不再渲染页面：无 builder，只有 redirect。
    final progress = productionRoutes.whereType<GoRoute>().firstWhere(
      (r) => r.path == RouteName.productionProgress,
    );
    expect(progress.builder, isNull);
    expect(progress.redirect, isNotNull);

    // 徽章轮询等周期定时器要先卸树再销毁容器，否则测试收尾报 pending timer。
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

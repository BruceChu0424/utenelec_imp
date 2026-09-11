// 生产计划单详情页「返回列表」显隐契约（2026-09-10 V543 审计）：
// 车间任务/财务审批等入口 push 进来的人可能没有 production_plan:view——
// 此前按钮 context.go('/production/plans') 会把他们带到 /access-denied；
// 现在按钮只对能进 /production/plans 的人渲染，并走返回键契约（pop 优先）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  for (final (permissions, expectation, reason) in [
    (
      const <String>{},
      findsNothing,
      '无 production_plan:view 的入口（车间任务等）不渲染「返回列表」',
    ),
    (
      const {Perm.productionPlanView},
      findsOneWidget,
      '持 production_plan:view 仍看到「返回列表」',
    ),
  ]) {
    testWidgets('plan detail back-to-list button: $reason', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _planApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWithValue(permissions),
          ],
          child: const MaterialApp(
            home: ProductionPlanDetailPage(id: 'plan-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('生产计划单详情'), findsOneWidget);
      expect(find.text('返回列表'), expectation, reason: reason);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('super admin always sees the back-to-list button', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _planApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          isSuperAdminProvider.overrideWithValue(true),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
        ],
        child: const MaterialApp(home: ProductionPlanDetailPage(id: 'plan-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('返回列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 已红冲（status=-1）、只读（allowedActions=VIEW）的计划：底部无业务动作
/// （已审单恒有「打印生产计划单」），只剩「返回列表」候选——正是显隐契约要锁定的分支。
ApiClient _planApi() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final Object data = switch (request.path) {
          '/production/plans/plan-1' => <String, dynamic>{
            'id': 'plan-1',
            'billNo': 'SJ-1',
            'billDate': '2026-08-11',
            'status': -1,
            'allowedActions': const ['VIEW'],
            'items': <Map<String, dynamic>>[],
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

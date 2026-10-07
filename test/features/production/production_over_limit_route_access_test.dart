import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';

void main() {
  testWidgets(
    'an approval-only planner can navigate from the queue to its detail',
    (tester) async {
      const actor = AppUser(
        id: 'planner',
        code: 'P1',
        name: '计划员',
        permissions: [Perm.productionPlanApprove],
      );
      final detail = RoutePath.productionOverLimitDisposition('case');
      final router = GoRouter(
        initialLocation: RouteName.productionOverLimitDispositions,
        redirect: (_, state) =>
            employeePermissionRedirect(actor, state.uri.toString()),
        routes: [
          GoRoute(
            path: RouteName.productionOverLimitDispositions,
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => context.go(detail),
                child: const Text('打开本批处置'),
              ),
            ),
          ),
          GoRoute(
            path: '${RouteName.productionOverLimitDispositions}/:id',
            builder: (_, _) => const Scaffold(body: Text('本批处置详情')),
          ),
          GoRoute(
            path: RouteName.accessDenied,
            builder: (_, _) => const Scaffold(body: Text('无权限')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开本批处置'));
      await tester.pumpAndSettle();
      expect(find.text('本批处置详情'), findsOneWidget);
      expect(find.text('无权限'), findsNothing);
    },
  );

  test('read-only detail permissions still cannot open the approval queue', () {
    for (final permission in [
      Perm.productionPlanView,
      Perm.productionExecutionView,
      Perm.productionDailyReportView,
    ]) {
      final actor = AppUser(
        id: 'reader',
        code: 'R1',
        name: '读者',
        permissions: [permission],
      );
      expect(
        employeePermissionRedirect(
          actor,
          RoutePath.productionOverLimitDisposition('case'),
        ),
        isNull,
      );
      expect(
        employeePermissionRedirect(
          actor,
          RouteName.productionOverLimitDispositions,
        ),
        RouteName.accessDenied,
      );
    }
    const none = AppUser(id: 'none', code: 'N1', name: '无授权');
    expect(
      employeePermissionRedirect(
        none,
        RoutePath.productionOverLimitDisposition('case'),
      ),
      RouteName.accessDenied,
    );
  });
}

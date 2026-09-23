// hub 守卫 = 子卡守卫并集(ADR-109「工作台权限管理总设计」/ permissions-04)。
//
// 过去 hub 入口的 any-of 清单是手写的：/warehouse 漏了库存查询、/finance 漏了应付结算，
// 只持这些码的人在 hub 页看得到卡片，却连 hub 都进不去。这里锁住三件事：
//   1. 每个 hub 的 any-of 守卫 ⊇ 其全部子卡 any-of 守卫的并集；
//   2. 只持某一张子卡码的人，经 GoRouter 真实跳转能到达 hub(不被重定向到无权页)；
//   3. 一张子卡都打不开的人，hub 与工作台入口都进不去。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/hub_catalog.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';

AppUser _userWith(Iterable<String> permissions) => AppUser(
  id: 'hub-test-user',
  code: 'H001',
  name: '入口测试用户',
  permissions: permissions.toList(growable: false),
);

/// 与 app_router 同一个守卫函数的最小 GoRouter：hub 与全部子卡落点各挂一个占位页。
GoRouter _router(AppUser user, String initial) {
  final paths = <String>{
    RouteName.accessDenied,
    RouteName.notFound,
    for (final entry in hubCardLocations.entries) ...[
      entry.key,
      for (final child in entry.value) hubCardPath(child),
    ],
  };
  return GoRouter(
    initialLocation: initial,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      if (loc == RouteName.accessDenied || loc == RouteName.notFound) {
        return null;
      }
      return employeePermissionRedirect(user, loc);
    },
    routes: [
      for (final path in paths)
        GoRoute(
          path: path,
          builder: (_, state) => Text('page:${state.matchedLocation}'),
        ),
    ],
  );
}

Future<String> _land(WidgetTester tester, AppUser user, String target) async {
  final router = _router(user, target);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router.routerDelegate.currentConfiguration.uri.path;
}

void main() {
  test('every hub guard covers the union of its card guards', () {
    for (final entry in hubCardLocations.entries) {
      final hubGuard = requiredAnyPermFor(entry.key)?.toSet();
      expect(hubGuard, isNotNull, reason: '${entry.key} 必须有入口守卫');
      for (final child in entry.value) {
        final childGuard = requiredAnyPermFor(child) ?? const <String>[];
        expect(
          hubGuard,
          containsAll(childGuard),
          reason: '${entry.key} 的入口守卫漏了子卡 $child 的码',
        );
      }
    }
  });

  testWidgets('a holder of any single card code reaches the hub via GoRouter', (
    tester,
  ) async {
    for (final entry in hubCardLocations.entries) {
      for (final child in entry.value) {
        final any = requiredAnyPermFor(child);
        if (any == null || any.isEmpty) continue;
        final user = _userWith({any.first, ...requiredAllPermsFor(child)});
        if (employeePermissionRedirect(user, child) != null) continue;
        expect(
          await _land(tester, user, entry.key),
          entry.key,
          reason: '只持 ${any.first} 的人能打开 $child，却进不了 ${entry.key}',
        );
      }
    }
  });

  testWidgets('the two historical gaps are closed', (tester) async {
    // 研发只持库存查看：能开即时库存，就必须能进仓库首页。
    expect(
      await _land(tester, _userWith({Perm.stockView}), RouteName.warehouse),
      RouteName.warehouse,
    );
    // 委外仓只持损耗索赔查看：能开应付结算，就必须能进钱流首页。
    expect(
      await _land(
        tester,
        _userWith({Perm.subcontractLossClaimView}),
        RouteName.finance,
      ),
      RouteName.finance,
    );
    expect(
      locationAllowedFor({Perm.stockView}, false, RouteName.warehouse),
      isTrue,
      reason: '工作台入口与路由守卫同源',
    );
  });

  testWidgets('without any card code the hub is denied', (tester) async {
    for (final hub in hubCardLocations.keys) {
      expect(
        await _land(tester, _userWith(const []), hub),
        RouteName.accessDenied,
        reason: hub,
      );
      expect(locationAllowedFor(const {}, false, hub), isFalse, reason: hub);
    }
  });

  test('hub cards ignore query parameters when matching guards', () {
    // 卡片落点常带 ?orderType= 等参数；过去带参数的路径被当成「登录即可」。
    expect(
      requiredAnyPermFor('${RouteName.financeAudits}?segment=shipment'),
      requiredAnyPermFor(RouteName.financeAudits),
    );
  });
}

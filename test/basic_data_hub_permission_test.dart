import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/pages/basic_data_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

Widget _app(Set<String> permissions, {bool superAdmin = false}) {
  return ProviderScope(
    overrides: [
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(superAdmin),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('zh'),
      home: BasicDataHubPage(),
    ),
  );
}

void main() {
  for (final navigation in ['go', 'platform']) {
    testWidgets('$navigation return permits the hub history action again', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var opened = 0;
      final router = GoRouter(
        initialLocation: RouteName.basicinfo,
        routes: [
          GoRoute(
            path: RouteName.basicinfo,
            builder: (_, _) => const BasicDataHubPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoHistory,
            builder: (_, _) {
              opened++;
              return const Scaffold(body: Text('history target'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue({Perm.goodsView}),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var visit = 0; visit < 2; visit++) {
        await tester.tap(find.text('修改历史'));
        await tester.pumpAndSettle();
        expect(find.text('history target'), findsOneWidget);
        if (navigation == 'go') {
          router.go(RouteName.basicinfo);
        } else {
          await router.routeInformationProvider.didPushRouteInformation(
            RouteInformation(uri: Uri.parse(RouteName.basicinfo)),
          );
        }
        await tester.pumpAndSettle();
      }
      expect(opened, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('basic-data hub only exposes authorized resources', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const {Perm.goodsView, Perm.currencyView}));

    expect(find.text('货品资料'), findsOneWidget);
    expect(find.text('币种资料'), findsOneWidget);
    expect(find.text('客户资料'), findsNothing);
    expect(find.text('账户资料'), findsNothing);
  });

  testWidgets('super admin sees every resource without explicit grants', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const {}, superAdmin: true));

    expect(find.text('货品资料'), findsOneWidget);
    expect(find.text('客户资料'), findsOneWidget);
    expect(find.text('供应商资料'), findsOneWidget);
    expect(find.text('账户资料'), findsOneWidget);
  });
}

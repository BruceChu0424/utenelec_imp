import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/document_scope_capability_overrides.dart';

const _families = [
  (
    name: 'purchase-order',
    template: '/purchase/orders/:id/edit',
    location: '/purchase/orders',
  ),
  (
    name: 'purchase-doc',
    template: '/purchase/:doc/:id/edit',
    location: '/purchase/receipts',
  ),
  (
    name: 'subcontract',
    template: '/subcontract/:seg/:id/edit',
    location: '/subcontract/orders',
  ),
  (name: 'sales', template: '/sales/:seg/:id/edit', location: '/sales/orders'),
  (
    name: 'stock',
    template: '/warehouse/:code/:id/edit',
    location: '/warehouse/OTHER_IN',
  ),
  (
    name: 'finance',
    template: '/finance/:seg/:id/edit',
    location: '/finance/expenses',
  ),
  (
    name: 'plan',
    template: '/production/plans/:id/edit',
    location: '/production/plans',
  ),
  (
    name: 'daily',
    template: '/production/daily-reports/:id/edit',
    location: '/production/daily-reports',
  ),
];

void main() {
  for (final family in _families) {
    testWidgets(
      '${family.name} actual route drops A late GET after changing to B',
      (tester) async {
        final api = _Api()..gates['doc-A'] = Completer<Map<String, dynamic>>();
        final router = await _mount(
          tester,
          api,
          family.template,
          family.location,
        );
        await tester.pump();
        await tester.pump();
        expect(api.detailReads, contains('doc-A'));
        router.go('${family.location}/doc-B/edit');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(
          api.detailReads,
          contains('doc-B'),
          reason: 'B needs its own authoritative initial read',
        );
        expect(find.text(_billLabel(family.name, 'doc-B')), findsOneWidget);
        api.gates['doc-A']!.complete(_detail('doc-A'));
        await tester.pumpAndSettle();
        expect(find.text(_billLabel(family.name, 'doc-A')), findsNothing);
        expect(find.text(_billLabel(family.name, 'doc-B')), findsOneWidget);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${family.name} actual route removes accepted A form while B loads',
      (tester) async {
        final api = _Api();
        final router = await _mount(
          tester,
          api,
          family.template,
          family.location,
        );
        await tester.pumpAndSettle();
        expect(find.text(_billLabel(family.name, 'doc-A')), findsOneWidget);
        api.gates['doc-B'] = Completer<Map<String, dynamic>>();
        router.go('${family.location}/doc-B/edit');
        await tester.pump();
        await tester.pump();
        expect(
          find.text(_billLabel(family.name, 'doc-A')),
          findsNothing,
          reason: 'A input must not be saved against widget.id B',
        );
        expect(api.detailReads, contains('doc-B'));
        api.gates['doc-B']!.complete(_detail('doc-B'));
        await tester.pumpAndSettle();
        expect(find.text(_billLabel(family.name, 'doc-B')), findsOneWidget);
        expect(find.text(_billLabel(family.name, 'doc-A')), findsNothing);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

String _billLabel(String family, String id) =>
    family == 'finance' ? '单据号：PRIVATE-$id' : 'PRIVATE-$id';

Future<GoRouter> _mount(
  WidgetTester tester,
  _Api api,
  String template,
  String location,
) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
      sharedPreferencesProvider.overrideWithValue(preferences),
      sessionProvider.overrideWith(_Session.new),
      isSuperAdminProvider.overrideWithValue(true),
      currentPermissionsProvider.overrideWithValue(const {
        Perm.salesOrderView,
        Perm.salesOrderEdit,
        Perm.purchaseOrderView,
        Perm.purchaseOrderEdit,
        Perm.purchaseReceiptView,
        Perm.purchaseReceiptEdit,
        Perm.subcontractOrderView,
        Perm.subcontractOrderEdit,
        Perm.stockDocView,
        Perm.stockDocEdit,
        Perm.financeExpenseView,
        Perm.financeExpenseEdit,
        Perm.productionPlanView,
        Perm.productionPlanEdit,
        Perm.productionDailyReportView,
        Perm.productionDailyReportEdit,
      }),
      writeAllDocumentScope(DocumentDataScope.sales),
      writeAllDocumentScope(DocumentDataScope.purchase),
      writeAllDocumentScope(DocumentDataScope.subcontract),
      writeAllDocumentScope(DocumentDataScope.stockDocument),
      writeAllDocumentScope(DocumentDataScope.finance),
      writeAllDocumentScope(DocumentDataScope.productionPlan),
    ],
  );
  addTearDown(container.dispose);
  final original = _findRoute(
    container.read(appRouterProvider).configuration.routes,
    template,
  )!;
  // Keep the application's actual builder and redirect. Only the surrounding
  // shell/auth navigation is omitted so this test observes resource identity.
  final router = GoRouter(
    initialLocation: '$location/doc-A/edit',
    routes: [
      GoRoute(
        path: original.path,
        builder: original.builder,
        redirect: original.redirect,
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  return router;
}

GoRoute? _findRoute(List<RouteBase> routes, String path) {
  for (final route in routes) {
    if (route is GoRoute && route.path == path) return route;
    final children = switch (route) {
      GoRoute() => route.routes,
      ShellRoute() => route.routes,
      StatefulShellRoute() =>
        route.branches.expand((branch) => branch.routes).toList(),
      _ => const <RouteBase>[],
    };
    final match = _findRoute(children, path);
    if (match != null) return match;
  }
  return null;
}

Map<String, dynamic> _detail(String id) => {
  'id': id,
  'billNo': 'PRIVATE-$id',
  'billDate': '2026-10-13',
  'remark': 'content-$id',
  'status': 0,
  'makerId': 'maker',
  'writable': true,
  'canEdit': true,
  'allowedActions': ['EDIT'],
  'docType': 'OTHER_IN',
  'version': 0,
  'rowVersion': 0,
  'items': <Map<String, dynamic>>[],
};

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'reader', code: 'reader', name: 'Reader'),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://example.invalid/api')));
  final gates = <String, Completer<Map<String, dynamic>>>{};
  final detailReads = <String>[];
  final writes = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/auth/me') {
      return {'id': 'reader', 'session': <String, dynamic>{}};
    }
    final id = path.split('/').last;
    if (id == 'doc-A' || id == 'doc-B') {
      detailReads.add(id);
      return gates[id]?.future ?? _detail(id);
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes.add(path);
    return _detail(path.split('/').last);
  }
}

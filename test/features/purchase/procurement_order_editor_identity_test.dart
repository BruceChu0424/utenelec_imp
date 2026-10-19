import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/buttons/uten_edit_floating_actions.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

final _reader = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'a'),
);

void main() {
  for (final language in ['en', 'ko']) {
    testWidgets(
      '$language invalid editor shows localized notice and returns through its original back button',
      (tester) async {
        final subcontract = language == 'ko';
        final id = ValueNotifier('order-a');
        addTearDown(id.dispose);
        final router = GoRouter(
          initialLocation: '/origin',
          routes: [
            GoRoute(
              path: '/origin',
              builder: (_, _) => const Scaffold(body: Text('Origin')),
            ),
            GoRoute(
              path: '/edit',
              builder: (_, _) => ValueListenableBuilder<String>(
                valueListenable: id,
                builder: (_, value, _) => subcontract
                    ? SubcontractOrderEditPage(id: value)
                    : PurchaseOrderEditPage(id: value),
              ),
            ),
          ],
        );
        final api = _Api(subcontract);
        final container = await _mount(
          tester,
          api,
          subcontract,
          routerOverride: router,
          locale: Locale(language),
        );
        router.push('/edit');
        await tester.pumpAndSettle();
        if (subcontract) {
          id.value = 'order-b';
        } else {
          container.read(_reader.notifier).state = const AuthenticatedScope(
            userId: 'b',
          );
        }
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'ko'
                ? '문서 또는 원본이 변경되었습니다. 이 페이지를 다시 열어 주세요.'
                : 'The signed-in account or server has changed. Reopen this page.',
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate((w) => w is UtenEditableGrid),
          findsNothing,
        );
        expect(find.byType(UtenEditFloatingActions), findsNothing);
        await tester.tap(find.byKey(const ValueKey('editor-identity-back')));
        await tester.pumpAndSettle();
        expect(find.text('Origin'), findsOneWidget);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final subcontract in [false, true]) {
    final name = subcontract ? 'subcontract' : 'purchase';
    testWidgets(
      '$name reused editor cannot write its accepted A form to route B',
      (tester) async {
        final api = _Api(subcontract);
        final router = _resourceRouter(subcontract);
        await _mount(tester, api, subcontract, routerOverride: router);
        await tester.pumpAndSettle();
        final oldState = tester.state(
          find.byType(
            subcontract ? SubcontractOrderEditPage : PurchaseOrderEditPage,
          ),
        );
        final save = tester
            .widget<UtenEditFloatingActions>(
              find.byType(UtenEditFloatingActions),
            )
            .onSave!;
        router.go(
          '${subcontract ? '/subcontract' : '/purchase'}/orders/order-b/edit',
        );
        await tester.pumpAndSettle();
        expect(
          identical(
            oldState,
            tester.state(
              find.byType(
                subcontract ? SubcontractOrderEditPage : PurchaseOrderEditPage,
              ),
            ),
          ),
          isTrue,
          reason:
              'the unkeyed template route intentionally reuses the same Element',
        );
        save();
        await tester.pumpAndSettle();
        if (tester.any(find.text('确认提交'))) {
          await tester.tap(find.text('确认提交'));
          await tester.pumpAndSettle();
        }
        expect(
          api.writes,
          isEmpty,
          reason: 'A inputs and callbacks must not update or submit order-b',
        );
        expect(
          find.byWidgetPredicate((w) => w is UtenEditableGrid),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$name reused editor hides a late A detail after the route changes to B',
      (tester) async {
        final api = _Api(subcontract)
          ..detailGate = Completer<Map<String, dynamic>>();
        final router = _resourceRouter(subcontract);
        await _mount(tester, api, subcontract, routerOverride: router);
        await tester.pump();
        await tester.pump();
        expect(api.detailCalls, 1);
        router.go(
          '${subcontract ? '/subcontract' : '/purchase'}/orders/order-b/edit',
        );
        await tester.pump();
        api.detailGate!.complete(_detail(id: 'order-a'));
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate((w) => w is UtenEditableGrid),
          findsNothing,
          reason:
              'the old detail must not fill an editor whose document identity changed',
        );
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('$name existing editor hides its late GET after A-B-A', (
      tester,
    ) async {
      final api = _Api(subcontract)
        ..detailGate = Completer<Map<String, dynamic>>();
      final container = await _mount(tester, api, subcontract);
      await tester.pump();
      await tester.pump();
      expect(api.detailCalls, 1);
      container.read(_reader.notifier).state = const AuthenticatedScope(
        userId: 'b',
      );
      await tester.pump();
      expect(find.text('登录身份或服务器已变化，请重新进入页面'), findsOneWidget);
      container.read(_reader.notifier).state = const AuthenticatedScope(
        userId: 'a',
      );
      api.detailGate!.complete(_detail());
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is UtenEditableGrid),
        findsNothing,
      );
      expect(find.text('登录身份或服务器已变化，请重新进入页面'), findsOneWidget);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$name correction save cannot submit finance under a different reader',
      (tester) async {
        final api = _Api(subcontract)
          ..updateGate = Completer<Map<String, dynamic>>();
        final container = await _mount(tester, api, subcontract);
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate((w) => w is UtenEditableGrid),
          findsOneWidget,
        );
        await tester.tap(find.text('保存并提交财务审核'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认提交'));
        await tester.pump();
        await tester.pump();
        expect(api.writes, [api.documentPath]);
        container.read(_reader.notifier).state = const AuthenticatedScope(
          userId: 'b',
        );
        await tester.pump();
        expect(find.text('登录身份或服务器已变化，请重新进入页面'), findsOneWidget);
        api.updateGate!.complete(_detail());
        await tester.pumpAndSettle();
        expect(
          api.writes,
          [api.documentPath],
          reason:
              'the accepted update must not dispatch finance-submit in the new session',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  bool subcontract, {
  GoRouter? routerOverride,
  Locale locale = const Locale('zh'),
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router =
      routerOverride ??
      GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => subcontract
                ? const SubcontractOrderEditPage(id: 'order-1')
                : const PurchaseOrderEditPage(id: 'order-1'),
          ),
        ],
      );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_reader)),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.purchaseOrderView,
          Perm.purchaseOrderEdit,
          Perm.purchaseOrderSubmitFinance,
          Perm.subcontractOrderView,
          Perm.subcontractOrderEdit,
          Perm.subcontractOrderSubmitFinance,
        }),
        writeAllDocumentScope(DocumentDataScope.purchase),
        writeAllDocumentScope(DocumentDataScope.subcontract),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

GoRouter _resourceRouter(bool subcontract) {
  final prefix = subcontract ? '/subcontract' : '/purchase';
  return GoRouter(
    initialLocation: '$prefix/orders/order-a/edit',
    routes: [
      GoRoute(
        path: '$prefix/orders/:id/edit',
        builder: (_, state) => subcontract
            ? SubcontractOrderEditPage(id: state.pathParameters['id'])
            : PurchaseOrderEditPage(id: state.pathParameters['id']),
      ),
      GoRoute(
        path: '$prefix/orders/:id',
        builder: (_, _) => const Scaffold(body: Text('Saved')),
      ),
    ],
  );
}

Map<String, dynamic> _detail({String id = 'order-1'}) => {
  'id': id,
  'makerId': 'maker-1',
  'billNo': 'PRIVATE-ORDER-A',
  'billDate': '2026-10-13',
  'status': 0,
  'canEdit': true,
  'supplierId': 's1',
  'settlementMethodId': 'settle-1',
  'currencyId': 'cny',
  'exchangeRate': 1,
  'taxRate': 0,
  'financeApproval': {'status': 'REJECTED'},
  'items': [
    {'id': 'i1', 'goodsId': 'g1', 'unitId': 'u1', 'qty': 4, 'price': 10},
  ],
};

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'a', code: 'a', name: 'A'),
  );
}

class _Api extends ApiClient {
  _Api(this.subcontract)
    : super(Dio(BaseOptions(baseUrl: 'https://example.invalid/api')));
  final bool subcontract;
  String get documentPath =>
      '${subcontract ? '/subcontract' : '/purchase'}/orders/order-1';
  Completer<Map<String, dynamic>>? detailGate;
  Completer<Map<String, dynamic>>? updateGate;
  final writes = <String>[];
  int detailCalls = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final prefix = '${subcontract ? '/subcontract' : '/purchase'}/orders/';
    if (path.startsWith(prefix) &&
        !path.substring(prefix.length).contains('/')) {
      detailCalls++;
      return detailGate == null
          ? _detail(id: path.substring(prefix.length))
          : detailGate!.future;
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('reference-methods/settlement')) {
      return [
        {'id': 'settle-1', 'code': 'M30', 'name': 'Monthly'},
      ];
    }
    if (path == ApiEndpoints.goodsLookup) {
      return [
        {'id': 'g1', 'name': 'Part', 'code': 'G1'},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes.add(path);
    return updateGate == null
        ? _detail(id: path.split('/').last)
        : updateGate!.future;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(path);
    return _detail();
  }
}

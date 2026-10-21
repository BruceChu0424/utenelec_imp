import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _reader = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'a'),
);
final _purchaseType = StateProvider<PurchaseDocType>(
  (_) => PurchaseDocType.order,
);

void main() {
  for (final subcontract in [false, true]) {
    final label = subcontract ? 'subcontract' : 'purchase';
    testWidgets('$label clears accepted private rows on A-B-A reader changes', (
      tester,
    ) async {
      final api = _Api(subcontract);
      final container = await _mount(tester, api, subcontract);
      await tester.pumpAndSettle();
      expect(find.text('PRIVATE-A'), findsOneWidget);
      final b = Completer<Map<String, dynamic>>();
      api.responses.add(b);
      container.read(_reader.notifier).state = const AuthenticatedScope(
        userId: 'b',
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.text('PRIVATE-A'),
        findsNothing,
        reason: 'old reader data must disappear before the new GET finishes',
      );
      final a = Completer<Map<String, dynamic>>();
      api.responses.add(a);
      container.read(_reader.notifier).state = const AuthenticatedScope(
        userId: 'a',
      );
      await tester.pump();
      await tester.pump();
      b.complete(_page('PRIVATE-B'));
      await tester.pump();
      expect(
        find.text('PRIVATE-B'),
        findsNothing,
        reason: 'A-B-A must invalidate the intermediate owner',
      );
      a.complete(_page('FRESH-A'));
      await tester.pumpAndSettle();
      expect(find.text('FRESH-A'), findsOneWidget);
      expect(find.text('PRIVATE-A'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label releases refresh when its reader is replaced', (
      tester,
    ) async {
      final api = _Api(subcontract);
      final container = await _mount(tester, api, subcontract);
      await tester.pumpAndSettle();
      final old = Completer<Map<String, dynamic>>();
      api.responses.add(old);
      await tester.tap(find.byType(UtenRefreshButton));
      await tester.pump();
      await tester.pump();
      expect(api.queries.length, 2);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      container.read(_reader.notifier).state = const AuthenticatedScope(
        userId: 'b',
      );
      api.nextBill = 'FRESH-B';
      await tester.pumpAndSettle();
      expect(find.text('FRESH-B'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        old.isCompleted,
        isFalse,
        reason:
            'replacing a reader releases only its wait, not the in-flight request',
      );
      old.complete(_page('STALE-A'));
      await tester.pumpAndSettle();
      expect(find.text('STALE-A'), findsNothing);
      expect(find.text('FRESH-B'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label releases refresh on logout without a replacement GET', (
      tester,
    ) async {
      final api = _Api(subcontract);
      final container = await _mount(tester, api, subcontract);
      await tester.pumpAndSettle();
      final old = Completer<Map<String, dynamic>>();
      api.responses.add(old);
      await tester.tap(find.byType(UtenRefreshButton));
      await tester.pump();
      await tester.pump();
      expect(api.queries.length, 2);
      container.read(_reader.notifier).state = null;
      await tester.pumpAndSettle();
      expect(
        api.queries.length,
        2,
        reason: 'logout must not start a new reader request',
      );
      expect(find.text('PRIVATE-A'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(old.isCompleted, isFalse);
      old.completeError(ApiException('FORBIDDEN', 'STALE LOGOUT ERROR'));
      await tester.pumpAndSettle();
      expect(find.text('STALE LOGOUT ERROR'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$label ignores old reader errors after the new list is loaded',
      (tester) async {
        final api = _Api(subcontract);
        final old = Completer<Map<String, dynamic>>();
        api.responses.add(old);
        final container = await _mount(tester, api, subcontract);
        await tester.pump();
        await tester.pump();
        container.read(_reader.notifier).state = const AuthenticatedScope(
          userId: 'b',
        );
        api.nextBill = 'FRESH-B';
        await tester.pumpAndSettle();
        expect(find.text('FRESH-B'), findsOneWidget);
        old.completeError(ApiException('FORBIDDEN', 'OLD READER ERROR'));
        await tester.pumpAndSettle();
        expect(find.text('OLD READER ERROR'), findsNothing);
        expect(find.text('FRESH-B'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'changing purchase document type clears supplier, bill and sort filters',
    (tester) async {
      final api = _Api(false);
      final container = await _mount(tester, api, false);
      await tester.pumpAndSettle();
      MasterDataTableView<dynamic> table() => tester.widget(
        find.byWidgetPredicate((w) => w is MasterDataTableView),
      );
      table().onFilterChanged('supplier', 'supplier-of-order');
      await tester.pumpAndSettle();
      table().onFilterChanged('billNo', 'PRIVATE-A');
      await tester.pumpAndSettle();
      table().onSortChange!('billNo', false);
      await tester.pumpAndSettle();
      expect(api.queries.last['supplierId'], 'supplier-of-order');
      container.read(_purchaseType.notifier).state = PurchaseDocType.receipt;
      await tester.pumpAndSettle();
      expect(api.paths.last, '/purchase/receipts');
      expect(api.queries.last.containsKey('supplierId'), isFalse);
      expect(api.queries.last.containsKey('billNo'), isFalse);
      expect(api.queries.last.containsKey('sort'), isFalse);
      expect(api.queries.last['page'], 1);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  bool subcontract,
) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Consumer(
          builder: (_, ref, _) => subcontract
              ? const SubcontractOrderWorkspacePage(initialStatus: 'draft')
              : PurchaseDocListPage(
                  docType: ref.watch(_purchaseType),
                  initialStatus: 'draft',
                ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_reader)),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.purchaseOrderView,
          Perm.purchaseReceiptView,
          Perm.subcontractOrderView,
        }),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

Map<String, dynamic> _page(String bill) => {
  'items': [
    {'id': bill, 'billNo': bill, 'billDate': '2026-10-13', 'status': 0},
  ],
  'page': 1,
  'size': 20,
  'total': 1,
  'totalPages': 1,
};

class _Api extends ApiClient {
  _Api(this.subcontract) : super(Dio());
  final bool subcontract;
  final responses = Queue<Completer<Map<String, dynamic>>>();
  final queries = <Map<String, dynamic>>[];
  final paths = <String>[];
  String nextBill = 'PRIVATE-A';

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/documents/status-counts') {
      return {'ACTIONABLE_DRAFT': 1, 'DRAFT': 1};
    }
    if (path == '/purchase/orders' ||
        path == '/purchase/receipts' ||
        path == '/subcontract/orders') {
      paths.add(path);
      queries.add(Map.of(query ?? {}));
      return responses.isEmpty
          ? _page(nextBill)
          : responses.removeFirst().future;
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

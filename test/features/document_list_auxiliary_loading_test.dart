import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';

void main() {
  final cases = <({String name, Widget page, String path, String partyKey})>[
    (
      name: '采购',
      page: const PurchaseDocListPage(
        docType: PurchaseDocType.order,
        initialStatus: 'draft',
      ),
      path: '/purchase/orders',
      partyKey: 'supplierId',
    ),
    (
      name: '销售',
      page: const SalesDocListPage(
        docType: SalesDocType.order,
        initialStatus: 'draft',
      ),
      path: '/sales/orders',
      partyKey: 'clientId',
    ),
    (
      name: '付款',
      page: const FinanceDocListPage(
        docType: FinanceDocType.payment,
        initialStatus: 'draft',
      ),
      path: '/finance/payments',
      partyKey: 'supplierId',
    ),
  ];
  for (final scenario in cases) {
    testWidgets(
      '${scenario.name} publishes nonempty rows before the party lookup and later updates names',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _Api(scenario.path, scenario.partyKey);
        final router = GoRouter(
          routes: [GoRoute(path: '/', builder: (_, _) => scenario.page)],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.purchaseOrderView,
                Perm.salesOrderView,
                Perm.financePaymentView,
              }),
              fixedBadgeSummaryOverride(),
            ],
            child: MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            ),
          ),
        );
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final tables = find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView,
        );
        expect(tables, findsOneWidget);
        final table = tester.widget<MasterDataTableView<dynamic>>(tables);
        expect(table.items, hasLength(1));
        expect(table.isLoading, isFalse);
        expect(find.text('DOC-FAST'), findsOneWidget);
        expect(api.partyReads, greaterThan(0));
        expect(api.names.isCompleted, isFalse);
        api.names.complete([
          {'id': 'party-1', 'name': '名称已补齐', 'status': '使用'},
        ]);
        await tester.pumpAndSettle();
        expect(find.text('名称已补齐'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _Api extends ApiClient {
  _Api(this.path, this.partyKey) : super(Dio());
  final String path;
  final String partyKey;
  int partyReads = 0;
  final names = Completer<List<Map<String, dynamic>>>();
  @override
  Future<Map<String, dynamic>> get(
    String route, {
    Map<String, dynamic>? query,
  }) async => route == path
      ? {
          'items': [
            {
              'id': 'doc-1',
              'billNo': 'DOC-FAST',
              'billDate': '2026-10-26',
              'status': 0,
              partyKey: 'party-1',
            },
          ],
          'page': 1,
          'size': 20,
          'total': 1,
          'totalPages': 1,
        }
      : {};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (const {
      '/master/clients/lookup',
      '/master/suppliers/lookup',
    }.contains(path)) {
      partyReads++;
      return names.future;
    }
    return [];
  }
}

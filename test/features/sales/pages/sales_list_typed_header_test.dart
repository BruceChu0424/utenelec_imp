import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _currency = '11111111-1111-4111-8111-111111111111';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/facets')) return {'billNo': <Object?>[]};
    if (path.endsWith('/stats')) return {};
    if (!path.startsWith('/sales/')) return {};
    queries.add({...?query});
    return {
      'items': [
        {
          'id': 'document',
          'billNo': 'TEST-01',
          'billDate': '2026-10-28',
          'deliverDate': '2026-11-02',
          'currencyId': _currency,
          'status': 1,
          'totalOriginal': '12345678901234.1234',
          'totalLocal': '12345678901234.1234',
          'totalOriginalText': '12345678901234.1234',
          'totalLocalText': '12345678901234.1234',
          'priceMasked': false,
        },
      ],
      'page': query?['page'] ?? 1,
      'size': 20,
      'total': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('currenc')
      ? [
          {'id': _currency, 'name': '美元', 'code': 'USD'},
        ]
      : [];
}

void main() {
  for (final kind in SalesDocType.values) {
    testWidgets(
      '${kind.name} date and visible amount headers query the server, retaining the history scope',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1700, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _Api();
        final router = GoRouter(
          initialLocation: '/sales/list',
          routes: [
            GoRoute(
              path: '/sales/list',
              builder: (_, _) =>
                  SalesDocListPage(docType: kind, initialHistory: true),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              apiClientProvider.overrideWithValue(api),
              localServerReachableProvider.overrideWith(
                (ref) =>
                    LocalServerReachabilityNotifier(preferences, web: true),
              ),
              salesMasterNameServiceProvider.overrideWithValue(
                SalesMasterNameService(api),
              ),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.salesOrderPriceView,
                'sales_order:view',
                'sales_quote:view',
                'sales_shipment:view',
                'sales_other_shipment:view',
                'sales_return:view',
              }),
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
        MasterDataTableView<SalesDocListItem> table() =>
            tester.widget(find.byType(MasterDataTableView<SalesDocListItem>));
        await tester.tap(find.text('日期'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('uten-column-keyword-input')),
          '2026-10-01..2026-10-28',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(api.queries.last['search.billDate'], '2026-10-01..2026-10-28');
        if (kind == SalesDocType.order) {
          expect(
            table().columns
                .singleWhere((column) => column.key == 'total')
                .columnSearchEnabled,
            isFalse,
          );
          table().onFilterChanged('currency', _currency);
          await tester.pumpAndSettle();
          expect(api.queries.last['currencyId'], _currency);
        }
        await tester.ensureVisible(
          find.text(kind == SalesDocType.order ? '订单金额' : '合计'),
        );
        await tester.tap(find.text(kind == SalesDocType.order ? '订单金额' : '合计'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('uten-column-keyword-input')),
          '>=12345678901234.1234',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(api.queries.last['search.total'], '>=12345678901234.1234');
        expect(api.queries.last['search.billDate'], '2026-10-01..2026-10-28');
        table().onSortChange!('total', false);
        await tester.pumpAndSettle();
        expect(api.queries.last['sort'], 'total');
        expect(api.queries.last['order'], 'desc');
        expect(api.queries.last['page'], 1);
        if (kind == SalesDocType.order || kind == SalesDocType.quote) {
          await tester.ensureVisible(find.text('交货'));
          await tester.tap(find.text('交货'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('uten-column-keyword-input')),
            '2026-11',
          );
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          expect(api.queries.last['search.deliver'], '2026-11');
        }
        if (kind == SalesDocType.order) {
          table().onFilterChanged('currency', null);
          await tester.pumpAndSettle();
          expect(api.queries.last.containsKey('search.total'), isFalse);
          expect(api.queries.last['sort'], isNull);
          expect(
            table().columns
                .singleWhere((column) => column.key == 'total')
                .columnSearchEnabled,
            isFalse,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

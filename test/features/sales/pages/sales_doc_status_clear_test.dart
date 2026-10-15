import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (const [
      '/sales/orders',
      '/sales/quotes',
      '/sales/returns',
    ].contains(path)) {
      queries.add(Map<String, dynamic>.of(query ?? const {}));
      return {
        'items': [
          {
            'id': 'document-1',
            'billNo': 'TEST-1',
            'billDate': '2026-10-12',
            'clientId': 'client-1',
            'status': 1,
          },
        ],
        'page': query?['page'] ?? 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

void main() {
  Future<_Api> pump(WidgetTester tester, SalesDocType type) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(false),
          draftCountsProvider.overrideWith((ref) => DraftCounts.empty),
          documentStatusCountsProvider.overrideWith((ref, scope) async => {}),
          fixedBadgeSummaryOverride(),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: SalesDocListPage(docType: type, initialStatus: 'draft'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  MasterDataTableView<dynamic> table(WidgetTester tester) => tester.widget(
    find.byWidgetPredicate((widget) => widget is MasterDataTableView),
  );

  testWidgets('clearing order status retains stage and currency filter', (
    tester,
  ) async {
    final api = await pump(tester, SalesDocType.order);
    expect(table(tester).facets.containsKey('status'), isFalse);
    expect(table(tester).filters['status'], isNull);
    await tester.tap(find.text('待生产'));
    await tester.pumpAndSettle();
    table(tester).onFilterChanged('currency', 'currency-1');
    await tester.pumpAndSettle();
    table(tester).onFilterChanged('status', '1');
    await tester.pumpAndSettle();
    expect(api.queries.last['status'], 1);
    final queryCount = api.queries.length;
    table(tester).onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(api.queries.length, greaterThan(queryCount));
    expect(api.queries.last.containsKey('status'), isFalse);
    expect(api.queries.last['chainGroup'], 'pending');
    expect(api.queries.last['currencyId'], 'currency-1');
    expect(table(tester).filters['status'], isNull);
    expect(tester.takeException(), isNull);
  });

  for (final type in [SalesDocType.quote, SalesDocType.returnDoc]) {
    testWidgets(
      '${type.name} clear status retains its active or history parent',
      (tester) async {
        final api = await pump(tester, type);
        table(tester).onFilterChanged(
          'status',
          type == SalesDocType.quote ? SalesQuoteStage.financeRejected : '1',
        );
        await tester.pumpAndSettle();
        final queryCount = api.queries.length;
        table(tester).onFilterChanged('status', null);
        await tester.pumpAndSettle();
        expect(api.queries.length, greaterThan(queryCount));
        expect(api.queries.last.containsKey('status'), isFalse);
        if (type == SalesDocType.quote) {
          expect(api.queries.last['bucket'], 'ACTIVE');
        } else {
          expect(api.queries.last.containsKey('bucket'), isFalse);
        }
        expect(api.queries.last.containsKey('stage'), isFalse);
        expect(api.queries.last.containsKey('dateFrom'), isFalse);
        expect(api.queries.last.containsKey('dateTo'), isFalse);
        expect(
          find.byKey(Key('sales-doc-history-time-${type.pathSegment}')),
          type == SalesDocType.quote ? findsNothing : findsOneWidget,
        );
        expect(table(tester).filters['status'], isNull);
        expect(table(tester).selectable, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

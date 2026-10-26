import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_account_flow_page.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_overview_page.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/finance/pages/finance_statement_page.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
import 'package:uten_imp/features/purchase/config/purchase_report_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_table_page.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_report_config.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_report_table_page.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_report_config.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void replace(Set<String> value) => state = value;
}

final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);

class _StatementPrefs extends FinanceStatementReportPrefsNotifier {
  @override
  ReportFilterPrefs build() =>
      const ReportFilterPrefs(extra: {'partyId': 'party-1'});
}

class _ReportApi extends ApiClient {
  _ReportApi() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  int pages = 2;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.contains('/reports/')) return {};
    final parameters = Map<String, dynamic>.of(query ?? {});
    queries.add(parameters);
    final page = parameters['page'] as int? ?? 1;
    final omitted = parameters['includeCount'] == false;
    return {
      'readScopeVersion': 'fixture-v1',
      'statisticsGeneratedAt': omitted ? null : '2026-10-25T00:00:00Z',
      'columns': [
        {'key': 'proof', 'label': '记录', 'type': 'text', 'width': 280},
      ],
      'rows': [
        {'id': '$page', 'proof': '服务端第$page页'},
      ],
      'page': page,
      'total': omitted ? -1 : (pages == 2 ? 51 : 4000),
      'totalPages': omitted ? -1 : pages,
      'facets': omitted
          ? <String, dynamic>{}
          : {
              'proof': [
                {'value': 'source', 'label': '原始来源', 'count': 51},
              ],
            },
      'totals': omitted
          ? <dynamic>[]
          : [
              {
                'key': 'qty',
                'label': '数量',
                'type': 'number',
                'groupKey': 'unit',
                'groups': [
                  {'unit': '箱', 'identity': 'box', 'value': '1000.00000001'},
                ],
              },
            ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/accounts/')) {
      return [
        {'id': 'account-1', 'name': '账户', 'code': 'A1'},
      ];
    }
    if (path.endsWith('/clients/dict') || path.endsWith('/suppliers/dict')) {
      return [
        {'id': 'party-1', 'name': '往来单位', 'code': 'P1'},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  Widget page,
  _ReportApi api,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'report-reader'),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        financeStatementReportPrefsProvider.overrideWith(_StatementPrefs.new),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(api.queries, isNotEmpty);
  return ProviderScope.containerOf(
    tester.element(find.byType(page.runtimeType)),
  );
}

void main() {
  final pages = <String, Widget>{
    'sales': const SalesReportPage(kind: SalesReportKind.summary),
    'purchase': const PurchaseReportTablePage(kind: PurchaseReportKind.summary),
    'subcontract': const SubcontractReportTablePage(
      kind: SubcontractReportKind.summary,
    ),
    'warehouse': const WarehouseReportTablePage(
      kind: WarehouseReportKind.summary,
    ),
    'production': const ProductionReportPage(
      kind: ProductionReportKind.summary,
    ),
    'finance': const FinanceReportTablePage(cardId: 'detail'),
    'statement': const FinanceStatementPage(),
    'account': const FinanceAccountFlowPage(),
    'ar-ap': const FinanceArApOverviewPage(),
    'customer drilldown': const SalesClientDetailDialog(
      docType: SalesReportDocType.order,
      docSeg: 'orders',
      clientId: 'client-1',
      currencyId: 'usd',
      clientName: '客户',
      dateFrom: '2026-10-01',
      dateTo: '2026-10-25',
    ),
  };
  for (final entry in pages.entries) {
    testWidgets(
      '${entry.key} paginates with server metadata and reloads on sorting',
      (tester) async {
        final api = _ReportApi();
        await _mount(tester, entry.value, api);
        final finder = find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<Map<String, dynamic>>,
        );
        MasterDataTableView<Map<String, dynamic>> table() =>
            tester.widget(finder);
        expect(table().totalPages, 2);
        expect(api.queries.first['includeCount'], isNull);
        await table().onPageChange!(2);
        await tester.pumpAndSettle();
        expect(api.queries.last, containsPair('includeCount', false));
        expect(api.queries.last, containsPair('includeFacets', false));
        expect(api.queries.last, containsPair('includeTotals', false));
        expect(table().currentPage, 2);
        expect(table().totalPages, 2);
        expect(find.text('服务端第2页'), findsOneWidget);
        if (const {
          'sales',
          'purchase',
          'subcontract',
          'warehouse',
          'production',
          'finance',
        }.contains(entry.key)) {
          expect(table().facets['proof']!.single.label, '原始来源');
        }
        final beforeReturn = api.queries.length;
        await table().onPageChange!(1);
        await tester.pumpAndSettle();
        expect(table().currentPage, 1);
        expect(table().totalPages, 2);
        expect(
          api.queries.length,
          beforeReturn,
          reason: 'completed report payload returns without RPC',
        );
        expect(find.text('服务端第1页'), findsOneWidget);
        if (entry.key != 'ar-ap') {
          expect(find.textContaining('1000'), findsWidgets);
        }
        final beforeSort = api.queries.length;
        table().onSortChange!('proof', false);
        await tester.pumpAndSettle();
        final sorted = api.queries
            .skip(beforeSort)
            .firstWhere((q) => q['page'] == 1);
        expect(sorted['includeCount'], isNull);
        expect(sorted['includeFacets'], isNull);
        expect(sorted['includeTotals'], isNull);
        expect(table().currentPage, 1);
        if (const {'statement', 'account', 'ar-ap'}.contains(entry.key)) {
          api.pages = 80;
          table().onRetry!();
          await tester.pumpAndSettle();
          final rows = table().rowsController!;
          rows.goToPage(79);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 20));
          await tester.pumpAndSettle();
          expect(rows.visiblePage, 79);
          expect(api.queries.map((q) => q['page']), containsAll([79, 78, 80]));
          final beforeRefresh = api.queries.length;
          table().onRetry!();
          await tester.pumpAndSettle();
          expect(
            api.queries.skip(beforeRefresh).first['page'],
            79,
            reason: 'manual report retry follows visible page rather than seed',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

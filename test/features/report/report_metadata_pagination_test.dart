import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
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
  bool previewClamp = false;
  bool headerFacts = false;
  bool failHeaders = false;
  final postBodies = <Object?>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.contains('/reports/')) return {};
    final parameters = Map<String, dynamic>.of(query ?? {});
    queries.add(parameters);
    if (failHeaders &&
        parameters.keys.any((key) => key.startsWith('f.search.'))) {
      throw StateError('fixture header read failed');
    }
    if (headerFacts) {
      final statement = path.contains('/statement/');
      return {
        'readScopeVersion': 'fixture-v1',
        'columns': statement
            ? [
                {'key': 'billDate', 'label': '开单日期', 'type': 'date'},
                {'key': 'currencyCode', 'label': '币别', 'type': 'text'},
                {'key': 'refNo', 'label': '关联单号', 'type': 'text'},
                {
                  'key': 'receiptOriginal',
                  'label': '冲减应收金额(外)',
                  'type': 'money',
                },
                {'key': 'balanceLocal', 'label': '应收余额(本)', 'type': 'money'},
              ]
            : [
                {'key': 'partyName', 'label': '往来单位', 'type': 'text'},
                {'key': 'phone', 'label': '电话', 'type': 'text'},
                {'key': 'receivable', 'label': '应收金额', 'type': 'money'},
              ],
        'columnSearchKeys': statement
            ? [
                'billDate',
                'currencyCode',
                'refNo',
                'receiptOriginal',
                'balanceLocal',
              ]
            : ['partyName', 'phone', 'receivable'],
        'facets': statement
            ? {
                'currencyCode': [
                  {
                    'value': '00000000-0000-4000-8000-000000000001',
                    'label': '美金',
                    'count': 1,
                  },
                ],
              }
            : <String, dynamic>{},
        'rows': [
          statement
              ? <String, dynamic>{
                  'billDate': '2026-10-12',
                  'currencyCode': '美金',
                  'refNo': 'TARGET',
                  'receiptOriginal': '0.123456789012',
                  'receiptOriginalExact': '0.123456789012',
                  'balanceLocal': '525',
                }
              : <String, dynamic>{
                  'partyName': '服务器往来单位',
                  'phone': '12345678',
                  'receivable': '30',
                  'receivableExact': '30',
                },
        ],
        'page': parameters['page'] ?? 1,
        'size': parameters['size'] ?? 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    final page = parameters['page'] as int? ?? 1;
    final omitted = parameters['includeCount'] == false;
    if (previewClamp && omitted && parameters['size'] == 500) {
      return {
        'readScopeVersion': 'fixture-v1',
        'page': page,
        'size': 2,
        'total': -1,
        'totalPages': -1,
        if (parameters['includeColumns'] != false)
          'columns': [
            {'key': 'proof', 'label': '记录', 'type': 'text'},
          ],
        'rows': [
          if (page == 1) ...[
            {'id': 'repeated-head', 'proof': '预览第一行'},
            {'id': 'repeated-head', 'proof': '预览第二行'},
          ],
          if (page == 2) {'id': 'repeated-head', 'proof': '预览第三行'},
        ],
      };
    }
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

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    postBodies.add(body);
    return get(path, query: query);
  }
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
  for (final statement in [false, true]) {
    testWidgets(
      '${statement ? 'party statement' : 'overview'} failed new header query keeps controls but publishes no old facts',
      (tester) async {
        final api = _ReportApi()..headerFacts = true;
        await _mount(
          tester,
          statement
              ? const FinanceStatementPage()
              : const FinanceArApOverviewPage(),
          api,
        );
        MasterDataTableView<Map<String, dynamic>> table() => tester.widget(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
        );
        expect(table().items, hasLength(1));
        api.failHeaders = true;
        final key = statement ? 'search.refNo' : 'search.partyName';
        table().onFilterChanged(key, '新条件失败');
        await tester.pumpAndSettle();
        expect(table().items, isEmpty);
        expect(table().filters[key], '新条件失败');
        expect(table().error, isNotNull);
        expect(table().summaryBar, isNull);
        api.failHeaders = false;
        table().onRetry!();
        await tester.pumpAndSettle();
        expect(table().items, hasLength(1));
        expect(table().error, isNull);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 800));
      },
    );
  }
  testWidgets(
    'party statement typed header uses exact selected currency and clears dependent conditions',
    (tester) async {
      final api = _ReportApi()..headerFacts = true;
      await _mount(tester, const FinanceStatementPage(), api);
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(
        table().columns
            .firstWhere((column) => column.key == 'receiptOriginal')
            .columnSearchEnabled,
        isFalse,
      );
      table().onFilterChanged(
        'currencyCode',
        '00000000-0000-4000-8000-000000000001',
      );
      await tester.pumpAndSettle();
      expect(
        table().columns
            .firstWhere((column) => column.key == 'receiptOriginal')
            .columnSearchEnabled,
        isTrue,
      );
      await tester.tap(find.text('冲减应收金额(外)'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '>=0.123456789012',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.queries.last['f.search.receiptOriginal'], '>=0.123456789012');
      expect(
        api.queries.last['f.currencyCode'],
        '00000000-0000-4000-8000-000000000001',
      );
      expect(table().items, hasLength(1));
      final print = tester.widget<UtenPrintPreviewButton>(
        find.byType(UtenPrintPreviewButton).first,
      );
      expect(
        print.exportQuery!['f.search.receiptOriginal'],
        '>=0.123456789012',
      );
      table().onFilterChanged('currencyCode', null);
      await tester.pumpAndSettle();
      expect(table().filters.containsKey('search.receiptOriginal'), isFalse);
      expect(
        api.queries.last.containsKey('f.search.receiptOriginal'),
        isFalse,
        reason: api.queries.toString(),
      );
      expect(
        table().columns
            .firstWhere((column) => column.key == 'receiptOriginal')
            .columnSearchEnabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 800));
    },
  );
  testWidgets(
    'overview phone headers keep private body criteria in list print and export scopes',
    (tester) async {
      final api = _ReportApi()..headerFacts = true;
      await _mount(tester, const FinanceArApOverviewPage(), api);
      await tester.tap(find.text('电话'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '1234 5678',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(
        api.queries.every((query) => !query.containsKey('f.search.phone')),
        isTrue,
      );
      expect(api.postBodies.last, {
        'columnSearch': {'phone': '1234 5678'},
      });
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.queryParams.containsKey('f.search.phone'), isFalse);
      expect(export.bodyParams, {
        'sensitiveFilter': {
          'columnSearch': {'phone': '1234 5678'},
        },
      });
      final print = tester.widget<UtenPrintPreviewButton>(
        find.byType(UtenPrintPreviewButton).first,
      );
      expect(print.exportBody, export.bodyParams);
      await tester.runAsync(print.loader);
      expect(api.postBodies.last, {
        'columnSearch': {'phone': '1234 5678'},
      });
      expect(
        api.queries.every((query) => !query.containsKey('f.search.phone')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 800));
    },
  );
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
      '${entry.key} print loader respects actual server pages and keeps the declared preview scope',
      (tester) async {
        final api = _ReportApi();
        await _mount(tester, entry.value, api);
        final button = tester.widget<UtenPrintPreviewButton>(
          find.byType(UtenPrintPreviewButton).first,
        );
        api.previewClamp = true;
        final before = api.queries.length;
        final preview = await tester.runAsync(button.loader);
        expect(preview!.rows, [
          ['预览第一行'],
          ['预览第二行'],
          ['预览第三行'],
        ]);
        expect(preview.rowIds, [
          'repeated-head',
          'repeated-head',
          'repeated-head',
        ]);
        final reads = api.queries.skip(before).toList();
        expect(reads.map((query) => query['page']), [1, 2, 3]);
        expect(reads.map((query) => query['size']), everyElement(500));
        expect(button.subtitle, contains('2000'));
        for (final filter
            in (button.exportQuery ?? const <String, dynamic>{}).entries) {
          expect(
            reads.first[filter.key],
            filter.value,
            reason: 'Print and export share ${filter.key}',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${entry.key} paginates with server metadata${entry.key == 'account' ? ' and retains balance chronology' : ' and reloads on sorting'}',
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
        if (entry.key == 'account') {
          expect(table().onSortChange, isNull);
          expect(table().columns.every((column) => !column.sortable), isTrue);
        } else {
          table().onSortChange!('proof', false);
          await tester.pumpAndSettle();
          final sorted = api.queries
              .skip(beforeSort)
              .firstWhere((q) => q['page'] == 1);
          expect(sorted['includeCount'], isNull);
          expect(sorted['includeFacets'], isNull);
          expect(sorted['includeTotals'], isNull);
          expect(table().currentPage, 1);
        }
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

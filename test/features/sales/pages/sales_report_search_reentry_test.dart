import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'returning to sales report clears search while retaining document type and dates',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final api = _SalesReportApi();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          salesSummaryReportPrefsProvider.overrideWith(_SalesReportPrefs.new),
        ],
      );
      var containerDisposed = false;
      addTearDown(() {
        if (!containerDisposed) container.dispose();
      });
      final router = GoRouter(
        initialLocation: '/sales/report/summary',
        routes: [
          GoRoute(
            path: '/sales/report/summary',
            builder: (_, _) =>
                const SalesReportPage(kind: SalesReportKind.summary),
          ),
          GoRoute(
            path: '/another-page',
            builder: (_, _) => const Scaffold(body: Text('Another page')),
          ),
        ],
      );
      addTearDown(router.dispose);
      final detach = attachPageResume(
        router,
        container.read(pageResumeProvider.notifier),
      );
      addTearDown(detach);
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      final toolbar = tester.widget<UtenFilterToolbar<SalesReportDocType>>(
        find.byType(UtenFilterToolbar<SalesReportDocType>),
      );
      toolbar.onSelectionChanged!(SalesReportDocType.shipment);
      await tester.pumpAndSettle();
      final unfilteredQuery = Map<String, dynamic>.of(api.queries.last);

      final input = find.descendant(
        of: find.byType(UtenSearchBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'CUSTOMER-123');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.queries.last, containsPair('keyword', 'CUSTOMER-123'));
      expect(api.paths.last, '/sales/reports/SHIPMENT/summary');

      // The report search and a table-column search can both be active. A
      // return must remove both or the fresh all-customer response stays hidden.
      await tester.tap(find.text('客户').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        'Filtered',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('客户：Filtered'), findsOneWidget);
      expect(find.text('Filtered customer'), findsOneWidget);

      final requestsBeforeFullscreen = api.queries.length;
      final fullscreenToggle = find.byKey(
        const ValueKey('master-table-fullscreen-toggle'),
      );
      await tester.tap(fullscreenToggle);
      await tester.pumpAndSettle();
      expect(find.text('客户：Filtered'), findsOneWidget);
      await tester.tap(fullscreenToggle);
      await tester.pumpAndSettle();
      expect(api.queries.length, requestsBeforeFullscreen);
      expect(tester.widget<TextField>(input).controller!.text, 'CUSTOMER-123');
      expect(find.text('客户：Filtered'), findsOneWidget);

      router.push<void>('/another-page');
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(api.queries.last, isNot(contains('keyword')));
      expect(api.queries.last['page'], 1);
      expect(api.queries.last['dateFrom'], unfilteredQuery['dateFrom']);
      expect(api.queries.last['dateTo'], unfilteredQuery['dateTo']);
      expect(api.paths.last, '/sales/reports/SHIPMENT/summary');
      expect(
        tester
            .widget<UtenFilterToolbar<SalesReportDocType>>(
              find.byType(UtenFilterToolbar<SalesReportDocType>),
            )
            .selected,
        {SalesReportDocType.shipment},
      );
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(table.items.single['clientName'], 'All customers');
      expect(find.text('All customers'), findsOneWidget);
      expect(find.text('客户：Filtered'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      containerDisposed = true;
    },
  );
}

class _SalesReportPrefs extends SalesSummaryReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs();

  @override
  void update(ReportFilterPrefs value) => state = value;
}

class _SalesReportApi extends ApiClient {
  _SalesReportApi() : super(Dio());

  final paths = <String>[];
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.startsWith('/sales/reports/')) {
      throw StateError('Unexpected GET $path');
    }
    paths.add(path);
    queries.add(Map<String, dynamic>.of(query ?? const {}));
    return {
      'columns': [
        {'key': 'clientName', 'label': '客户', 'type': 'text', 'width': 220},
      ],
      'rows': [
        {
          '__clientId': 'client-1',
          'clientName': query?['keyword'] == null
              ? 'All customers'
              : 'Filtered customer',
        },
      ],
      'facets': <String, dynamic>{},
      'page': 1,
      'size': 50,
      'total': 1,
      'totalPages': 1,
    };
  }
}

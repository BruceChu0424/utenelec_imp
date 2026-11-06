import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'sales report keeps new filter results when an old internal refresh batch arrives late',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final api = _DelayedSalesReportApi();
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentPermissionsProvider.overrideWithValue(const <String>{}),
          ],
          child: const MaterialApp(
            home: SalesReportPage(kind: SalesReportKind.summary),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Original customer'), findsOneWidget);

      final tableFinder = find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<Map<String, dynamic>>,
      );
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(tableFinder);

      expect(table().items, hasLength(51));
      expect(api.queries.map((query) => query['page']), [1, 2]);
      expect(api.queries.map((query) => query['size']), everyElement(50));
      // Complete reads have no user next-page control. A fresh read still owns
      // bounded internal batches, and its held continuation can lose a race.
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      api.holdOldContinuation = true;
      table().onRetry!();
      final eventTurn = tester.binding.clock.now();
      // The shared complete reader yields through a zero-duration timer.
      // Drive that event turn, without advancing the original time budget.
      await tester.pump(Duration.zero);
      expect(tester.binding.clock.now(), eventTurn);
      expect(api.queries.last['page'], 2);
      expect(api.queries.map((query) => query['page']), [1, 2, 1, 2]);
      expect(table().isRefreshing, isTrue);
      expect(table().items, hasLength(51));
      table().onFilterChanged('clientName', 'fresh-client');
      await tester.pump();
      expect(api.queries.last['page'], 1);
      expect(api.queries.last['f.clientName'], 'fresh-client');
      expect(table().items, isEmpty);

      api.filteredPage.complete(
        _reportResponse('New query customer', page: 1, totalPages: 1),
      );
      await tester.pumpAndSettle();
      expect(find.text('New query customer'), findsOneWidget);
      expect(table().currentPage, 1);

      api.oldSecondPage.complete(
        _reportResponse('Stale page two', page: 2, totalPages: 2),
      );
      await tester.pumpAndSettle();
      expect(table().items.single['clientName'], 'New query customer');
      expect(table().currentPage, 1);
      expect(table().isLoading, isFalse);
      expect(find.text('New query customer'), findsOneWidget);
      expect(find.text('Stale page two'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _DelayedSalesReportApi extends ApiClient {
  _DelayedSalesReportApi() : super(Dio());

  final queries = <Map<String, dynamic>>[];
  final oldSecondPage = Completer<Map<String, dynamic>>();
  final filteredPage = Completer<Map<String, dynamic>>();
  bool holdOldContinuation = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/reports/ORDER/summary') {
      throw StateError('unexpected GET $path');
    }
    final parameters = Map<String, dynamic>.of(query ?? const {});
    queries.add(parameters);
    if (parameters['f.clientName'] == 'fresh-client') {
      return filteredPage.future;
    }
    if (parameters['page'] == 2) {
      if (holdOldContinuation) return oldSecondPage.future;
      return _reportResponse('Initial tail customer', page: 2, totalPages: 2);
    }
    return _reportResponse('Original customer', page: 1, totalPages: 2);
  }
}

Map<String, dynamic> _reportResponse(
  String customer, {
  required int page,
  required int totalPages,
}) => {
  'columns': [
    {'key': 'clientName', 'label': '客户', 'type': 'text', 'width': 220},
  ],
  'rows': [
    {'__clientId': '$customer-$page-0', 'clientName': customer},
    if (totalPages > 1 && page == 1)
      for (var index = 1; index < 50; index++)
        {
          '__clientId': '$customer-$page-$index',
          'clientName': 'Original sibling customer $index',
        },
  ],
  'facets': <String, dynamic>{},
  'page': page,
  'size': 50,
  'total': totalPages == 1 ? 1 : 51,
  'totalPages': totalPages,
};

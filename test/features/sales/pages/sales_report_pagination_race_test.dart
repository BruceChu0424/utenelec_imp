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
    'sales report keeps new filter results when the previous page arrives late',
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

      // Exercise the real report's pagination callback while its response is
      // pending, then change its real server-side header filter.
      await tester.tap(find.text('下一页'));
      await tester.pump();
      expect(api.queries.last['page'], 2);
      expect(table().isLoading, isTrue);
      table().onFilterChanged('clientName', 'fresh-client');
      await tester.pump();
      expect(api.queries.last['page'], 1);
      expect(api.queries.last['f.clientName'], 'fresh-client');

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
    if (parameters['page'] == 2) return oldSecondPage.future;
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
    {'__clientId': customer, 'clientName': customer},
  ],
  'facets': <String, dynamic>{},
  'page': page,
  'size': 50,
  'total': totalPages == 1 ? 1 : 51,
  'totalPages': totalPages,
};

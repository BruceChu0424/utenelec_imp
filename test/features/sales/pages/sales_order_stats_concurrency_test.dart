import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final requests = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    if (path == '/sales/orders/stats') {
      final request = Completer<Map<String, dynamic>>();
      requests.add(request);
      return request.future;
    }
    return Future.value({});
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

void main() {
  testWidgets(
    'late order statistics cannot replace a newer refresh badge count',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _Api();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const SalesDocListPage(docType: SalesDocType.order),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            apiBaseUrlProvider.overrideWithValue(
              'http://sales-test.invalid/api',
            ),
            currentPermissionsProvider.overrideWithValue({Perm.salesOrderView}),
            sharedPreferencesProvider.overrideWithValue(preferences),
            fixedBadgeSummaryOverride(),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));
      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      expect(api.requests, hasLength(2));
      api.requests[1].complete({
        'pendingProduction': 2,
        'inProduction': 3,
        'shippable': 1,
        'monthDone': 4,
      });
      await tester.pumpAndSettle();
      UtenFilterToolbar<String> toolbar() => tester.widget(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenFilterToolbar<String> &&
              widget.segmentsKey == const Key('sales-doc-order-stages'),
        ),
      );
      expect(toolbar().segments.first.count, 2);
      api.requests[0].complete({
        'pendingProduction': 99,
        'inProduction': 88,
        'shippable': 77,
        'monthDone': 66,
      });
      await tester.pumpAndSettle();
      expect(toolbar().segments.first.count, 2);
      expect(toolbar().segments[1].count, 3);
      expect(toolbar().segments[2].count, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

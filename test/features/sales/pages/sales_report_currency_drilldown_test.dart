import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'order summary drills the same client into the selected currency only',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final api = _SalesReportApi();

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

      expect(find.text('USD'), findsOneWidget);
      expect(find.text('CNY'), findsOneWidget);

      await tester.tap(find.text('USD'));
      await tester.pumpAndSettle();

      expect(api.detailQueries, hasLength(1));
      expect(api.detailQueries.single, containsPair('clientId', 'client-1'));
      expect(
        api.detailQueries.single,
        containsPair('currencyId', 'currency-usd'),
      );

      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CNY'));
      await tester.pumpAndSettle();

      expect(api.detailQueries, hasLength(2));
      expect(api.detailQueries.last, containsPair('clientId', 'client-1'));
      expect(
        api.detailQueries.last,
        containsPair('currencyId', 'currency-cny'),
      );
      expect(api.detailQueries.map((query) => query['currencyId']).toSet(), {
        'currency-usd',
        'currency-cny',
      });
    },
  );
}

class _SalesReportApi extends ApiClient {
  _SalesReportApi() : super(Dio());

  final detailQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/reports/ORDER/summary') {
      return const <String, dynamic>{
        'columns': <Map<String, dynamic>>[
          {'key': 'clientName', 'label': '客户', 'type': 'text', 'width': 200},
          {'key': 'currencyCode', 'label': '币别', 'type': 'text', 'width': 80},
          {
            'key': 'totalAmount',
            'label': '订货总额',
            'type': 'money',
            'width': 120,
          },
        ],
        'rows': <Map<String, dynamic>>[
          {
            '__clientId': 'client-1',
            '__currencyId': 'currency-usd',
            'clientName': '甲客户',
            'currencyCode': 'USD',
            'totalAmount': 100,
          },
          {
            '__clientId': 'client-1',
            '__currencyId': 'currency-cny',
            'clientName': '甲客户',
            'currencyCode': 'CNY',
            'totalAmount': 720,
          },
        ],
        'facets': <String, dynamic>{},
        'page': 1,
        'size': 50,
        'total': 2,
        'totalPages': 1,
      };
    }
    if (path == '/sales/reports/ORDER/detail') {
      detailQueries.add(Map<String, dynamic>.of(query ?? const {}));
      return const <String, dynamic>{
        'columns': <Map<String, dynamic>>[],
        'rows': <Map<String, dynamic>>[],
        'facets': <String, dynamic>{},
        'page': 1,
        'size': 50,
        'total': 0,
        'totalPages': 1,
      };
    }
    throw StateError('unexpected GET $path');
  }
}

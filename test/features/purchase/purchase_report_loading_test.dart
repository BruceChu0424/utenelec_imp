import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final populated in [false, true]) {
    testWidgets(
      'purchase summary ${populated ? 'resolves only displayed names' : 'empty state skips master dictionaries'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final api = _ReportApi(populated);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(prefs),
            ],
            child: const MaterialApp(home: PurchaseReportPage()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          api.paths,
          unorderedEquals([
            ApiEndpoints.purchaseReportMonthly,
            ApiEndpoints.purchaseReportPending,
            if (populated) '/master/suppliers/lookup',
            if (populated) ApiEndpoints.goodsLookup,
          ]),
        );
        if (populated) {
          expect(find.text('测试货品'), findsOneWidget);
          expect(find.textContaining('测试供应商'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        api.unrelated.complete([]);
        await tester.pumpAndSettle();
      },
    );
  }
}

class _ReportApi extends ApiClient {
  _ReportApi(this.populated) : super(Dio());

  final bool populated;
  final paths = <String>[];
  final unrelated = Completer<List<Map<String, dynamic>>>();

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    if (path == ApiEndpoints.purchaseReportMonthly) {
      return populated
          ? [
              {
                'docType': 'ORDER',
                'ym': '2026-10-01',
                'goodsId': 'goods-1',
                'supplierId': 'supplier-1',
                'qty': 10,
                'amt': 20,
              },
            ]
          : [];
    }
    if (path == ApiEndpoints.purchaseReportPending) return [];
    if (path == '/master/suppliers/lookup') {
      return [
        {'id': 'supplier-1', 'name': '测试供应商', 'status': '使用'},
      ];
    }
    if (path == ApiEndpoints.goodsLookup) {
      return [
        {'id': 'goods-1', 'name': '测试货品'},
      ];
    }
    return unrelated.future;
  }
}

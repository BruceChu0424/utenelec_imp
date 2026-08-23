import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('customer prepayment report has a useful empty state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_EmptyReportApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeReportView,
            Perm.customerPrepaymentView,
            Perm.financeViewAll,
          }),
        ],
        child: const MaterialApp(
          home: FinanceReportTablePage(cardId: 'customer-prepayment'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('所选日期和客户暂无客户预收流水'), findsOneWidget);
  });
}

class _EmptyReportApi extends ApiClient {
  _EmptyReportApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {
    'columns': [
      {'key': 'eventDate', 'label': '记账日期', 'type': 'date'},
      {'key': 'eventNo', 'label': '资金单号', 'type': 'text'},
    ],
    'rows': <Object>[],
    'facets': <String, dynamic>{},
    'page': 1,
    'size': 50,
    'total': 0,
    'totalPages': 0,
  };
}

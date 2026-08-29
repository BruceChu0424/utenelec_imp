import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/widgets/sales_order_money_summary_card.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'money summary is hidden and never requested without permission',
    (tester) async {
      final api = _MoneySummaryApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const <String>{}),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SalesOrderMoneySummaryCard(salesOrderId: 'order-1'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('sales-order-money-summary')),
        findsNothing,
      );
      expect(find.textContaining('财务预收'), findsNothing);
      expect(api.getCount, 0);
    },
  );

  testWidgets('375px money summary displays server facts and source clearly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _MoneySummaryApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeViewAll,
            Perm.customerPrepaymentView,
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SalesOrderMoneySummaryCard(salesOrderId: 'order-1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('订单资金状态(财务只读)'), findsOneWidget);
    expect(find.textContaining('不读取历史订单订金快照'), findsOneWidget);
    expect(find.text('现金累计已收'), findsOneWidget);
    expect(find.text('预收累计到账'), findsOneWidget);
    expect(find.text('预收累计已抵'), findsOneWidget);
    expect(find.text('可用预收'), findsOneWidget);
    expect(find.text('正式应收未收'), findsOneWidget);
    expect(find.text('订单计划未收'), findsOneWidget);
    expect(find.text('40.12'), findsOneWidget);
    expect(find.text('30.0234'), findsOneWidget);
    expect(find.text('59.8566'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data ?? '').startsWith('001 '),
      ),
      findsNothing,
    );
    expect(api.getCount, 1);
  });

  testWidgets('money summary error offers retry', (tester) async {
    final api = _MoneySummaryApi(failFirst: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeViewAll,
            Perm.customerPrepaymentView,
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SalesOrderMoneySummaryCard(salesOrderId: 'order-1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('订单资金汇总加载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('订单资金状态(财务只读)'), findsOneWidget);
    expect(find.text('现金累计已收'), findsOneWidget);
    expect(api.getCount, 2);
  });
}

class _MoneySummaryApi extends ApiClient {
  _MoneySummaryApi({this.failFirst = false}) : super(Dio());

  final bool failFirst;
  int getCount = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    getCount++;
    if (failFirst && getCount == 1) throw StateError('offline');
    return _summary;
  }
}

const _summary = <String, dynamic>{
  'salesOrderId': 'order-1',
  'orderBillNo': 'XD-001',
  'clientId': 'client-1',
  'currencyId': 'currency-usd',
  'currencyCode': '001',
  'orderTotalOriginal': '100.0000',
  'orderTotalLocal': '720.0000',
  'formalArOriginal': '80.0000',
  'formalArLocal': '576.0000',
  'cashReceivedOriginal': '40.1200',
  'cashReceivedLocal': '288.8640',
  'writeOffOriginal': '0.0234',
  'writeOffLocal': '0.1685',
  'prepaymentReceivedOriginal': '100.1234',
  'prepaymentReceivedLocal': '720.8885',
  'prepaymentAppliedOriginal': '30.0234',
  'prepaymentAppliedSourceBookLocal': '216.1685',
  'prepaymentAppliedTargetBookLocal': '216.1685',
  'prepaymentExchangeDifferenceLocal': '0.0000',
  'prepaymentAvailableOriginal': '70.1000',
  'prepaymentAvailableLocal': '504.7200',
  'arOutstandingOriginal': '9.8566',
  'arOutstandingLocal': '70.9675',
  'unrecognizedOrderOriginal': '0.0000',
  'unrecognizedOrderLocal': '0.0000',
  'plannedRemainingOriginal': '59.8566',
  'overpaidOriginal': '0.0000',
  'hasUnallocated': false,
  'unallocatedReceiptLines': <Object>[],
  'warnings': <Object>[],
};

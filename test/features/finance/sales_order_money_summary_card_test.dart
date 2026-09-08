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
    // 折叠态（默认）：只显示订单总额 + 已收金额，明细收起。
    expect(find.text('订单资金状态'), findsOneWidget);
    expect(find.text('订单总额'), findsOneWidget);
    expect(find.text('客户已付'), findsOneWidget);
    expect(find.text('40.12'), findsOneWidget);
    expect(find.textContaining('银行实际到账以账户流水为准'), findsNothing);
    expect(find.text('其中：预收到账'), findsNothing);

    // 展开明细：来源脚注 + 重命名后的口径齐备；常显摘要行保留
    // （已收金额在摘要与明细各出现一次）。
    await tester.tap(
      find.byKey(const ValueKey('sales-order-money-summary-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('银行实际到账以账户流水为准'), findsOneWidget);
    expect(find.text('其中：预收到账'), findsOneWidget);
    expect(find.text('预收已抵扣'), findsOneWidget);
    expect(find.text('可用预收余额'), findsOneWidget);
    expect(find.text('当前还需收款'), findsOneWidget);
    expect(find.text('预计还需新收'), findsOneWidget);
    expect(find.text('30.0234'), findsNWidgets(2));
    expect(find.text('59.8566'), findsOneWidget);
    expect(find.text('40.12'), findsNWidgets(2));
    // 超收为 0 时不再显示「超收金额」派生项。
    expect(find.text('超收金额'), findsNothing);
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
    expect(find.text('订单资金状态'), findsOneWidget);
    expect(find.text('客户已付'), findsOneWidget);
    expect(api.getCount, 2);
  });

  testWidgets(
    'paid return exposes the customer balance without presenting it as a completed refund',
    (tester) async {
      final api = _MoneySummaryApi(
        data: {
          ..._summary,
          'formalArOriginal': '100.0000',
          'cashReceivedOriginal': '100.0000',
          'returnCreditOriginal': '100.0000',
          'unusedReturnCreditOriginal': '100.0000',
          'netReceivableOriginal': '0.0000',
          'customerPendingBalanceOriginal': '100.0000',
          'unrecognizedOrderOriginal': '0.0000',
          'plannedRemainingOriginal': '0.0000',
        },
      );
      await _pumpSummary(tester, api);
      expect(find.text('退货金额'), findsOneWidget);
      expect(find.text('当前还需收款'), findsOneWidget);
      expect(find.text('客户待处理余额'), findsOneWidget);
      expect(find.text('待处理余额需财务确认抵扣或退款，不表示已退款。'), findsOneWidget);
      expect(find.text('已退款金额'), findsNothing);
      expect(find.text('0.00'), findsOneWidget);
    },
  );

  testWidgets(
    'applied return balance is distinct from the displayed total returned amount',
    (tester) async {
      final api = _MoneySummaryApi(
        data: {
          ..._summary,
          'returnCreditOriginal': '50.0000',
          'unusedReturnCreditOriginal': '0.0000',
          'netReceivableOriginal': '50.0000',
          'unrecognizedOrderOriginal': '150.0000',
          'plannedRemainingOriginal': '200.0000',
        },
      );
      await _pumpSummary(tester, api);
      await tester.tap(
        find.byKey(const ValueKey('sales-order-money-summary-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('尚未处理的退货金额'), findsOneWidget);
      expect(find.text('150.00'), findsOneWidget);
      expect(find.text('200.00'), findsOneWidget);
      expect(find.text('客户待处理余额'), findsNothing);
    },
  );
}

Future<void> _pumpSummary(WidgetTester tester, _MoneySummaryApi api) async {
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
}

class _MoneySummaryApi extends ApiClient {
  _MoneySummaryApi({this.failFirst = false, this.data = _summary})
    : super(Dio());

  final bool failFirst;
  final Map<String, dynamic> data;
  int getCount = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    getCount++;
    if (failFirst && getCount == 1) throw StateError('offline');
    return data;
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
  'prepaymentReceivedOriginal': '30.0234',
  'prepaymentReceivedLocal': '216.1685',
  'prepaymentAppliedOriginal': '30.0234',
  'prepaymentAppliedSourceBookLocal': '216.1685',
  'prepaymentAppliedTargetBookLocal': '216.1685',
  'prepaymentExchangeDifferenceLocal': '0.0000',
  'prepaymentAvailableOriginal': '0.0000',
  'prepaymentAvailableLocal': '0.0000',
  'arOutstandingOriginal': '39.8566',
  'arOutstandingLocal': '286.9675',
  'unrecognizedOrderOriginal': '20.0000',
  'unrecognizedOrderLocal': '0.0000',
  'plannedRemainingOriginal': '59.8566',
  'overpaidOriginal': '0.0000',
  'hasUnallocated': false,
  'unallocatedReceiptLines': <Object>[],
  'warnings': <Object>[],
  'returnCreditOriginal': '0.0000',
  'unusedReturnCreditOriginal': '0.0000',
  'netReceivableOriginal': '39.8566',
  'customerPendingBalanceOriginal': '0.0000',
  'positionComplete': true,
};

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/customer_prepayment.dart';
import 'package:uten_imp/features/finance/widgets/customer_prepayment_apply_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'incomplete prepayment pages use the additive local-currency summary',
    () {
      const singleCurrencyItem = CustomerPrepaymentItem(
        ledgerId: 'prepayment-1',
        currencyId: 'currency-cny',
      );
      const completePage = CustomerPrepaymentPage(
        summary: CustomerPrepaymentSummary(),
        items: [singleCurrencyItem],
        page: 1,
        size: 100,
        total: 1,
        totalPages: 1,
      );
      const incompletePage = CustomerPrepaymentPage(
        summary: CustomerPrepaymentSummary(),
        items: [singleCurrencyItem],
        page: 1,
        size: 100,
        total: 101,
        totalPages: 2,
      );

      expect(customerPrepaymentSummaryUsesLocalCurrency(completePage), isFalse);
      expect(
        customerPrepaymentSummaryUsesLocalCurrency(incompletePage),
        isTrue,
      );
    },
  );

  testWidgets('375px applies exact prepayment and can reverse the result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _ApplyPanelApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeViewAll,
            Perm.customerPrepaymentView,
            Perm.customerPrepaymentApply,
            Perm.customerPrepaymentReverse,
          }),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showCustomerPrepaymentApplyPanel(
                  context,
                  clientId: 'client-1',
                ),
                child: const Text('打开预收'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开预收'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('应用客户预收'), findsOneWidget);
    expect(find.textContaining('人民币'), findsOneWidget);
    expect(find.textContaining('美金'), findsOneWidget);
    expect(find.text('累计预收(本币)'), findsOneWidget);
    expect(find.text('1080.8885'), findsOneWidget);
    expect(find.textContaining(' · 001'), findsNothing);
    expect(find.textContaining(' · 002'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byKey(
          const ValueKey('customer-prepayment-prepayment-ledger-1'),
        ),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(UtenButton, '选择应收'));
    await tester.pumpAndSettle();

    expect(find.text('引用应收'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('ar-ap-select-ar-ledger-1')));
    await tester.pump();
    final amountField = tester.widget<TextField>(
      find.byKey(const ValueKey('ar-ap-amount-ar-ledger-1')),
    );
    expect(amountField.controller?.text, '65.1234');
    await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('AR-001'), findsOneWidget);
    expect(find.textContaining('001 65.1234'), findsNothing);
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '应用原因(必填)',
      ),
      '客户确认预收用于订单 XD-001',
    );
    await tester.tap(find.byKey(const ValueKey('customer-prepayment-apply')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('预收已成功应用'), findsOneWidget);
    expect(find.textContaining('batch-1'), findsWidgets);
    final applyBody = api.posts.first.body;
    expect(applyBody?['sourceLedgerId'], 'prepayment-ledger-1');
    final target = Map<String, dynamic>.from(
      (applyBody?['targets'] as List).single as Map,
    );
    expect(target['receivableLedgerId'], 'ar-ledger-1');
    expect(target['salesOrderId'], 'order-1');
    expect(target['amountOriginal'], '65.1234');

    await tester.tap(find.byKey(const ValueKey('customer-prepayment-reverse')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '反转原因(必填)',
      ),
      '客户要求改用其它订单',
    );
    await tester.tap(find.text('确认反转'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      api.posts.last.path,
      '/finance/customer-prepayment-offsets/batch-1/reverse',
    );
    expect(api.posts.last.body?['expectedVersion'], 2);
    expect(find.text('本次抵销已反转'), findsOneWidget);
  });
}

class _PostCall {
  const _PostCall(this.path, this.body);

  final String path;
  final Map<String, dynamic>? body;
}

class _ApplyPanelApi extends ApiClient {
  _ApplyPanelApi() : super(Dio());

  final posts = <_PostCall>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/customer-prepayments') return _prepayments;
    if (path == '/finance/ar-ap') return _openReceivables;
    return const <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    final json = Map<String, dynamic>.from(body! as Map);
    posts.add(_PostCall(path, json));
    final reversed = path.endsWith('/reverse');
    return {
      'batchId': 'batch-1',
      'rowVersion': reversed ? 3 : 2,
      'status': reversed ? 'REVERSED' : 'APPLIED',
      'effectiveDate': '2026-08-22',
      'allocations': const <Object>[],
    };
  }
}

const _prepayments = <String, dynamic>{
  'summary': {
    'receivedOriginal': '100.1234',
    'receivedLocal': '1080.8885',
    'appliedOriginal': '30.0234',
    'appliedSourceBookLocal': '216.1685',
    'availableOriginal': '70.1000',
    'availableLocal': '864.7200',
  },
  'items': [
    {
      'ledgerId': 'prepayment-ledger-1',
      'receiptId': 'receipt-1',
      'billNo': 'YS-001',
      'billDate': '2026-08-20',
      'salesOrderId': 'source-order-1',
      'clientId': 'client-1',
      'clientName': '甲客户',
      'currencyId': 'currency-cny',
      'currencyCode': '001',
      'currencyName': '人民币',
      'exchangeRate': '7.200000',
      'receivedOriginal': '100.1234',
      'receivedLocal': '720.8885',
      'appliedOriginal': '30.0234',
      'appliedSourceBookLocal': '216.1685',
      'availableOriginal': '70.1000',
      'availableLocal': '504.7200',
    },
    {
      'ledgerId': 'prepayment-ledger-2',
      'receiptId': 'receipt-2',
      'billNo': 'YS-002',
      'billDate': '2026-08-19',
      'clientId': 'client-1',
      'clientName': '甲客户',
      'currencyId': 'currency-usd',
      'currencyCode': '002',
      'currencyName': '美金',
      'exchangeRate': '7.200000',
      'receivedOriginal': '50.0000',
      'receivedLocal': '360.0000',
      'appliedOriginal': '0.0000',
      'appliedSourceBookLocal': '0.0000',
      'availableOriginal': '50.0000',
      'availableLocal': '360.0000',
    },
  ],
  'page': 1,
  'size': 100,
  'total': 2,
  'totalPages': 1,
};

const _openReceivables = <String, dynamic>{
  'items': [
    {
      'id': 'ar-ledger-1',
      'direction': 'AR',
      'openItemKind': 'RECEIVABLE',
      'sourceDocType': 'SALES_SHIPMENT',
      'sourceDocId': 'shipment-1',
      'sourceDocNo': 'XSCK-001',
      'billNo': 'AR-001',
      'billDate': '2026-08-22',
      'clientId': 'client-1',
      'currencyId': 'currency-cny',
      'currencyCode': '001',
      'amountOriginal': 100,
      'amountReceivedOriginal': 20,
      'amountWriteOffOriginal': 5,
      'prepaymentAppliedOriginal': '9.8766',
      'amountBalanceOriginal': 65.1234,
      'authoritativeSalesOrderId': 'order-1',
      'salesOrderIds': ['order-1'],
      'salesOrderNos': ['XD-001'],
      'settled': false,
    },
  ],
  'page': 1,
  'size': 50,
  'total': 1,
  'totalPages': 1,
};

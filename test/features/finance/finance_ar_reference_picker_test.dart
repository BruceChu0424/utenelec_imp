import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_decimal.dart';
import 'package:uten_imp/features/finance/widgets/ar_ap_picker_dialog.dart';

void main() {
  for (final scenario in [
    (
      name: 'positive legacy direct receipt is an ordinary settlement target',
      kind: 'LEGACY_UNVERIFIED',
      balance: 12,
      currency: 'currency-usd',
      allowed: true,
    ),
    (
      name: 'negative legacy balance is not a credit',
      kind: 'LEGACY_UNVERIFIED',
      balance: -12,
      currency: 'currency-usd',
      allowed: false,
    ),
    (
      name: 'zero legacy balance cannot be referenced',
      kind: 'LEGACY_UNVERIFIED',
      balance: 0,
      currency: 'currency-usd',
      allowed: false,
    ),
    (
      name: 'unknown original legacy balance stays unavailable',
      kind: 'LEGACY_UNVERIFIED',
      balance: null,
      currency: 'currency-usd',
      allowed: false,
    ),
    (
      name: 'unknown legacy currency stays unavailable',
      kind: 'LEGACY_UNVERIFIED',
      balance: 12,
      currency: null,
      allowed: false,
    ),
    (
      name: 'native prepayment still requires apply prepayment',
      kind: 'CUSTOMER_PREPAYMENT',
      balance: 12,
      currency: 'currency-usd',
      allowed: false,
    ),
  ]) {
    testWidgets(scenario.name, (tester) async {
      final api = _ArReferenceApi(
        overrides: {
          'openItemKind': scenario.kind,
          'sourceDocType': 'DIRECT_RECEIPT',
          'amountBalanceOriginal': scenario.balance,
          'currencyId': scenario.currency,
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: FilledButton(
                  onPressed: () => showArApPickerDialog(
                    context,
                    ref,
                    direction: 'AR',
                    partyId: 'client-1',
                  ),
                  child: const Text('打开引用'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开引用'));
      await tester.pumpAndSettle();
      final checkbox = tester.widget<Checkbox>(
        find.byKey(const ValueKey('ar-ap-select-ledger-1')),
      );
      expect(checkbox.onChanged != null, scenario.allowed);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 ${scenario.allowed ? 1 : 0} 行'), findsOneWidget);
      expect(
        tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('ar-ap-confirm')),
                )
                .onPressed !=
            null,
        scenario.allowed,
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('exact finance decimal keeps four-place money without double math', () {
    expect(financeExactDecimal('100.1200'), '100.1200');
    expect(financeExactDecimalUnits('100.1200'), BigInt.from(1001200));
    expect(financeExactDecimalFromUnits(BigInt.from(1001200)), '100.1200');
    expect(financeExactMoneyDisplay('100.1200'), '100.12');
    expect(financeExactMoneyDisplay('100.1234'), '100.1234');
    expect(financeExactDecimalUnits('1.00001'), isNull);
  });

  testWidgets('375px AR picker exposes source and complete settlement facts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _ArReferenceApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Consumer(
                builder: (context, ref, _) => FilledButton(
                  onPressed: () => showArApPickerDialog(
                    context,
                    ref,
                    direction: 'AR',
                    partyId: 'client-1',
                  ),
                  child: const Text('打开引用'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开引用'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('引用应收'), findsWidgets);
    expect(find.text('来源类型 / 单号'), findsOneWidget);
    expect(find.text('销售发运 · XSCK-001'), findsOneWidget);
    expect(find.text('应收总额'), findsOneWidget);
    expect(find.text('累计已收'), findsOneWidget);
    expect(find.text('累计冲销'), findsOneWidget);
    expect(find.text('预收已抵'), findsOneWidget);
    expect(find.text('本次可收'), findsOneWidget);
    expect(find.text('销售订单号'), findsOneWidget);
    expect(find.text('XD-001'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, '搜索应收单号、发运单号、销售订单号或客户'),
      findsOneWidget,
    );
  });
}

class _ArReferenceApi extends ApiClient {
  _ArReferenceApi({this.overrides = const {}}) : super(Dio());

  final Map<String, dynamic> overrides;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/ar-ap') {
      return {
        'items': [
          {
            'id': 'ledger-1',
            'direction': 'AR',
            'openItemKind': 'RECEIVABLE',
            'sourceDocType': 'SALES_SHIPMENT',
            'sourceDocId': 'shipment-1',
            'sourceDocNo': 'XSCK-001',
            'billNo': 'AR-001',
            'billDate': '2026-08-22',
            'clientId': 'client-1',
            'currencyId': 'currency-usd',
            'currencyCode': 'USD',
            'amountOriginal': 100,
            'amountReceivedOriginal': 20,
            'amountWriteOffOriginal': 5,
            'prepaymentAppliedOriginal': '10.0000',
            'amountBalanceOriginal': 65,
            'salesOrderIds': ['order-1'],
            'salesOrderNos': ['XD-001'],
            'settled': false,
            ...overrides,
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{};
  }
}

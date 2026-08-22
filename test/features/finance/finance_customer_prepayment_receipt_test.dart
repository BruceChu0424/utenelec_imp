import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  test('receipt models expose explicit kind and bound sales order', () {
    final list = FinanceDocListItem.fromJson(const {
      'id': 'receipt-1',
      'receiptKind': 'CUSTOMER_PREPAYMENT',
      'salesOrderId': 'order-1',
    });
    final detail = FinanceDocDetail.fromJson(_prepaymentDetail);

    expect(list.receiptKind, 'CUSTOMER_PREPAYMENT');
    expect(list.salesOrderId, 'order-1');
    expect(detail.receiptKind, 'CUSTOMER_PREPAYMENT');
    expect(detail.salesOrderId, 'order-1');
    expect(financeReceiptKindLabel(detail.receiptKind), '客户订单预收');
  });

  testWidgets('375px order prepayment locks identity and submits no lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _PrepaymentReceiptApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeViewAll,
            Perm.financeReceiptCreate,
            Perm.financeReceiptEdit,
            Perm.customerPrepaymentView,
          }),
        ],
        child: const MaterialApp(
          home: FinanceDocEditPage(
            docType: FinanceDocType.receipt,
            id: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('登记订单预收'), findsWidgets);
    expect(
      find.text('客户预收由财务登记实际到账。必须绑定已审核销售订单；客户和币种随订单锁定，不生成普通应收核销明细。'),
      findsOneWidget,
    );
    expect(find.text('XD-001'), findsWidgets);
    expect(find.text('甲客户'), findsWidgets);
    expect(find.text('美元'), findsWidgets);
    expect(
      find.byKey(const ValueKey('customer-prepayment-receipt-rate')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('customer-prepayment-receipt-amount')),
      findsOneWidget,
    );
    expect(find.byType(UtenEditableGrid<FinanceGridRow>), findsNothing);
    expect(_textField('手续费（人民币）'), findsNothing);
    expect(_textField('其它费用（人民币）'), findsNothing);
    expect(find.text('本次预收 美元 88.1234 · 到账汇率 7.123456'), findsOneWidget);
    expect(find.text('保存').hitTestable(), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final body = api.lastPutBody;
    expect(body, isNotNull);
    expect(body?['receiptKind'], 'CUSTOMER_PREPAYMENT');
    expect(body?['salesOrderId'], 'order-1');
    expect(body?['clientId'], 'client-1');
    expect(body?['currencyId'], 'currency-usd');
    expect(body?['exchangeRate'], '7.123456');
    expect(body?['amountOriginal'], '88.1234');
    expect(body?['items'], isEmpty);
    expect(body?.containsKey('bankFee'), isFalse);
    expect(body?.containsKey('otherFee'), isFalse);
  });
}

Finder _textField(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _PrepaymentReceiptApi extends ApiClient {
  _PrepaymentReceiptApi() : super(Dio());

  Map<String, dynamic>? lastPutBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/summary')) return _moneySummary;
    return _prepaymentDetail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/clients/dict') {
      return const [
        {'id': 'client-1', 'name': '甲客户'},
      ];
    }
    if (path == '/master/accounts/dict') {
      return const [
        {'id': 'account-1', 'name': '人民币账户'},
      ];
    }
    if (path == '/master/currencies/dict') {
      return const [
        {'id': 'currency-usd', 'name': '美元'},
      ];
    }
    if (path == '/master/reference-methods/finance') {
      return const [
        {
          'id': 'receipt-method-1',
          'code': 'BANK',
          'name': '银行转账',
          'legacyNameConfirmed': true,
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return _prepaymentDetail;
  }
}

const _prepaymentDetail = <String, dynamic>{
  'id': 'receipt-1',
  'billNo': 'YS-001',
  'billDate': '2026-08-23',
  'receiptKind': 'CUSTOMER_PREPAYMENT',
  'salesOrderId': 'order-1',
  'clientId': 'client-1',
  'accountId': 'account-1',
  'currencyId': 'currency-usd',
  'exchangeRate': 7.123456,
  'amountOriginal': 88.1234,
  'amountLocal': 627.6999,
  'receiptMethodId': 'receipt-method-1',
  'status': 0,
  'items': <Object>[],
};

const _moneySummary = <String, dynamic>{
  'salesOrderId': 'order-1',
  'orderBillNo': 'XD-001',
  'clientId': 'client-1',
  'currencyId': 'currency-usd',
  'currencyCode': 'USD',
  'orderTotalOriginal': '500.0000',
  'orderTotalLocal': '3561.7280',
  'formalArOriginal': '0.0000',
  'formalArLocal': '0.0000',
  'cashReceivedOriginal': '0.0000',
  'cashReceivedLocal': '0.0000',
  'writeOffOriginal': '0.0000',
  'writeOffLocal': '0.0000',
  'prepaymentReceivedOriginal': '0.0000',
  'prepaymentReceivedLocal': '0.0000',
  'prepaymentAppliedOriginal': '0.0000',
  'prepaymentAppliedSourceBookLocal': '0.0000',
  'prepaymentAppliedTargetBookLocal': '0.0000',
  'prepaymentExchangeDifferenceLocal': '0.0000',
  'prepaymentAvailableOriginal': '0.0000',
  'prepaymentAvailableLocal': '0.0000',
  'arOutstandingOriginal': '0.0000',
  'arOutstandingLocal': '0.0000',
  'unrecognizedOrderOriginal': '0.0000',
  'unrecognizedOrderLocal': '0.0000',
  'plannedRemainingOriginal': '500.0000',
  'overpaidOriginal': '0.0000',
  'hasUnallocated': false,
  'unallocatedReceiptLines': <Object>[],
  'warnings': <Object>[],
};

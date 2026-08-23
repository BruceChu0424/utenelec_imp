import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    '375px prepayment detail is read-only and does not render AR lines',
    (tester) async {
      tester.view.physicalSize = const Size(375, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _DetailApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.financeViewAll,
              Perm.customerPrepaymentView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: FinanceDocDetailPage(
              docType: FinanceDocType.receipt,
              id: 'receipt-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('收款业务'), findsOneWidget);
      expect(find.text('客户订单预收'), findsOneWidget);
      expect(find.text('绑定销售订单 UUID'), findsOneWidget);
      expect(find.text('order-1'), findsWidgets);
      expect(find.text('本次预收原币金额'), findsOneWidget);
      expect(find.text('88.1234'), findsOneWidget);
      expect(find.text('预收到账本币'), findsOneWidget);
      expect(find.text('627.6999'), findsOneWidget);
      expect(find.text('资金来源'), findsOneWidget);
      expect(find.text('已审核财务收款单；不是销售订单历史订金'), findsOneWidget);
      expect(find.textContaining('明细 ('), findsNothing);
      expect(find.text('订单资金状态（财务只读）'), findsOneWidget);
    },
  );
}

class _DetailApi extends ApiClient {
  _DetailApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/summary')) return _summary;
    return _detail;
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
    return const [];
  }
}

const _detail = <String, dynamic>{
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
  'status': 1,
  'items': <Object>[],
};

const _summary = <String, dynamic>{
  'salesOrderId': 'order-1',
  'orderBillNo': 'XD-001',
  'clientId': 'client-1',
  'currencyId': 'currency-usd',
  'currencyCode': 'USD',
  'orderTotalOriginal': '500.0000',
  'orderTotalLocal': '3561.7280',
  'formalArOriginal': '0.0000',
  'formalArLocal': '0.0000',
  'cashReceivedOriginal': '88.1234',
  'cashReceivedLocal': '627.6999',
  'writeOffOriginal': '0.0000',
  'writeOffLocal': '0.0000',
  'prepaymentReceivedOriginal': '88.1234',
  'prepaymentReceivedLocal': '627.6999',
  'prepaymentAppliedOriginal': '0.0000',
  'prepaymentAppliedSourceBookLocal': '0.0000',
  'prepaymentAppliedTargetBookLocal': '0.0000',
  'prepaymentExchangeDifferenceLocal': '0.0000',
  'prepaymentAvailableOriginal': '88.1234',
  'prepaymentAvailableLocal': '627.6999',
  'arOutstandingOriginal': '0.0000',
  'arOutstandingLocal': '0.0000',
  'unrecognizedOrderOriginal': '0.0000',
  'unrecognizedOrderLocal': '0.0000',
  'plannedRemainingOriginal': '411.8766',
  'overpaidOriginal': '0.0000',
  'hasUnallocated': false,
  'unallocatedReceiptLines': <Object>[],
  'warnings': <Object>[],
};

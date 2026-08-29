import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/customer_prepayment.dart';
import 'package:uten_imp/features/finance/repositories/customer_prepayment_repository.dart';

void main() {
  test('list and order money summary preserve decimal text', () async {
    final api = _PrepaymentApi();
    final repository = CustomerPrepaymentRepository(api);

    final page = await repository.list(
      clientId: 'client-1',
      currencyId: 'currency-usd',
      salesOrderId: 'order-1',
    );
    final summary = await repository.salesOrderSummary('order-1');

    expect(api.gets.first.path, '/finance/customer-prepayments');
    expect(api.gets.first.query?['clientId'], 'client-1');
    expect(api.gets.first.query?['currencyId'], 'currency-usd');
    expect(api.gets.first.query?['salesOrderId'], 'order-1');
    expect(page.items.single.receivedOriginal, '100.1234');
    expect(page.items.single.availableOriginal, '70.1000');
    expect(page.items.single.hasAvailable, isTrue);
    expect(page.items.single.currencyName, '美金');
    expect(page.summary.appliedOriginal, '30.0234');
    expect(
      api.gets.last.path,
      '/finance/customer-prepayments/sales-orders/order-1/summary',
    );
    expect(summary.cashReceivedOriginal, '40.1200');
    expect(summary.prepaymentAppliedOriginal, '30.0234');
    expect(summary.plannedRemainingOriginal, '59.8566');
  });

  test(
    'apply and reverse send authoritative UUIDs and exact money strings',
    () async {
      final api = _PrepaymentApi();
      final repository = CustomerPrepaymentRepository(api);

      final applied = await repository.apply(
        sourceLedgerId: 'prepayment-ledger-1',
        targets: const [
          CustomerPrepaymentOffsetTarget(
            receivableLedgerId: 'ar-ledger-1',
            salesOrderId: 'order-1',
            amountOriginal: '65.1234',
          ),
        ],
        reason: '客户确认将预收用于订单 XD-001',
        idempotencyKey: 'prepayment-test-key',
      );
      final applyCall = api.posts.first;
      expect(applyCall.path, '/finance/customer-prepayment-offsets');
      expect(applyCall.body?['sourceLedgerId'], 'prepayment-ledger-1');
      expect(applyCall.body?.containsKey('effectiveDate'), isFalse);
      final target = Map<String, dynamic>.from(
        (applyCall.body?['targets'] as List).single as Map,
      );
      expect(target['receivableLedgerId'], 'ar-ledger-1');
      expect(target['salesOrderId'], 'order-1');
      expect(target['amountOriginal'], '65.1234');
      expect(applied.batchId, 'batch-1');
      expect(applied.rowVersion, 2);

      final reversed = await repository.reverse(
        batchId: applied.batchId,
        expectedVersion: applied.rowVersion,
        reason: '客户要求改用其它订单',
      );
      expect(
        api.posts.last.path,
        '/finance/customer-prepayment-offsets/batch-1/reverse',
      );
      expect(api.posts.last.body?['expectedVersion'], 2);
      expect(reversed.status, 'REVERSED');
    },
  );
}

class _Call {
  const _Call(this.path, this.query, this.body);

  final String path;
  final Map<String, dynamic>? query;
  final Map<String, dynamic>? body;
}

class _PrepaymentApi extends ApiClient {
  _PrepaymentApi() : super(Dio());

  final gets = <_Call>[];
  final posts = <_Call>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    gets.add(_Call(path, query, null));
    if (path.endsWith('/summary')) return _moneySummary;
    return _prepaymentPage;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    final json = Map<String, dynamic>.from(body! as Map);
    posts.add(_Call(path, query, json));
    return {
      'batchId': 'batch-1',
      'rowVersion': path.endsWith('/reverse') ? 3 : 2,
      'status': path.endsWith('/reverse') ? 'REVERSED' : 'APPLIED',
      'effectiveDate': '2026-08-22',
      'allocations': const <Object>[],
    };
  }
}

const _prepaymentPage = <String, dynamic>{
  'summary': {
    'receivedOriginal': '100.1234',
    'receivedLocal': '720.8885',
    'appliedOriginal': '30.0234',
    'appliedSourceBookLocal': '216.1685',
    'availableOriginal': '70.1000',
    'availableLocal': '504.7200',
  },
  'items': [
    {
      'ledgerId': 'prepayment-ledger-1',
      'receiptId': 'receipt-1',
      'billNo': 'YS-001',
      'billDate': '2026-08-20',
      'salesOrderId': 'order-1',
      'clientId': 'client-1',
      'clientName': '甲客户',
      'currencyId': 'currency-usd',
      'currencyCode': 'USD',
      'currencyName': '美金',
      'exchangeRate': '7.200000',
      'receivedOriginal': '100.1234',
      'receivedLocal': '720.8885',
      'appliedOriginal': '30.0234',
      'appliedSourceBookLocal': '216.1685',
      'availableOriginal': '70.1000',
      'availableLocal': '504.7200',
      'updatedAt': '2026-08-22T10:00:00+08:00',
    },
  ],
  'page': 1,
  'size': 20,
  'total': 1,
  'totalPages': 1,
};

const _moneySummary = <String, dynamic>{
  'salesOrderId': 'order-1',
  'orderBillNo': 'XD-001',
  'clientId': 'client-1',
  'currencyId': 'currency-usd',
  'currencyCode': 'USD',
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

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/payables/repositories/supplier_settlement_repository.dart';

void main() {
  test(
    'monthly settlement repository follows exact workflow contracts',
    () async {
      final api = _SettlementApi();
      final repo = SupplierSettlementRepository(api);

      final page = await repo.list(
        supplierId: 'supplier-1',
        periodStart: '2026-07-01',
        status: 'FROZEN',
        keyword: '  SET-001  ',
        page: 2,
        size: 40,
      );
      expect(page.items.single.snapshotHash, 'sha256-value');
      expect(api.requests.removeAt(0).query, {
        'supplierId': 'supplier-1',
        'periodStart': '2026-07-01',
        'status': 'FROZEN',
        'keyword': 'SET-001',
        'page': 2,
        'size': 40,
      });

      await repo.freeze(
        supplierId: 'supplier-1',
        currencyId: 'currency-cny',
        periodStart: '2026-07-01',
        settlementMethodId: 'method-monthly',
      );
      final freeze = api.requests.removeAt(0);
      expect(freeze.path, '/finance/supplier-settlements');
      expect(freeze.body, {
        'supplierId': 'supplier-1',
        'currencyId': 'currency-cny',
        'periodStart': '2026-07-01',
        'settlementMethodId': 'method-monthly',
      });
      expect(freeze.body, isNot(contains('dueDate')));

      await repo.supplierConfirm(
        'batch-1',
        expectedVersion: 3,
        reference: ' 对账回执 ',
        note: ' 已盖章 ',
      );
      expect(api.requests.removeAt(0).body, {
        'expectedVersion': 3,
        'reference': '对账回执',
        'note': '已盖章',
      });

      await repo.internalConfirm('batch-1', expectedVersion: 4, note: '复核完成');
      expect(
        api.requests.removeAt(0).path.endsWith('/internal-confirm'),
        isTrue,
      );

      await repo.dispute('batch-1', expectedVersion: 5, reason: ' 数量有异议 ');
      expect(api.requests.removeAt(0).body, {
        'expectedVersion': 5,
        'reason': '数量有异议',
      });

      await repo.reverse('batch-1', expectedVersion: 6, reason: '冻结口径错误');
      expect(api.requests.removeAt(0).path.endsWith('/reverse'), isTrue);
    },
  );
}

const _summary = <String, dynamic>{
  'id': 'batch-1',
  'batchNo': 'SET-001',
  'supplierId': 'supplier-1',
  'supplierCode': 'V60001',
  'supplierName': '示例供应商',
  'currencyId': 'currency-cny',
  'currencyCode': 'CNY',
  'periodStart': '2026-07-01',
  'periodEnd': '2026-07-31',
  'dueDate': '2026-08-30',
  'status': 'FROZEN',
  'openingBalanceOriginal': '100.0000',
  'periodPostedOriginal': '80.0000',
  'periodPaidOriginal': '30.0000',
  'periodOffsetOriginal': '10.0000',
  'closingBalanceOriginal': '140.0000',
  'openingBalanceLocal': '100.0000',
  'periodPostedLocal': '80.0000',
  'periodPaidLocal': '30.0000',
  'periodOffsetLocal': '10.0000',
  'closingBalanceLocal': '140.0000',
  'lineCount': 1,
  'version': 3,
  'snapshotHash': 'sha256-value',
};

const _detail = <String, dynamic>{
  'summary': _summary,
  'lines': <Map<String, dynamic>>[
    {
      'id': 'line-1',
      'ledgerId': 'ledger-1',
      'businessType': 'PURCHASE',
      'openItemKind': 'PAYABLE',
      'sourceDocType': 'PURCHASE_RECEIPT',
      'sourceDocNo': 'PI-001',
      'billDate': '2026-07-10',
      'dueDate': '2026-08-30',
      'bookingRate': '1.000000',
      'openingBalanceOriginal': '100.0000',
      'periodPostedOriginal': '80.0000',
      'periodPaidOriginal': '30.0000',
      'periodOffsetOriginal': '10.0000',
      'closingBalanceOriginal': '140.0000',
    },
  ],
  'events': <Map<String, dynamic>>[
    {'id': 'event-1', 'type': 'FROZEN', 'reason': '冻结快照'},
  ],
};

typedef _Request = ({
  String method,
  String path,
  Map<String, dynamic>? query,
  Map<String, dynamic>? body,
});

class _SettlementApi extends ApiClient {
  _SettlementApi() : super(Dio());

  final List<_Request> requests = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requests.add((method: 'GET', path: path, query: query, body: null));
    if (path.endsWith('/batch-1')) return _detail;
    return {
      'items': [_summary],
      'page': 1,
      'size': 30,
      'total': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    requests.add((
      method: 'POST',
      path: path,
      query: query,
      body: (body as Map?)?.cast<String, dynamic>(),
    ));
    return _detail;
  }
}

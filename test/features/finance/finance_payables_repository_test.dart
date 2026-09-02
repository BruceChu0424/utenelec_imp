import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/payables/repositories/finance_payables_repository.dart';

void main() {
  test('payables repository sends the complete filter contract', () async {
    final api = _PayablesApi(_response);
    final repository = FinancePayablesRepository(api);

    final result = await repository.list(
      page: 2,
      size: 50,
      filter: const FinancePayablesFilter(
        businessType: 'SUBCONTRACT',
        supplierId: 'supplier-1',
        status: 'OVERDUE',
        settlementMethodId: 'method-1',
        keyword: '  加工厂  ',
        dateFrom: '2026-08-01',
        dateTo: '2026-08-31',
        dueFrom: '2026-09-01',
        dueTo: '2026-09-30',
      ),
      sort: 'dueDate',
      order: 'asc',
    );

    expect(api.path, '/finance/payables');
    expect(api.query, {
      'page': 2,
      'size': 50,
      'businessType': 'SUBCONTRACT',
      'supplierId': 'supplier-1',
      'status': 'OVERDUE',
      'settlementMethodId': 'method-1',
      'keyword': '加工厂',
      'dateFrom': '2026-08-01',
      'dateTo': '2026-08-31',
      'dueFrom': '2026-09-01',
      'dueTo': '2026-09-30',
      'sort': 'dueDate',
      'order': 'asc',
    });
    expect(result.page, 2);
    expect(result.size, 50);
    expect(result.total, 51);
    expect(result.totalPages, 2);
  });

  test('money stays as exact server decimal strings', () async {
    final result = await FinancePayablesRepository(_PayablesApi(_response))
        .list();

    expect(result.summary.payableLocal, '9007199254740993.12');
    expect(result.summary.outstandingLocal, '5000.01');
    expect(result.summary.settledBookLocal, '4400.00');
    expect(result.summary.exchangeDifferenceLocal, '-399.90');
    expect(result.summary.offsetLocal, '300.01');
    expect(result.summary.creditLocal, '88.00');
    expect(result.summary.prepaymentLocal, '66.00');
    expect(result.summary.pendingLossCases, 3);
    final item = result.items.single;
    expect(item.grossOriginal, '9007199254740993.12');
    expect(item.grossLocal, '9007199254740993.12');
    expect(item.paidOriginal, '4000.10');
    expect(item.offsetOriginal, '300.01');
    expect(item.outstandingOriginal, '5000.01');
    expect(item.openItemKind, 'PAYABLE');
    expect(item.businessTypeLabel, '委外');
    expect(item.sourceTypeLabel, '委外进仓');
    expect(item.supplierName, '精密加工厂');
    expect(item.currencyCode, 'CNY');
    expect(item.currencyName, '人民币');
  });
}

const _response = <String, dynamic>{
  'summary': <String, dynamic>{
    'payableLocal': '9007199254740993.12',
    'paidLocal': '4000.10',
    'settledBookLocal': '4400.00',
    'exchangeDifferenceLocal': '-399.90',
    'offsetLocal': '300.01',
    'outstandingLocal': '5000.01',
    'overdueLocal': '2000.01',
    'dueThisMonthLocal': '3000.00',
    'creditLocal': '88.00',
    'prepaymentLocal': '66.00',
    'pendingLossCases': 3,
  },
  'items': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'ap-1',
      'version': 4,
      'businessType': 'SUBCONTRACT',
      'openItemKind': 'PAYABLE',
      'sourceDocType': 'SUBCONTRACT_RECEIPT',
      'sourceDocId': 'receipt-1',
      'sourceDocNo': 'SWI-001',
      'supplier': <String, dynamic>{
        'id': 'supplier-1',
        'code': 'V60001',
        'name': '精密加工厂',
      },
      'billDate': '2026-08-20',
      'dueDate': '2026-09-30',
      'settlementMethod': <String, dynamic>{'name': '月结'},
      'currency': <String, dynamic>{'code': 'CNY', 'name': '人民币'},
      'currencyName': '人民币',
      'grossOriginal': '9007199254740993.12',
      'grossLocal': '9007199254740993.12',
      'paidOriginal': '4000.10',
      'paidLocal': '4000.10',
      'offsetOriginal': '300.01',
      'offsetLocal': '300.01',
      'outstandingOriginal': '5000.01',
      'outstandingLocal': '5000.01',
      'status': 'OVERDUE',
      'overdueDays': 7,
    },
  ],
  'page': 2,
  'size': 50,
  'total': 51,
  'totalPages': 2,
};

class _PayablesApi extends ApiClient {
  _PayablesApi(this.response) : super(Dio());

  final Map<String, dynamic> response;
  String? path;
  Map<String, dynamic>? query;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.query = query;
    return response;
  }
}

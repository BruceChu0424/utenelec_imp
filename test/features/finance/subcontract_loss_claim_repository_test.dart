import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/payables/models/subcontract_loss_claim.dart';
import 'package:uten_imp/features/finance/payables/repositories/subcontract_loss_claim_repository.dart';

void main() {
  test('loss claim parser preserves exact quantities and money', () {
    final detail = SubcontractLossClaimDetail.fromJson(_detail);
    expect(detail.summary.excessLossQty, '7.1234');
    expect(detail.summary.lossBookValueLocal, '9007199254740993.1200');
    expect(detail.lines.single.goodsLabel, 'G-01 · 铜料');
    expect(detail.resolutions.single.typeLabel, '现金赔偿');
    expect(detail.events.single.type, 'DECIDED');
    expect(financeDecimalUnits('7.1234'), BigInt.from(71234));
    expect(financeDecimalUnits('7.12340'), BigInt.from(71234));
    expect(financeDecimalUnits('7.12345'), isNull);
  });

  test('repository sends list, detail and write contracts exactly', () async {
    final api = _ClaimApi();
    final repository = SubcontractLossClaimRepository(api);

    await repository.list(
      supplierId: 'supplier-1',
      status: 'OPEN',
      keyword: '  SW-001  ',
      page: 2,
      size: 40,
    );
    final listRequest = api.requests.removeAt(0);
    expect(listRequest.method, 'GET');
    expect(listRequest.path, '/finance/subcontract-loss-claims');
    expect(listRequest.body, isNull);
    expect(listRequest.query, {
      'supplierId': 'supplier-1',
      'status': 'OPEN',
      'keyword': 'SW-001',
      'page': 2,
      'size': 40,
    });

    await repository.detail('case-1');
    expect(
      api.requests.removeAt(0).path,
      '/finance/subcontract-loss-claims/case-1',
    );

    await repository.decide(
      'case-1',
      expectedVersion: 3,
      disputed: false,
      reason: ' 委外商责任 ',
      resolutions: const [
        SubcontractLossResolutionInput(
          caseLineId: 'line-1',
          type: SubcontractLossResolutionType.apOffset,
          quantity: '7.1234',
          amountLocal: '100.00',
          offsetTargets: [
            SubcontractLossOffsetTarget(
              payableId: 'payable-1',
              amountOriginal: '100.00',
            ),
          ],
        ),
      ],
    );
    final decision = api.requests.removeAt(0);
    expect(decision.method, 'POST');
    expect(decision.path, '/finance/subcontract-loss-claims/case-1/decision');
    expect(decision.body?['expectedVersion'], 3);
    expect(decision.body?['reason'], '委外商责任');
    expect(
      ((decision.body?['resolutions'] as List).single as Map)['offsetTargets'],
      [
        {'payableId': 'payable-1', 'amountOriginal': '100.00'},
      ],
    );

    await repository.fulfill(
      'case-1',
      'resolution-1',
      expectedCaseVersion: 4,
      fulfilledQuantity: '7.1234',
      evidenceReference: '质检签收单',
      fulfillmentDocType: 'SUBCONTRACT_MATERIAL_RETURN',
      fulfillmentDocId: '11111111-1111-4111-8111-111111111111',
      fulfillmentDocItemId: '22222222-2222-4222-8222-222222222222',
      fulfillmentDocNo: 'SMR-001',
      accountId: 'account-1',
      cashReceiptDate: '2026-08-22',
    );
    final fulfill = api.requests.removeAt(0);
    expect(
      fulfill.path,
      '/finance/subcontract-loss-claims/case-1/resolutions/resolution-1/fulfill',
    );
    expect(fulfill.body?['expectedCaseVersion'], 4);
    expect(fulfill.body?['evidenceReference'], '质检签收单');
    expect(
      fulfill.body?['fulfillmentDocItemId'],
      '22222222-2222-4222-8222-222222222222',
    );
    expect(fulfill.body?['accountId'], 'account-1');
    expect(fulfill.body?['cashReceiptDate'], '2026-08-22');

    await repository.reverseFulfillment(
      'case-1',
      'resolution-1',
      expectedCaseVersion: 5,
      reason: ' 现金到账录入错误 ',
    );
    final reverseFulfillment = api.requests.removeAt(0);
    expect(
      reverseFulfillment.path,
      '/finance/subcontract-loss-claims/case-1/resolutions/resolution-1/reverse-fulfillment',
    );
    expect(reverseFulfillment.body, {
      'expectedCaseVersion': 5,
      'reason': '现金到账录入错误',
    });

    await repository.reverse('case-1', expectedVersion: 5, reason: ' 决定录入错误 ');
    final reverse = api.requests.removeAt(0);
    expect(reverse.path, '/finance/subcontract-loss-claims/case-1/reverse');
    expect(reverse.body, {'expectedVersion': 5, 'reason': '决定录入错误'});
  });
}

const _summary = <String, dynamic>{
  'id': 'case-1',
  'wasteId': 'waste-1',
  'wasteBillNo': 'SW-001',
  'supplierId': 'supplier-1',
  'supplierCode': 'V60001',
  'supplierName': '精密加工厂',
  'status': 'AWAITING_FULFILLMENT',
  'actualLossQty': '10.1234',
  'allowedLossQty': '3.0000',
  'excessLossQty': '7.1234',
  'lossBookValueLocal': '9007199254740993.1200',
  'claimAmountLocal': '100.0000',
  'version': 4,
  'createdAt': '2026-08-22T10:00:00+08:00',
};

const _detail = <String, dynamic>{
  'summary': _summary,
  'lines': <Map<String, dynamic>>[
    {
      'id': 'line-1',
      'goodsCode': 'G-01',
      'goodsName': '铜料',
      'actualLossQty': '10.1234',
      'allowedLossQty': '3.0000',
      'excessLossQty': '7.1234',
      'unitBookValueLocal': '10.0000',
      'lossBookValueLocal': '71.2340',
      'valuationStatus': 'VALUED',
    },
  ],
  'resolutions': <Map<String, dynamic>>[
    {
      'id': 'resolution-1',
      'caseLineId': 'line-1',
      'type': 'CASH_COMPENSATION',
      'quantity': '7.1234',
      'amountLocal': '100.0000',
      'status': 'PENDING',
    },
  ],
  'events': <Map<String, dynamic>>[
    {
      'id': 'event-1',
      'type': 'DECIDED',
      'reason': '委外商承担',
      'createdAt': '2026-08-22T11:00:00+08:00',
    },
  ],
};

typedef _CapturedRequest = ({
  String method,
  String path,
  Map<String, dynamic>? query,
  Map<String, dynamic>? body,
});

class _ClaimApi extends ApiClient {
  _ClaimApi() : super(Dio());

  final List<_CapturedRequest> requests = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requests.add((method: 'GET', path: path, query: query, body: null));
    if (path.endsWith('/case-1')) return _detail;
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

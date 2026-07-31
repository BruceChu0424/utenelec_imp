import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';

void main() {
  test('loads the material conservation ledger for a plan', () async {
    late RequestOptions captured;
    final repository = ProductionMaterialRepository(
      _api((request) {
        captured = request;
        return [
          {
            'planId': 'plan-1',
            'demandId': 'demand-1',
            'executionSegmentId': 'segment-1',
            'executionSegmentCode': 'SEG-001',
            'goodsId': 'goods-1',
            'goodsCode': 'MAT-001',
            'goodsName': '轴套',
            'requiredQty': 10,
            'issuedQty': 8,
            'returnedQty': 1,
            'consumedQty': 5,
            'approvedLossQty': 1,
            'legalWipQty': 0,
            'maxReturnQty': 1,
            'unclearedQty': 1,
            'canClose': false,
          },
        ];
      }),
    );

    final rows = await repository.clearance('plan-1');

    expect(captured.path, '/stock/production-materials/plans/plan-1/clearance');
    expect(rows.single.goodsName, '轴套');
    expect(rows.single.executionSegmentId, 'segment-1');
    expect(rows.single.executionSegmentCode, 'SEG-001');
    expect(rows.single.unclearedQty, 1);
    expect(rows.single.canClose, isFalse);
  });

  test('posts typed settlement lines with a stable idempotency key', () async {
    late RequestOptions captured;
    final repository = ProductionMaterialRepository(
      _api((request) {
        captured = request;
        return <Map<String, dynamic>>[];
      }),
    );

    await repository.settle(
      'plan-1',
      idempotencyKey: 'material-settle-001',
      reason: '本次实际消耗',
      lines: const [
        ProductionMaterialSettlementLine(
          demandId: 'demand-1',
          settlementType: 'CONSUMED',
          qtyBase: 3,
        ),
      ],
    );

    expect(
      captured.path,
      '/stock/production-materials/plans/plan-1/settlements',
    );
    expect(captured.method, 'POST');
    expect(captured.data, {
      'idempotencyKey': 'material-settle-001',
      'reason': '本次实际消耗',
      'lines': [
        {'demandId': 'demand-1', 'settlementType': 'CONSUMED', 'qtyBase': 3.0},
      ],
    });
  });
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_return_quality.dart';
import 'package:uten_imp/features/sales/repositories/sales_return_quality_repository.dart';

void main() {
  test(
    'loads the quality projection from the return-scoped endpoint',
    () async {
      late RequestOptions captured;
      final repository = SalesReturnQualityRepository(
        _api((request) {
          captured = request;
          return [_row()];
        }),
      );

      final rows = await repository.list('return-1');

      expect(captured.method, 'GET');
      expect(captured.path, '/sales/returns/return-1/quality');
      expect(rows, hasLength(1));
      expect(rows.single.remainingBaseQty, 10);
    },
  );

  test('disposition uses the row endpoint and trims audited reason', () async {
    late RequestOptions captured;
    final repository = SalesReturnQualityRepository(
      _api((request) {
        captured = request;
        return [
          _row(releasedBaseQty: 2.5, remainingBaseQty: 7.5, status: 'PARTIAL'),
        ];
      }),
    );

    final rows = await repository.dispose(
      returnId: 'return-1',
      returnItemId: 'return-item-1',
      action: SalesReturnQualityAction.goodRelease,
      baseQty: 2.5,
      reason: '  IQC-20260801 合格  ',
      idempotencyKey: 'quality-dispose-001',
    );

    expect(captured.method, 'POST');
    expect(
      captured.path,
      '/sales/returns/return-1/quality/return-item-1/dispose',
    );
    expect(captured.data, {
      'action': 'GOOD_RELEASE',
      'baseQty': 2.5,
      'reason': 'IQC-20260801 合格',
      'idempotencyKey': 'quality-dispose-001',
    });
    expect(rows.single.status, 'PARTIAL');
    expect(rows.single.releasedBaseQty, 2.5);
  });
}

Map<String, dynamic> _row({
  double releasedBaseQty = 0,
  double remainingBaseQty = 10,
  String status = 'PENDING',
}) => {
  'id': 'quality-1',
  'returnId': 'return-1',
  'returnItemId': 'return-item-1',
  'warehouseId': 'warehouse-1',
  'goodsId': 'goods-1',
  'colorId': null,
  'unitId': 'unit-1',
  'unitRate': 1,
  'receivedBaseQty': 10,
  'releasedBaseQty': releasedBaseQty,
  'scrappedBaseQty': 0,
  'reworkBaseQty': 0,
  'remainingBaseQty': remainingBaseQty,
  'status': status,
  'receivedAt': '2026-08-01T10:00:00+08:00',
  'updatedAt': '2026-08-01T10:00:00+08:00',
};

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: responder(request),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

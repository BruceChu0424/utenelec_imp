import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';

void main() {
  test(
    'partial shipment confirmation uses the V187 command contract',
    () async {
      late RequestOptions captured;
      final repository = SalesRepository(
        _api((request) {
          captured = request;
          return const {'id': 'order-1', 'shipmentPolicy': 'CUSTOMER_CONFIRM'};
        }),
        SalesDocType.order,
      );

      final detail = await repository.setPartialShipmentConfirmation(
        'order-1',
        confirmed: true,
        reason: '  客户邮件确认  ',
      );

      expect(captured.method, 'POST');
      expect(
        captured.path,
        '/sales/orders/order-1/partial-shipment-confirmation',
      );
      expect(captured.data, {'confirmed': true, 'reason': '客户邮件确认'});
      expect(detail.shipmentPolicy, SalesShipmentPolicy.customerConfirm);
    },
  );

  test('warehouse transition sends target status and audited reason', () async {
    late RequestOptions captured;
    final repository = SalesRepository(
      _api((request) {
        captured = request;
        return const {'id': 'shipment-1', 'warehouseWorkStatus': 'EXCEPTION'};
      }),
      SalesDocType.shipment,
    );

    final detail = await repository.transitionWarehouseWork(
      'shipment-1',
      targetStatus: SalesWarehouseWorkStatus.exception,
      reason: '  外箱破损待复核  ',
    );

    expect(captured.method, 'POST');
    expect(captured.path, '/sales/shipments/shipment-1/warehouse-work');
    expect(captured.data, {
      'targetStatus': SalesWarehouseWorkStatus.exception,
      'reason': '外箱破损待复核',
    });
    expect(detail.warehouseWorkStatus, SalesWarehouseWorkStatus.exception);
  });

  test('warehouse transition omits an empty optional reason', () async {
    late RequestOptions captured;
    final repository = SalesRepository(
      _api((request) {
        captured = request;
        return const {'id': 'shipment-1', 'warehouseWorkStatus': 'PICKING'};
      }),
      SalesDocType.shipment,
    );

    await repository.transitionWarehouseWork(
      'shipment-1',
      targetStatus: SalesWarehouseWorkStatus.picking,
      reason: '   ',
    );

    expect(captured.data, {'targetStatus': SalesWarehouseWorkStatus.picking});
  });

  test('finance audit preview is GET before the POST command', () async {
    final captured = <RequestOptions>[];
    final repository = SalesRepository(
      _api((request) {
        captured.add(request);
        return {
          'shipmentId': 'shipment-1',
          'financeAudit': request.method == 'POST' ? 1 : 0,
          'salesPaymentType': 'CASH',
          'settlementMethodName': '现金',
          'outstanding': '100.00',
          'creditFloor': '20.00',
          'overFloor': '80.00',
        };
      }),
      SalesDocType.shipment,
    );

    final preview = await repository.financeAuditInfo('shipment-1');
    final result = await repository.financeAudit(
      'shipment-1',
      expectedRevision: 3,
      expectedContentHash: 'review-hash',
      expectedClaimId: 'claim-id',
    );

    expect(captured.map((request) => request.method), ['GET', 'POST']);
    expect(
      captured.first.path,
      '/sales/shipments/shipment-1/finance-audit-info',
    );
    expect(captured.last.path, '/sales/shipments/shipment-1/finance-audit');
    expect(captured.last.data, {
      'expectedRevision': 3,
      'expectedContentHash': 'review-hash',
      'expectedClaimId': 'claim-id',
    });
    expect(preview.overFloor, '80.00');
    expect(result.financeAudit, 1);
  });

  test(
    'shipment task filters are forwarded without client-side inference',
    () async {
      RequestOptions? captured;
      final repository = SalesRepository(
        _api((request) {
          captured = request;
          return const {
            'items': <Map<String, dynamic>>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          };
        }),
        SalesDocType.shipment,
      );

      await repository.list(
        filter: const SalesDocFilter(
          financeAudit: 1,
          warehouseWorkStatus: SalesWarehouseWorkStatus.picking,
        ),
      );

      expect(captured?.queryParameters['financeAudit'], 1);
      expect(captured?.queryParameters['warehouseWorkStatus'], 'PICKING');
    },
  );
}

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

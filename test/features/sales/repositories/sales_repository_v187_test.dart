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

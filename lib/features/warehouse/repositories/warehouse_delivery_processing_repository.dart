import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../models/warehouse_sales_outbound.dart';

class WarehouseDeliveryProcessingRepository {
  const WarehouseDeliveryProcessingRepository(this.api);
  final ApiClient api;
  String _base(String shipmentId) =>
      '/warehouse/sales-outbound/${Uri.encodeComponent(shipmentId)}';
  Future<WarehouseDeliveryComponent> submit(
    String shipmentId,
    String componentId,
    String action,
    Map<String, dynamic> body,
  ) async {
    const paths = {
      'ISSUE': 'processing-issue',
      'RECEIVE': 'processing-receive',
      'CANCEL_ISSUE': 'processing-cancel-issue',
    };
    final path = paths[action];
    if (path == null) throw const FormatException('未知加工交接动作');
    final json = await api.post(
      '${_base(shipmentId)}/delivery-components/${Uri.encodeComponent(componentId)}/$path',
      body: body,
    );
    return WarehouseDeliveryComponent.fromJson(
      json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : json,
    );
  }

  Future<Map<String, dynamic>> result(
    String shipmentId,
    String requestId,
  ) => api.get(
    '${_base(shipmentId)}/delivery-requests/${Uri.encodeComponent(requestId)}',
  );
}

final warehouseDeliveryProcessingRepositoryProvider =
    Provider<WarehouseDeliveryProcessingRepository>(
      (ref) =>
          WarehouseDeliveryProcessingRepository(ref.watch(apiClientProvider)),
    );

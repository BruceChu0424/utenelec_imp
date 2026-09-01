import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/warehouse_iqc_stock_in.dart';

/// IQC 待入库写网关（合并页「品质部检查结果」接管列表与详情读路径后，只剩
/// 单张入库确认；批量确认走 WarehouseQualityResultGateway.batchConfirm）。
abstract interface class WarehouseIqcStockInGateway {
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  );
}

class WarehouseIqcStockInRepository implements WarehouseIqcStockInGateway {
  const WarehouseIqcStockInRepository(this.api);

  final ApiClient api;

  @override
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  ) async {
    final json = await api.post(
      ApiEndpoints.warehouseIqcStockInConfirm(receiptType, receiptId),
      body: command.toJson(),
    );
    return WarehouseIqcStockInConfirmResult.fromJson(_body(json));
  }
}

Map<String, dynamic> _body(Map<String, dynamic> json) {
  return json['data'] is Map
      ? Map<String, dynamic>.from(json['data'] as Map)
      : json;
}

final warehouseIqcStockInRepositoryProvider =
    Provider<WarehouseIqcStockInGateway>((ref) {
      return WarehouseIqcStockInRepository(ref.watch(apiClientProvider));
    });

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/warehouse_iqc_stock_in.dart';

abstract interface class WarehouseIqcStockInGateway {
  Future<PagedResult<WarehouseIqcStockInTaskSummary>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  });

  Future<int> pendingCount();

  Future<WarehouseIqcStockInTaskDetail> detail(
    String receiptType,
    String receiptId,
  );

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
  Future<PagedResult<WarehouseIqcStockInTaskSummary>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async {
    final normalizedKeyword = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseIqcStockIns,
      query: {
        'page': page < 1 ? 1 : page,
        'size': size.clamp(1, 100),
        'receiptType': receiptType?.apiValue ?? 'ALL',
        if (normalizedKeyword?.isNotEmpty == true) 'keyword': normalizedKeyword,
      },
    );
    return PagedResult.fromJson(json, WarehouseIqcStockInTaskSummary.fromJson);
  }

  @override
  Future<int> pendingCount() async {
    final json = await api.get(ApiEndpoints.warehouseIqcStockInCount);
    final value = json['count'];
    return value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Future<WarehouseIqcStockInTaskDetail> detail(
    String receiptType,
    String receiptId,
  ) async {
    final json = await api.get(
      ApiEndpoints.warehouseIqcStockInDetail(receiptType, receiptId),
    );
    return WarehouseIqcStockInTaskDetail.fromJson(_body(json));
  }

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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';

abstract interface class WarehouseQualityResultGateway {
  Future<PagedResult<WarehouseQualityResultTask>> list({
    int page,
    int size,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    String? billNo,
  });

  /// 收货单号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径。
  Future<List<MasterFacetBucket>> billNoFacets({
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
  });

  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  });

  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  );

  Future<WarehouseQualityBatchConfirmResult> batchConfirm(
    WarehouseQualityBatchConfirmCommand command,
  );
}

class WarehouseQualityResultRepository
    implements WarehouseQualityResultGateway {
  const WarehouseQualityResultRepository(this.api);

  final ApiClient api;

  @override
  Future<PagedResult<WarehouseQualityResultTask>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    String? billNo,
  }) async {
    final normalizedKeyword = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseQualityResults,
      query: {
        'page': page < 1 ? 1 : page,
        'size': size.clamp(1, 100),
        'receiptType': receiptType?.apiValue ?? 'ALL',
        if (workStatus != null) 'status': workStatus.apiValue,
        if (normalizedKeyword?.isNotEmpty == true) 'keyword': normalizedKeyword,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        // 2026-09-25 单号列统一：表头排序 + 收货单号表头值筛选。
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
        if (billNo != null && billNo.trim().isNotEmpty) 'billNo': billNo.trim(),
      },
    );
    return PagedResult.fromJson(json, WarehouseQualityResultTask.fromJson);
  }

  @override
  Future<List<MasterFacetBucket>> billNoFacets({
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
  }) async {
    final normalizedKeyword = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseQualityResultFacets,
      query: {
        'receiptType': receiptType?.apiValue ?? 'ALL',
        if (workStatus != null) 'status': workStatus.apiValue,
        if (normalizedKeyword?.isNotEmpty == true) 'keyword': normalizedKeyword,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
      },
    );
    return parseFacetBuckets(json, 'billNo');
  }

  @override
  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async {
    final normalizedKeyword = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.warehouseQualityResultStatusCounts,
      query: {
        'receiptType': receiptType?.apiValue ?? 'ALL',
        if (normalizedKeyword?.isNotEmpty == true) 'keyword': normalizedKeyword,
      },
    );
    final raw = json;
    return {
      for (final status in WarehouseQualityWorkStatus.values)
        status: _countOf(raw, status.apiValue),
    };
  }

  @override
  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  ) async {
    final json = await api.get(
      ApiEndpoints.warehouseQualityResultDetail(receiptType, receiptId),
    );
    return WarehouseQualityResultDetail.fromJson(_body(json));
  }

  @override
  Future<WarehouseQualityBatchConfirmResult> batchConfirm(
    WarehouseQualityBatchConfirmCommand command,
  ) async {
    final json = await api.post(
      ApiEndpoints.warehouseIqcStockInBatchConfirm,
      body: command.toJson(),
    );
    return WarehouseQualityBatchConfirmResult.fromJson(_body(json));
  }

  static int _countOf(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

Map<String, dynamic> _body(Map<String, dynamic> json) {
  return json['data'] is Map
      ? Map<String, dynamic>.from(json['data'] as Map)
      : json;
}

final warehouseQualityResultRepositoryProvider =
    Provider<WarehouseQualityResultGateway>((ref) {
      return WarehouseQualityResultRepository(ref.watch(apiClientProvider));
    });

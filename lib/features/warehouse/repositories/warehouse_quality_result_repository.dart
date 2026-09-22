import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
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
  });

  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  });

  /// 父分类(来源类型)分段计数: 红色「轮到仓库动手」与黄色「等待检查结果」两支。
  /// 页内大类分段、hub 卡红黄徽章都取这一份, 三个数字不会再各算各的。
  Future<WarehouseQualityTypeCounts> typeCounts();

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
      },
    );
    return PagedResult.fromJson(json, WarehouseQualityResultTask.fromJson);
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
  Future<WarehouseQualityTypeCounts> typeCounts() async {
    final json = await api.get(ApiEndpoints.warehouseQualityResultTypeCounts);
    return WarehouseQualityTypeCounts.fromJson(json);
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

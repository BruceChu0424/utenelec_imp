import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_fqc_inspection.dart';

class ProductionFqcRepository {
  const ProductionFqcRepository(this.api);

  final ApiClient api;

  /// [sheet]：`NONE` = 只列无检查单的历史任务；检查单 UUID = 该单任务；空 = 不过滤。
  Future<PagedResult<ProductionFqcInspection>> list({
    String status = 'ACTIVE',
    String keyword = '',
    String? sheet,
    int page = 1,
    int size = 40,
  }) async {
    final json = await api.get(
      ApiEndpoints.productionQualityInspections,
      query: {
        'status': status,
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (sheet != null && sheet.isNotEmpty) 'sheet': sheet,
      },
    );
    return PagedResult.fromJson(json, ProductionFqcInspection.fromJson);
  }

  /// V547 品质检查单队列（ACTIVE = 仍有待检行；CLOSED = 全部决定/取消）。
  Future<PagedResult<ProductionFqcInspectionSheet>> listSheets({
    String status = 'ACTIVE',
    String keyword = '',
    int page = 1,
    int size = 40,
  }) async {
    final json = await api.get(
      ApiEndpoints.productionQualityInspectionSheets,
      query: {
        'status': status,
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      },
    );
    return PagedResult.fromJson(json, ProductionFqcInspectionSheet.fromJson);
  }

  Future<ProductionFqcInspectionSheetDetail> sheetDetail(String sheetId) async {
    final json = await api.get(
      ApiEndpoints.productionQualityInspectionSheet(sheetId),
    );
    return ProductionFqcInspectionSheetDetail.fromJson(json);
  }

  Future<ProductionFqcInspection> detail(String id) async {
    final json = await api.get(
      '${ApiEndpoints.productionQualityInspections}/$id',
    );
    return ProductionFqcInspection.fromJson(json);
  }

  Future<int> pendingCount() async {
    final json = await api.get(ApiEndpoints.productionQualityInspectionCount);
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  Future<bool> canDecide() async {
    final json = await api.get(
      ApiEndpoints.productionQualityInspectionCapability,
    );
    return json['canDecide'] == true;
  }

  Future<ProductionFqcDecisionResult> decide({
    required String id,
    required String decision,
    required String idempotencyKey,
    double? passQty,
    double? failQty,
    String? dispositionCode,
    String? reason,
  }) async {
    final trimmedReason = reason?.trim();
    final effectiveReason = trimmedReason == null || trimmedReason.isEmpty
        ? null
        : trimmedReason;
    final json = await api.post(
      '${ApiEndpoints.productionQualityInspections}/$id/decisions',
      body: {
        'decision': decision,
        'passQty': ?passQty,
        'failQty': ?failQty,
        'dispositionCode': ?dispositionCode,
        'reason': ?effectiveReason,
        'idempotencyKey': idempotencyKey,
      },
    );
    return ProductionFqcDecisionResult.fromJson(json);
  }

  Future<
    ({
      int processedCount,
      bool replay,
      List<ProductionFqcInspection> inspections,
    })
  >
  passAll({
    required List<String> inspectionIds,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.productionQualityInspectionPassAll,
      body: {'inspectionIds': inspectionIds, 'idempotencyKey': idempotencyKey},
    );
    final items = (json['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final inspections = [
      for (final item in items)
        ProductionFqcInspection.fromJson(
          item['inspection'] as Map<String, dynamic>? ?? item,
        ),
    ];
    return (
      processedCount: (json['processedCount'] as num?)?.toInt() ?? items.length,
      replay: json['replay'] == true,
      inspections: inspections,
    );
  }
}

final productionFqcRepositoryProvider = Provider<ProductionFqcRepository>(
  (ref) => ProductionFqcRepository(ref.watch(apiClientProvider)),
);

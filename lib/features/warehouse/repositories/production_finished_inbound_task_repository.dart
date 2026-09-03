import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_finished_inbound_task.dart';

class ProductionFinishedInboundTaskRepository {
  const ProductionFinishedInboundTaskRepository(this.api);

  final ApiClient api;

  Future<PagedResult<ProductionFinishedInboundTask>> tasks({
    int page = 1,
    int size = 40,
    String? keyword,
  }) async {
    final normalized = keyword?.trim();
    final json = await api.get(
      ApiEndpoints.productionFinishedInboundTasks,
      query: {
        'page': page,
        'size': size,
        if (normalized != null && normalized.isNotEmpty) 'keyword': normalized,
      },
    );
    return PagedResult.fromJson(json, ProductionFinishedInboundTask.fromJson);
  }

  Future<int> pendingCount() async {
    final json = await api.get(ApiEndpoints.productionFinishedInboundTaskCount);
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  Future<({int confirmedCount, bool replay, Set<String> confirmedDocumentIds})>
  confirmAll({
    required List<String> documentIds,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.productionFinishedInboundBatchConfirm,
      body: {'documentIds': documentIds, 'idempotencyKey': idempotencyKey},
    );
    final items = (json['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final confirmedDocumentIds = <String>{
      for (final item in items)
        if (item['documentId']?.toString().isNotEmpty == true)
          item['documentId'].toString(),
    };
    return (
      confirmedCount: (json['confirmedCount'] as num?)?.toInt() ?? items.length,
      replay: json['replay'] == true,
      confirmedDocumentIds: confirmedDocumentIds,
    );
  }

  Future<ProductionFinishedArrivalRegistration> arrivalRegistration(
    String reportId,
  ) async {
    final json = await api.get(
      ApiEndpoints.productionFinishedArrivalRegistration(reportId),
    );
    return ProductionFinishedArrivalRegistration.fromJson(json);
  }

  Future<List<ProductionFinishedPlaceSuggestion>> placeSuggestions(
    String reportId, {
    required String warehouseId,
  }) async {
    final json = await api.get(
      ApiEndpoints.productionFinishedArrivalPlaceSuggestions(reportId),
      query: {'warehouseId': warehouseId},
    );
    return (json['items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionFinishedPlaceSuggestion.fromJson)
            .toList(growable: false) ??
        const [];
  }

  Future<ProductionFinishedArrivalRegistration> saveArrivalRegistration(
    String reportId,
    Map<String, dynamic> body,
  ) async {
    final json = await api.post(
      ApiEndpoints.productionFinishedArrivalRegistration(reportId),
      body: body,
    );
    return ProductionFinishedArrivalRegistration.fromJson(json);
  }

  Future<ProductionFinishedRememberPlacesResult> rememberPlaces(
    String reportId,
  ) async {
    final json = await api.post(
      ApiEndpoints.productionFinishedArrivalRememberPlaces(reportId),
    );
    return ProductionFinishedRememberPlacesResult.fromJson(json);
  }

  /// 多报工单汇总登记：一次拉取多张待登记报工的明细（已登记的按只读带回）。
  Future<List<ProductionFinishedArrivalRegistration>> batchArrivalRegistrations(
    List<String> reportIds,
  ) async {
    final rows = await api.getList(
      ApiEndpoints.productionFinishedArrivalBatchBase,
      query: {'reportIds': reportIds.join(',')},
    );
    return rows
        .map(ProductionFinishedArrivalRegistration.fromJson)
        .toList(growable: false);
  }

  /// 多报工单同仓库位建议（一次请求合并全部行的建议）。
  Future<List<ProductionFinishedPlaceSuggestion>> batchPlaceSuggestions({
    required List<String> reportIds,
    required String warehouseId,
  }) async {
    final json = await api.get(
      ApiEndpoints.productionFinishedArrivalBatchPlaceSuggestions,
      query: {'reportIds': reportIds.join(','), 'warehouseId': warehouseId},
    );
    return (json['items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionFinishedPlaceSuggestion.fromJson)
            .toList(growable: false) ??
        const [];
  }

  /// 一次提交逐单 FQC：reports = [{reportId, warehouseId, items:[{reportItemId, place}]}]。
  Future<ProductionFinishedBatchRegistrationResult>
  saveArrivalRegistrationBatch(Map<String, dynamic> body) async {
    final json = await api.post(
      ApiEndpoints.productionFinishedArrivalBatchBase,
      body: body,
    );
    return ProductionFinishedBatchRegistrationResult.fromJson(json);
  }

  /// 批量登记后的库位记忆（逐单聚合 remembered/unchanged/ambiguous 与告警）。
  Future<ProductionFinishedRememberPlacesResult> rememberPlacesBatch(
    List<String> reportIds,
  ) async {
    final json = await api.post(
      ApiEndpoints.productionFinishedArrivalBatchRememberPlaces,
      body: reportIds,
    );
    return ProductionFinishedRememberPlacesResult.fromJson(json);
  }

  /// 当前用户最近一次成品送检登记所用成品仓（无历史/空响应返回 null）。
  Future<ProductionFinishedLastWarehouse?> lastArrivalWarehouse() async {
    try {
      final json = await api.get(
        ApiEndpoints.productionFinishedArrivalLastWarehouse,
      );
      if (json.isEmpty) return null;
      return ProductionFinishedLastWarehouse.fromJson(json);
    } catch (_) {
      // 上次仓记忆是锦上添花：拉取失败不阻断登记，仅不预选。
      return null;
    }
  }
}

final productionFinishedInboundTaskRepositoryProvider =
    Provider<ProductionFinishedInboundTaskRepository>(
      (ref) =>
          ProductionFinishedInboundTaskRepository(ref.watch(apiClientProvider)),
    );

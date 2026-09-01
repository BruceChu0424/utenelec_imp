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
}

final productionFinishedInboundTaskRepositoryProvider =
    Provider<ProductionFinishedInboundTaskRepository>(
      (ref) =>
          ProductionFinishedInboundTaskRepository(ref.watch(apiClientProvider)),
    );

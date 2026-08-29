import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_fqc_replenishment_task.dart';

class ProductionFqcReplenishmentRepository {
  const ProductionFqcReplenishmentRepository(this.api);

  final ApiClient api;

  Future<PagedResult<ProductionFqcReplenishmentTask>> pending({
    int page = 1,
    int size = 40,
  }) async {
    final json = await api.get(
      ApiEndpoints.productionQualityReplenishments,
      query: {'page': page, 'size': size},
    );
    return PagedResult.fromJson(json, ProductionFqcReplenishmentTask.fromJson);
  }

  Future<PagedResult<ProductionFqcReplenishmentMaterialTask>> materialTasks({
    int page = 1,
    int size = 40,
  }) async {
    final json = await api.get(
      ApiEndpoints.productionQualityReplenishmentMaterialTasks,
      query: {'page': page, 'size': size},
    );
    return PagedResult.fromJson(
      json,
      ProductionFqcReplenishmentMaterialTask.fromJson,
    );
  }

  Future<int> materialTaskCount() async {
    final json = await api.get(
      ApiEndpoints.productionQualityReplenishmentMaterialTaskCount,
    );
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  Future<ProductionFqcReplenishmentTask> createMaterialAnalysis(
    String authorizationId,
  ) async {
    final json = await api.post(
      '${ApiEndpoints.productionQualityReplenishments}/'
      '${Uri.encodeComponent(authorizationId)}/material-analysis',
    );
    return ProductionFqcReplenishmentTask.fromJson(json);
  }

  Future<ProductionFqcReplenishmentMaterialTask> confirmMaterial({
    required String authorizationId,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      '${ApiEndpoints.productionQualityReplenishments}/'
      '${Uri.encodeComponent(authorizationId)}/material-confirmations',
      body: {'idempotencyKey': idempotencyKey},
    );
    return ProductionFqcReplenishmentMaterialTask.fromJson(json);
  }
}

final productionFqcReplenishmentRepositoryProvider =
    Provider<ProductionFqcReplenishmentRepository>(
      (ref) =>
          ProductionFqcReplenishmentRepository(ref.watch(apiClientProvider)),
    );

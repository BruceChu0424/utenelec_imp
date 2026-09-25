import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/production_material_discovery.dart';

class ProductionMaterialDiscoveryRepository {
  const ProductionMaterialDiscoveryRepository(this.api);
  final ApiClient api;
  static const path = '/production/material-discovery';

  Future<ProductionMaterialDiscoveryDetail> detail(String id) async =>
      ProductionMaterialDiscoveryDetail.fromJson(
        Map<String, dynamic>.from(await api.get('$path/requests/$id') as Map),
      );

  Future<ProductionMaterialDiscoveryDetail> configure({
    required String id,
    required int version,
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
  }) async => ProductionMaterialDiscoveryDetail.fromJson(
    Map<String, dynamic>.from(
      await api.post(
            '$path/requests/$id/materials',
            body: {
              'expectedVersion': version,
              'idempotencyKey': idempotencyKey,
              'items': items,
            },
          )
          as Map,
    ),
  );
}

final productionMaterialDiscoveryRepositoryProvider =
    Provider<ProductionMaterialDiscoveryRepository>(
      (ref) =>
          ProductionMaterialDiscoveryRepository(ref.watch(apiClientProvider)),
    );

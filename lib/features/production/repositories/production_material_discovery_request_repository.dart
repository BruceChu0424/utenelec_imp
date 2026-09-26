import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/idempotency_key.dart';

class ProductionMaterialDiscoveryRequestRepository {
  const ProductionMaterialDiscoveryRequestRepository(this.api);
  final ApiClient api;

  Future<void> cancel(String requestId) async {
    final result = Map<String, dynamic>.from(
      await api.get('/production/material-discovery/requests/$requestId')
          as Map,
    );
    final version = (result['version'] as num).toInt();
    if (result['status'] == 'CANCELLED') return;
    await api.post(
      '/production/material-discovery/requests/$requestId/cancel',
      body: {
        'expectedVersion': version,
        'idempotencyKey': businessIdempotencyKey(
          'discovery-cancel',
          '$requestId:$version',
        ),
      },
    );
  }

  Future<void> request(
    String segmentId,
    int expectedVersion,
    String idempotencyKey,
  ) async {
    await api.post(
      '/production/material-discovery/segments/$segmentId/request',
      body: {
        'expectedVersion': expectedVersion,
        'idempotencyKey': idempotencyKey,
      },
    );
  }
}

final productionMaterialDiscoveryRequestRepositoryProvider =
    Provider<ProductionMaterialDiscoveryRequestRepository>(
      (ref) => ProductionMaterialDiscoveryRequestRepository(
        ref.watch(apiClientProvider),
      ),
    );

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/production_execution_batch.dart';

class ProductionExecutionBatchRepository {
  ProductionExecutionBatchRepository(this._api);
  final ApiClient _api;

  Future<ProductionExecutionBatchPreview> preview({
    required String segmentId,
    int? expectedVersion,
    double? quantity,
  }) async => ProductionExecutionBatchPreview.fromJson(
    await _api.post(
      '/production/execution-batches/preview',
      body: {
        'segmentId': segmentId,
        'expectedVersion': ?expectedVersion,
        'quantity': ?quantity,
      },
    ),
  );

  Future<ProductionExecutionBatchResult> submit({
    required ProductionExecutionBatchPreview preview,
    required String idempotencyKey,
  }) async => ProductionExecutionBatchResult.fromJson(
    await _api.post(
      '/production/execution-batches/submit',
      body: {
        'segmentId': preview.segmentId,
        'expectedVersion': preview.expectedVersion,
        'quantity': preview.quantity,
        'previewFingerprint': preview.fingerprint,
        'idempotencyKey': idempotencyKey,
      },
    ),
  );
}

final productionExecutionBatchRepositoryProvider =
    Provider<ProductionExecutionBatchRepository>(
      (ref) => ProductionExecutionBatchRepository(ref.watch(apiClientProvider)),
    );

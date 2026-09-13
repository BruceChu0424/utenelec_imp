import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/production_draw_request.dart';

class ProductionDrawRequestRepository {
  ProductionDrawRequestRepository(this._api);

  static const batchLimit = 50;
  static const _path = '/production/workshop-tasks/draw-request';
  final ApiClient _api;

  /// Read-only preview. Visiting the page never releases work to the warehouse.
  Future<ProductionDrawRequestPreview> preview(
    List<ProductionDrawRequestItem> items,
  ) async => ProductionDrawRequestPreview.fromJson(
    await _api.post(
      '$_path/preview',
      body: {'items': items.map((item) => item.toJson()).toList()},
    ),
  );

  Future<ProductionDrawRequestResult> submit({
    required List<ProductionDrawRequestItem> items,
    required String idempotencyKey,
    required String previewFingerprint,
    List<ProductionDrawRequestSelection>? lines,
  }) async => ProductionDrawRequestResult.fromJson(
    await _api.post(
      '$_path/submit',
      body: {
        'items': items.map((item) => item.toJson()).toList(),
        'idempotencyKey': idempotencyKey,
        'previewFingerprint': previewFingerprint,
        if (lines != null) 'lines': lines.map((line) => line.toJson()).toList(),
      },
    ),
  );
}

final productionDrawRequestRepositoryProvider =
    Provider<ProductionDrawRequestRepository>(
      (ref) => ProductionDrawRequestRepository(ref.watch(apiClientProvider)),
    );

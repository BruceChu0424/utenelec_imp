import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_draw_request.dart';
import 'package:uten_imp/features/production/repositories/production_draw_request_repository.dart';

import 'support/production_draw_request_fixture.dart';

void main() {
  test(
    'partial request retains exact DRAW source UUIDs and quantity',
    () async {
      final requests = <RequestOptions>[];
      await _repository(requests).submit(
        items: const [
          ProductionDrawRequestItem(segmentId: 'a', expectedVersion: 7),
        ],
        idempotencyKey: 'partial-intent',
        previewFingerprint: 'reviewed',
        lines: const [
          ProductionDrawRequestSelection(drawItemId: 'line-a', quantity: 0.25),
        ],
      );
      expect((requests.single.data as Map<String, dynamic>)['lines'], [
        {'drawItemId': 'line-a', 'quantity': 0.25},
      ]);
    },
  );

  test(
    'partial summary uses stable source UUID order and keeps leaf warehouses separate',
    () {
      final json = productionDrawRequestFixture();
      json['lines'] = (json['lines'] as List).reversed.toList();
      final preview = ProductionDrawRequestPreview.fromJson(json);
      expect(
        preview
            .selectionsFor(preview.summaries.first, 4.25)
            .map((line) => line.toJson()),
        [
          {'drawItemId': 'line-a', 'quantity': 3.0},
          {'drawItemId': 'line-b', 'quantity': 1.25},
        ],
      );
      expect(
        preview.selectionsFor(preview.summaries.last, 0.5).single.toJson(),
        {'drawItemId': 'line-c', 'quantity': 0.5},
      );
      expect(
        () => preview.selectionsFor(preview.summaries.first, 8),
        throwsFormatException,
      );
    },
  );
  test(
    'preview is a separate read and carries selected segment versions',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(requests);
      final preview = await repository.preview(const [
        ProductionDrawRequestItem(segmentId: 'a', expectedVersion: 7),
        ProductionDrawRequestItem(segmentId: 'b'),
      ]);

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(
        requests.single.path,
        '/production/workshop-tasks/draw-request/preview',
      );
      expect(requests.single.data, {
        'items': [
          {'segmentId': 'a', 'expectedVersion': 7},
          {'segmentId': 'b'},
        ],
      });
      expect(preview.taskCount, 2);
      expect(preview.tasks.last.expectedVersion, 7);
      expect(preview.requestItems.last.toJson(), {
        'segmentId': 'b',
        'expectedVersion': 7,
      });
      expect(preview.summaries, hasLength(2));
      expect(
        preview.sourcesFor(preview.summaries.first).map((line) => line.qty),
        [3, 4],
      );
      expect(
        preview.sourcesFor(preview.summaries.last).map((line) => line.qty),
        [2],
      );
    },
  );

  test('summary sources match warehouse goods color and unit UUIDs', () {
    final preview = ProductionDrawRequestPreview.fromJson(
      productionDrawRequestFixture(),
    );
    final summary = preview.summaries.first;
    for (final changes in [
      {'warehouseId': 'other-warehouse'},
      {'goodsId': 'other-goods'},
      {'colorId': 'other-color'},
      {'unitId': 'other-unit'},
    ]) {
      final json = Map<String, dynamic>.from(
        (productionDrawRequestFixture()['lines'] as List).first as Map,
      )..addAll(changes);
      expect(
        summary.matches(ProductionDrawRequestLine.fromJson(json)),
        isFalse,
      );
    }
  });

  test(
    'submit carries reviewed fingerprint versions and a stable caller key',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(requests);
      final result = await repository.submit(
        items: const [
          ProductionDrawRequestItem(segmentId: 'a', expectedVersion: 7),
        ],
        idempotencyKey: 'workshop-draw-123',
        previewFingerprint: 'reviewed-fingerprint',
      );

      expect(
        requests.single.path,
        '/production/workshop-tasks/draw-request/submit',
      );
      expect(requests.single.data, {
        'items': [
          {'segmentId': 'a', 'expectedVersion': 7},
        ],
        'idempotencyKey': 'workshop-draw-123',
        'previewFingerprint': 'reviewed-fingerprint',
      });
      expect(result.taskCount, 2);
      expect(result.documentIds, ['draw-a', 'draw-b']);
      expect(result.replayed, isFalse);
    },
  );
}

ProductionDrawRequestRepository _repository(List<RequestOptions> requests) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: request.path.endsWith('/preview')
                ? productionDrawRequestFixture()
                : productionDrawRequestResultFixture,
          ),
        );
      },
    ),
  );
  return ProductionDrawRequestRepository(ApiClient(dio));
}

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/material_aggregate_order.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  test(
    'aggregate transport preserves exact total, public share, CAS and identity bridges',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final preview = request.path.endsWith('/preview');
            handler.resolve(
              Response(
                requestOptions: request,
                data: preview
                    ? {
                        'analysisId': 'a',
                        'version': 4,
                        'fingerprint': 'fp',
                        'previewFingerprint': 'reviewed-exact',
                        'analysis': _analysis,
                        'groups': [
                          {
                            'clientGroupKey': 'same',
                            'goodsId': 'g',
                            'route': 'MAKE',
                            'requestedQty': 3100.0001,
                            'publicExtraQty': 100.0001,
                            'existingBatchId': 'batch',
                            'priorOutputQty': 3,
                            'sources': [
                              for (var i = 0; i < 3; i++)
                                {'materialLineId': 's$i', 'allocatedQty': 1000},
                            ],
                            'sharedBomChildren': [
                              {
                                'goodsId': 'raw',
                                'requiredQty': 0,
                                'relativeBomPath': 'edge-1',
                              },
                            ],
                          },
                        ],
                      }
                    : {
                        'analysis': _analysis,
                        'replayed': true,
                        'batches': <Object>[],
                        'materialIdentityBridges': [
                          {
                            'fromMaterialLineIds': ['old-a', 'old-b'],
                            'toMaterialLineId': 'canonical',
                            'relativeBomPath': 'edge-1',
                            'requiredQty': 1,
                          },
                          {
                            'fromMaterialLineIds': <String>[],
                            'toMaterialLineId': 'extra-responsibility',
                            'relativeBomPath': 'edge-2',
                            'requiredQty': 2,
                          },
                        ],
                      },
              ),
            );
          },
        ),
      );
      final repository = ProductionPlanRepository(ApiClient(dio));
      const request = MaterialAggregateOrderRequest(
        analysisId: 'a',
        version: 4,
        fingerprint: 'fp',
        idempotencyKey: 'exact-command',
        warehouseId: 'wh',
        billDate: '2026-09-25',
        groups: [
          MaterialAggregateOrderGroupInput(
            clientGroupKey: 'same',
            materialLineIds: ['s0', 's1', 's2'],
            route: MaterialSupplyRoute.make,
            qty: '3100.0001',
            allowPublicExtra: true,
            allowedOverproductionRate: 0,
          ),
        ],
      );
      final preview = await repository.previewAggregateOrders(request);
      expect(
        requests.single.path,
        '/production/material-analyses/a/aggregate-orders/preview',
      );
      expect(
        (((requests.single.data as Map)['groups'] as List).single
            as Map)['qty'],
        '3100.0001',
      );
      expect(
        (((requests.single.data as Map)['groups'] as List).single
            as Map)['allowedOverproductionRate'],
        0,
      );
      expect(
        (requests.single.data as Map).containsKey('previewFingerprint'),
        false,
      );
      expect(
        preview.groups.single.sources.map((source) => source.allocatedQty),
        [1000, 1000, 1000],
      );
      expect(preview.groups.single.publicExtraQty, 100.0001);
      expect(preview.groups.single.existingBatchId, 'batch');
      expect(preview.groups.single.priorOutputQty, 3);
      expect(preview.groups.single.sharedBomChildren.single.requiredQty, 0);
      final result = await repository.submitAggregateOrders(
        request,
        previewFingerprint: preview.previewFingerprint,
      );
      expect(
        requests.last.path,
        '/production/material-analyses/a/aggregate-orders/submit',
      );
      expect(requests.last.data, {
        ...request.toJson(),
        'previewFingerprint': 'reviewed-exact',
      });
      expect(result.replayed, true);
      expect(result.materialIdentityBridges.first.fromMaterialLineIds, [
        'old-a',
        'old-b',
      ]);
      expect(result.materialIdentityBridges.last.fromMaterialLineIds, isEmpty);
      expect(
        result.materialIdentityBridges.last.toMaterialLineId,
        'extra-responsibility',
      );
    },
  );
}

const _analysis = <String, dynamic>{
  'analysisId': 'a',
  'version': 4,
  'fingerprint': 'fp',
  'warehouseId': 'wh',
  'status': 'ACTIVE',
  'products': <Object>[],
  'flatMaterials': <Object>[],
  'allowedActions': <String>[],
};

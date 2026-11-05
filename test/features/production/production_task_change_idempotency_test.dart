import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_material_increment_repository.dart';
import 'package:uten_imp/features/production/repositories/production_overproduction_rate_repository.dart';

void main() {
  test(
    'same tolerance command retries once, identical returned proposal can be resubmitted',
    () async {
      final api = _RecordingApi();
      final repository = ProductionOverproductionRateRepository(api);
      final first = ProductionOverproductionRateContext({
        'segmentId': 'segment',
        'rateVersion': 0,
        'requestGeneration': 0,
      });
      await repository.submit(first, .15, '本批工艺要求');
      await repository.submit(first, .15, '本批工艺要求');
      await repository.submit(
        ProductionOverproductionRateContext({
          ...first.data,
          'requestGeneration': 1,
        }),
        .15,
        '本批工艺要求',
      );
      expect(api.keys[0], api.keys[1]);
      expect(api.keys[2], isNot(api.keys[0]));
      expect(api.bodies.map((body) => body['expectedRateVersion']), [0, 0, 0]);
    },
  );

  test(
    'another legitimate same quantity material increment does not replay an earlier approval',
    () async {
      final api = _RecordingApi();
      final repository = ProductionMaterialIncrementRepository(api);
      final context = ProductionMaterialIncrementContext({
        'segmentId': 'segment',
      });
      final first = <String, dynamic>{
        'originalDemandId': 'demand',
        'lockVersion': 5,
        'requestGeneration': 0,
        'approvedIncrementQty': 0,
      };
      await repository.submit(
        context: context,
        demand: first,
        deltaQty: 30,
        reason: '本批实际追加用料',
      );
      await repository.submit(
        context: context,
        demand: first,
        deltaQty: 30,
        reason: '本批实际追加用料',
      );
      await repository.submit(
        context: context,
        demand: {...first, 'requestGeneration': 1, 'approvedIncrementQty': 30},
        deltaQty: 30,
        reason: '本批实际追加用料',
      );
      expect(api.keys[0], api.keys[1]);
      expect(api.keys[2], isNot(api.keys[0]));
      expect(api.bodies.map((body) => body['deltaQty']), [30, 30, 30]);
      expect(api.bodies.map((body) => body['expectedDemandVersion']), [
        5,
        5,
        5,
      ]);
    },
  );

  test(
    'batch material commands preserve exact text and validate every returned source',
    () async {
      final api = _RecordingApi();
      final repository = ProductionMaterialIncrementRepository(api);
      final context = ProductionMaterialIncrementContext({
        'segmentId': 'segment',
      });
      final commands = [
        for (final item in [
          ('demand-a', '99999999999999.9999'),
          ('demand-b', '0.0001'),
        ])
          repository.submissionBody(
            context: context,
            demand: {
              'originalDemandId': item.$1,
              'lockVersion': 5,
              'requestGeneration': 0,
              'approvedIncrementQty': 0,
            },
            deltaQty: item.$2,
            reason: '按材料分别申请实际追加',
          ),
      ];
      final first = await repository.submitBatch(commands);
      await repository.submitBatch(commands.reversed.toList());
      expect(first.map((row) => row.originalDemandId), [
        'demand-a',
        'demand-b',
      ]);
      final body = (api.bodies.first['requests'] as List)
          .cast<Map<String, dynamic>>();
      expect(body.map((row) => row['deltaQty']), [
        '99999999999999.9999',
        '0.0001',
      ]);
      expect((api.bodies.last['requests'] as List).reversed.toList(), body);
      api.corruptBatchReceipt = true;
      await expectLater(
        repository.submitBatch(commands),
        throwsFormatException,
      );
    },
  );
}

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(Dio());
  final bodies = <Map<String, dynamic>>[];
  bool corruptBatchReceipt = false;
  List<String> get keys =>
      bodies.map((body) => body['idempotencyKey'] as String).toList();
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    bodies.add(Map<String, dynamic>.from(body! as Map));
    if (path.endsWith('/batch')) {
      return {
        'requests': [
          for (final command
              in ((body as Map)['requests'] as List)
                  .cast<Map<String, dynamic>>())
            {
              'id': 'request-${command['originalDemandId']}',
              'originalDemandId': corruptBatchReceipt
                  ? 'unrelated-demand'
                  : command['originalDemandId'],
              'targetSegmentId': command['targetSegmentId'],
              'deltaQty': command['deltaQty'],
            },
        ],
      };
    }
    return {'id': 'request'};
  }
}

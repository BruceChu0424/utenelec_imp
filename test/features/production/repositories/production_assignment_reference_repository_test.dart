import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/models/employee_reference.dart';

void main() {
  test(
    'workflow defaults sort 100-ID batches with four one-shot readers',
    () async {
      final requests = <RequestOptions>[];
      var active = 0;
      var maximum = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            requests.add(request);
            active++;
            if (active > maximum) maximum = active;
            await Future<void>.delayed(Duration.zero);
            active--;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: [
                  for (final id
                      in (request.queryParameters['ids'] as String).split(','))
                    {
                      'departmentId': id,
                      'departmentName': '车间',
                      'responsibleEmployeeId': 'worker-$id',
                      'responsibleEmployeeName': '负责人',
                    },
                  {
                    'departmentId': 'not-requested',
                    'responsibleEmployeeId': 'must-not-publish',
                  },
                ],
              ),
            );
          },
        ),
      );
      final ids = {
        for (var index = 500; index >= 0; index--)
          'workshop-${index.toString().padLeft(3, '0')}',
      };
      final result = await ProductionPlanRepository(ApiClient(dio))
          .workshopAssignmentDefaults(
            ids,
            purpose: EmployeeReferencePurpose.productionMaterialOwner,
          );
      expect(requests, hasLength(6));
      expect(maximum, greaterThan(1));
      expect(maximum, lessThanOrEqualTo(4));
      expect(
        requests.map((r) => r.path),
        everyElement(ApiEndpoints.productionWorkshopAssignmentDefaults),
      );
      expect(
        requests.map((r) => r.queryParameters['purpose']),
        everyElement('PRODUCTION_MATERIAL_OWNER'),
      );
      expect(
        requests.map((r) => r.receiveTimeout),
        everyElement(const Duration(seconds: 10)),
      );
      expect(
        requests.map((r) => r.extra[safeRequestRetryDisabledKey]),
        everyElement(isTrue),
      );
      expect(
        requests.map(
          (r) => (r.queryParameters['ids'] as String).split(',').length,
        ),
        [100, 100, 100, 100, 100, 1],
      );
      expect(
        requests.expand((r) => (r.queryParameters['ids'] as String).split(',')),
        ids.toList()..sort(),
      );
      expect(result.keys, unorderedEquals(ids));
      expect(result['workshop-000']?.id, 'worker-workshop-000');
      expect(result.containsKey('not-requested'), isFalse);
    },
  );

  test(
    'empty requests do not read and unrelated purposes cannot open production defaults',
    () async {
      final requests = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request.path);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: <Object>[],
              ),
            );
          },
        ),
      );
      final repository = ProductionPlanRepository(ApiClient(dio));
      expect(
        await repository.workshopAssignmentDefaults(
          {},
          purpose: EmployeeReferencePurpose.productionPlanOwner,
        ),
        isEmpty,
      );
      await expectLater(
        repository.workshopAssignmentDefaults({
          'workshop',
        }, purpose: EmployeeReferencePurpose.supplierOwner),
        throwsArgumentError,
      );
      expect(requests, isEmpty);
      await repository.workshopAssignmentDefaults({
        'workshop',
      }, purpose: EmployeeReferencePurpose.productionSegmentOwner);
      expect(requests, [ApiEndpoints.productionWorkshopAssignmentDefaults]);
    },
  );
}

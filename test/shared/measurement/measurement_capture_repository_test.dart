import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/measurement/measurement_capture_profile.dart';
import 'package:uten_imp/shared/measurement/measurement_capture_repository.dart';

const firstGoodsId = '11111111-1111-4111-8111-111111111111';
const secondGoodsId = '22222222-2222-4222-8222-222222222222';
const businessUnitId = '33333333-3333-4333-8333-333333333333';
const weightUnitId = '44444444-4444-4444-8444-444444444444';
const commandId = '55555555-5555-4555-8555-555555555555';

Map<String, dynamic> profileJson(
  String goodsId, {
  String status = 'UNCLASSIFIED',
  String primaryInput = 'BUSINESS_QUANTITY',
  String secondaryPolicy = 'OFFERED',
  String? actualWeightUnitId,
}) => {
  'goodsId': goodsId,
  'operationFamily': 'WAREHOUSE',
  'status': status,
  'primaryInput': primaryInput,
  'secondaryPolicy': secondaryPolicy,
  'businessUnitId': businessUnitId,
  'businessUnitName': '个',
  'actualWeightUnitId': ?actualWeightUnitId,
  if (actualWeightUnitId != null) 'actualWeightUnitName': 'kg',
  'confidence': 0.75,
  'activeEvidenceCount': 4,
  'version': 2,
};

void main() {
  test('batch key deduplicates and sorts UUIDs for provider caching', () {
    final left = MeasurementProfileBatchRequest(
      operationFamily: OperationFamily.warehouse,
      goodsIds: const [secondGoodsId, firstGoodsId, firstGoodsId],
    );
    final right = MeasurementProfileBatchRequest(
      operationFamily: OperationFamily.warehouse,
      goodsIds: const [firstGoodsId, secondGoodsId],
    );

    expect(left.goodsIds, const [firstGoodsId, secondGoodsId]);
    expect(left, right);
    expect(left.hashCode, right.hashCode);
  });

  test('resolve uses one POST and validates every returned identity', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: {
                'items': [
                  profileJson(secondGoodsId, status: 'PROVISIONAL'),
                  profileJson(firstGoodsId),
                ],
              },
            ),
          );
        },
      ),
    );
    final repository = DioMeasurementCaptureRepository(ApiClient(dio));
    final request = MeasurementProfileBatchRequest(
      operationFamily: OperationFamily.warehouse,
      goodsIds: const [secondGoodsId, firstGoodsId],
    );

    final profiles = await repository.resolveBatch(request);

    expect(captured.method, 'POST');
    expect(captured.uri.path, '/api/measurement/profiles/resolve-batch');
    expect(captured.data, {
      'operationFamily': 'WAREHOUSE',
      'goodsIds': const [firstGoodsId, secondGoodsId],
    });
    expect(profiles.keys, const [firstGoodsId, secondGoodsId]);
    expect(profiles[secondGoodsId]!.status, Status.provisional);
    expect(profiles[secondGoodsId]!.evidenceCount, 4);
    expect(profiles[secondGoodsId]!.confidence, 0.75);
  });

  test('incomplete batch fails closed instead of guessing defaults', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: {
              'items': [profileJson(firstGoodsId)],
            },
          ),
        ),
      ),
    );
    final repository = DioMeasurementCaptureRepository(ApiClient(dio));

    expect(
      repository.resolveBatch(
        MeasurementProfileBatchRequest(
          operationFamily: OperationFamily.warehouse,
          goodsIds: const [firstGoodsId, secondGoodsId],
        ),
      ),
      throwsFormatException,
    );
  });

  test('override sends stable storage code and explicit weight unit', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: profileJson(
                firstGoodsId,
                status: 'MANUAL_OVERRIDE',
                primaryInput: 'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT',
                secondaryPolicy: 'VISIBLE',
                actualWeightUnitId: weightUnitId,
              ),
            ),
          );
        },
      ),
    );
    final repository = DioMeasurementCaptureRepository(ApiClient(dio));

    final profile = await repository.overridePreference(
      goodsId: firstGoodsId,
      operationFamily: OperationFamily.warehouse,
      commandId: commandId,
      idempotencyKey: 'measurement-command-001',
      expectedVersion: 2,
      primaryInput: PrimaryInput.businessQuantityAndActualWeight,
      reason: '负责人确认仓库场景同时登记数量和重量',
      actualWeightUnitId: weightUnitId,
    );

    expect(
      captured.uri.path,
      '/api/measurement/profiles/$firstGoodsId/WAREHOUSE/override',
    );
    expect(
      (captured.data as Map<String, dynamic>)['preference'],
      'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT',
    );
    expect(
      (captured.data as Map<String, dynamic>)['actualWeightUnitId'],
      weightUnitId,
    );
    expect(profile.status, Status.manualOverride);
    expect(profile.actualWeightUnitId, weightUnitId);
  });
}

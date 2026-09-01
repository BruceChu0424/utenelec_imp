import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/measurement_capture_profile.dart';

const goodsId = '11111111-1111-4111-8111-111111111111';
const businessUnitId = '22222222-2222-4222-8222-222222222222';
const weightUnitId = '33333333-3333-4333-8333-333333333333';
const profileId = '44444444-4444-4444-8444-444444444444';

void main() {
  test('capture modes never replace business quantity with weight only', () {
    expect(PrimaryInput.values, hasLength(2));
    expect(
      PrimaryInput.values,
      containsAll(<PrimaryInput>[
        PrimaryInput.businessQuantity,
        PrimaryInput.businessQuantityAndActualWeight,
      ]),
    );
  });

  test('offered weight can wait for a unit but visible input cannot', () {
    final offered = MeasurementCaptureProfile(
      goodsId: goodsId,
      operationFamily: OperationFamily.warehouse,
      status: Status.unknown,
      primaryInput: PrimaryInput.businessQuantity,
      secondaryPolicy: SecondaryPolicy.offered,
      businessUnitId: businessUnitId,
    );
    expect(offered.actualWeightUnitId, isNull);

    expect(
      () => MeasurementCaptureProfile(
        goodsId: goodsId,
        operationFamily: OperationFamily.warehouse,
        status: Status.unknown,
        primaryInput: PrimaryInput.businessQuantity,
        secondaryPolicy: SecondaryPolicy.visible,
        businessUnitId: businessUnitId,
      ),
      throwsArgumentError,
    );
    expect(
      () => MeasurementCaptureProfile(
        goodsId: goodsId,
        operationFamily: OperationFamily.warehouse,
        status: Status.unknown,
        primaryInput: PrimaryInput.businessQuantity,
        secondaryPolicy: SecondaryPolicy.offered,
        businessUnitId: businessUnitId,
        actualWeightUnitName: 'kg',
      ),
      throwsArgumentError,
    );
  });

  test('quantity plus actual weight must expose both facts', () {
    expect(
      () => MeasurementCaptureProfile(
        goodsId: goodsId,
        operationFamily: OperationFamily.purchase,
        status: Status.confirmed,
        primaryInput: PrimaryInput.businessQuantityAndActualWeight,
        secondaryPolicy: SecondaryPolicy.hidden,
        businessUnitId: businessUnitId,
        actualWeightUnitId: weightUnitId,
      ),
      throwsArgumentError,
    );
  });

  test('JSON round trip retains UUID authority and learning evidence', () {
    final profile = MeasurementCaptureProfile.fromJson(const {
      'profileId': profileId,
      'goodsId': goodsId,
      'operationFamily': 'PURCHASE',
      'status': 'MANUAL_OVERRIDE',
      'primaryInput': 'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT',
      'secondaryPolicy': 'VISIBLE',
      'businessUnitId': businessUnitId,
      'businessUnitName': '个',
      'actualWeightUnitId': weightUnitId,
      'actualWeightUnitName': 'kg',
      'version': 7,
      'activeEvidenceCount': 4,
      'confidence': 0.875,
      'evidenceSummary': '最近 4 张已审核单据',
    });

    expect(profile.operationFamily, OperationFamily.purchase);
    expect(profile.status, Status.manualOverride);
    expect(profile.capturesActualWeight, isTrue);
    expect(profile.statusLabel, '人工设置');
    expect(profile.identityKey, 'PURCHASE|$goodsId');
    expect(profile.toJson(), containsPair('actualWeightUnitId', weightUnitId));
    expect(profile.toJson(), containsPair('version', 7));
    expect(profile.evidenceCount, 4);
    expect(profile.confidence, 0.875);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/measurement_capture_profile.dart';
import 'package:uten_imp/shared/measurement/uten_adaptive_measurement_input.dart';

const goodsId = '11111111-1111-4111-8111-111111111111';
const businessUnitId = '22222222-2222-4222-8222-222222222222';
const weightUnitId = '33333333-3333-4333-8333-333333333333';

MeasurementCaptureProfile profile({
  Status status = Status.unknown,
  PrimaryInput primaryInput = PrimaryInput.businessQuantity,
  SecondaryPolicy secondaryPolicy = SecondaryPolicy.offered,
  int evidenceCount = 0,
  bool hasWeightUnit = true,
}) => MeasurementCaptureProfile(
  goodsId: goodsId,
  operationFamily: OperationFamily.warehouse,
  status: status,
  primaryInput: primaryInput,
  secondaryPolicy: secondaryPolicy,
  businessUnitId: businessUnitId,
  businessUnitName: '个',
  actualWeightUnitId:
      secondaryPolicy == SecondaryPolicy.hidden || !hasWeightUnit
      ? null
      : weightUnitId,
  actualWeightUnitName:
      secondaryPolicy == SecondaryPolicy.hidden || !hasWeightUnit ? null : 'kg',
  evidenceCount: evidenceCount,
);

Widget app(
  MeasurementCaptureRowState state, {
  VoidCallback? onConflictAction,
  VoidCallback? onEvidenceAction,
  VoidCallback? onSelectActualWeightUnit,
  double width = 720,
  double textScale = 1,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              child: UtenAdaptiveMeasurementInput(
                state: state,
                itemLabel: '铜材',
                onConflictAction: onConflictAction,
                onEvidenceAction: onEvidenceAction,
                onSelectActualWeightUnit: onSelectActualWeightUnit,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'unknown mode shows one primary input and a 44dp supplement action',
    (tester) async {
      final state = MeasurementCaptureRowState(profile: profile());
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));

      expect(
        find.byKey(const Key('measurement-business-quantity')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('measurement-actual-weight')), findsNothing);
      final addWeight = find.byKey(const Key('measurement-add-weight'));
      expect(addWeight, findsOneWidget);
      expect(tester.getSize(addWeight).height, greaterThanOrEqualTo(44));

      await tester.tap(addWeight);
      await tester.pump();
      expect(
        find.byKey(const Key('measurement-actual-weight')),
        findsOneWidget,
      );
    },
  );

  testWidgets('provisional mode uses text status and a quiet learning hint', (
    tester,
  ) async {
    final state = MeasurementCaptureRowState(
      profile: profile(status: Status.provisional, evidenceCount: 2),
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(app(state));

    expect(find.text('暂定'), findsOneWidget);
    expect(find.textContaining('已有 2 条依据'), findsOneWidget);
    expect(find.byKey(const Key('measurement-actual-weight')), findsNothing);
  });

  testWidgets(
    'unknown weight unit must be selected before weight input appears',
    (tester) async {
      var unitSelectionTapped = false;
      final state = MeasurementCaptureRowState(
        profile: profile(hasWeightUnit: false),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(
        app(
          state,
          onSelectActualWeightUnit: () => unitSelectionTapped = true,
          width: 375,
          textScale: 2,
        ),
      );

      await tester.tap(find.byKey(const Key('measurement-add-weight')));
      await tester.pump();

      expect(find.byKey(const Key('measurement-actual-weight')), findsNothing);
      final selectUnit = find.byKey(
        const Key('measurement-select-weight-unit'),
      );
      expect(selectUnit, findsOneWidget);
      expect(tester.getSize(selectUnit).height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);

      await tester.tap(selectUnit);
      expect(unitSelectionTapped, isTrue);

      state.updateProfile(profile());
      await tester.pump();
      expect(
        find.byKey(const Key('measurement-actual-weight')),
        findsOneWidget,
      );
    },
  );

  testWidgets('confirmed dual mode shows quantity and actual weight', (
    tester,
  ) async {
    final state = MeasurementCaptureRowState(
      profile: profile(
        status: Status.confirmed,
        primaryInput: PrimaryInput.businessQuantityAndActualWeight,
        secondaryPolicy: SecondaryPolicy.visible,
      ),
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(app(state));

    expect(find.text('已确定'), findsOneWidget);
    expect(
      find.byKey(const Key('measurement-business-quantity')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('measurement-actual-weight')), findsOneWidget);
  });

  testWidgets('conflict and manual override are announced with text', (
    tester,
  ) async {
    var conflictTapped = false;
    final conflict = MeasurementCaptureRowState(
      profile: profile(status: Status.conflict),
    );
    addTearDown(conflict.dispose);
    await tester.pumpWidget(
      app(conflict, onConflictAction: () => conflictTapped = true),
    );
    expect(find.text('计量习惯冲突'), findsOneWidget);
    await tester.tap(find.byKey(const Key('measurement-conflict-action')));
    expect(conflictTapped, isTrue);

    final manual = MeasurementCaptureRowState(
      profile: profile(
        status: Status.manualOverride,
        secondaryPolicy: SecondaryPolicy.hidden,
      ),
    );
    addTearDown(manual.dispose);
    await tester.pumpWidget(app(manual));
    expect(find.text('人工设置'), findsOneWidget);
  });

  testWidgets(
    'profile update never clears values or collapses entered weight',
    (tester) async {
      final state = MeasurementCaptureRowState(profile: profile());
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.enterText(
        find.byKey(const Key('measurement-business-quantity')),
        '46010',
      );
      await tester.tap(find.byKey(const Key('measurement-add-weight')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('measurement-actual-weight')),
        '136.4',
      );

      state.updateProfile(
        profile(
          status: Status.confirmed,
          secondaryPolicy: SecondaryPolicy.hidden,
        ),
      );
      await tester.pump();

      expect(state.businessQuantityController.text, '46010');
      expect(state.actualWeightController.text, '136.4');
      expect(
        find.byKey(const Key('measurement-actual-weight')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    '375px at 200 percent text scale stacks fields without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(375, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final state = MeasurementCaptureRowState(
        profile: profile(
          status: Status.confirmed,
          primaryInput: PrimaryInput.businessQuantityAndActualWeight,
          secondaryPolicy: SecondaryPolicy.visible,
        ),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state, width: 375, textScale: 2));

      final quantity = find.byKey(const Key('measurement-business-quantity'));
      final weight = find.byKey(const Key('measurement-actual-weight'));
      expect(
        tester.getTopLeft(weight).dy,
        greaterThan(tester.getTopLeft(quantity).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('semantics expose item, units and disclosure action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final state = MeasurementCaptureRowState(profile: profile());
    addTearDown(state.dispose);
    try {
      await tester.pumpWidget(app(state));

      expect(find.bySemanticsLabel(RegExp('铜材.*业务量单位个')), findsOneWidget);
      expect(find.bySemanticsLabel('铜材，补充实际重量'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });
}
